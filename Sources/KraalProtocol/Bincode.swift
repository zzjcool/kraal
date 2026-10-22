// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Bincode 2 "standard" primitive decoding.
//
// bincode uses positional encoding: enum variants are written as their
// declaration index as a varint, and integers **wider than 8 bits** use a
// variable-length scheme. A `u8` is always one raw byte — see `writeU8` /
// `readU8`. Getting that backwards is silent for 0...250 and shifts every
// following field above it. Field order is a wire contract — see `Wire.swift`.
//
// Reference: `herdr-gpui/crates/herdr-protocol/src/codec.rs` and bincode's
// `config::standard()` (little-endian, varint encoding, varint length prefix).

import Foundation

public enum BincodeError: Error, CustomStringConvertible, Equatable {
    case unexpectedEnd(offset: Int, needed: Int, available: Int)
    case invalidVarintPrefix(UInt8, offset: Int)
    case invalidBool(UInt8, offset: Int)
    case invalidUTF8(offset: Int)
    case invalidTag(UInt32, type: String)
    case trailingBytes(count: Int)
    case limitExceeded(Int)

    public var description: String {
        switch self {
        case let .unexpectedEnd(offset, needed, available):
            "unexpected end of payload at \(offset): needed \(needed) bytes, \(available) left"
        case let .invalidVarintPrefix(byte, offset):
            "invalid varint prefix 0x\(String(byte, radix: 16)) at \(offset)"
        case let .invalidBool(byte, offset):
            "invalid bool byte \(byte) at \(offset)"
        case let .invalidUTF8(offset):
            "invalid UTF-8 string at \(offset)"
        case let .invalidTag(tag, type):
            "unknown \(type) tag \(tag)"
        case let .trailingBytes(count):
            "\(count) trailing bytes after payload"
        case let .limitExceeded(limit):
            "payload exceeds \(limit) bytes"
        }
    }
}

/// A cursor over one bincode payload. Not `Sendable`: it is a scratch value
/// created per message inside the decoder actor.
public struct BincodeReader {
    public let bytes: [UInt8]
    public private(set) var offset: Int

    public init(_ data: Data) {
        bytes = [UInt8](data)
        offset = 0
    }

    public init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    public var remaining: Int { bytes.count - offset }
    public var isAtEnd: Bool { offset >= bytes.count }

    public mutating func require(_ count: Int) throws {
        guard remaining >= count else {
            throw BincodeError.unexpectedEnd(
                offset: offset,
                needed: count,
                available: remaining
            )
        }
    }

    public mutating func skip(_ count: Int) throws {
        try require(count)
        offset += count
    }

    public mutating func readU8() throws -> UInt8 {
        try require(1)
        defer { offset += 1 }
        return bytes[offset]
    }

    /// bincode's varint: one byte below 251, else 0xFB/0xFC/0xFD prefix plus a
    /// fixed-width little-endian integer.
    public mutating func readVarint() throws -> UInt64 {
        let prefix = try readU8()
        switch prefix {
        case 0x00 ... 0xFA:
            return UInt64(prefix)
        case 0xFB:
            try require(2)
            defer { offset += 2 }
            return UInt64(bytes[offset]) | (UInt64(bytes[offset + 1]) << 8)
        case 0xFC:
            try require(4)
            defer { offset += 4 }
            var value: UInt64 = 0
            for index in 0 ..< 4 {
                value |= UInt64(bytes[offset + index]) << (8 * UInt64(index))
            }
            return value
        case 0xFD:
            try require(8)
            defer { offset += 8 }
            var value: UInt64 = 0
            for index in 0 ..< 8 {
                value |= UInt64(bytes[offset + index]) << (8 * UInt64(index))
            }
            return value
        default:
            throw BincodeError.invalidVarintPrefix(prefix, offset: offset - 1)
        }
    }

    /// Varints are used for integers wider than 8 bits; this narrows with a
    /// bounds check so a corrupt frame cannot silently truncate a coordinate.
    public mutating func readU16Varint() throws -> UInt16 {
        let value = try readVarint()
        guard value <= UInt64(UInt16.max) else {
            throw BincodeError.invalidTag(UInt32(truncatingIfNeeded: value), type: "u16")
        }
        return UInt16(value)
    }

    public mutating func readU32Varint() throws -> UInt32 {
        let value = try readVarint()
        guard value <= UInt64(UInt32.max) else {
            throw BincodeError.invalidTag(UInt32(truncatingIfNeeded: value), type: "u32")
        }
        return UInt32(value)
    }

    public mutating func readBool() throws -> Bool {
        let byte = try readU8()
        switch byte {
        case 0: return false
        case 1: return true
        default: throw BincodeError.invalidBool(byte, offset: offset - 1)
        }
    }

    /// `Option<T>` is a single 0/1 tag byte.
    public mutating func readOptional<T>(
        _ body: (inout BincodeReader) throws -> T
    ) throws -> T? {
        guard try readBool() else { return nil }
        return try body(&self)
    }

    /// `Vec<T>` is a varint count followed by that many elements. The count is
    /// validated against the remaining bytes before allocating, so a corrupt
    /// length cannot force a huge allocation.
    public mutating func readArray<T>(
        minimumElementBytes: Int = 1,
        _ body: (inout BincodeReader) throws -> T
    ) throws -> [T] {
        let count64 = try readVarint()
        guard count64 <= UInt64(Int.max) else {
            throw BincodeError.limitExceeded(Int.max)
        }
        let count = Int(count64)
        if minimumElementBytes > 0 {
            guard count <= remaining / minimumElementBytes else {
                throw BincodeError.unexpectedEnd(
                    offset: offset,
                    needed: count * minimumElementBytes,
                    available: remaining
                )
            }
        }
        var result: [T] = []
        result.reserveCapacity(count)
        for _ in 0 ..< count {
            result.append(try body(&self))
        }
        return result
    }

    /// bincode `String`: varint byte length, then UTF-8.
    public mutating func readString() throws -> String {
        let length = try readVarint()
        guard length <= UInt64(remaining) else {
            throw BincodeError.unexpectedEnd(
                offset: offset,
                needed: Int(truncatingIfNeeded: length),
                available: remaining
            )
        }
        let count = Int(length)
        let start = offset
        try require(count)
        offset += count
        guard let string = String(bytes: bytes[start ..< start + count], encoding: .utf8) else {
            throw BincodeError.invalidUTF8(offset: start)
        }
        return string
    }

    /// `Vec<u8>`: varint length, then raw bytes.
    public mutating func readByteBuffer() throws -> Data {
        let length = try readVarint()
        guard length <= UInt64(remaining) else {
            throw BincodeError.unexpectedEnd(
                offset: offset,
                needed: Int(truncatingIfNeeded: length),
                available: remaining
            )
        }
        let count = Int(length)
        let start = offset
        try require(count)
        offset += count
        return Data(bytes[start ..< start + count])
    }

    /// Reads a `u16`/`u32`/`u64` by varint, for field types that bincode
    /// encodes as varints regardless of declaration width.
    public mutating func readUInt64() throws -> UInt64 {
        try readVarint()
    }

    /// Enum tag as a varint, checked against a known case count.
    public mutating func readTag(caseCount: Int, type: String) throws -> Int {
        let raw = try readVarint()
        guard raw < UInt64(caseCount) else {
            throw BincodeError.invalidTag(UInt32(truncatingIfNeeded: raw), type: type)
        }
        return Int(raw)
    }
}

// MARK: - Writing

/// Encoder for the handful of messages a client sends. Kept alongside the
/// reader so both halves of the wire contract live in one place.
public struct BincodeWriter {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    public mutating func writeVarint(_ value: UInt64) {
        switch value {
        case 0 ... 250:
            bytes.append(UInt8(value))
        case 251 ... 0xFFFF:
            bytes.append(0xFB)
            bytes.append(UInt8(value & 0xFF))
            bytes.append(UInt8((value >> 8) & 0xFF))
        case 0x1_0000 ... 0xFFFF_FFFF:
            bytes.append(0xFC)
            for shift in stride(from: 0, to: 32, by: 8) {
                bytes.append(UInt8((value >> UInt64(shift)) & 0xFF))
            }
        default:
            bytes.append(0xFD)
            for shift in stride(from: 0, to: 64, by: 8) {
                bytes.append(UInt8((value >> UInt64(shift)) & 0xFF))
            }
        }
    }

    public mutating func writeBool(_ value: Bool) {
        bytes.append(value ? 1 : 0)
    }

    /// A `u8` field is one raw byte, not a varint.
    ///
    /// bincode only uses the variable-length scheme for integers wider than 8
    /// bits; `u8` is positional-packing's one-byte case. Writing it through
    /// `writeVarint` happens to produce the same byte for every value up to 250,
    /// which is why this was invisible for so long — but 251...255 grow to three
    /// bytes and every field after them shifts.
    ///
    /// This is the writer-side mirror of `BincodeReader.readU8()`.
    public mutating func writeU8(_ value: UInt8) {
        bytes.append(value)
    }

    public mutating func writeString(_ value: String) {
        let utf8 = Array(value.utf8)
        writeVarint(UInt64(utf8.count))
        bytes.append(contentsOf: utf8)
    }

    public mutating func writeByteBuffer(_ value: Data) {
        writeVarint(UInt64(value.count))
        bytes.append(contentsOf: value)
    }

    public mutating func writeOptional<T>(
        _ value: T?,
        _ body: (inout BincodeWriter, T) -> Void
    ) {
        guard let value else {
            writeBool(false)
            return
        }
        writeBool(true)
        body(&self, value)
    }

    public mutating func writeArray<T>(
        _ values: [T],
        _ body: (inout BincodeWriter, T) -> Void
    ) {
        writeVarint(UInt64(values.count))
        for value in values {
            body(&self, value)
        }
    }
}
