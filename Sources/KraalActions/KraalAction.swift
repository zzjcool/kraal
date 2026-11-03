// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The app action contract. This target is deliberately free of AppKit, Ghostty
// and the terminal protocol: `kraal commands` and `kraal do` must be able to
// describe and validate actions without a window, a core, or a renderer.
//
// Names, argument names and required flags follow herdr-app's `commands.rs`
// one-for-one. `about` is ours (upstream's one-liners are not part of the wire
// contract); unsupported actions carry a reason instead of being silently
// omitted.

import Foundation
import KraalHC

public struct KraalActionArgument: Sendable, Equatable, Codable {
    public let name: String
    public let required: Bool

    public init(_ name: String, required: Bool = false) {
        self.name = name
        self.required = required
    }
}

public enum KraalActionSupport: Sendable, Equatable {
    /// Kraal implements this action natively (dispatch may land in a later
    /// phase, but the action is part of the product surface).
    case native
    /// Deliberately not implemented; the string is user-facing.
    case unsupported(String)

    public var isNative: Bool {
        if case .native = self { return true }
        return false
    }
}

public struct KraalAction: Sendable, Equatable {
    public let name: String
    public let args: [KraalActionArgument]
    public let about: String
    public let support: KraalActionSupport

    public init(
        _ name: String,
        _ args: [KraalActionArgument],
        _ about: String,
        support: KraalActionSupport = .native
    ) {
        self.name = name
        self.args = args
        self.about = about
        self.support = support
    }

    public var isNative: Bool { support.isNative }
    public var requiredArguments: [String] { args.filter(\.required).map(\.name) }
    public var validArguments: String {
        args.isEmpty ? "none" : args.map(\.name).joined(separator: ", ")
    }
}

/// The exact JSON shape `herdr-app commands` prints: an array of
/// `{name, args:[{name, required}], about}`. There is no `--json` flag
/// upstream; the command always emits this array.
public struct KraalActionListing: Sendable, Equatable, Codable {
    public let name: String
    public let args: [KraalActionArgument]
    public let about: String

    public init(_ action: KraalAction) {
        name = action.name
        args = action.args
        about = action.about
    }
}

public enum KraalActionError: Error, Equatable, Sendable, CustomStringConvertible {
    case unknownAction(String)
    case argumentsNotObject(String, valid: String)
    case unknownArguments(String, unknown: [String], valid: String)
    case invalidTarget(String, String)
    case missing(String, String)
    case invalidValue(String)

    public var description: String {
        switch self {
        case let .unknownAction(name):
            return "unknown command \"\(name)\": see `kraal commands`"
        case let .argumentsNotObject(name, valid):
            return "\(name): arguments must be an object; valid arguments: \(valid)"
        case let .unknownArguments(name, unknown, valid):
            return "\(name): unknown argument(s): \(unknown.joined(separator: ", ")); valid arguments: \(valid)"
        case let .invalidTarget(name, key):
            return "\(name): argument \(key) must be a string (or null to omit it)"
        case let .missing(name, key):
            return "\(name) needs \(key)"
        case let .invalidValue(message):
            return message
        }
    }
}

extension KraalAction {
    /// Upstream validates unknown arguments first, then `id|pane|space|terminal`
    /// types, then required arguments. Values that only the dispatch layer
    /// understands (`argv`, `props`, `layout`, ...) are intentionally not
    /// type-checked here, matching upstream's silent fallbacks.
    public func validate(_ arguments: JSONValue?) throws -> [String: JSONValue] {
        let values: [String: JSONValue]
        switch arguments {
        case nil, .null:
            values = [:]
        case let .object(object):
            values = object
        default:
            throw KraalActionError.argumentsNotObject(name, valid: validArguments)
        }

        let declared = Set(args.map(\.name))
        let unknown = values.keys.filter { !declared.contains($0) }.sorted()
        if !unknown.isEmpty {
            throw KraalActionError.unknownArguments(name, unknown: unknown, valid: validArguments)
        }

        for key in ["id", "pane", "space", "terminal"] {
            guard let value = values[key], !value.isNull else { continue }
            guard case .string = value else {
                throw KraalActionError.invalidTarget(name, key)
            }
        }

        // `move` reports both required pieces as one message upstream.
        if name == "space.move" || name == "tab.move" {
            guard isPresent(values["id"]), isPresent(values["index"]),
                  values["index"]?.intValue != nil
            else {
                throw KraalActionError.invalidValue("\(name) needs id and index")
            }
        }

        for argument in args where argument.required {
            guard isPresent(values[argument.name]) else {
                throw KraalActionError.missing(name, argument.name)
            }
        }

        try validateSpecific(values)
        return values
    }

    private func isPresent(_ value: JSONValue?) -> Bool {
        guard let value else { return false }
        switch value {
        case .null:
            return false
        case let .string(text):
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return true
        }
    }

    private func string(_ values: [String: JSONValue], _ key: String) -> String? {
        values[key]?.stringValue
    }

    private func validateSpecific(_ values: [String: JSONValue]) throws {
        switch name {
        case "pane.split":
            if let direction = string(values, "direction"), !["right", "down"].contains(direction) {
                throw KraalActionError.invalidValue(
                    "pane.split direction is \"right\" or \"down\", not \"\(direction)\""
                )
            }
        case "pane.go", "pane.swap":
            if let direction = string(values, "direction"),
               !["left", "right", "up", "down"].contains(direction) {
                throw KraalActionError.invalidValue(
                    "\(name) direction is left, right, up or down, not \"\(direction)\""
                )
            }
        case "terminal.right_click":
            if let target = string(values, "to"), !["program", "menu"].contains(target) {
                throw KraalActionError.invalidValue(
                    "terminal.right_click to is \"program\" or \"menu\", not \"\(target)\""
                )
            }
        case "terminal.pin":
            if let pinned = values["pinned"], pinned.boolValue == nil {
                throw KraalActionError.invalidValue("terminal.pin pinned is true or false")
            }
        case "app.feedback":
            if let from = string(values, "from"), !["person", "agent"].contains(from) {
                throw KraalActionError.invalidValue("from must be person or agent")
            }
        default:
            break
        }
    }
}

public enum KraalActions {
    public static func find(_ name: String) -> KraalAction? {
        all.first { $0.name == name }
    }

    public static func validate(name: String, arguments: JSONValue?) throws -> [String: JSONValue] {
        guard let action = find(name) else {
            throw KraalActionError.unknownAction(name)
        }
        return try action.validate(arguments)
    }

    /// What `herdr-app commands` prints: every action, in source order, with
    /// upstream's `{name, args, about}` shape. Unsupported actions stay in the
    /// list too, so a script sees the same names; `do` reports the reason.
    public static var listing: [KraalActionListing] {
        all.map(KraalActionListing.init)
    }

    public static func listingJSON(pretty: Bool = true) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted] : []
        let data = try encoder.encode(listing)
        return String(bytes: data, encoding: .utf8) ?? "[]"
    }

    public static var unsupported: [KraalAction] {
        all.filter { !$0.isNative }
    }
}
