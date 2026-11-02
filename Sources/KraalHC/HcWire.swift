// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The framed side of the herdr-core protocol.
//
// After `hello {framed: true}` every message is:
//
//     [channel u32 LE][kind u8][len u32 LE][payload]
//
// Channel 0 carries JSON-RPC; other channels carry stream bytes (terminal
// attach). Reference: herdr-core schema/README.md, "Framed mode".

import Foundation

public enum HcWireError: Error, Equatable, CustomStringConvertible {
    case payloadTooLarge(Int)
    case truncatedFrame

    public var description: String {
        switch self {
        case let .payloadTooLarge(bytes):
            "frame payload is \(bytes) bytes; the core allows at most \(HcWire.maxPayload)"
        case .truncatedFrame:
            "truncated frame header"
        }
    }
}

public enum HcFrameKind: UInt8, Sendable {
    case data = 0
    case credit = 1
    case close = 2
    case resize = 3
    case focus = 4
    case facts = 5
}

public struct HcFrame: Sendable, Equatable {
    public let channel: UInt32
    /// Raw kind. Kept as `UInt8` because the protocol only grows: an unknown kind
    /// must be ignorable, not a decode failure.
    public let kind: UInt8
    public let payload: Data

    public var knownKind: HcFrameKind? {
        HcFrameKind(rawValue: kind)
    }
}

public enum HcWire {
    public static let headerSize = 9
    public static let maxPayload = 16 * 1024 * 1024

    /// A stream starts with this much credit. The viewer returns credit for bytes
    /// it consumed; RESIZE does not consume it.
    public static let initialCredit = 256 * 1024

    /// The core sends DATA in chunks of at most this size.
    public static let maxDataChunk = 16 * 1024

    public static func frame(channel: UInt32, kind: UInt8, payload: Data = Data()) throws -> Data {
        guard payload.count <= maxPayload else {
            throw HcWireError.payloadTooLarge(payload.count)
        }
        var data = Data(capacity: headerSize + payload.count)
        appendUInt32(UInt32(channel), to: &data)
        data.append(kind)
        appendUInt32(UInt32(payload.count), to: &data)
        data.append(payload)
        return data
    }

    public static func dataFrame(channel: UInt32, payload: Data) throws -> Data {
        try frame(channel: channel, kind: HcFrameKind.data.rawValue, payload: payload)
    }

    public static func creditFrame(channel: UInt32, bytes: Int) -> Data {
        let clamped = max(0, min(bytes, Int(UInt32.max)))
        var payload = Data(capacity: 4)
        appendUInt32(UInt32(clamped), to: &payload)
        return (try? frame(channel: channel, kind: HcFrameKind.credit.rawValue, payload: payload))
            ?? Data()
    }

    public static func closeFrame(channel: UInt32, reason: JSONValue? = nil) throws -> Data {
        let payload: Data
        if let reason {
            payload = try JSONEncoder().encode(reason)
        } else {
            payload = Data()
        }
        return try frame(channel: channel, kind: HcFrameKind.close.rawValue, payload: payload)
    }

    public static func resizeFrame(channel: UInt32, cols: UInt16, rows: UInt16) throws -> Data {
        var payload = Data(capacity: 4)
        payload.append(UInt8(cols & 0xFF))
        payload.append(UInt8(cols >> 8))
        payload.append(UInt8(rows & 0xFF))
        payload.append(UInt8(rows >> 8))
        return try frame(channel: channel, kind: HcFrameKind.resize.rawValue, payload: payload)
    }

    public static func focusFrame(channel: UInt32, focused: Bool) throws -> Data {
        try frame(
            channel: channel,
            kind: HcFrameKind.focus.rawValue,
            payload: Data([focused ? 1 : 0])
        )
    }

    public static func factsFrame(channel: UInt32, facts: JSONValue) throws -> Data {
        try frame(
            channel: channel,
            kind: HcFrameKind.facts.rawValue,
            payload: JSONEncoder().encode(facts)
        )
    }

    public static func decodeResize(_ payload: Data) throws -> (cols: UInt16, rows: UInt16) {
        guard payload.count == 4 else { throw HcWireError.truncatedFrame }
        let bytes = [UInt8](payload)
        return (
            UInt16(bytes[0]) | (UInt16(bytes[1]) << 8),
            UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
        )
    }

    static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }
}

/// Incremental frame decoder. Feed it whatever the socket returned; pull frames
/// until it returns nil.
public struct HcFrameDecoder {
    private var buffer = Data()
    private var offset = 0

    public init() {}

    public var bufferedByteCount: Int {
        buffer.count - offset
    }

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// Returns the next complete frame, or nil when more bytes are needed.
    /// Throws when the header announces a payload larger than the protocol allows.
    public mutating func next() throws -> HcFrame? {
        let available = buffer.count - offset
        guard available >= HcWire.headerSize else { return nil }

        let channel = readUInt32(at: offset)
        let kind = buffer[offset + 4]
        let length = Int(readUInt32(at: offset + 5))
        guard length <= HcWire.maxPayload else {
            throw HcWireError.payloadTooLarge(length)
        }
        guard available >= HcWire.headerSize + length else { return nil }

        let start = offset + HcWire.headerSize
        let payload = buffer.subdata(in: start ..< start + length)
        offset = start + length
        compactIfNeeded()
        return HcFrame(channel: channel, kind: kind, payload: payload)
    }

    private func readUInt32(at index: Int) -> UInt32 {
        UInt32(buffer[index])
            | (UInt32(buffer[index + 1]) << 8)
            | (UInt32(buffer[index + 2]) << 16)
            | (UInt32(buffer[index + 3]) << 24)
    }

    private mutating func compactIfNeeded() {
        // Amortised: drop consumed bytes once they dominate, not per frame.
        guard offset > 64 * 1024, offset * 2 > buffer.count else { return }
        buffer.removeFirst(offset)
        offset = 0
    }
}
