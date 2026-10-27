// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import KraalProtocol

extension PaneTerminalModel {
    /// The frame to paint while the grid is still the previous size, or `nil` when
    /// there is nothing worth painting.
    ///
    /// Split from the crop itself so the *decision* is testable without a Ghostty
    /// surface: `state.surfaceSize` is `internal(set)` and has no injection point, so
    /// reducing the mismatch branch to a bare `return` used to leave every unit test
    /// green — which is how a stray background band reached a user twice.
    static func bridgeFrame(_ frame: FrameData, gridColumns: UInt16, gridRows: UInt16) -> FrameData? {
        let bridge = cropped(frame, toColumns: Int(gridColumns), rows: Int(gridRows))
        return bridge.width > 0 && bridge.height > 0 ? bridge : nil
    }

    /// The top-left `columns x rows` of a frame.
    ///
    /// Used only to bridge the moment when Ghostty's grid is still the previous size
    /// while the view already has the new one. The result is never cached: the parked
    /// full frame is what gets painted once the grid catches up.
    static func cropped(_ frame: FrameData, toColumns columns: Int, rows: Int) -> FrameData {
        let width = min(columns, Int(frame.width))
        let height = min(rows, Int(frame.height))
        guard width > 0, height > 0 else {
            return FrameData(
                cells: [], width: 0, height: 0,
                cursor: nil, hyperlinks: frame.hyperlinks, graphics: Data()
            )
        }
        var cells: [CellData] = []
        cells.reserveCapacity(width * height)
        for row in 0 ..< height {
            let rowCells = frame.buffer.row(row)
            for column in 0 ..< width where column < rowCells.count {
                cells.append(rowCells[rowCells.startIndex + column])
            }
            // A malformed frame's row can be shorter than the grid says; pad so the
            // buffer keeps a uniform width (the renderer indexes by `row * width + column`).
            if rowCells.count < width {
                cells.append(contentsOf: Array(repeating: .blank, count: width - rowCells.count))
            }
        }
        return FrameData(
            cells: cells,
            width: UInt16(width),
            height: UInt16(height),
            cursor: frame.cursor.flatMap { cursor in
                cursor.row < height && cursor.column < width ? cursor : nil
            },
            hyperlinks: frame.hyperlinks,
            // Dropped on purpose: graphic placements are addressed in surface cells,
            // and a cropped frame has no way to say "this one is off-screen now". The
            // parked frame carries them, and it lands as soon as the grid agrees.
            graphics: Data()
        )
    }
}
