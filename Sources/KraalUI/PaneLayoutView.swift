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

    /// Builds each pane's terminal view; injected so this file stays free of the
    /// Ghostty dependency and can be previewed with a stub.
    let paneContent: (String, PaneSurfacePane) -> AnyView

    var body: some View {
        GeometryReader { proxy in
            let surface = store.surface
            let grid = CGSize(
                width: CGFloat(max(surface?.frame.width ?? 1, 1)),
                height: CGFloat(max(surface?.frame.height ?? 1, 1))
            )

            ZStack(alignment: .topLeading) {
                Color(nsColor: .textBackgroundColor)

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
                } else {
                    placeholder
                }
            }
            .negotiatingSurfaceGeometry()
            .task(id: store.surface?.surfaceRevision) {
                // One line per surface change, not per frame: this is the data
                // needed to tell a sizing bug from a rendering one.
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
                    return "\(pane.paneId)=\(pane.innerRect.width)x\(pane.innerRect.height)"
                        + "->\(Int(frame.width))x\(Int(frame.height))pt"
                }
                kraalLog("layout: container=\(Int(proxy.size.width))x\(Int(proxy.size.height)) "
                    + "grid=\(Int(grid.width))x\(Int(grid.height)) "
                    + "surfacePaned=\(store.surface != nil) "
                    + "cell=\(pointsPerCell.width)x\(pointsPerCell.height) "
                    + "panes=[\(panes.joined(separator: " "))]")
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
            .fill(Color.secondary.opacity(0.25))
            .frame(width: hit.width, height: hit.height)
            .offset(x: hit.minX, y: hit.minY)
            .gesture(
                DragGesture()
                    .onEnded { value in
                        guard let surface = store.surface else { return }
                        let ratio = ratio(
                            for: split,
                            drag: value,
                            grid: grid,
                            surface: surface
                        )
                        store.setSplitRatio(path: split.path, ratio: ratio)
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
    private func ratio(
        for split: PaneSurfaceSplit,
        drag: DragGesture.Value,
        grid: CGSize,
        surface: PaneSurfaceFrame
    ) -> Double {
        let area = split.area
        let translatedX = drag.translation.width / max(grid.width, 1)
            * CGFloat(surface.frame.width)
        let translatedY = drag.translation.height / max(grid.height, 1)
            * CGFloat(surface.frame.height)
        return Self.splitRatio(
            direction: split.direction,
            position: split.position,
            area: area,
            translatedX: translatedX,
            translatedY: translatedY
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
    static func splitRatio(
        direction: PaneSurfaceSplitDirection,
        position: UInt16,
        area: SurfaceRect,
        translatedX: CGFloat,
        translatedY: CGFloat
    ) -> Double {
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

/// Which way a split divider moves.
///
/// The daemon names a split after the divider *line*, and the drag axis is
/// perpendicular to that name. The two names therefore read backwards to anyone
/// thinking about where the panes go, and that is the whole bug this type exists
/// to make explicit:
///
/// * `.vertical` — a vertical line — leaves panes stacked top to bottom, which
///   the UI offers as "Split Down". The divider moves **up and down**.
/// * `.horizontal` — a horizontal line — leaves panes side by side, offered as
///   "Split Right". The divider moves **left and right**.
///
/// Verified against a live daemon: a `direction: down` split came back as
/// `.vertical` with a 120×2 hit rect in a 120×40 area (a wide, thin, horizontal
/// strip), and its `position` tracked the row axis.
public enum PaneSplitAxis: Sendable {
    /// The divider moves along Y; the resize cursor is the up-down arrows.
    case verticalDrag
    /// The divider moves along X; the resize cursor is the left-right arrows.
    case horizontalDrag

    public init(_ direction: PaneSurfaceSplitDirection) {
        switch direction {
        case .vertical: self = .verticalDrag
        case .horizontal: self = .horizontalDrag
        }
    }

    public var direction: PaneSurfaceSplitDirection {
        switch self {
        case .verticalDrag: .vertical
        case .horizontalDrag: .horizontal
        }
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
