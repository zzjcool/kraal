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
                                    Rectangle()
                                        .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
                                        .allowsHitTesting(false)
                                }
                            }
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
                let cell = SurfaceGeometry.points(for: store.terminalCellSize)
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
    private var pointsPerCell: CGSize {
        SurfaceGeometry.points(for: store.terminalCellSize)
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
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
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

        switch split.direction {
        case .horizontal:
            let base = Double(split.position - area.originY)
            let moved = base + Double(translatedY)
            return min(max(moved / Double(max(area.height, 1)), 0.1), 0.9)
        case .vertical:
            let base = Double(split.position - area.originX)
            let moved = base + Double(translatedX)
            return min(max(moved / Double(max(area.width, 1)), 0.1), 0.9)
        }
    }

    /// Places a cell rectangle at its real pixel size, centred in the available
    /// space when the grid and the view differ slightly.
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
            width: CGFloat(cellRect.width) * cellSize.width,
            height: CGFloat(cellRect.height) * cellSize.height
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
    /// A pane's rectangle in content-view coordinates, top-left origin.
    public static func rect(container: CGRect, pane: CGRect, contentHeight: CGFloat) -> CGRect {
        CGRect(
            x: container.minX + pane.minX,
            y: contentHeight - (container.minY + pane.maxY),
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
