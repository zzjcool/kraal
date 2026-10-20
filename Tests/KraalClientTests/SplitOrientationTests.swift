// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Regression tests for split-divider orientation.
//
// The bug: hovering the divider of a top/bottom split showed the left-right
// resize cursor. The divider was hard-coded to `NSCursor.resizeLeftRight`, so it
// was accidental that the side-by-side case looked right.
//
// The underlying confusion is worth spelling out, because it is what makes both
// the cursor and the drag direction easy to get wrong. The daemon names a split
// after the divider *line*, and the drag axis is perpendicular to that line:
//
//   direction: down  -> PaneSurfaceSplitDirection.vertical   (vertical line,
//                       panes stacked vertically, divider moves along Y)
//   direction: right -> PaneSurfaceSplitDirection.horizontal (horizontal line,
//                       panes side by side, divider moves along X)
//
// The values below are what a live herdr 0.9.5 daemon actually returned for a
// 120x40 surface: `direction: down` produced a 120x2 hit rect at y=19, and
// `direction: right` produced a 2x20 hit rect at x=59. Those thin, wide / tall,
// narrow shapes are the ground truth the axis rule is derived from.
//
// The drag mapping is covered too: it read the ratio off the wrong axis, which
// put the divider in the wrong place *and* moved it backwards while dragging.

import CoreGraphics
import Testing

import KraalProtocol
@testable import KraalUI

@Suite("Split divider orientation")
struct SplitOrientationTests {
    /// The cursor the view actually pushes, not just the axis it derives from.
    /// `NSCursor` instances are singletons, so identity is the assertion.
    @Test("the vertical divider pushes the up-down cursor")
    @MainActor
    func verticalCursorIsUpDown() {
        #expect(PaneLayoutView.splitCursor(for: .vertical) == .resizeUpDown)
    }

    /// Guards the side-by-side case the old hard-coded cursor happened to get
    /// right: a fix that swaps both would break it.
    @Test("the horizontal divider pushes the left-right cursor")
    @MainActor
    func horizontalCursorIsLeftRight() {
        #expect(PaneLayoutView.splitCursor(for: .horizontal) == .resizeLeftRight)
    }
    /// A top/bottom split must offer the up-down cursor.
    @Test("a vertical divider uses the up-down cursor axis")
    func verticalDividerDragsVertically() {
        let axis = PaneSplitAxis(.vertical)

        #expect(axis == .verticalDrag)
        #expect(axis.direction == .vertical)
    }

    /// A side-by-side split must keep the left-right cursor.
    @Test("a horizontal divider uses the left-right cursor axis")
    func horizontalDividerDragsHorizontally() {
        let axis = PaneSplitAxis(.horizontal)

        #expect(axis == .horizontalDrag)
        #expect(axis.direction == .horizontal)
    }

    /// The two axes must stay perpendicular: if both mapped to one case, the
    /// cursor would be right for one split and wrong for the other, which is
    /// exactly the reported bug.
    @Test("the two directions map to different drag axes")
    func axesAreDistinct() {
        #expect(PaneSplitAxis(.vertical) != PaneSplitAxis(.horizontal))
    }

    /// The 120x40 surface from the live daemon, root split at y=20 (ratio 0.5).
    /// Dragging down by 10 rows must give 30/40, not something derived from X.
    @Test("dragging a vertical divider down increases the ratio along Y")
    func verticalDividerUsesYAxis() {
        let area = SurfaceRect(originX: 0, originY: 0, width: 120, height: 40)

        let ratio = PaneLayoutView.splitRatio(
            direction: .vertical,
            position: 20,
            area: area,
            translatedX: 0,
            translatedY: 10
        )

        #expect(ratio == 0.75, "expected 30/40, got \(ratio)")
    }

    /// The same divider must ignore horizontal motion entirely. Reading X here is
    /// the bug: a sideways drag would move a divider that cannot move sideways.
    @Test("a vertical divider ignores horizontal drag")
    func verticalDividerIgnoresX() {
        let area = SurfaceRect(originX: 0, originY: 0, width: 120, height: 40)

        let ratio = PaneLayoutView.splitRatio(
            direction: .vertical,
            position: 20,
            area: area,
            translatedX: 99,
            translatedY: 0
        )

        #expect(ratio == 0.5, "horizontal motion must not move a vertical divider, got \(ratio)")
    }

    /// Side-by-side case: 120 wide, divider at column 60 (ratio 0.5). Dragging
    /// right by 30 columns gives 90/120.
    @Test("dragging a horizontal divider right increases the ratio along X")
    func horizontalDividerUsesXAxis() {
        let area = SurfaceRect(originX: 0, originY: 0, width: 120, height: 20)

        let ratio = PaneLayoutView.splitRatio(
            direction: .horizontal,
            position: 60,
            area: area,
            translatedX: 30,
            translatedY: 0
        )

        #expect(ratio == 0.75, "expected 90/120, got \(ratio)")
    }

    /// Vertical motion must not move a side-by-side divider.
    @Test("a horizontal divider ignores vertical drag")
    func horizontalDividerIgnoresY() {
        let area = SurfaceRect(originX: 0, originY: 0, width: 120, height: 20)

        let ratio = PaneLayoutView.splitRatio(
            direction: .horizontal,
            position: 60,
            area: area,
            translatedX: 0,
            translatedY: 99
        )

        #expect(ratio == 0.5, "vertical motion must not move a horizontal divider, got \(ratio)")
    }

    /// The clamp keeps a pane from being dragged out of existence in either axis.
    @Test("both orientations clamp to the 0.1...0.9 band")
    func ratioIsClamped() {
        let area = SurfaceRect(originX: 0, originY: 0, width: 120, height: 40)

        let tiny = PaneLayoutView.splitRatio(
            direction: .vertical,
            position: 20,
            area: area,
            translatedX: 0,
            translatedY: -1000
        )
        let huge = PaneLayoutView.splitRatio(
            direction: .vertical,
            position: 20,
            area: area,
            translatedX: 0,
            translatedY: 1000
        )

        #expect(tiny == 0.1)
        #expect(huge == 0.9)
    }

    /// A split nested inside another reports an area offset from the surface
    /// origin. Its `position` shares that offset's frame, so subtracting the
    /// origin must happen before dividing — otherwise a nested divider jumps on
    /// first drag.
    @Test("a nested divider subtracts its area origin before dividing")
    func nestedAreaOriginIsSubtracted() {
        let area = SurfaceRect(originX: 0, originY: 20, width: 120, height: 20)

        let ratio = PaneLayoutView.splitRatio(
            direction: .vertical,
            position: 25,
            area: area,
            translatedX: 0,
            translatedY: 0
        )

        #expect(ratio == 0.25, "expected (25-20)/20, got \(ratio)")
    }
}
