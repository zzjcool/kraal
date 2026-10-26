// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// `PaneSurfaceSplit` decoding, pinned byte by byte.
//
// This decoder had no test at all. `WireOrderTests` only ever asserted
// `splits.isEmpty`, and the one surface fixture (`surface_120x40.bin`) carries a
// single pane and no splits — so every byte of `decodeSplit` was unexercised.
//
// The failure mode is the same one `WireOrderTests` documents for the rest of the
// wire: bincode is **positional**. Reorder two fields, or read `area` where
// `hitRect` belongs, and nothing fails to decode. The client simply draws the
// divider in the wrong place, or lets the pointer grab it somewhere else, or
// misses it entirely — and the daemon has no idea, because the frame was well
// formed.
//
// `herdr-gpui` reaches the same struct from `herdr-protocol/src/wire.rs:457`,
// where the order is `direction, pos, area, hit_rect, path`. That is the order
// asserted below, written out from the upstream declaration rather than from this
// repository's decoder, so the two have to agree independently.

import Foundation
import Testing

@testable import KraalProtocol

@Suite("Split wire order")
struct SplitWireOrderTests {
    /// The smallest legal encoding of one split.
    ///
    /// `direction` is a one-byte-or-more varint tag, `position` a u16 varint, each
    /// rect four u16 varints, and `path` a varint length followed by one byte per
    /// element. All values are kept under 251 so every integer is a single byte,
    /// which makes the expected bytes readable against the field list.
    private static func bytes(
        directionTag: UInt64 = 0,
        position: UInt64 = 40,
        area: SurfaceRect = SurfaceRect(originX: 0, originY: 0, width: 80, height: 24),
        hitRect: SurfaceRect = SurfaceRect(originX: 40, originY: 0, width: 1, height: 24),
        path: [Bool] = [false, true]
    ) -> [UInt8] {
        var writer = BincodeWriter()
        writer.writeVarint(directionTag)
        writer.writeVarint(position)
        for value in [area.originX, area.originY, area.width, area.height] {
            writer.writeVarint(UInt64(value))
        }
        for value in [hitRect.originX, hitRect.originY, hitRect.width, hitRect.height] {
            writer.writeVarint(UInt64(value))
        }
        writer.writeVarint(UInt64(path.count))
        for step in path { writer.writeBool(step) }
        return writer.bytes
    }

    private static func decode(_ bytes: [UInt8]) throws -> PaneSurfaceSplit {
        var reader = BincodeReader(Data(bytes))
        let split = try WireDecoder.decodeSplit(&reader)
        // A decoder that reads too few bytes leaves the rest of the frame to be
        // interpreted as whatever comes next, which then fails somewhere far away
        // from here. Asserting the reader is drained localises that.
        #expect(reader.isAtEnd, "decodeSplit left \(reader.remaining) bytes unread")
        return split
    }

    /// The field order itself, as literal bytes.
    ///
    /// Written out by hand so a reordering in `decodeSplit` disagrees with this
    /// array instead of silently agreeing with itself.
    @Test("the bytes are direction, position, area, hitRect, path")
    func byteOrder() throws {
        let split = try Self.decode(Self.bytes())

        #expect(split.direction == .horizontal)
        #expect(split.position == 40)
        #expect(split.area == SurfaceRect(originX: 0, originY: 0, width: 80, height: 24))
        #expect(split.hitRect == SurfaceRect(originX: 40, originY: 0, width: 1, height: 24))
        #expect(split.path == [false, true])
    }

    /// `area` and `hitRect` are adjacent same-typed fields, which is exactly the
    /// pair a swap would survive. Giving them different contents is what makes the
    /// assertion above able to see a swap at all.
    @Test("area and hitRect are not interchangeable")
    func areaAndHitRectAreDistinct() throws {
        let bytes = Self.bytes(
            area: SurfaceRect(originX: 1, originY: 2, width: 30, height: 4),
            hitRect: SurfaceRect(originX: 5, originY: 6, width: 7, height: 8)
        )
        let split = try Self.decode(bytes)

        #expect(split.area == SurfaceRect(originX: 1, originY: 2, width: 30, height: 4))
        #expect(split.hitRect == SurfaceRect(originX: 5, originY: 6, width: 7, height: 8))
        #expect(split.area != split.hitRect, "a swap would make these equal")
    }

    /// The wire tag is `0 = horizontal, 1 = vertical`, and the two names describe
    /// the *divider line*, not the arrangement: `horizontal` is a vertical line
    /// between panes side by side. Pinned here because the direction decides both
    /// the drag axis and the cursor, so getting it backwards moves the divider the
    /// wrong way — which reads as a tracking bug, not a decoding one.
    @Test("tag 0 is horizontal and tag 1 is vertical")
    func directionTags() throws {
        #expect(try Self.decode(Self.bytes(directionTag: 0)).direction == .horizontal)
        #expect(try Self.decode(Self.bytes(directionTag: 1)).direction == .vertical)
    }

    /// A tag outside the two-case enum is a protocol error, not a default.
    ///
    /// Reading it as `vertical` would move a divider that is not there.
    @Test("an out-of-range direction tag is refused")
    func badDirectionTag() {
        var reader = BincodeReader(Data(Self.bytes(directionTag: 2)))
        #expect(throws: BincodeError.self) { try WireDecoder.decodeSplit(&reader) }
    }

    /// `path` is a BSP route: `false` takes the first child, `true` the second.
    /// Its length is a varint, so an empty path and a deep one both have to
    /// survive — the root divider has `[]`, and a divider three levels down does
    /// not fit the same assumption.
    @Test("the path length comes from the wire", arguments: [
        [Bool](),
        [false],
        [true],
        [false, false],
        [true, false, true, false],
    ] as [[Bool]])
    func pathLengths(path: [Bool]) throws {
        #expect(try Self.decode(Self.bytes(path: path)).path == path)
    }

    /// A value above 250 needs a two-byte varint, which shifts every field after
    /// it. A decoder that assumed one byte per integer would read the high half as
    /// the next field and produce a plausible-looking split.
    @Test("a multi-byte varint in one field does not shift the next")
    func multiByteVarint() throws {
        // 300 needs `0xFB 0x2C`; both a position and a rect dimension get one, so
        // the shift shows up whichever field a bug is in.
        let split = try Self.decode(Self.bytes(
            position: 300,
            area: SurfaceRect(originX: 300, originY: 0, width: 300, height: 24)
        ))

        #expect(split.position == 300)
        #expect(split.area.originX == 300)
        #expect(split.area.width == 300)
        #expect(split.hitRect == SurfaceRect(originX: 40, originY: 0, width: 1, height: 24))
    }

    /// A path length longer than the bytes that remain is refused before
    /// allocating, like the reader's other arrays.
    @Test("a path length beyond the payload is refused")
    func pathLengthGuard() {
        var writer = BincodeWriter()
        writer.writeVarint(0)          // direction
        writer.writeVarint(40)         // position
        for value in [UInt64(0), 0, 80, 24, 40, 0, 1, 24] { writer.writeVarint(value) }
        writer.writeVarint(200)        // claims 200 steps, carries none
        var reader = BincodeReader(Data(writer.bytes))
        #expect(throws: BincodeError.self) { try WireDecoder.decodeSplit(&reader) }
    }

    /// A `path` byte other than 0 or 1 is not a `Bool`. Treating any non-zero byte
    /// as `true` would make a protocol error look like a deep path.
    @Test("a non-boolean path step is refused")
    func badPathStep() {
        var writer = BincodeWriter()
        writer.writeVarint(0)
        writer.writeVarint(40)
        for value in [UInt64(0), 0, 80, 24, 40, 0, 1, 24] { writer.writeVarint(value) }
        writer.writeVarint(1)
        writer.writeU8(2)              // neither 0 nor 1
        var reader = BincodeReader(Data(writer.bytes))
        #expect(throws: BincodeError.self) { try WireDecoder.decodeSplit(&reader) }
    }

    /// A truncated split throws rather than decoding a half-read rectangle.
    ///
    /// The cut is placed mid-`hitRect`, so the fields before it are complete and
    /// the failure cannot be blamed on an earlier field.
    @Test("a truncated split throws instead of decoding a partial rect")
    func truncated() {
        let full = Self.bytes()
        // direction(1) + position(1) + area(4) + two of hitRect's four = 8.
        let cut = Array(full.prefix(8))
        var reader = BincodeReader(Data(cut))
        #expect(throws: BincodeError.self) { try WireDecoder.decodeSplit(&reader) }
    }
}
