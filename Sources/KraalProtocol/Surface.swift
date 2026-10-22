// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Surface invariants and atomic patch application.
//
// Adapted from `herdr-gpui/crates/herdr-protocol/src/frame.rs` (Apache-2.0).
// The rule is the same as upstream's: a patch either applies entirely or is
// rejected with no partial write, so the projection can never be left in a
// state the daemon did not send.

import Foundation

public enum SurfaceError: Error, CustomStringConvertible, Equatable {
    case cellCount(expected: Int, actual: Int)
    case hyperlinkIndex(index: UInt32, count: Int)
    case cursorBounds(column: UInt16, row: UInt16, width: UInt16, height: UInt16)
    case patchIdentity
    case patchRowBounds
    case patchRowOverlap(row: UInt16)
    case patchGeometry(paneId: String)
    case patchCursorBounds
    case patchBeforeBaseline
    case bootIdMismatch(expected: String, actual: String)

    public var description: String {
        switch self {
        case let .cellCount(expected, actual):
            "cell count \(actual) does not match \(expected)"
        case let .hyperlinkIndex(index, count):
            "cell hyperlink index \(index) outside \(count) hyperlinks"
        case let .cursorBounds(column, row, width, height):
            "cursor (\(column), \(row)) outside \(width)×\(height)"
        case .patchIdentity:
            "surface patch identity mismatch"
        case .patchRowBounds:
            "surface patch row outside frame"
        case let .patchRowOverlap(row):
            "surface patch rows overlap on row \(row)"
        case let .patchGeometry(paneId):
            "surface patch changed geometry for pane \(paneId)"
        case .patchCursorBounds:
            "patch cursor outside frame"
        case .patchBeforeBaseline:
            "patch arrived before any baseline surface"
        case let .bootIdMismatch(expected, actual):
            "boot id \(actual) does not match \(expected)"
        }
    }
}

public extension FrameData {
    func validate() throws {
        let expected = Int(width) * Int(height)
        guard cells.count == expected else {
            throw SurfaceError.cellCount(expected: expected, actual: cells.count)
        }
        for cell in cells {
            if let index = cell.hyperlink, Int(index) >= hyperlinks.count {
                throw SurfaceError.hyperlinkIndex(index: index, count: hyperlinks.count)
            }
        }
        if let cursor, cursor.visible, cursor.column >= width || cursor.row >= height {
            throw SurfaceError.cursorBounds(
                column: cursor.column,
                row: cursor.row,
                width: width,
                height: height
            )
        }
    }

    /// The cell at a grid position, or `nil` outside the frame.
    subscript(column: Int, row: Int) -> CellData? {
        guard column >= 0, row >= 0, column < Int(width), row < Int(height) else {
            return nil
        }
        let index = row * Int(width) + column
        guard index < cells.count else { return nil }
        return cells[index]
    }
}

public extension PaneSurfaceFrame {
    func validate() throws {
        try frame.validate()
    }

    /// Applies a patch atomically. On any validation failure the receiver is
    /// unchanged.
    mutating func apply(_ patch: PaneSurfacePatch) throws {
        try validatePatch(patch)

        for row in patch.rows {
            let start = Int(row.row) * Int(frame.width) + Int(row.column)
            for (offset, cell) in row.cells.enumerated() {
                let index = start + offset
                guard index < frame.cells.count else {
                    throw SurfaceError.patchRowBounds
                }
                frame.cells[index] = cell
            }
        }
        for patched in patch.panes {
            if let index = panes.firstIndex(where: { $0.paneId == patched.paneId }) {
                panes[index] = patched
            }
        }
        frame.cursor = patch.cursor
        surfaceRevision = patch.surfaceRevision
    }

    private func validatePatch(_ patch: PaneSurfacePatch) throws {
        guard patch.bootId == bootId,
              patch.projectionRevision == projectionRevision,
              patch.baseSurfaceRevision == surfaceRevision,
              surfaceRevision &+ 1 == patch.surfaceRevision,
              popup == nil
        else {
            throw SurfaceError.patchIdentity
        }
        try frame.validate()
        for row in patch.rows {
            guard row.row < frame.height,
                  Int(row.column) + row.cells.count <= Int(frame.width)
            else {
                throw SurfaceError.patchRowBounds
            }
            for cell in row.cells {
                if let index = cell.hyperlink, Int(index) >= frame.hyperlinks.count {
                    throw SurfaceError.hyperlinkIndex(
                        index: index,
                        count: frame.hyperlinks.count
                    )
                }
            }
        }
        // Rows must not cover the same cell twice. Overlap is not a bounds
        // problem, so the loop above cannot see it: the later row silently wins
        // and the screen shows content the daemon never composed. Sorted by
        // (row, column) so out-of-order-but-disjoint patches are still accepted
        // — upstream accepts those too.
        let ordered = patch.rows.sorted {
            $0.row == $1.row ? $0.column < $1.column : $0.row < $1.row
        }
        var previousEnd: (row: UInt16, column: Int)?
        for row in ordered where !row.cells.isEmpty {
            let start = Int(row.column)
            let end = start + row.cells.count
            if let previousEnd, previousEnd.row == row.row, start < previousEnd.column {
                throw SurfaceError.patchRowOverlap(row: row.row)
            }
            previousEnd = (row.row, end)
        }
        for patched in patch.panes {
            let unchanged = panes.contains { existing in
                existing.paneId == patched.paneId
                    && existing.rect == patched.rect
                    && existing.innerRect == patched.innerRect
            }
            guard unchanged else {
                throw SurfaceError.patchGeometry(paneId: patched.paneId)
            }
        }
        if let cursor = patch.cursor,
           cursor.visible,
           cursor.column >= frame.width || cursor.row >= frame.height {
            throw SurfaceError.patchCursorBounds
        }
    }

    /// The pane containing a grid cell, preferring its content area.
    func pane(atColumn column: Int, row: Int) -> PaneSurfacePane? {
        panes.first { pane in
            let area = pane.innerRect
            return column >= Int(area.originX) && column < Int(area.originX) + Int(area.width)
                && row >= Int(area.originY) && row < Int(area.originY) + Int(area.height)
        } ?? panes.first { pane in
            let area = pane.rect
            return column >= Int(area.originX) && column < Int(area.originX) + Int(area.width)
                && row >= Int(area.originY) && row < Int(area.originY) + Int(area.height)
        }
    }

    /// The split whose draggable hit area contains a grid cell.
    func split(atColumn column: Int, row: Int) -> PaneSurfaceSplit? {
        splits.first { split in
            let area = split.hitRect
            return column >= Int(area.originX) && column < Int(area.originX) + Int(area.width)
                && row >= Int(area.originY) && row < Int(area.originY) + Int(area.height)
        }
    }
}

// MARK: - Text projection

/// Projects a cell grid into plain text.
///
/// Wide glyphs occupy one cell whose successor is a `skip` cell, so the row's
/// string is shorter than its column count. Use ``columns`` when a column
/// index must stay meaningful (pane slicing, cursor math).
public enum SurfaceText {
    /// One entry per grid column: the glyph, or `""` for a wide glyph's
    /// continuation column and for `skip` cells.
    public static func columns(_ frame: FrameData, row: Int) -> [String] {
        let width = Int(frame.width)
        var result = [String](repeating: "", count: width)
        var padding = 0
        for column in 0 ..< width {
            guard let cell = frame[column, row] else { continue }
            if cell.skip { continue }
            if padding > 0, cell.symbol.isEmpty || cell.symbol == " " {
                padding -= 1
                continue
            }
            padding = 0
            result[column] = cell.symbol
            if isWide(cell.symbol) {
                padding = 1
            }
        }
        return result
    }

    public static func line(_ frame: FrameData, row: Int) -> String {
        columns(frame, row: row).joined()
    }

    public static func lines(_ frame: FrameData) -> [String] {
        (0 ..< Int(frame.height)).map { line(frame, row: $0) }
    }

    /// The text inside a pane's content area, one string per row.
    public static func paneLines(_ surface: PaneSurfaceFrame, pane: PaneSurfacePane) -> [String] {
        let rect = pane.innerRect
        var result: [String] = []
        result.reserveCapacity(Int(rect.height))
        for row in Int(rect.originY) ..< Int(rect.originY) + Int(rect.height) {
            let rowColumns = columns(surface.frame, row: row)
            let start = Int(rect.originX)
            let end = min(start + Int(rect.width), rowColumns.count)
            guard start < end else {
                result.append("")
                continue
            }
            result.append(rowColumns[start ..< end].joined())
        }
        return result
    }

    /// East Asian width check, matching the daemon's own continuation rules.
    public static func isWide(_ symbol: String) -> Bool {
        guard let first = symbol.unicodeScalars.first else { return false }
        let value = first.value
        return (0x1100 ... 0x115F).contains(value)
            || (0x2E80 ... 0xA4CF).contains(value)
            || (0xAC00 ... 0xD7A3).contains(value)
            || (0xF900 ... 0xFAFF).contains(value)
            || (0xFE30 ... 0xFE6F).contains(value)
            || (0xFF00 ... 0xFF60).contains(value)
            || (0xFFE0 ... 0xFFE6).contains(value)
            || (0x1F300 ... 0x1F9FF).contains(value)
            || (0x20000 ... 0x3FFFD).contains(value)
    }
}
