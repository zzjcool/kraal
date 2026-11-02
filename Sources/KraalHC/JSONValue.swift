// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// A minimal JSON value used by the herdr-core protocol.
//
// The core's params/results are open JSON (the schema is generated from Rust and
// only grows), so decoding into fixed structs would break on the next release.
// This keeps the wire faithful and lets callers read only the fields they know.

import Foundation

public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        guard case let .number(value) = self,
              value.rounded() == value,
              value.magnitude <= 9_007_199_254_740_992
        else { return nil }
        return Int(value)
    }

    public var int64Value: Int64? {
        guard case let .number(value) = self,
              value.rounded() == value,
              value.magnitude <= 9_007_199_254_740_992
        else { return nil }
        return Int64(value)
    }

    public var doubleValue: Double? {
        if case let .number(value) = self { return value }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    public subscript(index: Int) -> JSONValue? {
        guard let values = arrayValue, values.indices.contains(index) else { return nil }
        return values[index]
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public static func int(_ value: Int) -> JSONValue {
        .number(Double(value))
    }

    public var compactDescription: String {
        guard let data = try? JSONEncoder().encode(self) else { return "<unencodable>" }
        return String(bytes: data, encoding: .utf8) ?? "<unencodable>"
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "not a JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }
}
