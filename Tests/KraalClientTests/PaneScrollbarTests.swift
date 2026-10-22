// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Tests for the pane scrollbar geometry.
//
// The reason this is a separate file from the view: a thumb that is one cell off
// looks entirely plausible. There is no "type error" for "the drag lands two rows
// from where you let go", and nobody reports it — they just find the scrollbar
// slightly annoying. So the arithmetic is asserted as numbers.
//

import Foundation
import Testing

@testable import KraalProtocol
@testable import KraalUI

@Suite("Pane scrollbar")
struct PaneScrollbarTests {
    private func metrics(
        offset: UInt64,
        max: UInt64,
        viewport: UInt64
    ) -> PaneSurfaceScrollMetrics {
        PaneSurfaceScrollMetrics(
            offsetFromBottom: offset,
            maxOffsetFromBottom: max,
            viewportRows: viewport
        )
    }

    /// No scrollback is the common case (a fresh pane, a full-screen TUI) and must
    /// draw nothing. Upstream returns early on the same condition
    /// (`ui/scrollbar.rs:138-140`); drawing here would put a bar at the top of an
    /// empty track forever.
    @Test("no scrollback means no thumb")
    func noScrollbackNoThumb() {
        #expect(PaneScrollbar.thumb(metrics(offset: 0, max: 0, viewport: 24), laneHeight: 24) == nil)
        #expect(PaneScrollbar.offset(
            forClickAtRow: 5,
            metrics: metrics(offset: 0, max: 0, viewport: 24),
            laneHeight: 24
        ) == nil)
    }

    /// A zero-height lane has nowhere to draw; dividing by it would be a crash.
    @Test("a zero-height lane has no thumb")
    func emptyLane() {
        #expect(PaneScrollbar.thumb(metrics(offset: 0, max: 100, viewport: 24), laneHeight: 0) == nil)
    }

    /// The regression that matters most: at the bottom of the history the thumb is
    /// at the bottom of the lane. `offsetFromBottom == 0` is "showing the newest
    /// output", which is where a terminal spends almost all its time.
    @Test("at the newest output the thumb sits at the bottom")
    func bottomOfHistory() {
        // 100 rows of history, 25 rows on screen, 50-cell lane:
        // total = 125, thumb = 25*50/125 = 10, maxTop = 40.
        let thumb = PaneScrollbar.thumb(
            metrics(offset: 0, max: 100, viewport: 25),
            laneHeight: 50
        )
        #expect(thumb == PaneScrollbarThumb(top: 40, length: 10))
    }

    /// ...and scrolled all the way back it sits at the top. These two are the ends
    /// the user judges the scrollbar by; a half-cell error in either is visible.
    @Test("scrolled to the oldest output the thumb sits at the top")
    func topOfHistory() {
        let thumb = PaneScrollbar.thumb(
            metrics(offset: 100, max: 100, viewport: 25),
            laneHeight: 50
        )
        #expect(thumb == PaneScrollbarThumb(top: 0, length: 10))
    }

    /// Halfway through the history is halfway down the track. This is the case
    /// that catches a wrong sign: using `offsetFromBottom` directly instead of
    /// `max - offset` puts the thumb at the top here while claiming the bottom.
    @Test("halfway through the history is halfway down the lane")
    func halfway() {
        let thumb = PaneScrollbar.thumb(
            metrics(offset: 50, max: 100, viewport: 25),
            laneHeight: 50
        )
        #expect(thumb == PaneScrollbarThumb(top: 20, length: 10))
    }

    /// A viewport taller than the history has nothing to scroll *within* — but the
    /// daemon still reports a non-zero max, so the thumb must be full height and
    /// pinned. Allowing it to exceed the lane would draw outside the pane.
    @Test("a viewport taller than the history fills the lane")
    func thumbNeverExceedsLane() {
        let thumb = PaneScrollbar.thumb(
            metrics(offset: 0, max: 5, viewport: 100),
            laneHeight: 10
        )
        #expect(thumb == PaneScrollbarThumb(top: 0, length: 10))
    }

    /// A `totalRows` that overflows means the daemon sent something absurd. Draw
    /// nothing rather than wrapping into a plausible-looking small number: a wrong
    /// thumb with no trace of why is worse than no thumb.
    @Test("an overflowing total draws nothing instead of wrapping")
    func overflowingTotalRefused() {
        // `viewportRows: 2` and not `1`, deliberately: `.max + 1` wraps to **0**,
        // which a `totalRows > 0` guard rejects by accident, so a test using 1
        // passes even when the overflow check is removed (verified — the first
        // version of this test did exactly that). `.max + 2` wraps to 1, a value
        // that looks perfectly plausible, which is the case worth guarding.
        let absurd = PaneSurfaceScrollMetrics(
            offsetFromBottom: 0,
            maxOffsetFromBottom: .max,
            viewportRows: 2
        )
        #expect(PaneScrollbar.thumb(absurd, laneHeight: 20) == nil)
    }

    /// A tiny history still gets a visible thumb: rounding to zero would draw
    /// nothing at all, which looks like "this pane has no scrollback".
    @Test("a tiny history still gets at least one cell")
    func thumbIsAtLeastOneCell() {
        let thumb = PaneScrollbar.thumb(
            metrics(offset: 0, max: 10_000, viewport: 1),
            laneHeight: 10
        )
        #expect(thumb?.length == 1)
    }

    /// The daemon can report an offset past its own maximum for a frame while the
    /// viewport catches up. Subtracting it would underflow and put the thumb at
    /// the bottom of the lane, which reads as "you are at the newest output" —
    /// exactly backwards.
    @Test("an offset past the maximum does not underflow")
    func offsetPastMaximum() {
        let thumb = PaneScrollbar.thumb(
            metrics(offset: 500, max: 100, viewport: 25),
            laneHeight: 50
        )
        #expect(thumb == PaneScrollbarThumb(top: 0, length: 10))
    }

    // MARK: - Reading the pane

    /// Builds a pane the way the daemon sends one.
    ///
    /// Built through the memberwise initialiser rather than JSON: `PaneSurfacePane`
    /// is decoded by hand from bincode (`Decoder.swift:108-135`) and has no
    /// `Decodable` conformance, so there is no JSON form to round-trip through.
    private func pane(
        scrollbarHeight: UInt16?,
        offset: UInt64?,
        max: UInt64?,
        viewport: UInt64?
    ) -> PaneSurfacePane {
        let scroll: PaneSurfaceScrollMetrics? = if let offset, let max, let viewport {
            PaneSurfaceScrollMetrics(
                offsetFromBottom: offset,
                maxOffsetFromBottom: max,
                viewportRows: viewport
            )
        } else {
            nil
        }
        return PaneSurfacePane(
            paneId: "w1:p1",
            contentRevision: 1,
            rect: SurfaceRect(originX: 0, originY: 0, width: 24, height: 12),
            innerRect: SurfaceRect(originX: 0, originY: 0, width: 23, height: 12),
            scrollbarRect: scrollbarHeight.map {
                SurfaceRect(originX: 23, originY: 0, width: 1, height: $0)
            },
            scroll: scroll,
            focused: true,
            mouseReporting: false,
            sgrPixelMouse: false,
            alternateScreenActive: false,
            pixelWidth: 0,
            pixelHeight: 0
        )
    }

    /// The lane height comes from the daemon's `scrollbar_rect`, **not** from the
    /// scroll metrics. They are different numbers (the rect is in cells, the
    /// metrics are in rows of history), and using the viewport height there makes
    /// every thumb the wrong length — which is exactly the mistake an injection
    /// test confirmed this file would otherwise not catch.
    @Test("the lane height is the lane rect's height, not the viewport")
    func laneHeightComesFromTheRect() {
        let surfacePane = pane(scrollbarHeight: 30, offset: 0, max: 90, viewport: 24)
        #expect(surfacePane.scrollbarLaneHeight == 30)
        // 24 rows on screen out of 114 total in a 30-cell lane → 6 cells.
        #expect(surfacePane.scrollbarThumb?.length == 6)
        #expect(surfacePane.scrollbarThumb?.top == 24)
    }

    /// No lane means the daemon decided not to show one (`pane_scrollbars` off, or
    /// an alternate screen). Drawing a thumb then would put chrome where the
    /// daemon deliberately reserved no space — it would overlap content.
    @Test("no lane rect means no thumb")
    func noLaneNoThumb() {
        let surfacePane = pane(scrollbarHeight: nil, offset: 0, max: 90, viewport: 24)
        #expect(surfacePane.scrollbarLaneHeight == nil)
        #expect(surfacePane.scrollbarThumb == nil)
    }

    /// A lane with metrics but no scrollback is the common case: the lane exists
    /// (the daemon reserves it to keep the terminal width stable) but there is
    /// nothing to indicate.
    @Test("a lane without scrollback has no thumb")
    func laneWithoutScrollback() {
        let surfacePane = pane(scrollbarHeight: 30, offset: 0, max: 0, viewport: 24)
        #expect(surfacePane.scrollbarLaneHeight == 30)
        #expect(surfacePane.scrollbarThumb == nil)
    }

    /// Metrics without a lane rect: nothing to draw on.
    @Test("metrics without a lane have no thumb")
    func metricsWithoutLane() {
        let surfacePane = pane(scrollbarHeight: nil, offset: 0, max: 90, viewport: 24)
        #expect(surfacePane.scrollbarThumb == nil)
    }

    /// A zero-height lane is treated as absent rather than as a divide-by-zero.
    @Test("a zero-height lane is absent")
    func zeroHeightLane() {
        let surfacePane = pane(scrollbarHeight: 0, offset: 0, max: 90, viewport: 24)
        #expect(surfacePane.scrollbarLaneHeight == nil)
    }

    /// The overlay sizes one cell as `lane.height / laneCells`, so `laneCells` has
    /// to be the lane's height — **independent of where the thumb is**.
    ///
    /// An earlier version derived it as `thumb.top + thumb.length`, which is only
    /// correct at the bottom of the lane. Scrolled to the top (the state a user is
    /// in exactly when they are looking at the scrollbar) it reported `length`
    /// cells for a 50-cell lane, making every cell five times too tall and the
    /// thumb fill the whole track. Asserted here because the overlay cannot be
    /// tested directly — it has no pixel output to inspect.
    @Test("the lane height in cells never depends on the thumb position")
    func laneCellCountIsStable() throws {
        let laneCells = 50
        var reported: [Int] = []
        // Bottom, middle, top of a 100-row history in a 25-row viewport.
        for offset in [UInt64(0), 50, 100] {
            let surfacePane = pane(
                scrollbarHeight: UInt16(laneCells),
                offset: offset,
                max: 100,
                viewport: 25
            )
            let thumb = try #require(surfacePane.scrollbarThumb)
            reported.append(surfacePane.scrollbarLaneHeight ?? 0)
            // The bug's fingerprint: deriving the lane from the thumb.
            let derivedFromThumb = thumb.top + thumb.length
            #expect(
                derivedFromThumb <= laneCells,
                "a thumb must never claim a taller lane than it has"
            )
        }
        #expect(reported == [50, 50, 50], "the lane height changed with the thumb")
    }

    // MARK: - Lane geometry

    /// One cell is `lane.height / laneCells` whatever the thumb is doing.
    ///
    /// This is the assertion the overlay cannot make for itself: a SwiftUI `body`
    /// has no inspectable output, so the wrong `cellHeight` still *draws* — just at
    /// the wrong scale. The bug it guards produced a thumb several times too tall
    /// whenever the pane was scrolled to the top.
    @Test("cell height is the lane divided by its cell count")
    func cellHeightIndependentOfThumb() throws {
        let pixelHeight: CGFloat = 500
        let laneCells = 50

        for offset in [UInt64(0), 50, 100] {
            let metrics = metrics(offset: offset, max: 100, viewport: 25)
            let thumb = try #require(PaneScrollbar.thumb(metrics, laneHeight: laneCells))
            let geometry = try #require(PaneScrollbarLane.layout(
                pixelHeight: pixelHeight,
                laneCells: laneCells,
                thumb: thumb
            ))
            #expect(geometry.cellHeight == 10, "cell height changed with thumb position")
            #expect(geometry.thumbOffset == 10 * CGFloat(thumb.top))
            // Thumb is 10 cells of 50 → 100pt of 500pt.
            #expect(geometry.thumbHeight == 100)
        }
    }

    /// The thumb's bottom edge never leaves the lane. With offsets computed
    /// independently this can drift, and a thumb that overhangs its track is the
    /// kind of thing nobody files a bug about but everybody notices.
    @Test("the thumb never overhangs the lane")
    func thumbStaysInsideLane() throws {
        let pixelHeight: CGFloat = 300
        let laneCells = 30
        for offset in stride(from: UInt64(0), through: 200, by: 20) {
            let metrics = metrics(offset: offset, max: 200, viewport: 30)
            let thumb = try #require(PaneScrollbar.thumb(metrics, laneHeight: laneCells))
            let geometry = try #require(PaneScrollbarLane.layout(
                pixelHeight: pixelHeight,
                laneCells: laneCells,
                thumb: thumb
            ))
            #expect(geometry.thumbOffset >= 0)
            #expect(
                geometry.thumbOffset + geometry.thumbHeight <= pixelHeight + 0.001,
                "thumb bottom \(geometry.thumbOffset + geometry.thumbHeight) past \(pixelHeight)"
            )
        }
    }

    /// A degenerate lane draws nothing rather than dividing by zero.
    @Test("a lane with no cells or no pixels has no geometry")
    func degenerateLane() {
        let thumb = PaneScrollbarThumb(top: 0, length: 1)
        #expect(PaneScrollbarLane.layout(pixelHeight: 100, laneCells: 0, thumb: thumb) == nil)
        #expect(PaneScrollbarLane.layout(pixelHeight: 0, laneCells: 10, thumb: thumb) == nil)
        #expect(PaneScrollbarLane.layout(pixelHeight: 100, laneCells: 10, thumb: nil) == nil)
    }

    // MARK: - Placement

    /// The lane lands inside *its own* pane, not on the neighbour.
    ///
    /// The regression: the overlay was attached after `.position`, where the
    /// view's bounds are the whole pane container. Subtracting the pane origin
    /// there (the correct rebase for a pane-attached overlay) put every lane one
    /// pane-width to the left and on the container's top edge — invisible on the
    /// pane at the origin, wrong on all the others.
    @Test("the lane is rebased onto its own pane")
    func laneRebasedOntoPane() {
        // A pane 400pt wide at x=400 in a two-pane split, with a 1-cell lane at
        // the pane's right edge (cell width 8).
        let pane = CGRect(x: 400, y: 0, width: 400, height: 300)
        let laneInContainer = CGRect(x: 792, y: 0, width: 8, height: 300)
        let local = PaneScrollbarOverlay.laneRect(lane: laneInContainer, pane: pane)

        // Inside the pane's own box: 0..<400.
        #expect(local.minX == 392, "lane must sit at the pane's right edge")
        #expect(local.maxX == 400)
        #expect(local.minY == 0)
        #expect(local.width == 8)
        #expect(local.height == 300)
    }

    /// The second pane of a vertical split: the rebase must also move vertically.
    /// A doubled subtraction made this always 0, pinning every lane to the top.
    @Test("the lane is rebased vertically too")
    func laneRebasedVertically() {
        let pane = CGRect(x: 0, y: 300, width: 500, height: 300)
        let laneInContainer = CGRect(x: 492, y: 300, width: 8, height: 300)
        let local = PaneScrollbarOverlay.laneRect(lane: laneInContainer, pane: pane)
        #expect(local.minY == 0)
        #expect(local.minX == 492)
    }

    /// A pane at the origin is the case that hid the bug: subtracting zero twice
    /// is still zero, so it looked correct.
    @Test("a pane at the origin needs no rebase")
    func originPaneNeedsNoRebase() {
        let pane = CGRect(x: 0, y: 0, width: 300, height: 200)
        let lane = CGRect(x: 292, y: 0, width: 8, height: 200)
        #expect(PaneScrollbarOverlay.laneRect(lane: lane, pane: pane) == lane)
    }

    // MARK: - Clicking

    /// Clicking the lane moves the viewport there, with the thumb centred on the
    /// click. Clicking the very top scrolls to the oldest output.
    @Test("clicking the top of the lane scrolls to the oldest output")
    func clickTop() {
        let offset = PaneScrollbar.offset(
            forClickAtRow: 0,
            metrics: metrics(offset: 0, max: 100, viewport: 25),
            laneHeight: 50
        )
        #expect(offset == 100)
    }

    /// ...and the bottom scrolls back to the newest. This is the pair that proves
    /// the inverse conversion has the right sign.
    @Test("clicking the bottom of the lane scrolls to the newest output")
    func clickBottom() {
        let offset = PaneScrollbar.offset(
            forClickAtRow: 49,
            metrics: metrics(offset: 100, max: 100, viewport: 25),
            laneHeight: 50
        )
        #expect(offset == 0)
    }

    /// **The bug this file was rewritten for.** The offset conversion needs the
    /// lane height, which is *not* recoverable from a thumb alone: a thumb at
    /// `top: 3` of length 2 could be in a lane of 5 or of 20. An earlier version
    /// derived it from `thumb.top` and therefore produced the wrong offset for
    /// every thumb that was not at the bottom of the lane — clicks landed near the
    /// top of the history no matter where you clicked.
    @Test("a mid-lane click maps to a mid-history offset")
    func midLaneClickRoundTrips() {
        let mid = metrics(offset: 50, max: 100, viewport: 25)
        let thumb = PaneScrollbar.thumb(mid, laneHeight: 50)
        #expect(thumb == PaneScrollbarThumb(top: 20, length: 10))

        // Clicking the middle of the thumb must be (approximately) a no-op, not a
        // jump. With the thumb at 20..<30, row 25 is its centre.
        let offset = PaneScrollbar.offset(
            forClickAtRow: 25,
            metrics: mid,
            laneHeight: 50
        )
        #expect(offset == 50)
    }

    // MARK: - Dragging

    /// Dragging from the thumb's bottom edge must not jump: `grabOffset` records
    /// how far into the thumb the press landed, and the drag subtracts it.
    @Test("a drag from the thumb's bottom edge keeps its grab offset")
    func dragKeepsGrabOffset() {
        let mid = metrics(offset: 50, max: 100, viewport: 25)
        // Thumb occupies 20..<30, so a press at 29 is 9 cells into it.
        #expect(PaneScrollbar.grabOffset(atRow: 29, metrics: mid, laneHeight: 50) == 9)

        // Dragging to the same row is a no-op, because the grab offset puts the
        // thumb back where it started.
        let offset = PaneScrollbar.offset(
            forDragToRow: 29,
            grabOffset: 9,
            metrics: mid,
            laneHeight: 50
        )
        #expect(offset == 50)
    }

    /// A press outside the thumb is a click, not a drag. Returning `nil` is how the
    /// caller decides which gesture it has.
    @Test("a press outside the thumb has no grab offset")
    func grabOffsetOutsideThumb() {
        let mid = metrics(offset: 50, max: 100, viewport: 25)
        #expect(PaneScrollbar.grabOffset(atRow: 5, metrics: mid, laneHeight: 50) == nil)
        #expect(PaneScrollbar.grabOffset(atRow: 40, metrics: mid, laneHeight: 50) == nil)
        // The edges are inclusive at the top, exclusive at the bottom.
        #expect(PaneScrollbar.grabOffset(atRow: 20, metrics: mid, laneHeight: 50) == 0)
        #expect(PaneScrollbar.grabOffset(atRow: 30, metrics: mid, laneHeight: 50) == nil)
    }

    /// Dragging above the lane clamps instead of producing a negative offset.
    @Test("a drag above the lane clamps to the oldest output")
    func dragAboveLaneClamps() {
        let offset = PaneScrollbar.offset(
            forDragToRow: -50,
            grabOffset: 0,
            metrics: metrics(offset: 0, max: 100, viewport: 25),
            laneHeight: 50
        )
        #expect(offset == 100)
    }

    /// With no scrollback there is no drag to make, so the caller must not send a
    /// request. `nil` rather than 0, because 0 is a legitimate offset.
    @Test("dragging without scrollback yields no request")
    func dragWithoutScrollback() {
        #expect(PaneScrollbar.offset(
            forDragToRow: 10,
            grabOffset: 0,
            metrics: metrics(offset: 0, max: 0, viewport: 24),
            laneHeight: 24
        ) == nil)
    }
}
