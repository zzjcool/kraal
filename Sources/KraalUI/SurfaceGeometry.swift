// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Surface geometry negotiation.
//
// The endpoint protocol sizes the *server-side* render: a hello carries
// `surface_size` in cells, and the daemon composites the tab at exactly that
// grid. Each connection negotiates independently, so the right size is whatever
// this window can actually show — otherwise the surface is letterboxed and text
// is either cropped or pointless.
//
// The flow is therefore: measure the pane area in points → convert with the
// terminal's real cell metrics → ask the store for that grid → the store
// re-handshakes. Debouncing matters because a live window drag would otherwise
// trigger a reconnect per pixel.

import AppKit
import KraalProtocol
import SwiftUI

/// Converts a view's point size into the cell grid to request from the daemon.
///
/// Accuracy here is load-bearing, not cosmetic: the daemon composites the tab at
/// exactly the grid we ask for, and Ghostty parses that ANSI into *its own* grid.
/// If the two disagree, every row wraps and the screen repeats itself. So the
/// cell metrics used must be the ones the renderer actually reports, never a
/// guess — `fallbackCellSize` exists only to bootstrap the first handshake.
public enum SurfaceGeometry {
    /// Rough metrics for a 13 pt monospaced font, in points, used before any
    /// surface has reported its real cell size.
    ///
    /// The daemon renders the tab at whatever grid the first handshake asks for,
    /// so a fallback in the wrong unit asks for the wrong grid and every pane
    /// comes out too wide to fit (and every row wraps). Report it in the same
    /// unit as measured metrics — device pixels — by scaling at use.
    public static let fallbackCellPoints = CGSize(width: 7.8, height: 17.0)

    /// The fallback in device pixels, matching what Ghostty reports.
    public static var fallbackCellSize: CGSize {
        CGSize(
            width: fallbackCellPoints.width * backingScale,
            height: fallbackCellPoints.height * backingScale
        )
    }

    /// Cells that fit in `size`.
    ///
    /// `cellSize` is in device pixels (what Ghostty reports) and `size` in points,
    /// so the point size is scaled before dividing. Rounding down is deliberate:
    /// asking for a column more than fits is what causes wrapping.
    public static func cells(
        for size: CGSize,
        cellSize: CGSize,
        scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2
    ) -> ClientSurfaceSize {
        let cellWidth = max(cellSize.width, 1)
        let cellHeight = max(cellSize.height, 1)
        let cols = Int(((size.width * scale) / cellWidth).rounded(.down))
        let rows = Int(((size.height * scale) / cellHeight).rounded(.down))
        // Lower bounds are small on purpose: a narrow split pane can legitimately
        // be a handful of cells wide, and raising the floor there would ask the
        // daemon for more columns than fit, which is exactly the wrapping bug.
        return ClientSurfaceSize(
            cols: UInt16(min(max(cols, 4), 500)),
            rows: UInt16(min(max(rows, 2), 200))
        )
    }

    /// Converts Ghostty's device-pixel cell metrics into points for layout.
    public static var backingScale: CGFloat {
        NSScreen.main?.backingScaleFactor ?? 2
    }

    public static func points(for cellSize: CGSize) -> CGSize {
        CGSize(width: cellSize.width / backingScale, height: cellSize.height / backingScale)
    }
}

/// Reports the pane area's size so the store can negotiate a matching grid.
private struct SurfaceGeometryReader: ViewModifier {
    @Environment(AppStore.self) private var store
    @State private var pendingSize: CGSize?
    @State private var debounce: Task<Void, Never>?
    @State private var lastScheduled: CGSize?

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { schedule(proxy.size) }
                    .onChange(of: proxy.size) { _, newSize in schedule(newSize) }
                    // Measured cell metrics invalidate the current grid; the
                    // pane area did not change, so re-read it from here.
                    .onChange(of: store.terminalCellSize) { _, _ in
                        schedule(proxy.size, force: true)
                    }
                    .onChange(of: store.needsGeometryReeval) { _, needed in
                        guard needed else { return }
                        store.needsGeometryReeval = false
                        schedule(proxy.size, force: true)
                    }
            }
        }
    }

    private func schedule(_ size: CGSize, force: Bool = false) {
        guard size.width > 8, size.height > 8 else { return }
        if !force, lastScheduled == size { return }
        lastScheduled = size
        pendingSize = size
        debounce?.cancel()
        debounce = Task { @MainActor in
            // Coalesce a drag into one negotiation.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let pendingSize else { return }
            let cells = SurfaceGeometry.cells(
                for: pendingSize,
                cellSize: store.terminalCellSize
            )
            store.resizeSurface(cols: cells.cols, rows: cells.rows)
        }
    }
}

public extension View {
    /// Attaches surface-geometry negotiation to the pane container.
    func negotiatingSurfaceGeometry() -> some View {
        modifier(SurfaceGeometryReader())
    }
}
