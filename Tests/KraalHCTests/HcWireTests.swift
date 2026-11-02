// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import Testing

@testable import KraalHC

@Suite("Framed wire")
struct HcWireTests {
    @Test("encodes the header exactly as the core expects")
    func headerLayout() throws {
        let frame = try HcWire.dataFrame(channel: 1, payload: Data("hi".utf8))
        #expect(Array(frame) == [0x01, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x68, 0x69])
    }

    @Test("decodes frames fed one byte at a time")
    func partialReads() throws {
        let frame = try HcWire.dataFrame(channel: 7, payload: Data("hello".utf8))
        var decoder = HcFrameDecoder()
        for byte in frame.dropLast() {
            decoder.append(Data([byte]))
            #expect(try decoder.next() == nil)
        }
        decoder.append(Data([frame.last ?? 0]))
        let decoded = try decoder.next()
        #expect(decoded?.channel == 7)
        #expect(decoded?.kind == HcFrameKind.data.rawValue)
        #expect(decoded?.payload == Data("hello".utf8))
        #expect(try decoder.next() == nil)
    }

    @Test("decodes two frames in one chunk")
    func backToBack() throws {
        var data = HcWire.creditFrame(channel: 1, bytes: 4096)
        data.append(try HcWire.focusFrame(channel: 2, focused: true))
        var decoder = HcFrameDecoder()
        decoder.append(data)
        let credit = try decoder.next()
        let focus = try decoder.next()
        #expect(credit?.knownKind == .credit)
        #expect(credit?.payload == Data([0x00, 0x10, 0x00, 0x00]))
        #expect(focus?.knownKind == .focus)
        #expect(focus?.payload == Data([1]))
        #expect(try decoder.next() == nil)
    }

    @Test("keeps an unknown kind instead of failing")
    func unknownKind() throws {
        let frame = try HcWire.frame(channel: 4, kind: 200, payload: Data("future".utf8))
        var decoder = HcFrameDecoder()
        decoder.append(frame)
        let decoded = try decoder.next()
        #expect(decoded?.kind == 200)
        #expect(decoded?.knownKind == nil)
        #expect(decoded?.payload == Data("future".utf8))
    }

    @Test("rejects a payload above the protocol cap")
    func tooLarge() {
        var data = Data()
        data.append(contentsOf: [0, 0, 0, 0, 0])
        let bytes = withUnsafeBytes(of: UInt32(HcWire.maxPayload + 1).littleEndian) { Array($0) }
        data.append(contentsOf: bytes)
        var decoder = HcFrameDecoder()
        decoder.append(data)
        #expect(throws: HcWireError.self) {
            _ = try decoder.next()
        }
    }

    @Test("encodes and decodes resize payloads")
    func resize() throws {
        let payload = try HcWire.resizeFrame(channel: 3, cols: 120, rows: 40)
        var decoder = HcFrameDecoder()
        decoder.append(payload)
        let frame = try #require(try decoder.next())
        let size = try HcWire.decodeResize(frame.payload)
        #expect(size.cols == 120)
        #expect(size.rows == 40)
    }

    @Test("clamps credit instead of crashing on overflow")
    func creditClamp() throws {
        let huge = HcWire.creditFrame(channel: 1, bytes: Int.max)
        var decoder = HcFrameDecoder()
        decoder.append(huge)
        let frame = try #require(try decoder.next())
        #expect(frame.payload == Data([0xFF, 0xFF, 0xFF, 0xFF]))

        let negative = HcWire.creditFrame(channel: 1, bytes: -10)
        var second = HcFrameDecoder()
        second.append(negative)
        #expect(try second.next()?.payload == Data([0, 0, 0, 0]))
    }
}

@Suite("Frame decoder after compaction")
struct HcFrameDecoderCompactionTests {
    @Test("frames still decode after the buffer has compacted")
    func decodesPastCompaction() throws {
        var encoder = HcFrameDecoderHarness()
        var decoder = HcFrameDecoder()
        // 10k × 11 bytes = 110 KiB, so `compactIfNeeded` runs mid-stream.
        for index in 0 ..< 10_000 {
            let payload = Data([UInt8(index & 0xFF), UInt8((index >> 8) & 0xFF)])
            let frame = try HcWire.dataFrame(channel: UInt32(index % 7 + 1), payload: payload)
            encoder.frames.append(frame)
        }
        // Feed in chunks so compaction happens between frames, not at the end.
        for chunk in stride(from: 0, to: encoder.frames.count, by: 97) {
            let end = min(chunk + 97, encoder.frames.count)
            decoder.append(encoder.frames[chunk ..< end].reduce(into: Data()) { $0.append($1) })
            while try decoder.next() != nil {}
        }
        // The last frame must still carry its own bytes.
        var tailDecoder = HcFrameDecoder()
        tailDecoder.append(encoder.frames.last ?? Data())
        let tail = try #require(try tailDecoder.next())
        #expect(tail.channel == UInt32(9_999 % 7 + 1))
        #expect(tail.payload == Data([UInt8(9_999 & 0xFF), UInt8((9_999 >> 8) & 0xFF)]))
    }

    @Test("a frame split across the compaction boundary survives")
    func splitAtBoundary() throws {
        var decoder = HcFrameDecoder()
        let filler = try HcWire.dataFrame(channel: 1, payload: Data(repeating: 0x41, count: 1024))
        var stream = Data()
        for _ in 0 ..< 100 { stream.append(filler) } // 103 KiB, forces compaction
        let last = try HcWire.dataFrame(channel: 2, payload: Data("tail".utf8))
        stream.append(last)
        decoder.append(stream)

        var frames = 0
        var final: HcFrame?
        while let frame = try decoder.next() {
            frames += 1
            final = frame
        }
        #expect(frames == 101)
        #expect(final?.channel == 2)
        #expect(final?.payload == Data("tail".utf8))
    }
}

private struct HcFrameDecoderHarness {
    var frames: [Data] = []
}
