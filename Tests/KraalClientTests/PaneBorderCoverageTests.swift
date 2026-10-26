// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import CoreGraphics
import KraalProtocol
@testable import KraalUI
import Testing

/// The border cell the daemon reserves around a pane, and the strips the centred grid
/// leaves along the container's edges, must end up covered by a pane's background.
///
/// Measured on a live `split-down`: `container=959x664 grid=119x36 cell=8x18`
/// `panes=[p1 rect=119x18@0,0  p2 rect=119x18@0,18] divider hit=119x2@0,17`.
/// Every rectangle stops at the grid, so the 8pt strips above row 0 and below row 35
/// belonged to nobody and showed the container's background — which, once the
/// container carried a theme tint, read as a stray blank row above and below the panes.
@Suite("Pane border coverage")
struct PaneBorderCoverageTests {
    private let grid = CGSize(width: 119, height: 36)
    private let cell = CGSize(width: 8, height: 18)
    private let container = CGSize(width: 959, height: 664)

    @Test("the top pane's background reaches the container's top edge")
    func topPaneReachesTopEdge() {
        let top = SurfaceRect(originX: 0, originY: 0, width: 119, height: 18)
        let outer = CGRect(x: 0, y: 8, width: 959, height: 324)
            .extendedToContainerEdge(
                cellRect: top,
                grid: grid,
                container: container,
                cellSize: cell
            )
        // Before the fix this was y=8: the 8pt strip above the grid stayed unpainted.
        #expect(outer.minY == 0)
        // And the first row of cells is inside it.
        #expect(outer.maxY >= 8 + 324)
    }

    @Test("the bottom pane's background reaches the container's bottom edge")
    func bottomPaneReachesBottomEdge() {
        let bottom = SurfaceRect(originX: 0, originY: 18, width: 119, height: 18)
        let outer = CGRect(x: 0, y: 8 + 18 * 18, width: 959, height: 324)
            .extendedToContainerEdge(
                cellRect: bottom,
                grid: grid,
                container: container,
                cellSize: cell
            )
        #expect(outer.maxY == container.height)
    }

    @Test("a pane against the left edge grows left, one against the right grows right")
    func horizontalEdges() {
        let left = SurfaceRect(originX: 0, originY: 0, width: 60, height: 36)
        let grown = CGRect(x: 6, y: 0, width: 480, height: 648)
            .extendedToContainerEdge(
                cellRect: left,
                grid: CGSize(width: 120, height: 36),
                container: CGSize(width: 972, height: 648),
                cellSize: cell
            )
        #expect(grown.minX == 0)

        let right = SurfaceRect(originX: 60, originY: 0, width: 60, height: 36)
        let grownRight = CGRect(x: 486, y: 0, width: 480, height: 648)
            .extendedToContainerEdge(
                cellRect: right,
                grid: CGSize(width: 120, height: 36),
                container: CGSize(width: 972, height: 648),
                cellSize: cell
            )
        #expect(grownRight.maxX == 972)
    }

    @Test("a pane in the middle is left exactly where it was")
    func middlePaneUntouched() {
        let middle = SurfaceRect(originX: 30, originY: 10, width: 60, height: 16)
        let original = CGRect(x: 246, y: 188, width: 480, height: 288)
        let grown = original.extendedToContainerEdge(
            cellRect: middle,
            grid: grid,
            container: container,
            cellSize: cell
        )
        #expect(grown == original)
    }
}
