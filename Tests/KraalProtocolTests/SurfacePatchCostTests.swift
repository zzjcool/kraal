// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// issue #50: a patch must not copy the whole screen, and must not scan it.
//
// The cost is the point, but a timing assertion cannot prove it — it measures the
// machine, and on a fast one a regression can still come out under the threshold.
// So these tests assert the *mechanism* instead:
//
//   storage identity — after a one-row patch, every other row is the same buffer
//     as before, not an equal copy. That is the property that makes the copy free;
//     with a flat `[CellData]` it is false no matter how fast the machine is.
//
//   work performed — the patch path checks the grid in O(1), and the full cell
//     scan happens when a whole surface arrives instead. `validate()` still
//     checks everything; only the redundant per-patch scan is gone.
//
// docs/PERFORMANCE.md §2 is the reason for the shape: two of the four numbers in
// issues #49/#50 were wrong in opposite directions because the probe measured
// something adjacent to the code under test.

import Foundation
import Testing

@testable import KraalProtocol

enum TestHelperError: Error { case wrongMessage(String) }

/// A decoded surface, via the public wire path (the shape production uses).
private func decodedSurface(
    width: UInt16,
    height: UInt16,
    revision: UInt64 = 1,
    hyperlinks: [String] = []
) throws -> PaneSurfaceFrame {
    var writer = BincodeWriter()
    writer.writeVarint(13)                       // PaneSurface
    writer.writeString("boot-a")
    writer.writeVarint(3)                        // projectionRevision
    writer.writeVarint(revision)                 // surfaceRevision
    writer.writeArray(Array(0 ..< Int(width) * Int(height))) { writer, index in
        writer.writeString(String(UnicodeScalar(UInt8(97 + index % 26))))
        writer.writeVarint(UInt64(index % 8))
        writer.writeVarint(0x1E1E1E)
        writer.writeVarint(0)
        writer.writeBool(false)
        writer.writeBool(false)                  // no hyperlink
    }
    writer.writeVarint(UInt64(width))
    writer.writeVarint(UInt64(height))
    writer.writeBool(true)                       // cursor: Some
    writer.writeVarint(0)
    writer.writeVarint(0)
    writer.writeBool(true)
    writer.writeVarint(0)
    writer.writeArray(hyperlinks) { writer, uri in writer.writeString(uri) }
    writer.writeVarint(0)                        // graphics bytes
    writer.writeVarint(0)                        // panes
    writer.writeVarint(0)                        // splits
    writer.writeBool(false)                      // popup
    writer.writeVarint(0)                        // graphics assets
    writer.writeVarint(0)                        // graphics placements
    writer.writeVarint(0)                        // graphics retained
    guard case let .paneSurface(surface) = try ServerMessageDecoder.decode(Data(writer.bytes)) else {
        throw TestHelperError.wrongMessage("expected a surface")
    }
    return surface
}

/// A patch rewriting `cells` cells of `row`, based on `base`.
private func decodedPatch(
    row: UInt16,
    column: UInt16,
    cells: [CellData],
    base: UInt64
) throws -> PaneSurfacePatch {
    var writer = BincodeWriter()
    writer.writeVarint(19)                       // PaneSurfacePatch
    writer.writeString("boot-a")
    writer.writeVarint(3)                        // projectionRevision
    writer.writeVarint(base)
    writer.writeVarint(base &+ 1)
    writer.writeVarint(1)                        // one row
    writer.writeVarint(UInt64(column))
    writer.writeVarint(UInt64(row))
    writer.writeArray(cells) { writer, cell in
        writer.writeString(cell.symbol)
        writer.writeVarint(UInt64(cell.foreground))
        writer.writeVarint(UInt64(cell.background))
        writer.writeVarint(UInt64(cell.modifier))
        writer.writeBool(cell.skip)
        writer.writeOptional(cell.hyperlink) { writer, link in writer.writeVarint(UInt64(link)) }
    }
    writer.writeVarint(0)                        // panes
    writer.writeBool(false)                      // cursor: None
    guard case let .paneSurfacePatch(patch) = try ServerMessageDecoder.decode(Data(writer.bytes)) else {
        throw TestHelperError.wrongMessage("expected a patch")
    }
    return patch
}

/// One row of a multi-row patch.
private struct PatchRowSpec {
    var row: UInt16
    var column: UInt16
    var cells: [CellData]
}

/// A patch carrying several rows, for the cases where the *order* of the rows
/// matters.
private func decodedMultiRowPatch(
    rows: [PatchRowSpec],
    base: UInt64
) throws -> PaneSurfacePatch {
    var writer = BincodeWriter()
    writer.writeVarint(19)
    writer.writeString("boot-a")
    writer.writeVarint(3)
    writer.writeVarint(base)
    writer.writeVarint(base &+ 1)
    writer.writeVarint(UInt64(rows.count))
    for entry in rows {
        writer.writeVarint(UInt64(entry.column))
        writer.writeVarint(UInt64(entry.row))
        writer.writeArray(entry.cells) { writer, cell in
            writer.writeString(cell.symbol)
            writer.writeVarint(UInt64(cell.foreground))
            writer.writeVarint(UInt64(cell.background))
            writer.writeVarint(UInt64(cell.modifier))
            writer.writeBool(cell.skip)
            writer.writeOptional(cell.hyperlink) { writer, link in writer.writeVarint(UInt64(link)) }
        }
    }
    writer.writeVarint(0)                        // panes
    writer.writeBool(false)                      // cursor: None
    guard case let .paneSurfacePatch(patch) = try ServerMessageDecoder.decode(Data(writer.bytes)) else {
        throw TestHelperError.wrongMessage("expected a patch")
    }
    return patch
}

@Suite("Patch does not copy the screen (issue #50)")
struct PatchCopyOnWriteTests {
    /// The mechanism. A flat `[CellData]` has one buffer for the whole screen, so
    /// any write relocates every row; the row-chunked buffer relocates the one row
    /// the patch touched and shares the rest by reference.
    ///
    /// This is the assertion that goes red when the storage is a single flat
    /// array, or when the rows are made to share one class instance rather than a
    /// CoW buffer — i.e. when the mechanism the fix depends on is gone.
    @Test("a one-row patch leaves every other row sharing storage")
    func untouchedRowsShared() throws {
        var surface = try decodedSurface(width: 200, height: 50)
        let before = surface.frame.buffer
        let replacement = (0 ..< 200).map { index in
            CellData(symbol: String(UnicodeScalar(UInt8(65 + index % 26))),
                     foreground: 1, background: 2, modifier: 0,
                     skip: false, hyperlink: nil)
        }
        try surface.apply(try decodedPatch(row: 7, column: 0, cells: replacement, base: 1))

        for row in 0 ..< 50 where row != 7 {
            let shared = surface.frame.buffer.sharesRow(row, with: before)
            #expect(shared, Comment(rawValue: "row \(row) was copied by a patch that never mentioned it"))
        }
        let patchedShared = surface.frame.buffer.sharesRow(7, with: before)
        #expect(!patchedShared, Comment(rawValue: "the patched row must be a fresh buffer, "
            + "or the renderer's `previous` would be overwritten under it"))
    }

    /// The other half of the same property: the renderer keeps the frame it
    /// painted, so a patch that wrote *through* shared storage would change what
    /// the diff compares against. A plain reference type (`final class
    /// CellBuffer`) passes the sharing test above and fails this one, which is
    /// exactly why the storage is a value type over CoW rows.
    @Test("a patch does not mutate the frame the renderer already holds")
    func publishedCopyIsIndependent() throws {
        var surface = try decodedSurface(width: 80, height: 24)
        let published = surface.frame          // what `renderer.previous` holds
        let replacement = (0 ..< 80).map { index in
            CellData(symbol: String(UnicodeScalar(UInt8(65 + index % 26))),
                     foreground: 5, background: 6, modifier: 0,
                     skip: false, hyperlink: nil)
        }
        try surface.apply(try decodedPatch(row: 3, column: 0, cells: replacement, base: 1))

        let publishedRow = published.buffer.row(3)
        let patchedRow = surface.frame.buffer.row(3)
        #expect(publishedRow != patchedRow, Comment(rawValue: "the patch wrote through into the "
            + "already-painted frame; the row diff would compare the new cells against themselves "
            + "and paint nothing"))
        #expect(surface.frame.buffer.row(3).first?.foreground == 5)
        #expect(publishedRow.first?.foreground == 0,
                Comment(rawValue: "the painted frame's row changed under it"))
    }

    /// A patch writes rows; unchanged rows must stay byte-for-byte equal, which is
    /// what keeps `Array`'s `==` short-circuiting on storage identity.
    ///
    /// Equality alone would also pass for a deep copy of every row, so the
    /// *sharing* is asserted too — that is the property the renderer's row diff
    /// spends its speed on.
    @Test("an unchanged row stays equal and stays shared after a patch")
    func equalitySurvivesPatch() throws {
        var surface = try decodedSurface(width: 40, height: 10)
        let before = surface.frame
        try surface.apply(try decodedPatch(
            row: 2, column: 5,
            cells: [CellData.blank],
            base: 1
        ))
        for row in 0 ..< 10 where row != 2 {
            #expect(surface.frame.buffer.row(row) == before.buffer.row(row))
            #expect(surface.frame.buffer.sharesRow(row, with: before.buffer),
                    Comment(rawValue: "row \(row) is equal but was copied: the row diff now "
                        + "has to scan it instead of comparing storage identity"))
        }
    }

    /// A patch applied to a frame whose `width` was reassigned must be **refused**,
    /// not partly written.
    ///
    /// `width` is a public stored property. `validatePatch` checks a row against
    /// it, while the write places the row in the buffer's own chunking, so a frame
    /// whose cell count still adds up (`4x4` reassigned to `8x2` is still 16 cells,
    /// so `validateGrid` passes) gets past validation and then indexes the wrong
    /// rows. The write used to fall back to per-cell writes whose out-of-range
    /// single-cell write returned silently, and the loop still reported success.
    ///
    /// The patch deliberately carries **two** rows and the placeable one comes
    /// first: that is what distinguishes "refused" from "refused after writing the
    /// rows it could". A single bad row would pass this test even with a
    /// non-atomic `apply`.
    @Test("a patch that cannot be placed is refused and leaves the buffer untouched")
    func mismatchedChunkingRefused() throws {
        var surface = try decodedSurface(width: 4, height: 4)
        // Same cell count, different chunking: 8x2 over a 4-wide buffer.
        surface.frame.width = 8
        surface.frame.height = 2
        let before = surface
        // The cell count still adds up, so the grid check — the only arrival-side
        // check the patch path inherited — passes.
        #expect(throws: Never.self) { try surface.frame.validateGrid() }

        func cells(_ symbol: String) -> [CellData] {
            (0 ..< 2).map { _ in
                CellData(symbol: symbol, foreground: 9, background: 9,
                         modifier: 0, skip: false, hyperlink: nil)
            }
        }
        // In the 8-wide grid: row 1 column 0 is flat 8, which the 4-wide buffer sees
        // as row 2 column 0 — placeable. Row 1 column 3 is flat 11: row 2 column 3,
        // and the two-cell run 3..<5 does not fit in a 4-wide row — not placeable.
        // `validatePatch` cannot tell them apart: 0 + 2 <= 8 and 3 + 2 <= 8.
        let patch = try decodedMultiRowPatch(rows: [
            PatchRowSpec(row: 1, column: 0, cells: cells("A")),
            PatchRowSpec(row: 1, column: 3, cells: cells("B")),
        ], base: 1)

        #expect(throws: SurfaceError.patchRowBounds) { try surface.apply(patch) }
        #expect(surface == before,
                Comment(rawValue: "a refused patch left a partial write behind: the screen "
                    + "would show cells the daemon never composed"))
    }
}

@Suite("Patch validation is incremental (issue #50)")
struct PatchValidationScopeTests {
    /// The patch path checks the two things a patch can actually disturb — the
    /// grid size and the cursor — and nothing that needs the cells.
    @Test("a baseline whose cell count disagrees with its grid is still refused")
    func cellCountStillChecked() {
        // A frame built by hand with too few cells: `validateGrid` must catch it,
        // because this is the check that used to run on every patch.
        let frame = FrameData(
            cells: [.blank, .blank],
            width: 2,
            height: 2,
            cursor: nil,
            hyperlinks: [],
            graphics: Data()
        )
        #expect(throws: SurfaceError.cellCount(expected: 4, actual: 2)) {
            try frame.validateGrid()
        }
        // And the full check still catches it, for arriving surfaces.
        #expect(throws: SurfaceError.self) { try frame.validate() }
    }

    /// `validateGrid` must not have replaced the full check: hyperlink indices are
    /// still validated where they can actually be wrong — on a whole frame.
    @Test("the full check still rejects a dangling hyperlink index")
    func fullCheckKeepsHyperlinks() {
        let frame = FrameData(
            cells: [
                CellData(symbol: "a", foreground: 0, background: 0,
                         modifier: 0, skip: false, hyperlink: 0),
                .blank,
            ],
            width: 2,
            height: 1,
            cursor: nil,
            hyperlinks: [],                  // index 0 does not exist
            graphics: Data()
        )
        #expect(throws: SurfaceError.self) { try frame.validate() }
        #expect(frame.firstValidationError() != nil)
        // The O(1) check does not look at cells, by design: the patch path never
        // needs it to, because a patch cannot introduce a hyperlink the surface
        // did not already have.
        #expect(throws: Never.self) { try frame.validateGrid() }
    }

    /// A patch's own hyperlink indices are still checked cell by cell — that is
    /// the check that makes dropping the baseline scan safe.
    @Test("a patch introducing an out-of-range hyperlink is refused")
    func patchHyperlinkChecked() throws {
        var surface = try decodedSurface(width: 4, height: 2)
        let bad = CellData(symbol: "x", foreground: 0, background: 0,
                           modifier: 0, skip: false, hyperlink: 3)
        let patch = try decodedPatch(row: 0, column: 0, cells: [bad], base: 1)
        let before = surface
        #expect(throws: SurfaceError.hyperlinkIndex(index: 3, count: 0)) {
            try surface.apply(patch)
        }
        #expect(surface == before, "a rejected patch touched the frame")
    }

    /// A dangling hyperlink in the *baseline* is caught when the surface arrives,
    /// not on every patch. This is the coverage the incremental check moved rather
    /// than removed — asserted end to end so the move cannot quietly become a
    /// deletion (see `AppStore.handleSurface`).
    @Test("a surface with a dangling hyperlink fails full validation on arrival")
    func arrivalRejectsDanglingLink() throws {
        var surface = try decodedSurface(width: 4, height: 2)
        // Rewrite one cell to point at hyperlink 0 with no hyperlinks declared.
        var cells = surface.frame.flatCells
        cells[0] = CellData(symbol: "a", foreground: 0, background: 0,
                            modifier: 0, skip: false, hyperlink: 0)
        surface.frame.buffer = CellBuffer(cells, width: 4)

        #expect(surface.frame.firstValidationError() != nil,
                Comment(rawValue: "an arriving surface with a dangling hyperlink must be refused"))
        // And the patch path alone would have missed it — which is why the check
        // belongs on arrival, where it now runs.
        #expect(throws: Never.self) { try surface.frame.validateGrid() }
    }
}

@Suite("Cell buffer semantics (issue #50)")
struct CellBufferTests {
    @Test("every accessor agrees with a flat array")
    func matchesFlatArray() {
        let cells = (0 ..< 37).map { index in
            CellData(symbol: "\(index % 10)", foreground: UInt32(index),
                     background: 0, modifier: 0, skip: false, hyperlink: nil)
        }
        for width in [1, 5, 7, 37, 100] {
            let buffer = CellBuffer(cells, width: width)
            #expect(buffer.count == cells.count)
            #expect(buffer.flattened.count == cells.count)
            for index in 0 ..< cells.count {
                #expect(buffer[index].foreground == cells[index].foreground,
                    Comment(rawValue: "width \(width), index \(index)"))
                #expect(buffer.cell(at: index)?.symbol == cells[index].symbol)
            }
            #expect(buffer.cell(at: -1) == nil)
            #expect(buffer.cell(at: cells.count) == nil)
        }
    }

    @Test("a run of cells writes and refuses to overflow")
    func bulkWrite() {
        var buffer = CellBuffer(Array(repeating: .blank, count: 12), width: 4)
        let run = (0 ..< 4).map { index in
            CellData(symbol: "\(index)", foreground: 1, background: 0,
                     modifier: 0, skip: false, hyperlink: nil)
        }
        let wrote = buffer.write(run, at: 4)
        #expect(wrote)
        #expect(buffer[row0: 1] == run.map(\.symbol))
        // A run that would spill past the end must be refused whole.
        let spilled = buffer.write(run, at: 10)
        #expect(!spilled)
        #expect(buffer.count == 12)
    }

    @Test("a zero width does not divide by zero")
    func zeroWidth() {
        // `FrameData` can be built with width 0; the buffer must stay total rather
        // than trapping before validation gets a chance to reject the frame.
        let buffer = CellBuffer([.blank, .blank], width: 0)
        #expect(buffer.count == 2)
        #expect(buffer.cell(at: 0) != nil)
    }

    /// Two unrelated empty rows have no storage at all, so comparing
    /// `baseAddress` would report them as shared. Nothing depends on that answer
    /// being true, and reporting "shared" for unrelated rows is exactly the kind
    /// of false positive the self-check in `Scripts/bench.sh` reads.
    @Test("two empty rows do not count as shared storage")
    func emptyRowsAreNotShared() throws {
        let surface = try decodedSurface(width: 40, height: 4)
        var empty = surface
        empty.frame.buffer = CellBuffer(rows: Array(repeating: [], count: 4), width: 40)
        #expect(!surface.frame.buffer.sharesRow(0, with: empty.frame.buffer))
        #expect(!empty.frame.buffer.sharesRow(0, with: empty.frame.buffer),
                "a buffer reported an empty row as sharing storage with itself")
        // Rows that do have cells still answer by storage identity.
        #expect(surface.frame.buffer.sharesRow(0, with: surface.frame.buffer))
        var copied = surface
        copied.frame.buffer.write(.blank, at: 0)
        #expect(!surface.frame.buffer.sharesRow(0, with: copied.frame.buffer))
    }

    /// The path `paneFrame` uses: rows already built, handed over as-is, so the
    /// initialiser neither re-chunks nor copies them.
    @Test("the row initialiser takes the rows it is given, without copying")
    func rowsInitialiserSharesStorage() {
        let rows: [[CellData]] = (0 ..< 3).map { row in
            (0 ..< 4).map { column in
                CellData(symbol: "\(row)\(column)", foreground: 0, background: 0,
                         modifier: 0, skip: false, hyperlink: nil)
            }
        }
        let buffer = CellBuffer(rows: rows, width: 4)
        #expect(buffer.count == 12)
        #expect(buffer.rowCount == 3)
        // The initialiser took the row arrays themselves: a second buffer built from
        // the same `rows` shares every row's storage with the first. A defensive
        // `row.map { Array($0) }` inside the initialiser would break this, and that
        // defensive copy is precisely the cost this initialiser exists to avoid.
        #expect(buffer.sharesRow(0, with: CellBuffer(rows: rows, width: 4)))
        #expect(buffer.sharesRow(2, with: CellBuffer(rows: rows, width: 4)))
        // And the rows are the caller's values, not a builder's leftovers.
        #expect(buffer.flattened.map(\.symbol) == rows.flatMap { $0.map(\.symbol) })
        var mutable = rows
        mutable[0][0] = CellData(symbol: "X", foreground: 0, background: 0,
                                 modifier: 0, skip: false, hyperlink: nil)
        #expect(buffer.cell(column: 0, row: 0)?.symbol == "00",
                Comment(rawValue: "writing to the caller's array changed the buffer: rows "
                    + "were aliased, not shared copy-on-write"))
    }

    /// A row that is shorter than the declared width keeps `count` and indexing
    /// honest, which is what the crop relies on for a malformed frame.
    @Test("the row initialiser handles ragged rows")
    func rowsInitialiserRagged() {
        let rows: [[CellData]] = [Array(repeating: .blank, count: 3), [.blank]]
        let buffer = CellBuffer(rows: rows, width: 3)
        #expect(buffer.count == 4)
        #expect(buffer.rowCount == 2)
        #expect(buffer.cell(column: 2, row: 1) == nil)
        #expect(buffer.cell(column: 0, row: 1) != nil)
    }

    @Test("buffers with different chunking are still equal when their cells are")
    func equalityIsByCells() {
        let cells = Array(repeating: CellData.blank, count: 8)
        #expect(CellBuffer(cells, width: 4) == CellBuffer(cells, width: 8))
        #expect(CellBuffer(cells, width: 4) != CellBuffer(cells + [.blank], width: 4))
    }
}

private extension CellBuffer {
    /// Row `index`'s symbols, for readable assertions.
    subscript(row0 index: Int) -> [String] {
        row(index).map(\.symbol)
    }
}
