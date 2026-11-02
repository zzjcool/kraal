// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// JSON-RPC 2.0 as herdr-core speaks it.
//
// Plain mode is one JSON object per line. `hello {framed: true}` switches to
// frames afterwards, where channel 0 carries the same messages without the
// newline. Calls run concurrently, so replies are matched by id.

import Foundation

public struct HcRPCError: Error, Sendable, Equatable, CustomStringConvertible {
    public let code: Int
    public let message: String
    /// Stable machine-readable kind (`not_found`, `conflict`, `needs_update`,
    /// `needs_login`, `needs_framed`, `unavailable`, …).
    public let kind: String?
    public let hint: String?
    public let data: JSONValue?

    public init(code: Int, message: String, kind: String? = nil, hint: String? = nil, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.kind = kind
        self.hint = hint
        self.data = data
    }

    public init(json: JSONValue) {
        code = json["code"]?.intValue ?? -32_000
        message = json["message"]?.stringValue ?? "core call failed"
        let payload = json["data"]
        kind = payload?["kind"]?.stringValue
        hint = payload?["hint"]?.stringValue
        data = payload
    }

    public var description: String {
        var text = message
        if let hint, !hint.isEmpty { text += " (\(hint))" }
        if let kind { text += " [\(kind)]" }
        return text
    }
}

public enum HcRPCIncoming: Sendable, Equatable {
    case response(id: Int64, result: JSONValue)
    /// `id` is nil for a parse/validation error the core could not attribute.
    case failure(id: Int64?, error: HcRPCError)
    case notification(method: String, params: JSONValue)
    case request(id: Int64?, method: String, params: JSONValue)
}

public enum HcRPCErrorKind {
    public static let notFound = "not_found"
    public static let conflict = "conflict"
    public static let needsUpdate = "needs_update"
    public static let needsLogin = "needs_login"
    public static let needsFramed = "needs_framed"
    public static let unavailable = "unavailable"
    public static let unsupportedGeneration = "unsupported_generation"
    public static let live = "live"
    public static let usage = "usage"
}

public enum HcRPC {
    /// One JSON-RPC message, without a newline (framed channel 0).
    public static func requestJSON(id: Int64, method: String, params: JSONValue) throws -> Data {
        let message = JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .int(Int(id)),
            "method": .string(method),
            "params": params,
        ])
        return try JSONEncoder().encode(message)
    }

    /// One JSON-RPC message plus the newline plain mode uses.
    public static func requestLine(id: Int64, method: String, params: JSONValue) throws -> Data {
        var data = try requestJSON(id: id, method: method, params: params)
        data.append(0x0A)
        return data
    }

    public static func decode(_ data: Data) throws -> HcRPCIncoming {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw HcConnectionError.protocolViolation("not JSON: \(error)")
        }
        guard let object = value.objectValue else {
            throw HcConnectionError.protocolViolation("JSON-RPC message is not an object")
        }
        guard object["jsonrpc"]?.stringValue == "2.0" else {
            throw HcConnectionError.protocolViolation("missing jsonrpc 2.0")
        }

        if let method = object["method"]?.stringValue {
            let id = object["id"]?.int64Value
            let params = object["params"] ?? .null
            if let id {
                return .request(id: id, method: method, params: params)
            }
            return .notification(method: method, params: params)
        }

        if let id = object["id"]?.int64Value {
            if let error = object["error"] {
                return .failure(id: id, error: HcRPCError(json: error))
            }
            return .response(id: id, result: object["result"] ?? .null)
        }

        if let error = object["error"] {
            return .failure(id: nil, error: HcRPCError(json: error))
        }
        throw HcConnectionError.protocolViolation("reply has neither result nor error")
    }
}
