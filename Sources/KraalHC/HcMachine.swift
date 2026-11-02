// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// A machine this core has added, as `machine.list` / `machine.add` describe it.
//
// Machines belong to the core: it dials ssh, mirrors their terminals into the
// same `terminal.list`/events/attach stream, and reconnects on its own. The
// client only names the states and offers the two fixes that need a person:
// a login terminal (`hc machine login`) and an update terminal
// (`hc machine update`) — neither is an RPC.

import Foundation

public enum HcMachineState: Sendable, Equatable {
    case connecting
    case connected
    case needsLogin
    case needsUpdate
    case unreachable
    /// A state a newer core added; keep its word instead of lying about it.
    case other(String)

    public init(raw: String?) {
        switch raw {
        case "connecting": self = .connecting
        case "connected": self = .connected
        case "needs_login": self = .needsLogin
        case "needs_update": self = .needsUpdate
        case "unreachable": self = .unreachable
        case let other?: self = .other(other)
        case nil: self = .other("")
        }
    }

    public var rawValue: String {
        switch self {
        case .connecting: "connecting"
        case .connected: "connected"
        case .needsLogin: "needs_login"
        case .needsUpdate: "needs_update"
        case .unreachable: "unreachable"
        case let .other(raw): raw
        }
    }

    /// The word a person can act on; the raw state stays in the record.
    public var label: String {
        switch self {
        case .connecting: "connecting"
        case .connected: "connected"
        case .needsLogin: "needs login"
        case .needsUpdate: "needs update"
        case .unreachable: "unreachable"
        case let .other(raw): raw.isEmpty ? "unknown" : raw
        }
    }

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

public struct HcMachine: Identifiable, Sendable, Equatable {
    /// The whole record: `machine.add` omits `state`/`why`, `machine.list` has them.
    public let raw: JSONValue

    public init(json: JSONValue) {
        raw = json
    }

    public var name: String { raw["name"]?.stringValue ?? "" }
    public var target: String { raw["target"]?.stringValue ?? "" }
    public var host: String { raw["host"]?.stringValue ?? "" }
    public var version: String { raw["version"]?.stringValue ?? "" }
    public var session: String? { raw["session"]?.stringValue }
    public var temporary: Bool { raw["temporary"]?.boolValue ?? false }
    public var via: Bool { raw["via"]?.boolValue ?? false }
    public var state: HcMachineState { HcMachineState(raw: raw["state"]?.stringValue) }
    public var why: String? {
        guard let why = raw["why"]?.stringValue, !why.isEmpty else { return nil }
        return why
    }

    public var sinceMilliseconds: UInt64? { raw["since_ms"]?.uint64Value }

    public var id: String { name }

    /// The prefix its terminals carry: `rohan` → `rohan/t7`.
    public var addressPrefix: String { name }
}
