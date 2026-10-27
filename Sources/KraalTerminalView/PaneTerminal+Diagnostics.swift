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
        guard let grid = state.surfaceSize,
              grid.cellWidthPixels > 0,
              grid.cellHeightPixels > 0 else { return }
        onCellMetrics?(CGSize(
            width: CGFloat(grid.cellWidthPixels),
            height: CGFloat(grid.cellHeightPixels)
        ))
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
    grid: TerminalGridMetrics?
) {
    guard let grid, Int(grid.rows) != Int(cells.height) else { return }
    kraalLog("pane view: \(paneId) size=\(size.width)x\(size.height)pt "
        + "cells=\(cells.width)x\(cells.height) ghostty=\(grid.columns)x\(grid.rows)")
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
