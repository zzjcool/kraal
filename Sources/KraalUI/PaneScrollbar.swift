// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  PaneScrollbar.swift
//  Kraal
//
//  Where the scrollbar thumb sits inside a pane's scrollbar lane.
//
//  **The lane is an indicator, not a control.** Clicking and dragging it is not
//  wired up: `PaneScrollbarOverlay` is `allowsHitTesting(false)`, because mouse
//  input for a pane belongs to its AppKit surface and a second hit-testing path
//  over the same pane is how two code paths end up disagreeing about what a click
//  meant. The click/drag offset conversions below are the arithmetic that path
//  will need; they are exercised by tests and have no caller yet. Wiring them
//  means routing a press in the lane through `MouseCoordinateMapper` (mind
//  `AGENTS.md`'s one-command-per-connection rule: a scroll must not be issued in
//  the same tick as a focus change).
//
//  Split from the view for the same reason as everything else in this module: the
//  arithmetic is the part that can be wrong in a way nobody notices. A thumb that
//  is one row off looks plausible, and the only way to catch it in CI is to assert
//  the numbers. Ported from the daemon's own `ui/scrollbar.rs`, which draws the
//  same indicator in a terminal, so the two clients agree on what the user sees.
//
//  ## What the daemon gives us
//
//  `PaneSurfacePane.scrollbarRect` is the **lane** — a one-cell-wide column
//  spanning the pane's full height — not the thumb. The daemon has already
//  narrowed `innerRect` by that column when the lane is visible, so drawing here
//  cannot cover terminal content. `scroll` carries the three numbers the thumb
//  needs. Both were decoded from the start and neither was read by the UI, which
//  is why panes had no scroll indicator at all.
//
//  ## Why this is drawn in SwiftUI and not through the ANSI stream
//
//  Every pane's cells are re-encoded as VT sequences and fed to a real Ghostty
//  surface. Painting the scrollbar that way would mean writing characters into
//  cells the daemon considers content — and worse, into *Ghostty's* scrollback,
//  which would then disagree with the daemon's, so a later diff would repaint over
//  the wrong rows. The daemon draws its scrollbar into a buffer it owns; this
//  client's equivalent of "its own buffer" is a SwiftUI overlay.
//

#if canImport(SwiftUI)
    import SwiftUI
#endif
import CoreGraphics
import KraalProtocol

/// The thumb's vertical extent, in cells relative to the lane's top.
public struct PaneScrollbarThumb: Equatable, Sendable {
    /// Offset from the top of the lane, in cells.
    public var top: Int
    /// Height, in cells. Always at least 1 and at most the lane height.
    public var length: Int

    public init(top: Int, length: Int) {
        self.top = top
        self.length = length
    }
}

public enum PaneScrollbar {
    /// The thumb for these metrics, or `nil` when there is nothing to indicate.
    ///
    /// `nil` means "do not draw", and there are two distinct reasons for it that
    /// the caller must not collapse:
    ///
    /// - `maxOffsetFromBottom == 0`: the pane has no scrollback, so the indicator
    ///   would be a bar pinned to the top of an empty track with nothing to move
    ///   against. Upstream returns early on the same condition
    ///   (`ui/scrollbar.rs:138-140`).
    /// - the lane has no height: nothing can be drawn.
    ///
    /// The arithmetic follows `scrollbar_thumb` (`ui/scrollbar.rs:41-70`) step for
    /// step, including the `round()` calls. Rounding rather than truncating is
    /// what keeps the thumb from drifting up a cell on long histories, where the
    /// ratio is small and truncation compounds.
    public static func thumb(
        _ metrics: PaneSurfaceScrollMetrics,
        laneHeight: Int
    ) -> PaneScrollbarThumb? {
        guard metrics.maxOffsetFromBottom > 0, laneHeight > 0 else { return nil }

        // Every row the pane can show, history included.
        //
        // Reported overflow returns `nil` rather than wrapping. `&+` would turn an
        // absurd value from the daemon into a small `totalRows`, giving a thumb
        // that is wrong with no trace of why; refusing to draw is honest about not
        // knowing. Upstream uses `+` and would trap instead (`ui/scrollbar.rs:49`).
        let (totalRows, overflowed) = metrics.maxOffsetFromBottom
            .addingReportingOverflow(metrics.viewportRows)
        guard !overflowed, totalRows > 0 else { return nil }

        // How much of the whole thing is on screen, in lane cells. Clamped so a
        // viewport taller than the history still yields a full-height thumb
        // rather than one that overflows the lane.
        let scaled = Double(metrics.viewportRows) * Double(laneHeight) / Double(totalRows)
        let thumbLength = max(1, min(laneHeight, Int(scaled.rounded())))

        let maxThumbTop = laneHeight - thumbLength
        guard maxThumbTop > 0 else {
            // The thumb fills the lane: it cannot move, so it is at the top by
            // definition. Returning `top: 0` rather than dividing by zero is the
            // whole reason this branch exists.
            return PaneScrollbarThumb(top: 0, length: thumbLength)
        }

        // How far the viewport is from the *top* of the history. Scrolling to the
        // very top is `offsetFromBottom == maxOffsetFromBottom`.
        //
        // Saturating, not `-`: the daemon can report an offset larger than its own
        // maximum for one frame while the viewport catches up, and an underflow
        // there would put the thumb at the bottom of the lane — the opposite of
        // the truth.
        let scrolledFromTop = metrics.maxOffsetFromBottom > metrics.offsetFromBottom
            ? metrics.maxOffsetFromBottom - metrics.offsetFromBottom
            : 0

        let proportion = Double(scrolledFromTop) * Double(maxThumbTop)
            / Double(metrics.maxOffsetFromBottom)
        let thumbTop = min(maxThumbTop, max(0, Int(proportion.rounded())))
        return PaneScrollbarThumb(top: thumbTop, length: thumbLength)
    }

    /// The scroll offset a click at `row` should request.
    ///
    /// Clicking the lane centres the thumb on the click, which is what makes a
    /// click feel like "go here" rather than "jump one screenful". Ported from
    /// `scrollbar_offset_from_row` (`ui/scrollbar.rs:104-121`).
    ///
    /// Returns `nil` when there is nothing to scroll, so the caller skips the
    /// request instead of sending an offset the daemon would ignore.
    public static func offset(
        forClickAtRow row: Int,
        metrics: PaneSurfaceScrollMetrics,
        laneHeight: Int
    ) -> UInt64? {
        guard let thumb = thumb(metrics, laneHeight: laneHeight) else { return nil }
        let clampedRow = min(max(row, 0), max(laneHeight - 1, 0))
        // Centre the thumb on the click rather than aligning its top to it.
        let desiredTop = max(0, clampedRow - thumb.length / 2)
        return offset(
            forThumbTop: desiredTop,
            metrics: metrics,
            laneHeight: laneHeight,
            thumbLength: thumb.length
        )
    }

    /// The scroll offset for dragging the thumb so its top lands near `row`.
    ///
    /// `grabOffset` is how far into the thumb the drag started, so dragging from
    /// the thumb's bottom edge does not make it jump on the first movement.
    /// Ported from `scrollbar_offset_from_drag_row` (`ui/scrollbar.rs:123-137`).
    public static func offset(
        forDragToRow row: Int,
        grabOffset: Int,
        metrics: PaneSurfaceScrollMetrics,
        laneHeight: Int
    ) -> UInt64? {
        guard let thumb = thumb(metrics, laneHeight: laneHeight) else { return nil }
        let clampedRow = min(max(row, 0), max(laneHeight - 1, 0))
        let desiredTop = max(0, clampedRow - max(grabOffset, 0))
        return offset(
            forThumbTop: desiredTop,
            metrics: metrics,
            laneHeight: laneHeight,
            thumbLength: thumb.length
        )
    }

    /// Where inside the thumb a press at `row` landed, or `nil` if it missed.
    ///
    /// The drag path needs this to compute `grabOffset`; a press outside the thumb
    /// is a click, not a drag. Ported from `scrollbar_thumb_grab_offset`
    /// (`ui/scrollbar.rs:72-78`).
    public static func grabOffset(
        atRow row: Int,
        metrics: PaneSurfaceScrollMetrics,
        laneHeight: Int
    ) -> Int? {
        guard let thumb = thumb(metrics, laneHeight: laneHeight) else { return nil }
        guard row >= thumb.top, row < thumb.top + thumb.length else { return nil }
        return row - thumb.top
    }

    /// The inverse of `thumb(_:laneHeight:)`: which offset puts the thumb at
    /// `thumbTop`.
    ///
    /// Shared by click and drag because they differ only in how they compute the
    /// desired top — two copies of this conversion is how the two gestures would
    /// end up a cell apart.
    ///
    /// `laneHeight` and `thumbLength` are passed in rather than derived from the
    /// thumb: the lane height is not recoverable from a thumb alone (a thumb at
    /// `top: 3` of length 2 could belong to a lane of 5 or 20). An earlier version
    /// of this file tried to reconstruct it and silently produced the wrong offset
    /// for every thumb that was not at the bottom of the lane.
    private static func offset(
        forThumbTop thumbTop: Int,
        metrics: PaneSurfaceScrollMetrics,
        laneHeight: Int,
        thumbLength: Int
    ) -> UInt64 {
        guard metrics.maxOffsetFromBottom > 0 else { return 0 }
        let maxTop = max(laneHeight - thumbLength, 0)
        guard maxTop > 0 else { return 0 }

        let desiredTop = min(max(thumbTop, 0), maxTop)
        let proportion = Double(desiredTop) * Double(metrics.maxOffsetFromBottom) / Double(maxTop)
        let scrolledFromTop = UInt64(max(0, Int(proportion.rounded())))
        // Clamped: `rounded()` can land one past the maximum, and an offset past
        // the top makes the daemon jump somewhere unrelated — the same failure the
        // wheel path guards against in `MouseCoordinateMapper.ScrollTarget`.
        return metrics.maxOffsetFromBottom > scrolledFromTop
            ? metrics.maxOffsetFromBottom - scrolledFromTop
            : 0
    }
}

public extension PaneScrollbarOverlay {
    /// The lane rectangle in the overlay's own coordinate space.
    ///
    /// The overlay is attached to the *pane* view, so its origin is the pane's
    /// top-left corner, while `rect(for:)` answers in **container** coordinates.
    /// Rebasing is therefore a subtraction of the pane's origin — but only if the
    /// overlay really is attached to the pane. Attached after `.position` the
    /// bounds are the whole container (`PaneFrameReporter` documents this at
    /// `PaneLayoutView.swift:625-640`), and subtracting a second time puts the lane
    /// one pane-width to the left and on the container's top edge for every pane
    /// that is not at the origin.
    ///
    /// Split out so that mistake is a test failure rather than a visual one: a
    /// SwiftUI `body` cannot be inspected, so nothing else in the test suite could
    /// tell the two cases apart.
    static func laneRect(lane: CGRect, pane: CGRect) -> CGRect {
        CGRect(
            x: lane.minX - pane.minX,
            y: lane.minY - pane.minY,
            width: lane.width,
            height: lane.height
        )
    }
}

/// The pixel geometry of a lane, computed without a view.
///
/// Exists so the two numbers the overlay needs — the height of one cell, and where
/// the thumb's edges land — can be asserted. A SwiftUI `body` cannot be inspected
/// for "is the thumb 5 cells tall", and the failure mode of getting this wrong is
/// silent: the bar is drawn, just at the wrong scale.
public struct PaneScrollbarLane: Equatable, Sendable {
    /// Height of one lane cell, in points.
    public var cellHeight: CGFloat
    /// The thumb's offset from the lane's top, in points.
    public var thumbOffset: CGFloat
    /// The thumb's height, in points.
    public var thumbHeight: CGFloat

    /// Lays out a lane of `pixelHeight` points holding `laneCells` cells.
    ///
    /// `laneCells` must be the lane's height **in cells**, from
    /// `scrollbar_rect.height` — not anything derived from the thumb. Deriving it
    /// from the thumb (`top + length`) happens to be right only when the thumb sits
    /// at the bottom, so a scrollbar scrolled to the top was drawn with every cell
    /// several times too tall and the thumb filled the track.
    public static func layout(
        pixelHeight: CGFloat,
        laneCells: Int,
        thumb: PaneScrollbarThumb?
    ) -> PaneScrollbarLane? {
        guard laneCells > 0, pixelHeight > 0, let thumb else { return nil }
        let cellHeight = pixelHeight / CGFloat(laneCells)
        return PaneScrollbarLane(
            cellHeight: cellHeight,
            thumbOffset: cellHeight * CGFloat(thumb.top),
            // At least 2pt so a one-cell thumb is still a visible mark rather than
            // a hairline that disappears at 1x.
            thumbHeight: max(cellHeight * CGFloat(thumb.length), 2)
        )
    }
}

// MARK: - Overlay view

/// The pane's scroll indicator, drawn over the lane the daemon reserved for it.
///
/// Drawn as a SwiftUI overlay rather than through the terminal — see this file's
/// header for why writing into the surface's cells would be wrong. The overlay is
/// pure chrome: it never receives clicks (input for a pane goes through its
/// AppKit surface, and the lane lives outside `innerRect`, so no terminal content
/// is under it), which keeps this view from becoming a second input path.
public struct PaneScrollbarOverlay: View {
    /// The lane rectangle, in the pane container's coordinate space.
    public var lane: CGRect
    /// The thumb, from `PaneScrollbar.thumb`. `nil` draws nothing.
    public var thumb: PaneScrollbarThumb?
    /// The lane's height in **cells**.
    ///
    /// Passed in rather than derived from the thumb. An earlier version computed
    /// it as `thumb.top + thumb.length`, which is only right when the thumb is at
    /// the bottom of the lane: scrolled to the top it gave `length` cells for a
    /// lane of 50, so `cellHeight` came out five times too large and the thumb was
    /// drawn across the whole track. The lane height is already known — it is
    /// `scrollbar_rect.height`, in cells, from the daemon.
    public var laneCells: Int
    /// Focused panes get a brighter thumb, matching the daemon's own contrast
    /// (`ui/scrollbar.rs:161-166`).
    public var isFocused: Bool

    /// The pane this belongs to, for the log line only.
    public var paneId: String
    /// The pane's own size.
    ///
    /// The lane passed in has already been rebased onto the pane, so comparing it
    /// against the pane's *size* (rather than its container rect) is the check
    /// that catches a doubled rebase: a lane shifted by one pane-width becomes
    /// negative, and one shifted vertically exceeds the height.
    public var paneSize: CGSize

    public init(
        lane: CGRect,
        thumb: PaneScrollbarThumb?,
        laneCells: Int,
        paneId: String,
        paneSize: CGSize,
        isFocused: Bool
    ) {
        self.lane = lane
        self.thumb = thumb
        self.laneCells = laneCells
        self.paneId = paneId
        self.paneSize = paneSize
        self.isFocused = isFocused
    }

    public var body: some View {
        // Report the geometry this overlay actually laid out.
        //
        // The only place both rectangles are known, and the only measurement that
        // can catch a wrong rebase: `swift test` cannot see a SwiftUI body, so a
        // lane drawn one pane-width to the left passes every unit test.
        // `gui.sh run scrollbar` reads this line.
        // Nothing to indicate: draw nothing. Not an empty track either — the
        // daemon sends no lane at all when there is no scrollback, and drawing a
        // permanent groove would be chrome it never asked for.
        if let thumb,
           lane.width > 0,
           let geometry = PaneScrollbarLane.layout(
               pixelHeight: lane.height,
               laneCells: laneCells,
               thumb: thumb
           ) {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: lane.width / 2)
                    .fill(Color.secondary.opacity(isFocused ? 0.16 : 0.09))
                RoundedRectangle(cornerRadius: lane.width / 2)
                    .fill(Color.secondary.opacity(isFocused ? 0.55 : 0.28))
                    .frame(height: geometry.thumbHeight)
                    .offset(y: geometry.thumbOffset)
            }
            .frame(width: lane.width)
            .frame(maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
            // Report the geometry this overlay actually laid out.
            //
            // The only place both rectangles are known, and the only measurement
            // that can catch a wrong rebase: `swift test` cannot see a SwiftUI
            // body, so a lane drawn one pane-width to the left passes every unit
            // test. `gui.sh run scrollbar` reads this line.
            .onAppear { kraalLog(
                "scrollbar: \(paneId) "
                    + "lane=[\(Int(lane.minX)),\(Int(lane.minY)) "
                    + "\(Int(lane.width))x\(Int(lane.height))] "
                    + "pane=\(Int(paneSize.width))x\(Int(paneSize.height)) "
                    + "cells=\(laneCells)"
            ) }
        }
    }
}

// MARK: - Turning daemon rects into a thumb

public extension PaneSurfacePane {
    /// The lane's height in cells, from the rect the daemon sent.
    ///
    /// `scrollbarRect` is expressed in cells and spans the pane's full height, so
    /// its `height` *is* the lane height. Doing this here rather than in the view
    /// keeps the conversion in one place; a view that guessed it from pixels would
    /// be off by whatever the rounding did.
    var scrollbarLaneHeight: Int? {
        guard let scrollbarRect else { return nil }
        let height = Int(scrollbarRect.height)
        return height > 0 ? height : nil
    }

    /// The thumb this pane should draw, if any.
    ///
    /// `nil` in all the cases where drawing would be wrong: no lane, no metrics,
    /// or no scrollback. The view never has to ask a second question.
    var scrollbarThumb: PaneScrollbarThumb? {
        guard let scroll, let laneHeight = scrollbarLaneHeight else { return nil }
        return PaneScrollbar.thumb(scroll, laneHeight: laneHeight)
    }
}
