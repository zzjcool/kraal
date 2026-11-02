// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Event stream values: a snapshot, one fact change, and one line of the channel.
//
// In framed mode `events.subscribe` returns a channel; the core writes one
// JSON-RPC notification per line on it (`event`, `heartbeat` every 15 s, and
// `missed` with a fresh snapshot for a subscriber that fell behind). Channel
// DATA frames are not line-aligned, so the decoder below is.

import Foundation

public struct HcSnapshot: Sendable, Equatable {
    public let seq: UInt64
    public let terminals: [HcTerminal]
    public let channel: UInt32?

    public init(seq: UInt64, terminals: [HcTerminal], channel: UInt32? = nil) {
        self.seq = seq
        self.terminals = terminals
        self.channel = channel
    }

    public init?(json: JSONValue) {
        guard let seq = json["seq"]?.uint64Value else { return nil }
        self.seq = seq
        terminals = (json["terminals"]?.arrayValue ?? []).map(HcTerminal.init(json:))
        channel = json["channel"]?.intValue.map(UInt32.init)
    }
}

public struct HcEvent: Sendable, Equatable {
    public let seq: UInt64
    public let type: String
    public let terminal: String?
    public let machine: String?
    public let data: JSONValue

    public init(seq: UInt64, type: String, terminal: String?, machine: String? = nil, data: JSONValue) {
        self.seq = seq
        self.type = type
        self.terminal = terminal
        self.machine = machine
        self.data = data
    }

    public init?(json: JSONValue) {
        guard let seq = json["seq"]?.uint64Value,
              let type = json["type"]?.stringValue
        else { return nil }
        self.seq = seq
        self.type = type
        terminal = json["terminal"]?.stringValue
        machine = json["machine"]?.stringValue
        data = json["data"] ?? .object([:])
    }
}

/// What one line on the event channel turned out to be.
public enum HcEventLine: Sendable, Equatable {
    case event(HcEvent)
    case heartbeat(seq: UInt64)
    case missed(HcSnapshot)
    /// A method this client does not know. The protocol only grows.
    case unknown(method: String)
    case malformed

    public init(line: Data) {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: line),
              json["jsonrpc"]?.stringValue == "2.0",
              let method = json["method"]?.stringValue
        else {
            self = .malformed
            return
        }
        let params = json["params"] ?? .object([:])
        switch method {
        case "event":
            self = HcEvent(json: params).map(HcEventLine.event) ?? .malformed
        case "heartbeat":
            self = params["seq"]?.uint64Value.map(HcEventLine.heartbeat) ?? .malformed
        case "missed":
            self = HcSnapshot(json: params).map(HcEventLine.missed) ?? .malformed
        default:
            self = .unknown(method: method)
        }
    }
}

/// Reassembles the channel's byte stream into notification lines.
public struct HcLineBuffer: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex ..< newline]
            if !line.isEmpty { lines.append(Data(line)) }
            buffer = Data(buffer[buffer.index(after: newline)...])
        }
        return lines
    }

    public var pendingByteCount: Int { buffer.count }
}

/// The filter sent with `events.subscribe`.
public struct HcEventFilter: Sendable, Equatable {
    public var terminal: String?
    public var childrenOf: String?
    public var labels: [String: String]

    public init(terminal: String? = nil, childrenOf: String? = nil, labels: [String: String] = [:]) {
        self.terminal = terminal
        self.childrenOf = childrenOf
        self.labels = labels
    }

    public var isEmpty: Bool {
        terminal == nil && childrenOf == nil && labels.isEmpty
    }

    var params: JSONValue {
        var object: [String: JSONValue] = [:]
        if let terminal { object["terminal"] = .string(terminal) }
        if let childrenOf { object["children_of"] = .string(childrenOf) }
        if !labels.isEmpty {
            object["labels"] = .object(labels.mapValues(JSONValue.string))
        }
        return .object(object)
    }

    /// The same rules the core applies to a record, for label events that can
    /// move a terminal out of the filter.
    public func matches(_ terminal: HcTerminal) -> Bool {
        if let terminalFilter = self.terminal, terminal.address != terminalFilter { return false }
        if let childrenOf, terminal.parent != childrenOf { return false }
        for (key, value) in labels where terminal.labels[key] != value { return false }
        return true
    }
}
