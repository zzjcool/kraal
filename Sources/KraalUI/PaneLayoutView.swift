// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Pane layout: places one terminal view per pane using the daemon's own geometry.
//
// The rectangles come from `PaneSurfacePane.innerRect`, expressed in the cell
// grid, and are scaled into the available point space. That is deliberately a
// proportion of the *grid* rather than a BSP reconstruction: the daemon already
// resolved the layout, so re-deriving it could only disagree with it.
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
                        let frame = rect(for: pane.innerRect, grid: grid, in: proxy.size)
                        paneContent(pane.paneId, pane)
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                            .background {
                                // Report the pane's real rectangle so mouse hit
                                // testing matches what is drawn.
                                PaneFrameReporter(
                                    paneId: pane.paneId,
                                    origin: CGPoint(
                                        x: proxy.frame(in: .global).minX + frame.minX,
                                        y: proxy.frame(in: .global).minY + frame.minY
                                    ),
                                    size: frame.size
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
                        splitHandle(split, grid: grid, size: proxy.size)
                    }
                } else {
                    placeholder
                }
            }
            .negotiatingSurfaceGeometry()
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

    @ViewBuilder
    private func splitHandle(
        _ split: PaneSurfaceSplit,
        grid: CGSize,
        size: CGSize
    ) -> some View {
        let hit = rect(for: split.hitRect, grid: grid, in: size)
        Rectangle()
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

    private func rect(for cellRect: SurfaceRect, grid: CGSize, in size: CGSize) -> CGRect {
        let scaleX = size.width / grid.width
        let scaleY = size.height / grid.height
        return CGRect(
            x: CGFloat(cellRect.originX) * scaleX,
            y: CGFloat(cellRect.originY) * scaleY,
            width: CGFloat(cellRect.width) * scaleX,
            height: CGFloat(cellRect.height) * scaleY
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
    let origin: CGPoint
    let size: CGSize

    func makeNSView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.apply(paneId: paneId, store: store)
        return view
    }

    func updateNSView(_ nsView: ReportingView, context: Context) {
        nsView.apply(paneId: paneId, store: store)
    }

    static func dismantleNSView(_ nsView: ReportingView, coordinator: ()) {
        nsView.clear()
    }

    final class ReportingView: NSView {
        private var paneId: String?
        private weak var store: AppStore?

        func apply(paneId: String, store: AppStore) {
            self.paneId = paneId
            self.store = store
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
            let inContent = contentView.convert(bounds, from: self)
            // Convert to a top-left origin to match the surface grid.
            let topDown = CGRect(
                x: inContent.minX,
                y: contentView.bounds.height - inContent.maxY,
                width: inContent.width,
                height: inContent.height
            )
            store.paneViewFrames[paneId] = topDown
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
