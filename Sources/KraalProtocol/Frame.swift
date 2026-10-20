// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Length-prefixed framing: a u32 little-endian byte count followed by one
// bincode payload. Bounds mirror the daemon's own limits so both ends agree on
// what is representable.

import Foundation

public enum FrameError: Error, CustomStringConvertible, Equatable {
    case emptyFrame
    case frameTooLarge(Int, limit: Int)
    case incomplete(needed: Int, available: Int)

    public var description: String {
        switch self {
        case .emptyFrame:
            "empty frame"
        case let .frameTooLarge(size, limit):
            "frame of \(size) bytes exceeds limit \(limit)"
        case let .incomplete(needed, available):
            "incomplete frame: needed \(needed) bytes, have \(available)"
        }
    }
}

public enum FrameLimits {
    /// `herdr-client/src/limits.rs` and `herdr-protocol/src/codec.rs`.
    public static let maxFrameSize = 2 * 1024 * 1024
    public static let maxGraphicsFrameSize = 32 * 1024 * 1024
    public static let maxResponseBytes = 8 * 1024 * 1024
}

/// Splits a byte stream into frames. Fed with arbitrary chunk boundaries from
/// the socket; emits complete payloads only.
public struct FrameDecoder {
    private var buffer: [UInt8] = []
    private let limit: Int

    public init(limit: Int = FrameLimits.maxGraphicsFrameSize) {
        self.limit = limit
    }

    public var pendingByteCount: Int { buffer.count }

    /// Appends bytes and returns every frame that became complete.
    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(contentsOf: data)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let length = Int(buffer[0])
                | (Int(buffer[1]) << 8)
                | (Int(buffer[2]) << 16)
                | (Int(buffer[3]) << 24)
            guard length > 0 else { throw FrameError.emptyFrame }
            guard length <= limit else { throw FrameError.frameTooLarge(length, limit: limit) }
            guard buffer.count >= 4 + length else { break }
            frames.append(Data(buffer[4 ..< 4 + length]))
            buffer.removeFirst(4 + length)
        }
        return frames
    }

    /// Resets the buffer, e.g. after a reconnect.
    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }
}

public enum FrameEncoder {
    /// Prefixes `payload` with its u32 LE length.
    public static func encode(_ payload: Data, limit: Int = FrameLimits.maxFrameSize) throws -> Data {
        guard !payload.isEmpty else { throw FrameError.emptyFrame }
        guard payload.count <= limit else {
            throw FrameError.frameTooLarge(payload.count, limit: limit)
        }
        var out = Data(capacity: payload.count + 4)
        let length = UInt32(payload.count)
        out.append(UInt8(length & 0xFF))
        out.append(UInt8((length >> 8) & 0xFF))
        out.append(UInt8((length >> 16) & 0xFF))
        out.append(UInt8((length >> 24) & 0xFF))
        out.append(payload)
        return out
    }
}
