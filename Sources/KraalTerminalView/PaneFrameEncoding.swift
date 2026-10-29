// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import KraalProtocol

extension PaneTerminalModel {
    /// Crops the composited tab surface down to this pane's content area.
    ///
    /// The terminal only ever knows about its own pane, so the surrounding
    /// borders and sibling panes must not be fed to it — otherwise a patch in a
    /// neighbouring pane would repaint ours.
    ///
    /// Rows are handed to the frame already chunked (`CellBuffer(rows:width:)`)
    /// rather than flattened into one array and re-split. The flatten-then-chunk
    /// shape copied the pane twice — once into `[CellData]`, once per row by
    /// `Array(slice)` inside `CellBuffer.init(_:width:)`, which does not share
    /// storage with the slice it comes from. The storage step alone is what that
    /// removes, and it is the reproducible part: 200x50, 37.5 us -> 0.033 us
    /// (docs/PERFORMANCE.md, "`paneFrame`：本次改动自己制造、又自己还回去的那笔
    /// 存储拷贝"). The whole-path timings this comment used to quote could not be
    /// reproduced independently and were dropped — do not reintroduce them.
    func paneFrame(
        from surface: PaneSurfaceFrame,
        geometry: PaneSurfacePane
    ) -> FrameData {
        // Encode *here*, once per frame, so every path that paints this frame —
        // including the parked-frame retries below — carries the graphics without
        // each one having to remember. The encoder diffs against what it already
        // sent, so a frame with unchanged images contributes no bytes.
        //
        // The scene is in **surface** coordinates: a placement's `cellX`/`cellY`
        // address the whole tab, while this terminal only knows its own pane. The
        // cells below are cropped by `innerRect` for exactly that reason, and the
        // placements have to be shifted the same way or an image in a split pane is
        // drawn at the wrong column. Upstream does the same addition in reverse
        // (`client_host_piece`, `kitty_graphics/surface.rs:1032`: `origin.0 +
        // placement.x`), so subtracting the origin here restores pane-local space.
        let paneOrigin = (x: Int(geometry.innerRect.originX), y: Int(geometry.innerRect.originY))
        let paneSize = (
            width: Int(geometry.innerRect.width),
            height: Int(geometry.innerRect.height)
        )
        let graphics = graphicsEncoder.encode(
            scene: sceneInPaneSpace(surface.graphics, origin: paneOrigin, paneSize: paneSize),
            scope: graphicsScope
        )
        let area = geometry.innerRect
        let width = Int(area.width)
        let height = Int(area.height)
        let frameWidth = Int(surface.frame.width)
        var rows: [[CellData]] = []
        rows.reserveCapacity(height)

        // Row at a time: a row of the surface is one array, so this is one retain
        // per row instead of one per cell. The bounds check is per cell because a
        // malformed frame's last row can be shorter than the grid says; a cell the
        // surface does not cover is filled blank, exactly as `surface.frame[c, r]`
        // returning nil used to do.
        for row in 0 ..< height {
            let sourceRow = Int(area.originY) + row
            let rowCells = surface.frame.buffer.row(sourceRow)
            let available = rowCells.count
            var cropped: [CellData] = []
            cropped.reserveCapacity(width)
            for column in 0 ..< width {
                let sourceColumn = Int(area.originX) + column
                if sourceColumn < frameWidth, sourceColumn < available {
                    cropped.append(rowCells[rowCells.startIndex + sourceColumn])
                } else {
                    cropped.append(.blank)
                }
            }
            rows.append(cropped)
        }

        var cursor: CursorState?
        if let surfaceCursor = surface.frame.cursor,
           Int(surfaceCursor.column) >= Int(area.originX),
           Int(surfaceCursor.column) < Int(area.originX) + width,
           Int(surfaceCursor.row) >= Int(area.originY),
           Int(surfaceCursor.row) < Int(area.originY) + height {
            cursor = CursorState(
                column: surfaceCursor.column - area.originX,
                row: surfaceCursor.row - area.originY,
                visible: surfaceCursor.visible,
                shape: surfaceCursor.shape
            )
        }

        return FrameData(
            buffer: CellBuffer(rows: rows, width: width),
            width: UInt16(width),
            height: UInt16(height),
            cursor: cursor,
            hyperlinks: surface.frame.hyperlinks,
            // The encoder's output, not `surface.frame.graphics`. Kitty graphics do
            // not live in the cell frame: the daemon sends them as a *scene*
            // (`surface.graphics`) and the client encodes it. Reading
            // `surface.frame.graphics` here — what this used to do — reads the ANSI
            // path's field, which the daemon leaves empty for semantic clients, so
            // an image was decoded, laid out against the grid, and thrown away
            // (issues #37, #105).
            graphics: graphics
        )
    }
}
