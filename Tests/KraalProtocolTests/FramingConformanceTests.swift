// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Framing and payload hygiene, ported from upstream.
//
// Sources (all Apache-2.0, see NOTICE):
//   * `herdr-gpui/crates/herdr-protocol/tests/compatibility.rs`
//     (`framing_limits_truncation_trailing_bytes_and_hostile_lengths`,
//      `patch_validation_is_atomic`)
//   * `herdr/src/protocol/render_ansi.rs:1882`
//     (`retained_patch_rejects_overlapping_rows`)
//   * `herdr-gpui/crates/herdr-client/src/tests/framing.rs`
//     (`geometry_and_frame_reader_limits`)
//
// The theme: a payload is either accepted whole or rejected whole, and a length
// the payload cannot possibly honour is refused *before* anything is allocated.
// Both halves are cheap to get wrong silently — a truncated read just returns
// fewer frames, and an overlapping patch just paints the same cells twice.

import Foundation
import Testing

@testable import KraalProtocol

@Suite("Framing limits")
struct FramingLimitTests {
    /// `framing.rs:24`: a length prefix the peer cannot have meant is refused
    /// without waiting for the bytes to arrive. A decoder that merely buffers
    /// would sit on a hostile 4 GiB claim forever.
    @Test("a hostile length prefix is refused before reading")
    func hostileLength() {
        var decoder = FrameDecoder(limit: FrameLimits.maxFrameSize)
        // Length prefix claims u32::MAX.
        let header = Data([0xFF, 0xFF, 0xFF, 0xFF])
        #expect(throws: FrameError.self) { _ = try decoder.append(header) }
    }

    /// `compatibility.rs:430`: an empty payload is not a zero-length frame, it is
    /// a framing error — otherwise `append([])` looks like a clean end of stream.
    @Test("a zero-length frame is an error, not an empty message")
    func zeroLength() {
        var decoder = FrameDecoder(limit: FrameLimits.maxFrameSize)
        #expect(throws: FrameError.self) {
            _ = try decoder.append(Data([0x00, 0x00, 0x00, 0x00]))
        }
        #expect(throws: FrameError.self) {
            _ = try FrameEncoder.encode(Data())
        }
    }

    /// A declared array length is bounded by the bytes actually present, so a
    /// corrupt count fails instead of allocating. `readArray` does this with
    /// `minimumElementBytes`; upstream's `decode.rs` has the same rule.
    @Test("an array length the payload cannot honour is rejected before allocating")
    func hostileArrayLength() {
        var reader = BincodeReader(Data([0xFB, 0xFF, 0xFF])) // 65535 elements
        #expect(throws: BincodeError.self) {
            _ = try reader.readArray(minimumElementBytes: 1) { try $0.readU8() }
        }
    }

    /// Same rule for a string: the byte length must fit in what is left.
    @Test("a string length past the end is rejected")
    func hostileStringLength() {
        var reader = BincodeReader(Data([0xFB, 0xFF, 0xFF, 0x41]))
        #expect(throws: BincodeError.self) { _ = try reader.readString() }
    }

    /// `compatibility.rs:430`: bytes after a complete message are an error, not
    /// padding. Returning success would let a desynchronised stream keep
    /// "decoding" garbage as the start of the next message.
    ///
    /// issue #7: `ServerMessageDecoder.decode` now consumes the payload exactly;
    /// `BincodeError.trailingBytes` is no longer dead code.
    @Test("bytes after a complete message are rejected")
    func trailingBytes() {
        // endpoint_control with empty kind and empty data decodes cleanly on its
        // own; the extra byte is the only violation.
        var payload = Data([20, 0, 0])
        #expect(throws: Never.self) { _ = try ServerMessageDecoder.decode(payload) }
        payload.append(0x00)
        #expect(throws: (any Error).self) { _ = try ServerMessageDecoder.decode(payload) }
    }
}

@Suite("Surface patch atomicity")
struct SurfacePatchAtomicityTests {
    /// Two rows that both claim the same columns of row 0 of a four-column
    /// frame. Upstream rejects the whole patch
    /// (`retained_patch_rejects_overlapping_rows`); the client must never
    /// half-apply it, because the second row would silently win and the frame
    /// would show content the daemon never composited.
    ///
    /// issue #7: `validatePatch` now sorts by (row, column) and rejects overlap;
    /// out-of-order-but-disjoint rows are still accepted, matching upstream.
    @Test("overlapping rows are rejected")
    func overlappingRows() {
        var surface = Self.baseline()
        let patch = PaneSurfacePatch(
            bootId: "boot-a",
            projectionRevision: 3,
            baseSurfaceRevision: 7,
            surfaceRevision: 8,
            rows: [
                PaneSurfacePatchRow(
                    column: 0,
                    row: 0,
                    cells: [Self.cell("A"), Self.cell("B"), Self.cell("C")]
                ),
                PaneSurfacePatchRow(
                    column: 1,
                    row: 0,
                    cells: [Self.cell("D"), Self.cell("E")]
                ),
            ],
            panes: [],
            cursor: nil
        )
        let before = surface
        #expect(throws: SurfaceError.self) { try surface.apply(patch) }
        #expect(surface == before)
    }

    /// Upstream: a patch whose base revision was already consumed is refused.
    /// Replaying one would re-apply stale cells on top of newer content.
    @Test("a patch cannot be applied twice")
    func replayRejected() throws {
        var surface = Self.baseline()
        let patch = Self.simplePatch(base: 7, next: 8)
        try surface.apply(patch)
        let after = surface
        #expect(throws: SurfaceError.self) { try surface.apply(patch) }
        #expect(surface == after)
    }

    /// A patch that would leave the frame inconsistent (cell count no longer
    /// matches the grid) must be refused as a whole, never committed partially.
    @Test("a rejected patch leaves no trace of its rows")
    func rejectionIsWhole() {
        var surface = Self.baseline()
        let before = surface
        // Row 1 is valid, row 2 is out of bounds: the valid row must not land.
        let patch = PaneSurfacePatch(
            bootId: "boot-a",
            projectionRevision: 3,
            baseSurfaceRevision: 7,
            surfaceRevision: 8,
            rows: [
                PaneSurfacePatchRow(column: 0, row: 1, cells: [Self.cell("A"), Self.cell("B")]),
                PaneSurfacePatchRow(column: 0, row: 9, cells: [Self.cell("C")]),
            ],
            panes: [],
            cursor: nil
        )
        #expect(throws: SurfaceError.self) { try surface.apply(patch) }
        #expect(surface == before, "a rejected patch touched the frame")
    }

    /// The other half of the overlap rule: rows that arrive out of order but do
    /// not overlap must still be accepted. Upstream accepts these too, and a
    /// naive "adjacent rows must be non-decreasing" check would reject a legal
    /// patch — so this guards the fix from over-correcting.
    @Test("out-of-order rows that do not overlap are accepted")
    func outOfOrderDisjoint() throws {
        var surface = Self.baseline()
        let patch = PaneSurfacePatch(
            bootId: "boot-a",
            projectionRevision: 3,
            baseSurfaceRevision: 7,
            surfaceRevision: 8,
            rows: [
                PaneSurfacePatchRow(column: 2, row: 0, cells: [Self.cell("C")]),
                PaneSurfacePatchRow(column: 0, row: 0, cells: [Self.cell("A")]),
                PaneSurfacePatchRow(column: 0, row: 1, cells: [Self.cell("B")]),
            ],
            panes: [],
            cursor: nil
        )
        try surface.apply(patch)
        #expect(surface.frame.cells[0].symbol == "A")
        #expect(surface.frame.cells[2].symbol == "C")
    }

    private static func baseline() -> PaneSurfaceFrame {
        PaneSurfaceFrame(
            bootId: "boot-a",
            projectionRevision: 3,
            surfaceRevision: 7,
            frame: FrameData(
                cells: Array(repeating: CellData.blank, count: 16),
                width: 4,
                height: 4,
                cursor: CursorState(column: 0, row: 0, visible: true, shape: 0),
                hyperlinks: [],
                graphics: Data()
            ),
            panes: [],
            splits: [],
            popup: nil,
            graphics: SurfaceGraphicsScene()
        )
    }

    private static func simplePatch(base: UInt64, next: UInt64) -> PaneSurfacePatch {
        PaneSurfacePatch(
            bootId: "boot-a",
            projectionRevision: 3,
            baseSurfaceRevision: base,
            surfaceRevision: next,
            rows: [
                PaneSurfacePatchRow(column: 0, row: 1, cells: [cell("A"), cell("B")]),
            ],
            panes: [],
            cursor: nil
        )
    }

    private static func cell(_ symbol: String) -> CellData {
        CellData(
            symbol: symbol,
            foreground: 0,
            background: 0,
            modifier: 0,
            skip: false,
            hyperlink: nil
        )
    }
}
