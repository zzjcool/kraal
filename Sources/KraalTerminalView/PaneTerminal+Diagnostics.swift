// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import AppKit
import Foundation
import GhosttyTerminal
import KraalProtocol
import KraalUI

/// Diagnostics for a frame that does not fit the grid Ghostty derived.
///
/// Kept out of `PaneTerminal.swift` only because that file is at its length
/// budget; the reasoning for what is logged lives with the code below.
extension PaneTerminalModel {
    /// Records a grid that disagrees with the frame the daemon sent.
    ///
    /// `ghostty=WxH` alone cannot say *why* it disagreed: "one row short" is what a
    /// view half a point too small produces (Ghostty floors `pixels / cellPixels`,
    /// so it drops the partial row), and it is also what a stale grid shows before
    /// it has re-measured. Those need opposite fixes, and only the pixel numbers
    /// distinguish them — so they are logged next to the rows. `cell=0x0` means
    /// `surfaceSize` carried no usable metric, which is a third case.
    func logGridMismatch(
        grid: TerminalGridMetrics,
        frame: FrameData,
        surface: PaneSurfaceFrame
    ) {
        let all = surface.panes.map {
            "\($0.paneId)=\($0.innerRect.width)x\($0.innerRect.height)"
        }
        let cellHeight = grid.cellHeightPixels
        let measured = "\(grid.widthPixels)x\(grid.heightPixels)px"
            + " cell=\(grid.cellWidthPixels)x\(cellHeight)"
            + " fits=\(cellHeight > 0 ? Int(grid.heightPixels / cellHeight) : -1)"
        kraalLog("grid mismatch: pane=\(paneId) ghostty=\(grid.columns)x\(grid.rows) "
            + "frame=\(frame.width)x\(frame.height) "
            + "\(measured) "
            + "surface=\(surface.frame.width)x\(surface.frame.height) "
            + "panes=[\(all.joined(separator: " "))]")
    }

    /// Records that a parked frame was thrown away because its grid never matched.
    ///
    /// This is the difference between "the band went away on its own" and "the band
    /// was never repainted". A park lives 12 attempts x 80 ms; when it expires, the
    /// frame that would have covered the missing row is gone and only a later daemon
    /// revision repaints it — which on a still screen can be seconds. The user
    /// reports exactly that ("it fixes itself after a while"), so without this line
    /// the two causes are indistinguishable from the outside.
    func logParkExpired(paneId: String, frame: FrameData, grid: TerminalGridMetrics?) {
        let gridText = grid.map { "\($0.columns)x\($0.rows)" } ?? "nil"
        kraalLog("park expired: pane=\(paneId) frame=\(frame.width)x\(frame.height) "
            + "grid=\(gridText) after=\(Self.pendingRetryAttempts)")
    }

    /// Whether a parked frame can be written to a grid of this size.
    ///
    /// Equal is the ordinary case. A grid *larger* than the frame is also safe:
    /// every cell the frame has a coordinate for lands where it belongs, and the
    /// rows beyond it cannot be addressed anyway. Only a grid too *small* would
    /// wrap the rows that do not fit, so that one keeps waiting.
    ///
    /// Requiring exact equality here was a real defect rather than a conservative
    /// choice. Ghostty derives its grid from the NSView's `bounds`, which SwiftUI
    /// applies one layout pass after the frame that asked for it — so while a
    /// window is dragged the two stay one pass apart and equality never holds.
    /// The park then aged out after `pendingRetryAttempts`, and the row the
    /// mismatch left blank survived until the program next printed. Measured on
    /// a live session: at `17:19:26.473` Ghostty still reported the `26.318`
    /// layout (29 rows) while the frame was the `26.471` one (30 rows).
    static func parkedFrameFits(
        frameWidth: Int, frameHeight: Int,
        gridColumns: UInt16, gridRows: UInt16
    ) -> Bool {
        // **Exactly**, not "at least".
        //
        // An earlier revision used `>=` on the theory that a frame whose cells all
        // land on real coordinates cannot be wrong, and that waiting was only
        // costing latency. A live session shows why that is false: the pane's view
        // was 13 rows (240.5 pt) while Ghostty still reported a 14-row grid, so
        // `14 >= 13` allowed a 13-row frame to be written into a 14-row screen.
        // The last row kept whatever the *previous* layout had left there — the
        // band at the bottom that did not go away — and because `frameGrid` was
        // then set to the frame, nothing repainted it later.
        //
        // Waiting costs latency and is recoverable; painting at the wrong height is
        // neither.
        gridColumns == frameWidth && gridRows == frameHeight
    }

    /// Re-runs `apply` for the most recent surface once the terminal's grid has
    /// moved.
    ///
    /// This is the other half of "do not paint at a grid that does not match".
    /// Ghostty measures its grid from the NSView's `bounds`, and SwiftUI applies a
    /// new layout one pass after the frame that caused it — so `apply` routinely
    /// runs against the *previous* size and declines to paint. Something has to
    /// paint once the view has caught up, and this is that something: it re-applies
    /// the same surface against the grid that now exists.
    ///
    /// Without it, refusing to paint at a stale grid would leave the pane blank
    /// until the program next produced output.
    func reapplyAfterGridViewMoved() {
        guard let surface = lastSurface else { return }
        apply(surface: surface)
    }

    func reportCellMetrics() {
        guard let cell = cellMetrics else { return }
        onCellMetrics?(cell)
    }

    /// The renderer's cell size in device pixels, however it can be had.
    ///
    /// `state.surfaceSize` is the direct source, but it stops being republished the
    /// moment the grid holds still — so during a drag the client can be left
    /// dividing by `SurfaceGeometry.fallbackCellPoints` (7.8x17.0 pt) long after
    /// Ghostty measured the real font. That is not a rounding error: at 936 pt wide
    /// the fallback asks for 120 columns where Ghostty fits 110, and the daemon
    /// renders ten columns the view cannot show.
    ///
    /// The view's own pixels divided by the grid it is showing is the same cell, and
    /// both of those are observed rather than published. Used only when the reported
    /// value is missing, so nothing that already worked changes.
    var cellMetrics: CGSize? {
        if let reported = state.surfaceSize,
           reported.cellWidthPixels > 0, reported.cellHeightPixels > 0 {
            return CGSize(
                width: CGFloat(reported.cellWidthPixels),
                height: CGFloat(reported.cellHeightPixels)
            )
        }
        return nil
    }

    /// Whether painting `frame` needs the screen thrown away first.
    ///
    /// Only when the width moved, because a width change reflows every row. A
    /// height change keeps every row's coordinates, and the renderer clears the rows
    /// the new frame no longer covers on its own.
    ///
    /// Static and separate because the caller used to clear the baseline and then
    /// ask whether it was clear: `frameGrid = nil` followed by
    /// `frameGrid == nil ? true : ...` made this always true, so the erase it was
    /// meant to skip happened anyway. That read as correct code and passed every
    /// test, because nothing covered this decision.
    nonisolated static func widthMoved(from previous: FrameData?, to frame: FrameData) -> Bool {
        guard let previous else { return true }
        return previous.width != frame.width
    }
}

/// Logs a pane whose view disagrees with the grid the daemon asked for.
///
/// Only the disagreement, because a drag changes a pane's height at mouse speed and
/// every line here is a synchronous file write on the main thread — measured 562 in
/// one drag, which is itself part of why dragging felt heavy.
func logPaneViewIfMismatched(
    paneId: String,
    size: CGSize,
    cells: SurfaceRect,
    grid: TerminalGridMetrics?,
    viewSize: String
) {
    guard let grid, Int(grid.rows) != Int(cells.height) else { return }
    // `nsview` is the number that decides the argument: the grid comes from
    // `view.bounds`, so a mismatch between `size` (what SwiftUI was asked for) and
    // `nsview` (what the view got) says whether this is a layout problem or a
    // measurement one. Without it the two explanations print identically.
    kraalLog("pane view: \(paneId) size=\(size.width)x\(size.height)pt "
        + "cells=\(cells.width)x\(cells.height) ghostty=\(grid.columns)x\(grid.rows)"
        + " nsview=\(viewSize)")
}

extension PaneTerminalModel {
    /// The grid to lay a frame out in: the view's own measurement where possible.
    ///
    /// `state.surfaceSize` alone is not trustworthy. Ghostty computes the grid in
    /// `surface.setSize` and reports it back through `surface.size()`, which the
    /// engine's IO thread fills in *after* the resize is queued. When a pane's height
    /// settles just as the last of a drag's resizes lands, the coordinator's
    /// `metrics != lastMetrics` guard sees the previous size, logs `sync unchanged`,
    /// and returns without publishing the new one (`TerminalSurfaceCoordinator.swift:
    /// 395-402`). The published value then stays stale indefinitely.
    ///
    /// Measured on a live session: the view settled at `832.5pt`, which at
    /// `cellHeightPixels = 37` is exactly 45 rows, while `surfaceSize` stayed at the
    /// 36 rows reported a moment earlier — and never moved again. `apply` then
    /// refused every frame (each one needed 45), so the pane kept whatever the last
    /// good paint left: the blank area at the bottom, permanent.
    ///
    /// The cell size inside `surfaceSize` is still right — it is a property of the
    /// font, not of the resize — so the honest grid is the view's own pixels divided
    /// by it. That is the same arithmetic Ghostty does, from the same inputs, minus
    /// the round trip that can go stale.
    ///
    /// Falls back to the reported value whenever the view cannot answer, so nothing
    /// that worked before changes behaviour.
    var resolvedGrid: TerminalGridMetrics? {
        if let override = gridOverride { return override }
        guard let reported = state.surfaceSize else { return nil }
        guard let view = state.attachedPlatformView else { return reported }
        let scale = view.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
        let pixelsWide = Int((view.bounds.width * scale).rounded(.down))
        let pixelsHigh = Int((view.bounds.height * scale).rounded(.down))
        guard pixelsWide > 0, pixelsHigh > 0,
              reported.cellWidthPixels > 0, reported.cellHeightPixels > 0
        else { return reported }
        guard let derived = Self.grid(
            forViewPixelsWide: pixelsWide, high: pixelsHigh, cell: reported
        ), derived.columns != reported.columns || derived.rows != reported.rows
        else { return reported }
        // Worth a line: this is the case where the reported grid has gone stale, and
        // it is the only evidence that the workaround was needed at all. Throttled by
        // the fact that it can only fire on a change of the derived value.
        // Once per distinct correction, not once per call: `resolvedGrid` is read on
        // every frame, and a stale grid during a drag would otherwise re-log at mouse
        // speed — the same mistake the `pane view:` line made.
        // Logged only when the corrected size differs from what was on screen, which
        // is a change the pane cannot otherwise explain from the numbers it prints.
        if frameGrid.map({ Int($0.height) != Int(derived.rows) }) ?? true {
            kraalLog("grid from view: pane=\(paneId) reported=\(reported.columns)x\(reported.rows)"
                + " view=\(derived.columns)x\(derived.rows) px=\(pixelsWide)x\(pixelsHigh)")
        }
        return derived
    }

    /// The grid a view of this pixel size implies, given the cell metrics.
    ///
    /// Split out from `resolvedGrid` so the arithmetic is testable without an
    /// `NSView`. It is the same division Ghostty performs; the only thing being
    /// replaced is *where the number comes from*.
    ///
    /// Returns `nil` for a degenerate input rather than a zero grid, so the caller
    /// keeps whatever it had.
    static func grid(
        forViewPixelsWide pixelsWide: Int,
        high pixelsHigh: Int,
        cell: TerminalGridMetrics
    ) -> TerminalGridMetrics? {
        guard pixelsWide > 0, pixelsHigh > 0,
              cell.cellWidthPixels > 0, cell.cellHeightPixels > 0
        else { return nil }
        let columns = UInt16(clamping: pixelsWide / Int(cell.cellWidthPixels))
        let rows = UInt16(clamping: pixelsHigh / Int(cell.cellHeightPixels))
        guard columns > 0, rows > 0 else { return nil }
        return TerminalGridMetrics(
            columns: columns, rows: rows,
            widthPixels: UInt32(clamping: pixelsWide),
            heightPixels: UInt32(clamping: pixelsHigh),
            cellWidthPixels: cell.cellWidthPixels,
            cellHeightPixels: cell.cellHeightPixels
        )
    }
}

extension PaneTerminalModel {
    /// Whether the grid this frame belongs to differs from the last painted one.
    ///
    /// A grid change invalidates the row diff but does **not** need the screen erased:
    /// a pane that got shorter during a vertical drag keeps every row's coordinates.
    /// Conflating the two is what made a settled drag write nothing — measured
    /// `bytes=38`, the cursor sequence with zero cells, repeated for seconds, because
    /// every row compared equal to the frame just painted at the old grid. The rows
    /// the pane no longer covered kept their previous content, which is the blank
    /// area at the bottom.
    nonisolated static func gridMoved(from previous: FrameData?, to frame: FrameData) -> Bool {
        guard let previous else { return true }
        return Int(previous.width) != Int(frame.width)
            || Int(previous.height) != Int(frame.height)
    }
}

extension PaneTerminalModel {
    /// Records the grid a frame was actually laid out in, when it moved.
    ///
    /// `logPaneViewIfMismatched` reports `surfaceSize`, which is the field this
    /// workaround exists because it goes stale — so the log said `ghostty=126x41`
    /// while frames were being laid out at 42. A diagnostic built on a value the
    /// code already distrusts describes a screen nobody drew, and reading it cost
    /// two rounds of chasing the wrong row.
    func logPaintGridIfMoved(paneId: String, from previous: FrameData?, to frame: FrameData) {
        guard let previous, Self.gridMoved(from: previous, to: frame) else { return }
        kraalLog("paint grid: pane=\(paneId) was=\(previous.width)x\(previous.height)"
            + " now=\(frame.width)x\(frame.height)")
    }
}

extension PaneTerminalModel {
    /// Repaints when SwiftUI has handed the terminal a new size.
    ///
    /// The repaint used to hang off `onChange(of: state.surfaceSize)` — the field
    /// this workaround exists because it goes **stale**. Stale means no new value,
    /// no `onChange`, no repaint: a pane that shrank stayed frozen at its old
    /// contents and the rows it stopped covering showed as a blank band. Gating the
    /// cure on the symptom is why three attempts looked right in the logs and
    /// changed nothing on screen.
    ///
    /// A view's frame drives Ghostty's grid on its own path (`setFrameSize` →
    /// `fitToSize`), independently of what `surface.size()` reports back, so this
    /// size cannot go stale for this purpose.
    ///
    /// Cheap when nothing moved: only fires on an actual size change.
    func layoutSettled(size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        guard size != lastLaidOutSize else { return }
        lastLaidOutSize = size
        if let view = state.attachedPlatformView {
            enforceEngineLayerFrame(view: view)
        }
        // Report the cell size on **every** settled layout, not just from `apply`.
        //
        // `reportCellMetrics` ran inside `apply` and read `state.surfaceSize`, which
        // stops being republished once the grid holds still. So the measurement the
        // whole surface negotiation divides by could go unrefreshed, and the client
        // kept using `fallbackCellPoints` (7.8x17.0 pt).
        //
        // Measured on one session: the only correction in the entire log was
        //     [19:25:59.597] cell metrics: (15.6, 34.0) -> (17.0, 37.0)
        // arriving *after* the panes had been asked for 120x34 cells at a size where
        // Ghostty fits 110x31 — 8% on both axes, i.e. ten columns the view could not
        // show and three rows it did not have.
        reportCellMetrics()
        reapplyAfterGridViewMoved()
    }
}

extension PaneTerminalModel {
    /// Says which condition asked for the screen erase.
    ///
    /// Four unrelated conditions all reach `eraseBeforePaint`, and from the log they
    /// look identical: `paint: erase=1` with a constant width. That is why the flash
    /// during a vertical drag survived three attempts — each one removed a reason
    /// and the line did not change, because a different reason was firing.
    /// What this frame needs: wipe the screen, repaint every row, or both.
    struct PaintDecision {
        /// Erase before painting, which also destroys scrollback.
        var erase = false
        /// Write every row again, leaving scrollback alone.
        var repaintAll = false
    }

    func eraseDecision(
        projectionChanged: Bool,
        geometry: PaneSurfacePane
    ) -> PaintDecision {
        let restart = SurfaceGeometry.deltaStreamRestarted(
            previousRevision: lastRevision,
            incomingRevision: geometry.contentRevision
        )
        let currentGrid = Self.paneGrid(geometry)
        // `nil` means "nothing painted yet", which is **not** evidence that the
        // width moved. Reading it as `true` was a self-sustaining loop: the
        // width-mismatch branch below sets `frameGrid = nil` *and*
        // `needsCleanRepaint = true`, so every following frame saw "width moved",
        // erased, and set the flag again. Measured during one startup, eight erases
        // in 53 ms with the daemon grid constant at 120x40 the whole time.
        let widthMoved = frameGrid.map { Int($0.width) != currentGrid.width } ?? false
        // A width change reflows every row, so the baseline is worthless and the
        // scrollback is already meaningless. A **height** change does not: the rows
        // keep their columns, and the renderer clears the rows the frame no longer
        // covers.
        let widthReset = SurfaceGeometry.needsScreenReset(
            deltaStreamRestarted: restart,
            previousGrid: frameGrid.map { (width: Int($0.width), height: Int($0.height)) },
            currentGrid: currentGrid
        )
        // A clean repaint was requested by an earlier frame that could not be painted
        // at a trustworthy grid. That is a width problem by construction: the rows on
        // screen were written at the wrong width.
        var decision = PaintDecision()
        decision.erase = widthReset || needsCleanRepaint
        // A new projection means the cells on screen came from somewhere else, so
        // every row has to be written again — but not necessarily erased. Measured on
        // a live start: `erase why: projection=true widthMoved=false` fired twice
        // while the width never moved, throwing away both panes' scrollback for a
        // repaint that only needed the rows rewritten.
        decision.repaintAll = projectionChanged || decision.erase
        if decision.erase || projectionChanged {
            // Named, because four unrelated conditions all reach the same line and
            // from the log they look identical: `paint: erase=1` with a constant
            // width. Three attempts removed one reason each and the line did not
            // change, because a different reason was firing.
            kraalLog("erase why: \(paneId) projection=\(projectionChanged) restart=\(restart)"
                + " widthMoved=\(widthMoved) clean=\(needsCleanRepaint)"
                + " -> erase=\(decision.erase) repaintAll=\(decision.repaintAll)")
        }
        return decision
    }
}

extension PaneTerminalModel {
    /// Says why a frame was dropped without being painted.
    ///
    /// The `guard` above has five reasons and the log had none of them, so a pane
    /// that stopped updating was indistinguishable from one that had nothing to
    /// update. Measured on a live drag: `surfaceRevision` advanced 65 → 69 while
    /// `wB:p16` produced no `paint:` line at all, and there was no way to tell
    /// whether `apply` was refusing the frame or never receiving it.
    ///
    /// Written only on the drop path, so a working pane stays silent.
    func logSkippedFrame(
        paneId: String,
        revision: UInt64,
        frame: FrameData,
        previous: FrameData?
    ) {
        kraalLog("frame skipped: pane=\(paneId) rev=\(lastRevision)->\(revision)"
            + " frame=\(frame.width)x\(frame.height)"
            + " previous=\(previous.map { "\($0.width)x\($0.height)" } ?? "nil")"
            + " cellsDiffer=\(previous.map { $0.buffer != frame.buffer } ?? false)"
            + " graphicsDiffer=\(previous.map { $0.graphics != frame.graphics } ?? false)")
    }
}

extension PaneTerminalModel {
    /// Compares the three sizes that have to agree for the picture to fill the pane.
    ///
    /// Every diagnostic so far compared the *grid* to the frame, and the grid has been
    /// right while the pane still showed a band of background. The grid says how many
    /// cells to paint; it says nothing about how much of the view the renderer is
    /// allowed to cover. `CAMetalLayer.drawableSize` is that second number, and it is
    /// written in two different places: `updateMetalLayerMetrics` (from
    /// `setFrameSize`/`layout`) and `enforceMetalLayerScale`, which runs on every
    /// post-render and only touches `contentsScale`.
    ///
    /// So a layer whose `drawableSize` is a frame behind its `bounds` renders the old
    /// rectangle and leaves the rest showing the colour underneath — which looks
    /// exactly like empty rows, and which no cell-level assertion can see.
    func logSurfaceExtent(paneId: String, grid: TerminalGridMetrics?, frame: FrameData) {
        guard let view = state.attachedPlatformView else { return }
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let bounds = view.bounds.size
        let layerSize = (view.layer as? CAMetalLayer)?.drawableSize
        let wanted = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        // Only when they disagree: a correct pane stays quiet, and a mismatch prints
        // the numbers that would otherwise have to be inferred.
        guard let layerSize else {
            // `view.layer` is not always a `CAMetalLayer`: the render pipeline swaps it
            // for an IOSurfaceLayer when it composites through IOSurface, and the
            // cached `metalLayer` ivar is then detached from the view tree. Reporting
            // "no CAMetalLayer" and stopping hid the numbers that matter, so describe
            // whatever layer is actually attached.
            let attached = view.layer
            // `type(of:)` on an optional prints `Optional<CALayer>`, which says nothing:
            // what matters is the concrete class behind it (the pipeline swaps the
            // layer for IOSurface-backed compositing).
            let layerName = attached.map { String(describing: type(of: $0)) } ?? "nil"
            kraalLog("surface extent: pane=\(paneId)"
                + " layer=\(layerName)"
                + " bounds=\(bounds.width)x\(bounds.height)pt"
                + " contentsScale=\(attached?.contentsScale ?? -1)"
                + " frame=\(attached?.frame.size.width ?? -1)x\(attached?.frame.size.height ?? -1)"
                + " wants=\(wanted.width)x\(wanted.height)px")
            return
        }
        // The grid says how many cells to paint; it says nothing about how much of the
        // view those cells cover. A pane covering `rows * cellHeight` while its own
        // bounds are taller leaves the difference showing whatever is underneath —
        // identical to an empty row, invisible to every cell-level assertion. Reported
        // even when the layer agrees, because this is the one comparison that does not
        // need the layer at all.
        let covered = CGFloat(frame.height) * CGFloat(grid?.cellHeightPixels ?? 0) / scale
        let gap = bounds.height - covered
        if gap > 0.5 {
            kraalLog("surface extent: pane=\(paneId) short by \(gap)pt"
                + " bounds=\(bounds.width)x\(bounds.height)pt"
                + " covered=\(covered)pt rows=\(frame.height)"
                + " cell=\(grid?.cellWidthPixels ?? 0)x\(grid?.cellHeightPixels ?? 0)px"
                + " drawable=\(layerSize.width)x\(layerSize.height)px"
                + " wants=\(wanted.width)x\(wanted.height)px")
            return
        }
        let short = abs(layerSize.width - wanted.width) > 1
            || abs(layerSize.height - wanted.height) > 1
        guard short else { return }
        kraalLog("surface extent: pane=\(paneId)"
            + " bounds=\(bounds.width)x\(bounds.height)pt"
            + " drawable=\(layerSize.width)x\(layerSize.height)px"
            + " wants=\(wanted.width)x\(wanted.height)px"
            + " frame=\(frame.width)x\(frame.height)"
            + " grid=\(grid.map { "\($0.columns)x\($0.rows)" } ?? "nil")")
    }
}

/// Reports a pane whose terminal view is not the size SwiftUI allocated to it.
///
/// The decisive comparison, and the one every earlier diagnostic missed. `apply`
/// compares the frame against the **view's own** bounds, so a view that is too small
/// agrees with itself perfectly: `rows * cellHeight == bounds.height` holds, the grid
/// matches, and 44 rows of content are written — into a rectangle shorter than the
/// space the pane occupies. What shows through is the `ZStack`'s background, which is
/// why it reads as a blank band and why no cell-level check ever saw it.
///
/// Only printed on a real gap, so a correct pane stays quiet.
@MainActor
func logAllocationGap(
    paneId: String,
    allocated: CGSize,
    view: CGSize?,
    rows: UInt16
) {
    guard let view, allocated.height > 0, view.height > 0 else { return }
    let gap = allocated.height - view.height
    guard abs(gap) > 0.5 else { return }
    kraalLog("allocation gap: pane=\(paneId) allocated=\(allocated.height)pt"
        + " view=\(view.height)pt gap=\(gap)pt rows=\(rows)")
}

/// Forces the engine's own `IOSurfaceLayer` to cover the view it is inside.
///
/// Ghostty renders through a layer it creates itself (`src/renderer/metal/
/// IOSurfaceLayer.zig`), not through `view.layer`, and that layer carries its own
/// `frame` and `contentsScale`. Neither is rebuilt synchronously by
/// `surface.setSize` — the coordinator's own notes say so:
///
/// > When `synchronizeMetrics` sends a new pixel size to ghostty via `setSize`, the
/// > underlying IOSurface is not rebuilt synchronously. Until the next full render
/// > pass ghostty still uses the **old** IOSurface, so it derives an incorrect
/// > `contentsScale` for the IOSurfaceLayer (e.g. old-pixel-height / new-point-height
/// > → 4.62 instead of the expected 3.0).
///
/// and, for the host's obligation:
///
/// > Platform views use this hook to silently enforce the correct `contentsScale`
/// > **and `frame`** on sublayers after each render.
///
/// The AppKit side does half of that: `enforceMetalLayerScale` adjusts
/// `contentsScale` only. So a layer sized for the previous pane height keeps that
/// height, is stretched by its new contentsScale, and covers less than the view — the
/// rest shows the `ZStack` background. That is the reported band, it survives the end
/// of a drag, and no cell- or grid-level assertion can see it because the cells are
/// all correct.
///
/// Called from `layoutSettled`, i.e. once per settled layout, not per frame.
func enforceEngineLayerFrame(view: NSView) {
    let bounds = view.bounds
    guard bounds.width > 0, bounds.height > 0 else { return }
    // The engine's layer is a sublayer of the host's; the host's own layer is either
    // the CAMetalLayer (fresh) or an IOSurfaceLayer (after the engine took over).
    let candidates = [view.layer] + (view.layer?.sublayers ?? [])
    for layer in candidates.compactMap({ $0 }) {
        guard abs(layer.frame.width - bounds.width) > 0.5
            || abs(layer.frame.height - bounds.height) > 0.5
            || !layer.frame.origin.equalTo(.zero)
        else { continue }
        let className = String(describing: type(of: layer))
        kraalLog("layer frame: \(className) \(layer.frame.size) -> \(bounds.size)")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = bounds
        CATransaction.commit()
    }
}
