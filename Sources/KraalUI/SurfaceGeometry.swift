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
    /// The daemon's hard limits on a surface grid.
    ///
    /// `herdr-gpui/crates/herdr-client/src/options.rs:22` `validate_options`: at
    /// most 4096 per axis and 1 000 000 cells in total. Asking for more is not a
    /// harmless probe — the request goes out and the daemon refuses it, and the
    /// refusal is invisible in the UI.
    public static let maxCols = 4096
    public static let maxRows = 4096
    public static let maxCells = 1_000_000

    /// What this window can actually show. Tighter than the daemon's ceiling on
    /// purpose: a window bigger than this many cells means the cell metrics are
    /// wrong, not that the user wants a 4096-column terminal.
    public static let windowColsLimit = 500
    public static let windowRowsLimit = 200

    /// Whether a grid is one the daemon will accept.
    ///
    /// Both bounds matter. Zero is the obvious one; the ceiling is the quiet one
    /// — a bogus cell size produces a huge `cols`, and without this guard that
    /// travels to the daemon as a real request.
    public static func isAcceptableGrid(cols: Int, rows: Int) -> Bool {
        cols > 0 && rows > 0
            && cols <= maxCols && rows <= maxRows
            && cols * rows <= maxCells
    }

    /// Whether an incoming content revision means the delta stream was renumbered.
    ///
    /// Revisions only ever increase within one projection. A smaller one means
    /// the daemon started a fresh projection — a tab switch, a reconnect, a new
    /// boot — so frames already rendered belong to a stream that no longer exists
    /// and cannot be patched. Treating it as a stale frame instead leaves the
    /// pane blank: no later revision will ever exceed the stale high-water mark.
    public static func deltaStreamRestarted(
        previousRevision: UInt64,
        incomingRevision: UInt64
    ) -> Bool {
        incomingRevision < previousRevision
    }

    /// Identifies which projection a surface belongs to.
    ///
    /// Two things can make the cells on screen stop meaning anything: the daemon
    /// booted again, or it re-projected onto a different tab. Neither is visible
    /// in a pane's `contentRevision`, which keeps climbing across the whole daemon
    /// session and is not reset by a re-projection.
    public struct ProjectionIdentity: Equatable, Sendable {
        public var bootId: String
        public var revision: UInt64

        public init(bootId: String, revision: UInt64) {
            self.bootId = bootId
            self.revision = revision
        }
    }

    /// Whether a surface belongs to a different projection than the last one.
    ///
    /// This is the judgement that a workspace or machine switch needs and that
    /// revisions alone cannot make: two machines name their first workspace's
    /// first pane the same way, can hand over the same pane geometry, and count
    /// revisions independently — so a switch between them can arrive with every
    /// number unchanged while the pixels belong to the other machine. `bootId` is
    /// stamped at daemon boot and never shared, which is what separates them.
    ///
    /// A moved revision also counts: a daemon re-projects onto another tab without
    /// rebooting, and that re-numbering is how the client hears about it.
    ///
    /// This does **not** make a scroll a projection change — measured on a real
    /// scroll (`Scripts/gui.sh run scroll`): `projectionRevision` stayed at 5 across
    /// the scroll while `surfaceRevision` and `contentRevision` advanced. The white
    /// flash while scrolling came from somewhere else; see `PaneTerminal.apply`,
    /// which compared a pane-sized frame against a surface-sized grid.
    public static func projectionChanged(
        previous: ProjectionIdentity?,
        current: ProjectionIdentity
    ) -> Bool {
        guard let previous else { return true }
        return previous.bootId != current.bootId
            || previous.revision != current.revision
    }

    /// Whether a frame has to be parked because the terminal has no grid yet.
    ///
    /// Ghostty attaches its surface asynchronously. A frame that arrives before
    /// that has no grid to be laid out in, so writing it is useless and the pane
    /// is left blank — which is what made a tab switch show an empty pane until
    /// something printed again. Such a frame must be held and painted when the
    /// grid appears.
    public static func needsParkingUntilGridIsKnown(hasGrid: Bool) -> Bool {
        !hasGrid
    }

    /// Whether a frame must be painted even though its revision is unchanged.
    ///
    /// A pane's content revision only moves when its *content* changes, so it
    /// stays put when the pane merely gets a new grid. Going from a split to full
    /// width rewrites every row without touching a single cell of text, and the
    /// already-painted frame is then the wrong width. Keying repaints on the
    /// revision alone skipped exactly those frames.
    ///
    /// Scrolling is the other case, and the one that survived longest: the daemon
    /// renders the scrolled viewport into `cells`, but scrolling is a *view*
    /// operation — it never calls `content_seq.fetch_add` (`pane.rs:3408-3413`), so
    /// the revision stays put and the grid does not change. The frame therefore
    /// looked identical by every cheap measure and was dropped, while the scrollbar
    /// — which comes from `scroll.offset_from_bottom`, a different field — moved
    /// correctly. Measured: `rev=66 last=66 sameCells=false off=30/166`, i.e. the
    /// cells had changed and nothing repainted them.
    ///
    /// `cellsDiffer` is what closes that gap. It is only consulted when the cheap
    /// reasons are all false, so a normal printing frame never pays for it.
    public static func needsRepaint(
        contentRevisionChanged: Bool,
        previousGrid: (width: Int, height: Int)?,
        currentGrid: (width: Int, height: Int),
        cellsDiffer: @autoclosure () -> Bool = false,
        graphicsDiffer: @autoclosure () -> Bool = false
    ) -> Bool {
        if contentRevisionChanged { return true }
        guard let previousGrid else { return true }
        if previousGrid.width != currentGrid.width
            || previousGrid.height != currentGrid.height { return true }
        // Last, and lazily: comparing every cell is only worth it once the cheap
        // reasons have been ruled out. `@autoclosure` keeps a frame that repainted
        // for one of those reasons from paying for a comparison nobody asked.
        //
        // Graphics are a third, independent reason. An image can move, appear or be
        // removed without a single cell changing: the cells under it are covered by
        // the image, so the daemon's cell buffer is identical. Comparing cells alone
        // therefore dropped those frames and the picture froze at its old position
        // until something else happened to repaint (#105).
        return cellsDiffer() || graphicsDiffer()
    }

    /// Whether the cells changed, ignoring the cursor.
    ///
    /// The two are deliberately separate. A cursor move is the single most
    /// frequent thing a terminal does — every keystroke, every line an app
    /// prints — and it needs nothing more than a reposition. The *cells* did not
    /// change, so nothing on screen has to be erased and redrawn.
    ///
    /// Treating "the frame differs" and "the cells differ" as the same question
    /// is what made pressing Return flash: the cursor dropped one row, the
    /// frames compared unequal, and the whole screen was wiped and repainted for
    /// a change that was one escape sequence wide.
    public static func cellsChanged(previous: FrameData?, current: FrameData) -> Bool {
        guard let previous else { return true }
        guard previous.width == current.width, previous.height == current.height else {
            return true
        }
        // `buffer` equality, not `flatCells`: the row-chunked storage compares a
        // row whose buffer is shared in O(1) and only scans the rows that differ,
        // so the common case (one row changed) stays cheap. Flattening first would
        // allocate the whole screen on every call (issue #50).
        return previous.buffer != current.buffer
    }

    /// Whether a frame needs the screen erased before it can be painted.
    ///
    /// Erasing (and dropping scrollback) is only required when the *cell grid*
    /// cannot be trusted any more: the terminal's width or height changed, or the
    /// delta stream restarted and the renderer's idea of the screen refers to a
    /// stream that no longer exists. A cursor-only move, or even new text inside
    /// an unchanged grid, is expressible as a delta and must not trigger it.
    ///
    /// Note what is *not* a reason to erase: the cells differing. That is the
    /// normal case — every frame that prints anything differs — and the renderer
    /// already emits just the rows that changed for it.
    public static func needsScreenReset(
        deltaStreamRestarted: Bool,
        previousGrid: (width: Int, height: Int)?,
        currentGrid: (width: Int, height: Int)
    ) -> Bool {
        if deltaStreamRestarted { return true }
        guard let previousGrid else { return true }
        // Only a **width** change needs a screen reset.
        //
        // A width change reflows every row: no cell keeps its coordinate, so the
        // only trustworthy action is to throw the baseline away. A height change
        // does not — a row is still at the same column, and rows above the old
        // height are untouched. `SurfaceANSIRenderer` clears the rows the frame no
        // longer covers and diffs the rest.
        //
        // This is the difference between a drag that feels heavy and one that does
        // not. Measured on a live session: 1139 of 1195 paints during a drag went
        // through the `clearingFirst` path at ~6 KB of ANSI each, up to 97 paints
        // in one second, because every one-row height change was treated as a
        // reset. Height changes dominate a vertical drag.
        return previousGrid.width != currentGrid.width
    }

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
            cols: UInt16(min(max(cols, 4), windowColsLimit)),
            rows: UInt16(min(max(rows, 2), windowRowsLimit))
        )
    }

    /// Converts Ghostty's device-pixel cell metrics into points for layout.
    ///
    /// `NSScreen.main` is the screen with the menu bar, *not* the screen the
    /// window is on. On a single-display Mac those are the same and the
    /// difference is invisible; with a Retina laptop plus a scale-1 external, a
    /// window on the external display gets the built-in screen's scale factor
    /// and every cell is off by a factor of two — in every pane, which is what
    /// makes it look like one global offset instead of a per-pane mistake.
    /// Views therefore pass the scale down from SwiftUI's `displayScale`, which
    /// follows the view's own screen; this default stays only for callers with no
    /// view context (tests, and the very first layout before a window exists).
    public static var backingScale: CGFloat {
        NSScreen.main?.backingScaleFactor ?? 2
    }

    public static func points(
        for cellSize: CGSize,
        scale: CGFloat = SurfaceGeometry.backingScale
    ) -> CGSize {
        CGSize(width: cellSize.width / scale, height: cellSize.height / scale)
    }
}

/// When a resize should be released, as a pure decision so it can be tested.
///
/// Split out of the view because the interesting part is a timing rule, and a
/// timing rule buried in a `ViewModifier` can only be checked by dragging a window
/// by hand. The two edges it describes are what the bug was about:
///
/// - *leading*: a size change during a drag must go out at once, or the panes wait
///   for the gesture to end before they follow the window;
/// - *trailing*: the size the gesture stopped on must still be sent, including
///   when the drag ended inside the leading-edge interval.
public enum ResizePacing {
    /// Shortest gap between two negotiations while a resize is in progress.
    public static let dragInterval: TimeInterval = 0.05
    /// Quiet period after which a resize is treated as finished.
    public static let settleDelay: TimeInterval = 0.18

    /// Whether a size change is released immediately rather than coalesced.
    ///
    /// `sinceLastRelease` is how long ago the previous grid went to the daemon.
    /// A forced change (measured cell metrics, a geometry re-evaluation) is not
    /// part of a drag and always goes out.
    public static func releasesImmediately(
        sinceLastRelease: TimeInterval,
        forced: Bool
    ) -> Bool {
        forced || sinceLastRelease >= dragInterval
    }
}

/// Reports the pane area's size so the store can negotiate a matching grid.
private struct SurfaceGeometryReader: ViewModifier {
    @Environment(AppStore.self) private var store
    /// The scale of the screen this view is actually on. Not `NSScreen.main`,
    /// which belongs to the menu bar's screen and is the wrong screen whenever
    /// the window has been dragged to another display.
    @Environment(\.displayScale) private var displayScale
    @State private var pendingSize: CGSize?
    @State private var debounce: Task<Void, Never>?
    @State private var lastScheduled: CGSize?
    /// When the last resize was actually released to the store.
    @State private var lastReleasedAt = Date.distantPast

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

    /// Releases a new grid while a resize is happening and once more when it stops.
    ///
    /// A trailing debounce alone cannot do this: it restarts on every event, and a
    /// window drag never stops emitting them, so the negotiation only started
    /// ~350 ms *after* the user let go — the panes stayed at the old size for the
    /// whole gesture. Leading + trailing keeps up during the drag and still
    /// guarantees the final size lands exactly once after it.
    private func schedule(_ size: CGSize, force: Bool = false) {
        guard size.width > 8, size.height > 8 else { return }
        if !force, lastScheduled == size { return }
        lastScheduled = size
        pendingSize = size

        let now = Date()
        if ResizePacing.releasesImmediately(
            sinceLastRelease: now.timeIntervalSince(lastReleasedAt),
            forced: force
        ) {
            // Leading edge: the first change, and anything spaced by at least
            // `dragInterval`, goes out immediately.
            release(size)
        }
        debounce?.cancel()
        debounce = Task { @MainActor in
            // Trailing edge: the size the gesture ended on.
            try? await Task.sleep(for: .seconds(ResizePacing.settleDelay))
            guard !Task.isCancelled, let pendingSize else { return }
            release(pendingSize)
        }
    }

    private func release(_ size: CGSize) {
        lastReleasedAt = Date()
        let cells = SurfaceGeometry.cells(
            for: size,
            cellSize: store.terminalCellSize,
            scale: displayScale
        )
        store.resizeSurface(cols: cells.cols, rows: cells.rows)
    }
}

public extension View {
    /// Attaches surface-geometry negotiation to the pane container.
    func negotiatingSurfaceGeometry() -> some View {
        modifier(SurfaceGeometryReader())
    }
}
