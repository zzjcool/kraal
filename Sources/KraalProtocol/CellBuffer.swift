// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Cell storage for one frame: a copy-on-write array per row.
//
// Why not `[CellData]` (issue #50).
//
// A patch writes one to three rows of a screen that is already on display, and
// the frame holding it is referenced from at least three places at that moment:
// the store's `surface`, the `PaneSurfaceFrame` each `GhosttyPaneView` was built
// with, `SurfaceANSIRenderer.previous`, and `PaneTerminalModel.frameGrid`. A
// single stored-array write therefore has a reference count above one and copies
// the **whole screen**: 38.4 us for 200x50, 90 us for 300x80, per patch,
// independent of how few cells the patch carries.
//
// Note what this rules out: mutating the store's property in place
// (`surface?.apply(patch)`) does *not* avoid that copy. The copy is triggered by
// the other references, not by the copy-assign — measured, an in-place write with
// one live copy still relocates the buffer. Only making the *storage* cheap to
// copy removes it.
//
// Two candidate storages were measured (docs/PERFORMANCE.md, "附：本仓库的
// 性能现状" -> "#50 修掉之后的数字" -> "实际修法" / "残留成本"):
//
//   final class CellBuffer  — a plain reference type aliases on copy, so a patch
//     would write through into the renderer's `previous` and the view's copy.
//     `changedRows` would then compare a frame against itself, see nothing
//     changed, and skip the repaint: a stale screen with no error anywhere.
//     Rejected on correctness, not cost.
//
//     Note the argument that is *not* made any more: a class would supposedly
//     also stop `@Observable` from invalidating anything. It would not. The
//     patch path assigns `store.surface` whether its payload is a value or a
//     reference, and a nested-class mutation reached through `surface?.apply(...)`
//     still goes through the tracked property's `_modify` accessor, which fires
//     `willSet`/`didSet`. The real cost of aliasing is the write-through above.
//
//   one CoW array per row  — what this is. Unchanged rows are shared by buffer
//     reference (an O(1) retain), so a patch copies one row and the value
//     semantics that keep the diff honest survive.
//     200x50 one-cell patch: 36.6 us -> 1.6 us.
//
// The chunking is an implementation detail: equality compares cells, not layout,
// and every accessor is expressed in flat frame terms.
//
// Residual cost, measured after the change: writing one cell still relocates the
// *outer* `rows` array, i.e. `height` row handles, so the cost stays linear in
// pane height -- roughly 10 ns/row plus ~0.7 us of fixed cost for the copy and
// the read-back (200x10: 0.83 us, 200x300: 3.84 us, 200x600: 6.90 us,
// 200x1200: 12.3 us). The *width* dimension is what the change eliminated.
// 300x80 costs ~1.7 us per patch, 2% of a frame budget: acceptable, and *not*
// O(1). Boxing the row array to get rid of it would add a reference indirection
// to every render read; see docs/PERFORMANCE.md, "残留成本：与 pane **高度**线性，
// 不是 O(1)".

public struct CellBuffer: Equatable, Sendable {
    /// One CoW array per row, `rowWidth` cells each (the last may be short).
    private var rows: [[CellData]]
    /// Cells per row, i.e. the frame width this buffer was built for.
    private let rowWidth: Int
    /// Total cells, kept alongside `rows` so `count` does not have to sum.
    private let cellCount: Int

    /// Chunks a flat cell array into rows.
    ///
    /// - Parameter width: cells per row. Zero or negative puts everything in one
    ///   row, which keeps the index arithmetic total (`FrameData` bounds checks
    ///   on its own `width` before it ever indexes) instead of dividing by zero.
    public init(_ cells: [CellData], width: Int) {
        let stride = width > 0 ? width : max(cells.count, 1)
        var rows: [[CellData]] = []
        rows.reserveCapacity(cells.count / stride + 1)
        var start = 0
        while start < cells.count {
            let end = min(start + stride, cells.count)
            rows.append(Array(cells[start ..< end]))
            start = end
        }
        self.rows = rows
        rowWidth = stride
        cellCount = cells.count
    }

    /// Wraps an already-chunked grid, without re-copying it row by row.
    ///
    /// The callers that already loop over rows -- `PaneTerminalModel.paneFrame`
    /// crops the surface row by row -- have the arrays this type wants in hand.
    /// Handing them over costs one retain of the outer array instead of
    /// `Array(slice)` per row, which does not share storage with its source and
    /// so is a second full copy of the pane. Measured on the storage step alone,
    /// 200x50: 37.5 us -> 0.033 us (docs/PERFORMANCE.md, "`paneFrame`：本次改动
    /// 自己制造、又自己还回去的那笔存储拷贝").
    ///
    /// - Parameters:
    ///   - rows: one array per row, in frame order.
    ///   - width: cells per row, i.e. the grid width these rows were cropped for.
    ///     Zero or negative falls back to the longest row, for the same reason the
    ///     flat initialiser does: index arithmetic must stay total.
    public init(rows: [[CellData]], width: Int) {
        self.rows = rows
        rowWidth = width > 0 ? width : max(rows.lazy.map(\.count).max() ?? 0, 1)
        cellCount = rows.reduce(0) { $0 + $1.count }
    }

    /// A buffer of `count` blank cells, for a frame that arrives without any.
    public init(blankCells count: Int, width: Int) {
        self.init(Array(repeating: .blank, count: count), width: width)
    }

    public var count: Int { cellCount }

    /// Rows actually stored. Equal to `height` for a well-formed frame; a short
    /// buffer (a frame whose cell count disagrees with its grid) has fewer.
    public var rowCount: Int { rows.count }

    /// One row as a slice, empty when the row does not exist.
    ///
    /// The accessor for the hot read paths (rendering, cropping): it costs one
    /// retain for the row and then no per-cell retain at all, whereas the flat
    /// subscript writes/reads through a fresh array value per call.
    public func row(_ index: Int) -> ArraySlice<CellData> {
        guard index >= 0, index < rows.count else { return [][...] }
        return rows[index][...]
    }

    /// The cell at a flat index, `nil` outside the buffer.
    public func cell(at index: Int) -> CellData? {
        guard index >= 0, index < cellCount else { return nil }
        let row = index / rowWidth
        guard row < rows.count else { return nil }
        let rowCells = rows[row]
        let column = index - row * rowWidth
        guard column < rowCells.count else { return nil }
        return rowCells[column]
    }

    /// The cell at a grid position, `nil` outside the buffer.
    ///
    /// Expressed in the buffer's own chunking rather than in `FrameData.width`, so
    /// a frame whose width was reassigned after it was built cannot make reads land
    /// in the wrong row. That reassignment is *not* caught by validation in every
    /// case (4x4 reassigned to 8x2 keeps the cell count), so indexing must not
    /// depend on a check having run -- and a patch that this chunking cannot place
    /// is refused rather than half-written (``write(_:at:)``).
    public func cell(column: Int, row: Int) -> CellData? {
        guard column >= 0, row >= 0, row < rows.count else { return nil }
        let rowCells = rows[row]
        guard column < rowCells.count else { return nil }
        return rowCells[column]
    }

    /// A flat-index read. Traps outside the buffer, like the array it replaces.
    ///
    /// The trap is on `cellCount` on purpose — a caller indexing past the frame
    /// has a bug, and a silently blank cell would hide it. A **ragged** buffer is
    /// the other case: `count` is the sum of the rows, so `count` can admit an
    /// index the row chunking cannot place (`CellBuffer(rows: [[a, b], [c]],
    /// width: 3)` -> flat 2 is "in range" but lands past row 0). That one is not
    /// the caller's bug — the frame arrived malformed — so it reads blank. The two
    /// readers express the same *verdict* — "no cell here" — in the only way their
    /// types allow: ``cell(at:)`` returns `nil` (an optional can say "missing"), the
    /// subscript returns `.blank` (a `CellData` cannot). They are not interchangeable
    /// values and were never meant to be; the malformed frame is what they agree is
    /// unplaceable.
    public subscript(index: Int) -> CellData {
        get {
            precondition(index >= 0 && index < cellCount, "cell index \(index) outside \(cellCount)")
            let row = index / rowWidth
            guard row < rows.count else { return .blank }
            let rowCells = rows[row]
            let column = index - row * rowWidth
            guard column < rowCells.count else { return .blank }
            return rowCells[column]
        }
        set {
            precondition(index >= 0 && index < cellCount, "cell index \(index) outside \(cellCount)")
            write(newValue, at: index)
        }
    }

    /// Writes one cell. Copies that **row** only, never the screen.
    public mutating func write(_ cell: CellData, at index: Int) {
        let row = index / rowWidth
        guard row < rows.count else { return }
        let column = index - row * rowWidth
        guard column < rows[row].count else { return }
        rows[row][column] = cell
    }

    /// Writes a run of cells starting at a flat index.
    ///
    /// - Returns: `false` when the run does not fit, in which case nothing was
    ///   written. The patch path checks bounds before it gets here; the return
    ///   value keeps "a rejected patch leaves no trace" true even if it does not.
    @discardableResult
    public mutating func write(_ cells: [CellData], at start: Int) -> Bool {
        guard start >= 0, start + cells.count <= cellCount else { return false }
        guard !cells.isEmpty else { return true }
        // The patch path guarantees a run never crosses a row boundary, so this
        // is the branch that runs: one row array to copy, then one memmove-ish
        // replace instead of `cells.count` separate writes.
        let row = start / rowWidth
        let column = start - row * rowWidth
        guard row < rows.count, column >= 0, column + cells.count <= rows[row].count else {
            // A run this buffer cannot place as one row. That only happens when the
            // frame's `width` was reassigned after it was built, so its flat index
            // arithmetic no longer agrees with the chunking -- writing "somewhere"
            // per cell would land cells in the wrong row and still report success.
            // Refusing is what makes `PaneSurfaceFrame.apply` reject such a patch
            // with the buffer untouched.
            return false
        }
        rows[row].replaceSubrange(column ..< column + cells.count, with: cells)
        return true
    }

    /// The flat cells, in frame order. For tests and for callers that need a
    /// plain array (none in the render path — that indexes by row).
    public var flattened: [CellData] {
        if rows.count == 1 { return rows[0] }
        var cells: [CellData] = []
        cells.reserveCapacity(cellCount)
        for row in rows { cells.append(contentsOf: row) }
        return cells
    }

    /// Whether `index` shares storage between the two buffers.
    ///
    /// The property the patch path depends on: after applying a one-row patch,
    /// every other row is the *same buffer*, not an equal copy. Exposed because a
    /// timing assertion cannot prove that and a value-equality assertion cannot
    /// see it — `scripts/bench.sh` and the tests use this instead (see
    /// docs/PERFORMANCE.md §1b, "两份数据不能共享存储", on why an equality check
    /// cannot answer this).
    ///
    /// Public rather than `internal` + `@testable` because `Scripts/bench.sh`
    /// links the release library and imports it like any other client, so its
    /// self-checks see only the public surface.
    public func sharesRow(_ index: Int, with other: CellBuffer) -> Bool {
        guard index >= 0, index < rows.count, index < other.rows.count else { return false }
        // Two empty rows have no buffer at all (`baseAddress` is nil on both
        // sides), so "same address" would report sharing for unrelated rows. A
        // zero-width frame is the only way to get here, and it proves nothing.
        guard !rows[index].isEmpty, !other.rows[index].isEmpty else { return false }
        return rows[index].withUnsafeBufferPointer { mine in
            other.rows[index].withUnsafeBufferPointer { theirs in
                mine.baseAddress == theirs.baseAddress
            }
        }
    }

    /// Cell-wise equality.
    ///
    /// Rows that are the same buffer compare in O(1) (Swift's `Array` `==` short
    /// circuits on identical storage), which is what keeps the renderer's row diff
    /// cheap after a patch: only the patched row is a copy, so only that row is
    /// scanned.
    public static func == (lhs: CellBuffer, rhs: CellBuffer) -> Bool {
        guard lhs.cellCount == rhs.cellCount else { return false }
        if lhs.rowWidth == rhs.rowWidth, lhs.rows.count == rhs.rows.count {
            return lhs.rows == rhs.rows
        }
        // Same cells, different chunking: layout is not part of the value.
        return lhs.flattened == rhs.flattened
    }
}
