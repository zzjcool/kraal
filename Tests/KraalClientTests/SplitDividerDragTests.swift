// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Regression tests for dragging a split divider.
//
// Two bugs made the divider feel detached from the pointer:
//
// 1. Units were mixed. `DragGesture` reports points, but `position` and `area`
//    from the daemon are *cells*. The old code multiplied the drag by
//    `surface.frame.height / grid.height` — and those two are the same number,
//    so the multiplier was exactly 1 and a 40-point drag was treated as 40
//    *rows*. In a 45-row surface that is a ratio change of 0.89, which pins to
//    the 0.9 clamp immediately: the divider jumps to an edge on the first
//    twitch instead of following the pointer.
//
// 2. The ratio was only computed in `onEnded`. Nothing moved while dragging.
//
// The existing tests in SplitOrientationTests could not see bug 1 because they
// pass `translatedX/Y` already expressed in cells. The conversion from points
// to cells — the step that was wrong — was never exercised. That is what this
// suite covers: the same numbers a real mouse produces.

import CoreGraphics
import Testing

import KraalProtocol
@testable import KraalUI

@Suite("Split divider drag")
struct SplitDividerDragTests {
    /// A 45-row surface, as in the reported case (log line:
    /// `grid=99x45 cell=8.5x18.5`), split in half.
    private var surfaceRows: UInt16 { 45 }
    private var cellHeight: CGFloat { 18.5 }

    /// Dragging down 40pt in a 45-row surface is a little over two rows, not
    /// forty. The old code returned ~0.89 here and clamped to 0.9.
    @Test("a point drag is converted to rows before it becomes a ratio")
    func pointsBecomeCells() {
        let ratio = PaneLayoutView.splitRatioForDrag(
            direction: .vertical,
            position: 22,
            area: SurfaceRect(originX: 0, originY: 0, width: 99, height: 45),
            dragPoints: CGSize(width: 0, height: 40),
            cellSize: CGSize(width: 8.5, height: cellHeight)
        )

        // 22 rows + (40pt / 18.5pt-per-row) = 22 + 2.16 = 24.16 → /45 = 0.537
        let expected = (22.0 + 40.0 / 18.5) / 45.0
        #expect(abs(ratio - expected) < 0.001, "expected ~\(expected), got \(ratio)")
        #expect(ratio < 0.6, "a 40pt drag must not jump most of the way down")
    }

    /// The same drag expressed in cells must give the same answer — this is the
    /// property the old tests asserted directly, kept here so the two entry
    /// points cannot drift apart.
    @Test("the point-based and cell-based paths agree")
    func bothPathsAgree() {
        let viaPoints = PaneLayoutView.splitRatioForDrag(
            direction: .vertical,
            position: 22,
            area: SurfaceRect(originX: 0, originY: 0, width: 99, height: 45),
            dragPoints: CGSize(width: 0, height: 37),
            cellSize: CGSize(width: 8.5, height: cellHeight)
        )
        let viaCells = PaneLayoutView.splitRatio(
            direction: .vertical,
            position: 22,
            area: SurfaceRect(originX: 0, originY: 0, width: 99, height: 45),
            translatedX: 0,
            translatedY: 2
        )

        #expect(abs(viaPoints - viaCells) < 0.001)
    }

    /// A one-cell drag must move the divider by exactly one row. This is the
    /// statement a user would make: "I moved it one row and it moved one row."
    @Test("one cell of drag moves the divider one row")
    func oneCellIsOneRow() {
        let rows: UInt16 = 40
        let ratio = PaneLayoutView.splitRatioForDrag(
            direction: .vertical,
            position: 20,
            area: SurfaceRect(originX: 0, originY: 0, width: 120, height: rows),
            dragPoints: CGSize(width: 0, height: 20),   // one 20pt-tall row
            cellSize: CGSize(width: 10, height: 20)
        )

        #expect(abs(ratio - 0.525) < 0.001, "21/40 expected, got \(ratio)")
    }

    /// Side-by-side divider: the same conversion applies on X.
    @Test("a horizontal divider converts points to columns")
    func horizontalConvertsToColumns() {
        let ratio = PaneLayoutView.splitRatioForDrag(
            direction: .horizontal,
            position: 60,
            area: SurfaceRect(originX: 0, originY: 0, width: 120, height: 20),
            dragPoints: CGSize(width: 30, height: 0),
            cellSize: CGSize(width: 10, height: 20)
        )

        // 60 columns + 30pt/10pt-per-column = 63 → /120
        #expect(abs(ratio - 0.525) < 0.001, "got \(ratio)")
    }

    /// Cross-axis motion must stay ignored through the conversion too, or a
    /// sideway twitch would resize a stacked split.
    @Test("cross-axis drag is still ignored after conversion")
    func crossAxisIgnored() {
        let ratio = PaneLayoutView.splitRatioForDrag(
            direction: .vertical,
            position: 22,
            area: SurfaceRect(originX: 0, originY: 0, width: 99, height: 45),
            dragPoints: CGSize(width: 500, height: 0),
            cellSize: CGSize(width: 8.5, height: cellHeight)
        )

        #expect(abs(ratio - 22.0 / 45.0) < 0.001)
    }

    /// A zero cell size must not divide by zero. Ghostty reports 0 before its
    /// first frame measurement, and a drag can arrive in that window.
    @Test("a zero cell size falls back instead of dividing by zero")
    func zeroCellSizeIsSafe() {
        let ratio = PaneLayoutView.splitRatioForDrag(
            direction: .vertical,
            position: 22,
            area: SurfaceRect(originX: 0, originY: 0, width: 99, height: 45),
            dragPoints: CGSize(width: 0, height: 40),
            cellSize: .zero
        )

        #expect(ratio.isFinite)
        #expect((0.1...0.9).contains(ratio))
    }

    /// The clamp still applies after conversion.
    @Test("a huge drag still clamps")
    func hugeDragClamps() {
        let ratio = PaneLayoutView.splitRatioForDrag(
            direction: .vertical,
            position: 22,
            area: SurfaceRect(originX: 0, originY: 0, width: 99, height: 45),
            dragPoints: CGSize(width: 0, height: 10_000),
            cellSize: CGSize(width: 8.5, height: cellHeight)
        )

        #expect(ratio == 0.9)
    }
}
