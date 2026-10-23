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
    /// Every invariant: cell count, every cell's hyperlink index, cursor bounds.
    ///
    /// The cell scan is deliberately kept here — it belongs to a *surface
    /// arriving whole*, where the cells are new and untrusted. The patch path uses
    /// ``validateGrid()`` instead; see its note for why the scan is redundant
    /// there (issue #50).
    func validate() throws {
        try validateGrid()
        for index in 0 ..< buffer.rowCount {
            for cell in buffer.row(index) {
                if let link = cell.hyperlink, Int(link) >= hyperlinks.count {
                    throw SurfaceError.hyperlinkIndex(index: link, count: hyperlinks.count)
                }
            }
        }
    }

    /// The part of ``validate()`` a patch can actually disturb, at O(1).
    ///
    /// Two invariants, and neither needs the cells:
    ///
    ///   count — must be `width * height`. A patch writes into an existing grid,
    ///           so this can only be *found* wrong here, never made wrong; it is a
    ///           cheap tripwire on a baseline that was built badly.
    ///   cursor — bounds, against the frame's own grid.
    ///
    /// Hyperlink indices are the expensive one to check (a full scan, 3.1 us at
    /// 200x50) and are the one thing a patch provably cannot break: ``PaneSurfacePatch``
    /// carries no hyperlinks and cannot replace the array, so every index in the
    /// baseline was already checked against the very same array when the surface
    /// arrived, and every index a patch introduces is checked by
    /// `validatePatch`. Re-scanning the untouched rows on every patch is what made
    /// this repeat work expensive.
    func validateGrid() throws {
        let expected = Int(width) * Int(height)
        guard buffer.count == expected else {
            throw SurfaceError.cellCount(expected: expected, actual: buffer.count)
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

    /// The first invariant ``validate()`` would reject on, if any.
    ///
    /// A non-throwing form, for callers that report the reason rather than
    /// propagate it — `AppStore.handleSurface` has no `throws` in its path, and
    /// turning a corrupt frame into a UI message is the whole point of checking.
    func firstValidationError() -> SurfaceError? {
        do {
            try validate()
            return nil
        } catch let error as SurfaceError {
            return error
        } catch {
            return nil
        }
    }

    /// The cell at a grid position, or `nil` outside the frame.
    subscript(column: Int, row: Int) -> CellData? {
        buffer.cell(column: column, row: row)
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
            guard frame.buffer.write(row.cells, at: start) else {
                // Unreachable: `validatePatch` already refused this row. Kept so a
                // patch that somehow slipped through still cannot land partially.
                throw SurfaceError.patchRowBounds
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

    /// Whether a patch may be applied, and whether it may be applied *at all*.
    ///
    /// The baseline check is ``FrameData/validateGrid()``, not the full
    /// ``FrameData/validate()``. The full version scans every cell for a hyperlink
    /// index that a patch cannot invalidate — `PaneSurfacePatch` carries no
    /// hyperlinks and cannot replace the frame's array, so the untouched rows'
    /// indices were checked against this very array when the surface arrived
    /// (`AppStore.handleSurface`). The rows a patch *does* introduce are checked
    /// below, cell by cell. Rescanning the rest was 3.1 us of every 37.4 us patch
    /// at 200x50, for a check that could not fail (issue #50).
    private func validatePatch(_ patch: PaneSurfacePatch) throws {
        guard patch.bootId == bootId,
              patch.projectionRevision == projectionRevision,
              patch.baseSurfaceRevision == surfaceRevision,
              surfaceRevision &+ 1 == patch.surfaceRevision,
              popup == nil
        else {
            throw SurfaceError.patchIdentity
        }
        try frame.validateGrid()
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
        // Halfwidth katakana plus a voiced sound mark is one grapheme that takes
        // **two** columns even though neither scalar is wide on its own — the
        // base sits in the halfwidth block and `FF9E`/`FF9F` are combining marks,
        // so the East-Asian-width lookup on the first scalar answers 1 and every
        // glyph after it shifts one column left.
        //
        // `render_ansi.rs:757` `is_halfwidth_katakana_voiced_grapheme` handles
        // exactly this pair; a general width table cannot, which is why it is a
        // special case over there too.
        if isHalfwidthKatakanaVoiced(symbol) { return true }
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

    /// `U+FF66...U+FF9D` followed by `U+FF9E`/`U+FF9F` and nothing else.
    private static func isHalfwidthKatakanaVoiced(_ symbol: String) -> Bool {
        var iterator = symbol.unicodeScalars.makeIterator()
        guard let base = iterator.next(), let mark = iterator.next(), iterator.next() == nil else {
            return false
        }
        guard (0xFF66 ... 0xFF9D).contains(base.value) else { return false }
        return mark.value == 0xFF9E || mark.value == 0xFF9F
    }
}
