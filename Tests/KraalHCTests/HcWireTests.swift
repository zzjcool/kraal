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
