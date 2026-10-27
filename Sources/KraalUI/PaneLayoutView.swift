// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Pane layout: places one terminal view per pane using the daemon's own geometry.
//
// The rectangles come from `PaneSurfacePane.innerRect`, expressed in the cell
// grid. They are scaled by a single cell size — the renderer's measured metrics —
// rather than stretched to fill the view.
//
// That distinction matters: a pane is `innerRect.width` cells wide, and the
// daemon's cells for it were composed at exactly that width. Stretching the pane
// to a slightly different pixel width makes Ghostty lay out a different number of
// columns than were sent, so every row wraps. Scaling by a real cell size keeps
// "cells drawn" and "pixels available" consistent, leaving any remainder as
// background rather than as a layout change.
//
// Borders and split dividers are ours to draw because `ui.pane_borders` decides
// whether the daemon reserved a cell for them — which is exactly why layout uses
// `innerRect` and never assumes a one-cell inset.

import KraalProtocol
import SwiftUI
import KraalSidebar
import KraalTransport

struct PaneLayoutView: View {
    @Environment(AppStore.self) private var store
    /// The scale of the screen this window is on. `displayScale` follows the
    /// view, unlike `NSScreen.main`, which follows the menu bar.
    @Environment(\.displayScale) private var displayScale
    /// The user's theme.
    ///
    /// The pane container is the one piece of chrome that touches terminal content,
    /// so it is also the one where a system colour hurts most: the divider used to be
    /// `Color.secondary`, which is the *system appearance*, and a light-mode Mac
    /// running a dark theme drew a `(223,223,223)` band between two `(17,20,25)`
    /// panes. The theme has to reach here.
    @Environment(\.palette) private var palette

    /// Where the divider sat when the current drag began.
    ///
    /// Held here, not derived per event, because `split.position` comes back from the
    /// daemon already moved by the translation that was last sent. Adding the
    /// gesture's cumulative translation to that moving value applies the motion
    /// twice — measured at 2.12x on a real drag. Anchoring on the pre-drag position
    /// makes the calculation idempotent: delivering the same translation twice
    /// yields the same ratio.
    @State private var dragAnchor: (path: [Bool], position: UInt16)?

    /// The layout's structure when the current drag began.
    ///
    /// Every ratio this gesture sends is checked against it by
    /// ``AppStore/dragSplitRatio(path:ratio:fence:)``. A divider is named by its
    /// `path`, which is a position in a tree rather than an identity, so a pane
    /// that closes or splits while the button is held leaves the same path naming
    /// another border. Captured here — once, on the first change — because the
    /// fence has to describe the layout the user grabbed, not one that arrived
    /// mid-drag.
    @State private var dragFence: PaneSplitFence?

    /// The container's top-left inside the window, in points, as last reported.
    ///
    /// Read from a `GeometryReader` in the global (window) space rather than derived
    /// from sizes: `windowHeight - containerHeight` also counts the gap below the
    /// container, and that error is invisible to click tests (a 25pt offset lands in
    /// the same cell) while it shifts every pixel assertion by 25pt.
    @State private var containerOriginInWindow = "?"

    /// The anchor for this split, capturing it on first use within a gesture.
    ///
    /// Returns the pre-drag position and stores it for the rest of the gesture.
    /// A plain `@State` write inside a gesture handler is applied before the next
    /// event, so `onEnded` sees the same anchor `onChanged` established.
    private func splitDragAnchor(for split: PaneSurfaceSplit) -> UInt16 {
        if let dragAnchor, dragAnchor.path == split.path { return dragAnchor.position }
        dragAnchor = (path: split.path, position: split.position)
        return split.position
    }

    private func clearSplitDragAnchor() {
        dragAnchor = nil
        dragFence = nil
    }

    /// The fence for this split, capturing it on first use within a gesture.
    ///
    /// Same shape as ``splitDragAnchor(for:)`` and for the same reason: the value
    /// has to be the one from before the drag, so it is stored on the first call
    /// and reused until ``clearSplitDragAnchor()``.
    ///
    /// `nil` is returned when the layout has no dividers at all. That is not a
    /// failure to capture — it means there is nothing structural to compare, so
    /// the store skips the check rather than refusing every send.
    private func splitDragFence() -> PaneSplitFence? {
        if let dragFence { return dragFence }
        let fence = store.surface?.splitFence
        dragFence = fence
        return fence
    }

    /// Builds each pane's terminal view; injected so this file stays free of the
    /// Ghostty dependency and can be previewed with a stub.
    let paneContent: (String, PaneSurfacePane) -> AnyView

    /// Builds the popup's terminal view, injected for the same reason as
    /// `paneContent`. A popup is a whole separate terminal on the daemon, so this
    /// builds a second `PaneTerminalModel` rather than reusing a pane's.
    let popupContent: (ClientShellPopupSurface, PopupGeometry) -> AnyView

    var body: some View {
        GeometryReader { proxy in
            let surface = store.surface
            let grid = CGSize(
                width: CGFloat(max(surface?.frame.width ?? 1, 1)),
                height: CGFloat(max(surface?.frame.height ?? 1, 1))
            )

            ZStack(alignment: .topLeading) {
                // The baseline for everything the panes do not cover: the container's
                // own background, in the system's text colour.
                Color(nsColor: .textBackgroundColor)
                // Then the theme's say in it, on top of that baseline. Every gap in
                // this container — between panes and around them — shows this layer,
                // so with a theme that names a surface the seams match the panes
                // instead of the Mac's appearance. `.clear` when the theme has no
                // opinion, which leaves the line above exactly as it was.
                palette.paneGapColor

                if let surface {
                    ForEach(surface.panes, id: \.paneId) { pane in
                        let frame = rect(
                            for: pane.innerRect,
                            grid: grid,
                            in: proxy.size,
                            cellSize: pointsPerCell
                        )
                        paneContent(pane.paneId, pane)
                            // A terminal's grid is decided by its exact pixel
                            // size, so the pane must be that size — not "that
                            // size, compressed to fit". Letting the container
                            // shrink it made Ghostty compute a narrower grid
                            // than the cells it was sent, and every row wrapped.
                            .frame(width: frame.width, height: frame.height)
                            // The scroll indicator, in the lane the daemon
                            // reserved for it.
                            //
                            // Attached **before** `.position` on purpose. After
                            // `.position` the view's bounds are the whole pane
                            // container, not the pane — that is the contract
                            // `PaneFrameReporter` relies on (`:625-640`), and the
                            // reason it has to add the pane's offset by hand. An
                            // overlay attached there covers every pane at once, so
                            // the lane landed a pane-width to the left of where it
                            // belonged (and always at the container's top edge
                            // vertically). Here the bounds are exactly the pane, so
                            // the lane's container coordinates can be rebased onto
                            // the pane origin by subtracting it.
                            .overlay(alignment: .topLeading) {
                                if let lane = pane.scrollbarRect {
                                    let laneFrame = rect(
                                        for: lane,
                                        grid: grid,
                                        in: proxy.size,
                                        cellSize: pointsPerCell
                                    )
                                    let localLane = PaneScrollbarOverlay.laneRect(
                                        lane: laneFrame,
                                        pane: frame
                                    )
                                    PaneScrollbarOverlay(
                                        lane: localLane,
                                        thumb: pane.scrollbarThumb,
                                        // In cells, straight from the daemon — the
                                        // overlay needs it to size a cell, and it
                                        // cannot be recovered from the thumb.
                                        laneCells: pane.scrollbarLaneHeight ?? 0,
                                        paneId: pane.paneId,
                                        paneSize: frame.size,
                                        isFocused: pane.focused
                                    )
                                    .frame(width: localLane.width, height: localLane.height)
                                    .position(x: localLane.midX, y: localLane.midY)
                                }
                            }
                            // `position`, not `offset`: offset is a rendering
                            // transform applied after layout, so the pane's real
                            // NSView never moves and reports the wrong rectangle
                            // (both panes claimed the same frame). `position`
                            // takes part in layout, so what is drawn and what is
                            // measured are the same rectangle.
                            .position(x: frame.midX, y: frame.midY)
                            .background {
                                // Report the pane's real rectangle so mouse hit
                                // testing matches what is drawn.
                                PaneFrameReporter(
                                    paneId: pane.paneId,
                                    paneFrame: frame
                                )
                            }
                            .overlay {
                                if pane.focused {
                                    // A crisp 1pt accent outline. Kept outside the
                                    // blur on purpose: this is the only chrome that
                                    // touches terminal content, so it must not add
                                    // any translucency over the glyphs.
                                    Rectangle()
                                        .strokeBorder(Color.accentColor.opacity(0.65), lineWidth: 1)
                                        .allowsHitTesting(false)
                                }
                            }
                            // A frame held across a dropped connection is not
                            // current state. Dimming it says so without throwing
                            // away a picture that will very likely be replaced by
                            // the same content seconds later.
                            .opacity(store.surfaceIsStale ? 0.45 : 1)
                    }

                    ForEach(Array(surface.splits.enumerated()), id: \.offset) { _, split in
                        splitHandle(
                            split,
                            grid: grid,
                            size: proxy.size,
                            cellSize: pointsPerCell
                        )
                    }

                    // The popup goes last, and that is the whole of "it is on top":
                    // in a `ZStack` the later child draws over the earlier ones, so
                    // panes and split handles are both underneath it.
                    //
                    // Its geometry is in surface cells and has to be scaled like the
                    // panes are — `rect(for:)` converts both the box and its
                    // interior, and the border is drawn in the cell grid so it lines
                    // up with the terminal's own cells rather than in points.
                    if let popup = store.activePopup,
                       let popupGeometry = store.popupGeometry {
                        // Computed once: `rect(for:)` does a centring calculation, and
                        // calling it four times for the same box is both slow and a
                        // place for the four results to disagree.
                        let popupBox = rect(
                            for: popupGeometry.outer,
                            grid: grid,
                            in: proxy.size,
                            cellSize: pointsPerCell
                        )
                        popupContent(popup, popupGeometry)
                            .frame(width: popupBox.width, height: popupBox.height)
                            // The only evidence a GUI case can assert on: SwiftUI's
                            // `body` produces no inspectable output, so "the popup
                            // was laid out, at this box, with this interior" has to
                            // be logged. Same reasoning as the pane `layout:` line.
                            .background {
                                Color.clear
                                    .task(id: popup.terminalId) {
                                        kraalLog("popup: \(popup.terminalId) "
                                            + "outer=\(Int(popupBox.minX)),\(Int(popupBox.minY)) "
                                            + "\(Int(popupBox.width))x\(Int(popupBox.height)) "
                                            + "inner=\(popupGeometry.inner.width)"
                                            + "x\(popupGeometry.inner.height) "
                                            + "title=\(popup.title)")
                                    }
                            }
                            .position(x: popupBox.midX, y: popupBox.midY)
                            // The border and title, in the box the daemon reserved:
                            // one cell of padding all round, which is exactly what
                            // `PopupGeometry` subtracted from the interior.
                            .background {
                                PopupChrome(
                                    popup: popup,
                                    geometry: popupGeometry,
                                    cellSize: pointsPerCell
                                )
                            }
                            .overlay {
                                PaneFrameReporter(
                                    paneId: popup.terminalId,
                                    paneFrame: popupBox
                                )
                            }
                    }
                } else {
                    placeholder
                }
            }
            // Pin the pane container to the size the window actually offers, and
            // clip to it.
            //
            // Without this the container reports whatever its content demands. A
            // grid wider than the window pushes the panes past the right edge,
            // the container grows to fit them, and the negotiation in
            // `negotiatingSurfaceGeometry()` then measures that inflated width and
            // asks the daemon for the same over-wide grid again — the container
            // proving its own size back to itself, so it never recovers.
            //
            // Measured, not theorised: with the window offering 1004pt the
            // negotiation was being handed 1088pt, which at the real 8.5pt cell
            // is 128 columns — the very grid that made it 1088pt wide. Panes ran
            // 58.5pt past the right edge.
            //
            // Clipping is the second half. AppKit does not clip a pane's surface
            // on its own (no `masksToBounds` on the Ghostty view, and its
            // `IOSurfaceLayer` is top-left anchored and opaque), so an oversized
            // pane paints over its neighbour instead of being cut off at its own
            // edge. That is what makes an overflow read as one pane's content
            // appearing in another.
            .frame(
                width: proxy.size.width,
                height: proxy.size.height,
                alignment: .topLeading
            )
            .clipped()
            .negotiatingSurfaceGeometry()
            // Records where the container actually sits inside the window. A
            // zero-size overlay so it cannot affect layout; `GeometryReader` reports
            // the frame in the window's coordinate space, which is exactly what a
            // window screenshot uses.
            .overlay {
                GeometryReader { inner in
                    Color.clear
                        .task(id: inner.frame(in: .global).origin.debugDescription) {
                            let box = inner.frame(in: .global)
                            let text = "\(Int(box.minX)),\(Int(box.minY))"
                            if text != containerOriginInWindow {
                                containerOriginInWindow = text
                            }
                        }
                }
                .allowsHitTesting(false)
            }
            .task(id: store.surface?.surfaceRevision) {
                // One line per surface change, not per frame: this is the data
                // needed to tell a sizing bug from a rendering one.
                //
                // Note this *does* re-run for a patch the store refused and whose
                // frame number it claimed anyway (issue #50 review) — the revision
                // moved, the cells did not. That is one extra log line per refused
                // frame while a systematic refusal lasts, which is why the line is
                // kept to a single `kraalLog` call and nothing is measured here.
                // Do not turn this into per-frame work on the strength of "the
                // surface changed".
                let cell = SurfaceGeometry.points(
                    for: store.terminalCellSize,
                    scale: displayScale
                )
                let panes = (store.surface?.panes ?? []).map { pane -> String in
                    let frame = rect(
                        for: pane.innerRect,
                        grid: grid,
                        in: proxy.size,
                        cellSize: cell
                    )
                    // The cell origin is logged, not just the size.
                    //
                    // "Does every row belong to some pane, or does one fall between
                    // them?" is not answerable from sizes alone, and that question is
                    // the difference between a layout bug and a rendering one. A
                    // 35-row grid with panes 20 rows and 14 rows tall leaves exactly
                    // one row unaccounted for, and only the origin says which —
                    // measured on a live split: `grid=112x35` with
                    // `p14=112x20 p16=112x14`, i.e. 34 of 35 rows.
                    return "\(pane.paneId)=\(pane.innerRect.width)x\(pane.innerRect.height)"
                        + "@\(pane.innerRect.originX),\(pane.innerRect.originY)"
                        + " rect=\(pane.rect.width)x\(pane.rect.height)"
                        + "@\(pane.rect.originX),\(pane.rect.originY)"
                        + "->\(Int(frame.width))x\(Int(frame.height))pt"
                }
                // The split's geometry, in cells. Logged next to the panes because the
                // interesting question spans both: which rows does *nothing* cover?
                // `hitRect` is what the divider is drawn in, and it is not necessarily
                // the gap the daemon left between the two `innerRect`s.
                let splitsLog = (store.surface?.splits ?? []).map { split -> String in
                    let hit = split.hitRect
                    return "\(split.direction)@\(split.position) "
                        + "hit=\(hit.width)x\(hit.height)@\(hit.originX),\(hit.originY)"
                }.joined(separator: " ")
                // `containerOrigin` is the container's top-left **inside the
                // window**, in points. It exists because the harness needs to map a
                // pane onto a screenshot, and deriving the origin as
                // `windowHeight - containerHeight` was wrong by the title bar plus
                // the bottom gap: measured `96` where the container actually starts
                // at `71`, which shifted every pixel assertion by 25pt (issue #103).
                kraalLog("layout: container=\(Int(proxy.size.width))x\(Int(proxy.size.height)) "
                    + "grid=\(Int(grid.width))x\(Int(grid.height)) "
                    + "surfacePaned=\(store.surface != nil) "
                    + "cell=\(pointsPerCell.width)x\(pointsPerCell.height) "
                    + "containerOrigin=\(containerOriginInWindow) "
                    + "panes=[\(panes.joined(separator: " "))] "
                    + "splits=[\(splitsLog)]")
                // Exact sizes, unrounded, and only when they disagree with the
                // grid the daemon asked for.
                //
                // Ghostty floors `viewPixels / cellPixels`, so a pane laid out at
                // *exactly* `rows x cell` has zero slack: half a point lost turns
                // `333px` into `332px` and a whole row disappears. `Int()` in the
                // line above hides that (`166.5` prints as `166`, and 166pt is
                // precisely where a row is lost). Logged only on a disagreement so a
                // steady layout stays quiet; see docs/ENVIRONMENT.md §8.14.
                if let surface {
                    let cellPixels = max(pointsPerCell.height * displayScale, 1)
                    let mismatched = surface.panes.compactMap { pane -> String? in
                        let box = rect(
                            for: pane.innerRect,
                            grid: grid,
                            in: proxy.size,
                            cellSize: pointsPerCell
                        )
                        let rows = Int(box.height * displayScale / cellPixels)
                        guard rows != Int(pane.innerRect.height) else { return nil }
                        let outer = rect(
                            for: pane.rect,
                            grid: grid,
                            in: proxy.size,
                            cellSize: pointsPerCell
                        )
                        return "\(pane.paneId) inner=\(pane.innerRect.width)x\(pane.innerRect.height)"
                            + "=\(box.height)pt(\(box.height * displayScale)px)"
                            + " floorRows=\(rows)"
                            + " rect=\(pane.rect.width)x\(pane.rect.height)=\(outer.height)pt"
                    }
                    if !mismatched.isEmpty {
                        kraalLog("layout exact: container=\(proxy.size.width)x\(proxy.size.height)pt "
                            + "cellPx=\(cellPixels) "
                            + "panes=[\(mismatched.joined(separator: " "))]")
                    }
                }
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(store.phase.isLive ? "Waiting for the first frame…" : "Connecting…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The rendered size of one cell, in points.
    ///
    /// Ghostty reports cell metrics in device pixels; SwiftUI lays out in points,
    /// so this divides by the backing scale before use. Layout uses this rather
    /// than stretching panes to the container width: a pane composed at N cells
    /// must be drawn N cells wide, or the renderer reflows and every row wraps.
    ///
    /// The scale comes from `displayScale`, i.e. the screen this view is on.
    /// Asking `NSScreen.main` instead returns the menu bar's screen, and on a
    /// mixed Retina/external setup that is a different display from the one the
    /// window occupies — every cell then lands at twice or half its true size.
    private var pointsPerCell: CGSize {
        SurfaceGeometry.points(for: store.terminalCellSize, scale: displayScale)
    }

    private func splitHandle(
        _ split: PaneSurfaceSplit,
        grid: CGSize,
        size: CGSize,
        cellSize: CGSize
    ) -> some View {
        let hit = rect(for: split.hitRect, grid: grid, in: size, cellSize: cellSize)
        return Rectangle()
            // The band's fill is the theme's, not the platform's. `Color.secondary`
            // is the system appearance: on a light-mode Mac it turned this 2-cell
            // strip into a `(223,223,223)` bar running down a dark terminal.
            .fill(palette.paneGapColor)
            .frame(width: hit.width, height: hit.height)
            .overlay { gapLine(for: split.direction) }
            // The divider must stay draggable whatever the fill is.
            //
            // `paneGapColor` resolves to `.clear` when a palette names neither
            // `surface_dim` nor `panel_background`, and a shape that draws nothing is
            // not reliably hit-tested: the divider would look right and stop responding
            // to the mouse, which is a worse bug than the colour it fixes.
            //
            // No *built-in* theme reaches that arm — all 18 name `surface_dim` — so this
            // is defensive for a palette built by hand or by a future theme loader. That
            // makes it the kind of guard that quietly rots, so it is not left to
            // reasoning: measured with the fill forced to `.clear`, removing this line
            // gives `stuck: ratio 0.500 -> 0.500, the drag never reached the daemon`, and
            // restoring it gives `0.500 -> 0.588` again.
            //
            // An explicit content shape also makes the whole `hitRect` — both cells of
            // it — the target, rather than whatever the fill happens to paint.
            .contentShape(Rectangle())
            .offset(x: hit.minX, y: hit.minY)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        // The anchor is captured once, on the first change of this
                        // gesture, and cleared on release. Every later value is
                        // measured from it, so repeated delivery of the same
                        // cumulative translation produces the same ratio instead of
                        // compounding (see the note on `ratio(for:drag:anchoringAt:)`).
                        let position = splitDragAnchor(for: split)
                        store.dragSplitRatio(
                            path: split.path,
                            ratio: ratio(for: split, drag: value, cellSize: cellSize,
                                         anchoringAt: position),
                            fence: splitDragFence()
                        )
                    }
                    .onEnded { value in
                        // The final position is authoritative and must not be
                        // dropped: the last `onChanged` may have been coalesced
                        // away, and the daemon has no idea where the pointer
                        // stopped. It is the *same* anchor, so this cannot move the
                        // divider further than the pointer did.
                        let position = splitDragAnchor(for: split)
                        store.dragSplitRatio(
                            path: split.path,
                            ratio: ratio(for: split, drag: value, cellSize: cellSize,
                                         anchoringAt: position),
                            fence: splitDragFence()
                        )
                        clearSplitDragAnchor()
                    }
            )
            .onHover { hovering in
                if hovering {
                    Self.splitCursor(for: split.direction).push()
                } else {
                    NSCursor.pop()
                }
            }
    }

    /// The hairline down the middle of a split divider, along the divider's own axis.
    ///
    /// The axis comes from ``PaneSplitAxis``, the readable home of "the daemon names a
    /// split after the line, not after where the panes go": a `.verticalDrag` divider
    /// is a horizontal line between stacked panes, so its hairline runs full width and
    /// is one point tall. Centred by `.overlay`'s default alignment, so a 2-cell band
    /// gets the line in the middle of it.
    ///
    /// `.clear` when the theme has no `surface0`: no line, and `.allowsHitTesting(false)`
    /// keeps an invisible 1pt strip from swallowing the drag.
    @ViewBuilder
    private func gapLine(for direction: PaneSurfaceSplitDirection) -> some View {
        let line = Rectangle().fill(palette.paneGapLineColor)
        switch PaneSplitAxis(direction) {
        case .verticalDrag:
            line.frame(height: 1).allowsHitTesting(false)
        case .horizontalDrag:
            line.frame(width: 1).allowsHitTesting(false)
        }
    }

    /// The resize cursor matching a split direction.
    ///
    /// Thin AppKit adapter over ``PaneSplitAxis``, which holds the readable part
    /// of the rule and is what the tests assert on.
    static func splitCursor(for direction: PaneSurfaceSplitDirection) -> NSCursor {
        switch PaneSplitAxis(direction) {
        case .verticalDrag: .resizeUpDown
        case .horizontalDrag: .resizeLeftRight
        }
    }

    /// Converts a drag into the ratio the daemon expects: the divider's new
    /// offset within the split's own area, clamped so a pane cannot vanish.
    ///
    /// `DragGesture` reports **points**; `position` and `area` are **cells**. The
    /// conversion therefore has to go through the cell size, which is exactly what
    /// an earlier version got wrong: it scaled the drag by
    /// `surface.frame.height / grid.height`, and those two are the same number by
    /// construction (both come from `surface.frame`), so the factor was always 1
    /// and a 40-point drag counted as 40 *rows*. In a 45-row surface one small tug
    /// produced a ratio change of 0.89, hit the clamp, and pinned the divider to an
    /// edge — which reads as "the divider does not follow the mouse".
    /// Ratio to send for the current drag position.
    ///
    /// Anchored on the divider's position **as it was when the gesture began**, plus
    /// the gesture's cumulative translation. The naive version — current
    /// `split.position` plus the same translation — is not idempotent: the position
    /// that comes back from the daemon already contains the translation that was sent
    /// last time, so sending the same cumulative translation twice applies the motion
    /// twice. Measured in a VM against a 959pt container: one 40pt drag moved the
    /// divider 80pt (2.12x) whenever `onChanged` and `onEnded` were more than 100ms
    /// apart, which is every real drag. With `onChanged` and `onEnded` in the same
    /// tick the two calls coalesce into one request and the result was correct
    /// (1.11x) — which is why unit tests on the arithmetic never saw this.
    private func ratio(
        for split: PaneSurfaceSplit,
        drag: DragGesture.Value,
        cellSize: CGSize,
        anchoringAt position: UInt16
    ) -> Double {
        Self.splitRatioForDrag(
            direction: split.direction,
            position: position,
            area: split.area,
            dragPoints: drag.translation,
            cellSize: cellSize
        )
    }

    /// The points-to-cells step, split out so it can be tested without a view.
    ///
    /// Delegates to ``PaneSplitAxis/ratio(position:area:dragPoints:cellSize:)``,
    /// which is the public home of this arithmetic. Kept as a named entry point
    /// because the tests read better calling it this way.
    static func splitRatioForDrag(
        direction: PaneSurfaceSplitDirection,
        position: UInt16,
        area: SurfaceRect,
        dragPoints: CGSize,
        cellSize: CGSize
    ) -> Double {
        PaneSplitAxis(direction).ratio(
            position: position,
            area: area,
            dragPoints: dragPoints,
            cellSize: cellSize
        )
    }

    /// The new divider offset, as a ratio of the split's own area.
    ///
    /// The daemon names a split after the divider *line*, and the drag axis is
    /// perpendicular to that: a `.vertical` divider is a horizontal line between
    /// panes stacked top to bottom, so it moves along Y; a `.horizontal` divider
    /// is a vertical line between panes side by side, so it moves along X.
    ///
    /// `position` is already measured along that same axis — confirmed against a
    /// live daemon, where a `.vertical` split in a 120×40 area reported
    /// `position` 10 and 30 for ratios 0.25 and 0.75. Reading the ratio off the
    /// other axis therefore both misplaces the divider and drags it backwards.
    ///
    /// Clamped to 0.1…0.9 so a pane cannot be dragged to nothing.
    ///
    /// A non-finite drag delta is refused up front rather than clamped: `min` and
    /// `max` return `NaN` unchanged, so a `.nan` translation would sail straight
    /// out as the ratio. The daemon rejects that (`src/app/api/layouts.rs:235`
    /// `if !params.ratio.is_finite()`), but the error never reaches the user —
    /// the divider simply does not move.
    static func splitRatio(
        direction: PaneSurfaceSplitDirection,
        position: UInt16,
        area: SurfaceRect,
        translatedX: CGFloat,
        translatedY: CGFloat
    ) -> Double {
        // 0.5 is the neutral "stay put" ratio: it is what an unusable drag means.
        guard translatedX.isFinite, translatedY.isFinite else { return 0.5 }
        switch direction {
        case .vertical:
            let base = Double(position - area.originY)
            let moved = base + Double(translatedY)
            return min(max(moved / Double(max(area.height, 1)), 0.1), 0.9)
        case .horizontal:
            let base = Double(position - area.originX)
            let moved = base + Double(translatedX)
            return min(max(moved / Double(max(area.width, 1)), 0.1), 0.9)
        }
    }

    /// Places a cell rectangle at its real pixel size, centred in the available
    /// space when the grid and the view differ slightly.
    ///
    /// Pane sizes are snapped *up* to whole device pixels. Ghostty derives its
    /// own grid as `floor(viewPixels / cellPixels)`, and a cell is rarely a whole
    /// number of points — a 17x37 px cell at 2x is 8.5x18.5 pt, so a 111 x 35
    /// pane wants exactly 943.5 x 647.5 pt. Handing Ghostty a size a fraction of
    /// a pixel short makes that division land just under the integer, floor to
    /// 110 x 34, and then every cell, the cursor and the selection sit one row
    /// and one column off inside an otherwise correct pane. The error is the
    /// same for every pane, which is what makes it read as a global offset
    /// rather than a per-pane mistake.
    ///
    /// Rounding up rather than to-nearest because a pixel too many is harmless
    /// (the leftover stays background) while a pixel too few costs a whole cell.
    private func rect(
        for cellRect: SurfaceRect,
        grid: CGSize,
        in size: CGSize,
        cellSize: CGSize
    ) -> CGRect {
        let gridSize = CGSize(
            width: grid.width * cellSize.width,
            height: grid.height * cellSize.height
        )
        let originX = max((size.width - gridSize.width) / 2, 0)
        let originY = max((size.height - gridSize.height) / 2, 0)
        return CGRect(
            x: originX + CGFloat(cellRect.originX) * cellSize.width,
            y: originY + CGFloat(cellRect.originY) * cellSize.height,
            width: PaneFrameMath.pixelSnapped(
                CGFloat(cellRect.width) * cellSize.width,
                scale: displayScale
            ),
            height: PaneFrameMath.pixelSnapped(
                CGFloat(cellRect.height) * cellSize.height,
                scale: displayScale
            )
        )
    }
}

/// The arithmetic behind a pane's hit-testing rectangle.
///
/// Kept apart from the reporter because getting it wrong is silent: the mouse
/// monitor simply stops matching panes, with no error anywhere. Two concrete
/// mistakes it guards against are stacking the pane offset twice (once in the
/// SwiftUI host, once in the conversion) and leaving the origin at the bottom
/// while the surface grid counts from the top.
public enum PaneFrameMath {
    /// Rounds a point size up to a whole device pixel.
    ///
    /// Ghostty derives its grid by floor-dividing the view's pixel size by the
    /// cell's pixel size, so a pane measuring a fraction of a pixel under
    /// `cells * cellSize` silently loses a whole row and column — and every cell
    /// drawn in that pane, along with the cursor and the selection, lands one
    /// cell off. Since the loss is identical in every pane it reads as a global
    /// misalignment rather than a sizing bug.
    public static func pixelSnapped(
        _ points: CGFloat,
        scale: CGFloat = SurfaceGeometry.backingScale
    ) -> CGFloat {
        (points * scale).rounded(.up) / scale
    }
    /// A point in the content view's own space, converted to this app's pane
    /// coordinate space (top-left origin), given whether that view is flipped.
    ///
    /// Exists because the inverse of this was wrong for months in a way nobody
    /// could see from the outside: a wheel event over the top pane scrolled the
    /// bottom one, 100% of the time (issue #88). The content view is an
    /// `NSHostingView`, whose `isFlipped` is `true`, so `convert(_:from:)` already
    /// answers top-down — and the reader subtracted from `bounds.height` anyway,
    /// inverting a point that was already inverted.
    ///
    /// Kept as a function of `isFlipped` rather than hard-coded to `true`, because
    /// a future container (or a test) can legitimately be either, and the branch is
    /// the thing worth stating: *flipped means no arithmetic*.
    public static func contentPoint(
        _ point: CGPoint, contentHeight: CGFloat, isFlipped: Bool
    ) -> CGPoint {
        isFlipped ? point : CGPoint(x: point.x, y: contentHeight - point.y)
    }

    /// A pane's rectangle in content-view coordinates, top-left origin.
    ///
    /// `container` is in AppKit coordinates (origin bottom-left) and `pane` is in
    /// SwiftUI coordinates *inside* that container (origin top-left). Mixing the
    /// two was the bug: `contentHeight - (container.minY + pane.maxY)` subtracts a
    /// top-down pane offset from a bottom-up container offset, so the result is
    /// wrong by an amount that depends on where the container sits — every pane
    /// in the window shifted by the same constant, which reads as a global offset
    /// rather than a per-pane one. The old tests missed it because they put the
    /// container at y = 0, where the two conventions happen to coincide.
    ///
    /// The fix is to convert the container to top-down first, then add the pane's
    /// own top-down offset. Both operands are then measured from the same edge.
    /// Whether a reported rectangle is usable for hit testing.
    ///
    /// A pane view reports its own frame, and SwiftUI reports `0x0` while it is
    /// tearing a view down or before it has been laid out. Storing that would replace
    /// a good rectangle with an empty one, and `CGRect.contains` never matches an
    /// empty rect — so every click in that pane would afterwards be handed to Ghostty
    /// instead of raising the pane menu (issue: right-click on an SSH pane produced
    /// the system Copy/AutoFill menu).
    public static func isUsableForHitTesting(_ rect: CGRect) -> Bool {
        rect.width > 0 && rect.height > 0
    }

    public static func rect(container: CGRect, pane: CGRect, contentHeight: CGFloat) -> CGRect {
        let containerTop = contentHeight - (container.minY + container.height)
        return CGRect(
            x: container.minX + pane.minX,
            y: containerTop + pane.minY,
            width: pane.width,
            height: pane.height
        )
    }
}

/// Publishes a pane's rectangle for hit testing.
///
/// Uses `NSView` geometry rather than SwiftUI's coordinate spaces because the
/// consumer (the mouse monitor) works in window points.
private struct PaneFrameReporter: NSViewRepresentable {
    @Environment(AppStore.self) private var store
    let paneId: String
    /// The pane's rectangle inside the pane container, which is where this
    /// reporter is installed.
    let paneFrame: CGRect

    func makeNSView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.apply(paneId: paneId, store: store, paneFrame: paneFrame)
        return view
    }

    func updateNSView(_ nsView: ReportingView, context: Context) {
        nsView.apply(paneId: paneId, store: store, paneFrame: paneFrame)
    }

    static func dismantleNSView(_ nsView: ReportingView, coordinator: ()) {
        nsView.clear()
    }

    final class ReportingView: NSView {
        private var paneId: String?
        private weak var store: AppStore?
        private var paneFrame: CGRect = .zero

        func apply(paneId: String, store: AppStore, paneFrame: CGRect) {
            self.paneId = paneId
            self.store = store
            self.paneFrame = paneFrame
            report()
        }

        func clear() {
            if let paneId, let store {
                store.paneViewFrames.removeValue(forKey: paneId)
            }
            paneId = nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }

        override func layout() {
            super.layout()
            report()
        }

        private func report() {
            guard let paneId, let store, let window, let contentView = window.contentView else {
                return
            }
            // A zero-size report is not a pane at nowhere — it is SwiftUI tearing
            // the view down, or measuring before layout. Writing it through would
            // replace a good rectangle with an empty one, and since the monitor
            // matches with `rect.contains(point)`, an empty rect matches nothing:
            // every later click and right-click in that pane would be handed to
            // Ghostty instead of this app. Measured on a live session
            // (`~/Library/Logs/Kraal-live.log`): one pane reported
            // `1020x740` → `986x2423` → `0x0`, and after the `0x0` the pane never
            // raised the pane menu again — the right-click produced the system
            // Copy/AutoFill menu, which is Ghostty's own.
            //
            // Keep the last real rectangle instead. It goes stale only in the sense
            // that the next `layout()` pass overwrites it, which is exactly what
            // should happen.
            guard PaneFrameMath.isUsableForHitTesting(bounds) else { return }
            // The reporter's own bounds against the rectangle the layout asked
            // for. These are the only two numbers that can say whether SwiftUI
            // honoured `.frame`/`.position`: Ghostty reads its NSView's `bounds`,
            // so a disagreement here is exactly a pane measured at the wrong size
            // (docs/ENVIRONMENT.md §8.14 — observed as `inner +/- 1 row`, both
            // signs, summing to zero).
            // Deliberately not compared against `paneFrame.size` here: this view
            // is hosted in a container that `.frame`/`.position` do not move (see
            // below), so its bounds are the *container's*, not the pane's. Measured
            // `host=1071x988` against a `wanted` of `1054x499.5` on a three-pane
            // layout — the two are different rectangles by construction, which is
            // why the pane's offset is added by hand just below.
            //
            // The question that matters — "is the pane's NSView the size the layout
            // asked for?" — is answered by `grid mismatch`'s `px` field instead,
            // because that one comes from Ghostty's own `bounds`.
            // SwiftUI hosts this view in a container that is not moved by
            // `.frame`/`.position`, so the host's own rect is always the pane
            // container. The container's rect plus the pane's offset inside it is
            // the pane's real rectangle.
            let container = contentView.convert(bounds, from: self)
            store.paneViewFrames[paneId] = PaneFrameMath.rect(
                container: container,
                pane: paneFrame,
                contentHeight: contentView.bounds.height
            )
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
