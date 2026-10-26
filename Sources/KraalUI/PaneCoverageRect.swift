// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import CoreGraphics
import KraalProtocol
import SwiftUI

extension CGRect {
    /// Grows a pane's rectangle out to the container edge when the pane sits against
    /// it.
    ///
    /// The grid is *centred* in the container, so whenever `container - grid` is not
    /// zero there are leftover strips along the edges — measured 8pt top and bottom on
    /// a 959x664 container holding a 119x36 grid at 8x18pt cells. Those strips belong
    /// to nobody: every pane rectangle stops at the grid and the divider only covers
    /// its own `hitRect`, so they showed the container's background. Invisible while
    /// that background was the system's; a blank band above the top pane and below the
    /// bottom one once the container carried a theme tint.
    ///
    /// Only a *background* should be grown this way. Handing the grown rectangle to a
    /// terminal view instead would make Ghostty lay out a wider grid than the cells it
    /// was sent.
    public func extendedToContainerEdge(
        cellRect: SurfaceRect,
        grid: CGSize,
        container: CGSize,
        cellSize: CGSize
    ) -> CGRect {
        var rect = self
        if cellRect.originX == 0 {
            rect.size.width += rect.minX
            rect.origin.x = 0
        }
        if cellRect.originY == 0 {
            rect.size.height += rect.minY
            rect.origin.y = 0
        }
        if CGFloat(cellRect.originX) + CGFloat(cellRect.width) >= grid.width {
            rect.size.width = container.width - rect.origin.x
        }
        if CGFloat(cellRect.originY) + CGFloat(cellRect.height) >= grid.height {
            rect.size.height = container.height - rect.origin.y
        }
        return rect
    }
}

/// The fill behind every pane's border cell.
///
/// Kept out of `PaneLayoutView` so the arithmetic can be tested without a window, and
/// because this is the only part of the layout that exists purely to cover a gap in
/// the daemon's rectangles: `pane.rect` includes a one-cell border and `pane.innerRect`
/// is the content inside it, and only the content had a view. The border therefore
/// fell through to the container — invisible while that container wore the system's
/// background, a blank band above and below every pane once it carried a theme tint.
///
/// A *background* is the right lever: it takes no part in layout, so the terminal view
/// keeps the exact `innerRect` size its cells were composed for. Sizing the view to
/// the grown rectangle instead would make Ghostty lay out a wider grid than the cells
/// it was sent, and every row would wrap.
struct PaneBorderCells: View {
    let panes: [PaneSurfacePane]
    let grid: CGSize
    let container: CGSize
    let cellSize: CGSize
    /// The colour to fill one pane's border cell with, by pane id.
    let colour: (String) -> Color
    /// The cell-to-points conversion `PaneLayoutView` uses for its own panes.
    let rect: (SurfaceRect, CGSize, CGSize, CGSize) -> CGRect

    var body: some View {
        ForEach(panes, id: \.paneId) { pane in
            let outer = rect(pane.rect, grid, container, cellSize)
                .extendedToContainerEdge(
                    cellRect: pane.rect,
                    grid: grid,
                    container: container,
                    cellSize: cellSize
                )
            colour(pane.paneId)
                .frame(width: outer.width, height: outer.height)
                .position(x: outer.midX, y: outer.midY)
                .allowsHitTesting(false)
        }
    }
}
