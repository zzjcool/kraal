// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// A terminal as the core describes it, kept as the record plus typed readers.
//
// The record's schema only grows, so the wire value stays authoritative and
// patches edit it in place. Typed accessors are for the UI; `Equatable` compares
// the record, which is what "did this terminal change" means for a view.

import Foundation

public struct HcForeground: Sendable, Equatable {
    public let pid: Int?
    public let name: String
    public let argv: [String]
    public let cwd: String

    public init(json: JSONValue) {
        pid = json["pid"]?.intValue
        name = json["name"]?.stringValue ?? ""
        argv = json["argv"]?.arrayValue?.compactMap(\.stringValue) ?? []
        cwd = json["cwd"]?.stringValue ?? ""
    }
}

public struct HcTerminal: Identifiable, Sendable, Equatable {
    public let address: String
    /// The whole record, including fields this client does not know yet.
    public private(set) var raw: JSONValue

    public var id: String { address }

    public init(json: JSONValue) {
        raw = json
        address = json["address"]?.stringValue ?? ""
    }

    public var name: String {
        let value = raw["name"]?.stringValue ?? ""
        return value.isEmpty ? address : value
    }

    public var template: String? { raw["template"]?.stringValue }
    /// `live` or `finished`. A `lost` kept terminal stays `live`.
    public var state: String { raw["state"]?.stringValue ?? "unknown" }
    public var isLive: Bool { state == "live" }
    public var argv: [String] { raw["argv"]?.arrayValue?.compactMap(\.stringValue) ?? [] }
    public var cwd: String { raw["cwd"]?.stringValue ?? "" }
    public var cols: Int { raw["cols"]?.intValue ?? 0 }
    public var rows: Int { raw["rows"]?.intValue ?? 0 }
    public var pid: Int? { raw["pid"]?.intValue }
    public var parent: String? { raw["parent"]?.stringValue }
    public var keep: Bool { raw["keep"]?.boolValue ?? false }
    public var title: String { raw["title"]?.stringValue ?? "" }
    public var turn: Int { raw["turn"]?.intValue ?? 0 }
    public var status: JSONValue? { raw["status"] }
    public var statusRecords: [String: JSONValue] { raw["records"]?.objectValue ?? [:] }
    public var reported: Bool { raw["reported"]?.boolValue ?? false }
    public var reason: String? { raw["reason"]?.stringValue }
    public var exitCode: Int? { raw["exit_code"]?.intValue }
    public var signal: Int? { raw["signal"]?.intValue }
    public var finishedMilliseconds: Int64? { raw["finished_ms"]?.int64Value }
    public var createdMilliseconds: Int64? { raw["created_ms"]?.int64Value }
    public var statusMilliseconds: Int64? { raw["status_ms"]?.int64Value }

    public var labels: [String: String] {
        (raw["labels"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
    }

    public var foreground: HcForeground? {
        guard let value = raw["foreground"], !value.isNull else { return nil }
        return HcForeground(json: value)
    }

    /// The agent word in `status` (`working`, `idle`, …), when the program reports one.
    public var agentState: String? { status?["state"]?.stringValue }

    /// What to show as the running program: the foreground name, else the template.
    public var agent: String {
        foreground?.name ?? template ?? ""
    }

    /// The machine part of `rohan/t7`, or nil for this core.
    public var machine: String? {
        address.split(separator: "/", maxSplits: 1).count == 2
            ? String(address.split(separator: "/", maxSplits: 1)[0])
            : nil
    }

    /// One fact change, per `schema/README.md`.
    ///
    /// Unknown types are ignored: the protocol only grows.
    public mutating func apply(type: String, data: JSONValue) {
        switch type {
        case "lost":
            set("reason", data["reason"])
            set("exit_code", data["exit_code"])
            set("signal", data["signal"])
            set("finished_ms", data["finished_ms"])
            set("pid", .null)
            set("foreground", .null)
        case "finished":
            set("state", .string("finished"))
            set("reason", data["reason"])
            set("exit_code", data["exit_code"])
            set("signal", data["signal"])
            set("finished_ms", data["finished_ms"])
            set("foreground", .null)
        case "keep":
            set("keep", data["keep"] ?? .bool(false))
        case "status":
            set("status", data["status"] ?? .null)
            set("records", data["records"] ?? .object([:]))
            set("reported", data["reported"] ?? .bool(false))
        case "turn":
            set("turn", data["turn"] ?? .int(0))
        case "title":
            set("title", data["title"] ?? .string(""))
        case "labels":
            set("labels", data["labels"] ?? .object([:]))
        case "size":
            set("cols", data["cols"])
            set("rows", data["rows"])
        case "foreground":
            set("foreground", data.isNull ? .null : data)
        default:
            break
        }
    }

    /// A labels event may carry the whole record for a terminal that newly
    /// matches a label filter; adopting it is how it appears without a refetch.
    public mutating func adopt(record: JSONValue) {
        let adopted = HcTerminal(json: record)
        guard adopted.address == address else { return }
        raw = record
    }

    private mutating func set(_ key: String, _ value: JSONValue?) {
        var object = raw.objectValue ?? [:]
        if let value {
            object[key] = value
        } else {
            object[key] = .null
        }
        raw = .object(object)
    }
}

extension HcTerminal {
    /// Deterministic sidebar order: this core's terminals first, then machines,
    /// each by their `tN` number rather than by string.
    public static func ordered(_ lhs: HcTerminal, _ rhs: HcTerminal) -> Bool {
        let left = HcAddress(lhs.address)
        let right = HcAddress(rhs.address)
        if left.machine != right.machine {
            guard let leftMachine = left.machine else { return true }
            guard let rightMachine = right.machine else { return false }
            return leftMachine < rightMachine
        }
        return left.number < right.number
    }
}

struct HcAddress {
    let machine: String?
    let number: Int
    let text: String

    init(_ address: String) {
        text = address
        let parts = address.split(separator: "/", maxSplits: 1)
        if parts.count == 2 {
            machine = String(parts[0])
            number = HcAddress.parseNumber(String(parts[1]))
        } else {
            machine = nil
            number = HcAddress.parseNumber(address)
        }
    }

    private static func parseNumber(_ value: String) -> Int {
        Int(value.drop { $0 == "t" || $0 == "T" }) ?? Int.max
    }
}
