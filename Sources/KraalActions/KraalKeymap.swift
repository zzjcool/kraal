// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// keys.json is a two-level map: section -> key -> action. This file only
// parses and validates it; the window decides which sections apply and turns
// an NSEvent into the same normalized combo.

import Foundation

public enum KraalKeyModifier: String, CaseIterable, Sendable {
    case command = "cmd"
    case control = "ctrl"
    case option = "alt"
    case shift
}

public struct KraalKeyCombo: Hashable, Sendable, CustomStringConvertible {
    public let modifiers: Set<KraalKeyModifier>
    /// Lowercased base key: shifted punctuation is normalized to the physical
    /// key and the shift flag is added, so `cmd-+` and `cmd-shift-=` agree.
    public let key: String

    public init(modifiers: Set<KraalKeyModifier>, key: String) {
        self.modifiers = modifiers
        self.key = key
    }

    public init(_ text: String) throws {
        var rest = text.lowercased()
        var modifiers: Set<KraalKeyModifier> = []
        // `ctrl--` is a valid binding (zoom out): consume only complete
        // modifier prefixes, then leave the remaining `-` as the key.
        while let dash = rest.firstIndex(of: "-") {
            let prefix = String(rest[rest.startIndex ..< dash])
            guard let modifier = KraalKeyModifier(rawValue: prefix) else { break }
            guard modifiers.insert(modifier).inserted else {
                throw KraalKeymapError.badKey(text, "duplicate modifier \(prefix)")
            }
            rest = String(rest[rest.index(after: dash)...])
        }
        guard !rest.isEmpty, !rest.contains(where: \.isWhitespace) else {
            throw KraalKeymapError.badKey(text, "missing key")
        }
        let normalized = Self.normalize(rest)
        self.modifiers = modifiers.union(normalized.extraModifiers)
        key = normalized.key
    }

    public var description: String {
        let order: [KraalKeyModifier] = [.command, .control, .option, .shift]
        return (order.filter(modifiers.contains).map(\.rawValue) + [key]).joined(separator: "-")
    }

    public func matches(modifiers other: Set<KraalKeyModifier>, key otherKey: String) -> Bool {
        modifiers == other && key == Self.normalize(otherKey).key
    }

    private static let shifted: [Character: Character] = [
        "~": "`", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5",
        "^": "6", "&": "7", "*": "8", "(": "9", ")": "0", "_": "-",
        "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'",
        "<": ",", ">": ".", "?": "/",
    ]

    static func normalize(_ text: String) -> (key: String, extraModifiers: Set<KraalKeyModifier>) {
        guard text.count == 1, let character = text.first, let base = shifted[character] else {
            return (text, [])
        }
        return (String(base), [.shift])
    }
}

public struct KraalKeyBinding: Sendable, Equatable {
    public let section: String
    public let keys: String
    public let combo: KraalKeyCombo
    public let action: String

    public init(section: String, keys: String, combo: KraalKeyCombo, action: String) {
        self.section = section
        self.keys = keys
        self.combo = combo
        self.action = action
    }
}

public enum KraalKeymapError: Error, CustomStringConvertible {
    case notAnObject
    case badSection(String)
    case badKey(String, String)
    case badAction(String, String)
    case reserved(String)

    public var description: String {
        switch self {
        case .notAnObject:
            "keys.json must be an object of sections"
        case let .badSection(section):
            "unknown section \(section.debugDescription): use \"global\", \"terminal\", "
                + "\"layout:<name>\" or \"mod:<name>\""
        case let .badKey(keys, why):
            "keys \(keys.debugDescription): \(why)"
        case let .badAction(keys, action):
            "keys \(keys.debugDescription): unknown action \(action.debugDescription)"
        case let .reserved(keys):
            "keys \(keys.debugDescription): \(KraalKeymap.escapeHatch) is reserved for resetting Kraal"
        }
    }
}

public enum KraalKeymap {
    /// The official escape hatch; it is never allowed as a user binding.
    public static let escapeHatch = "ctrl-alt-shift-escape"

    /// The macOS defaults shipped by herdr-app. They are written once when the
    /// user's file is missing, exactly like the official app does.
    public static let defaultMacOS = """
    {
      "global": {
        "cmd-q": "app.quit",
        "cmd-h": "app.hide",
        "cmd-alt-h": "app.hide_others",
        "cmd-t": "tab.new",
        "cmd-w": "tab.close",
        "ctrl-tab": "tab.next",
        "ctrl-shift-tab": "tab.prev",
        "cmd-shift-]": "tab.next",
        "cmd-shift-[": "tab.prev",
        "cmd-alt-]": "space.next",
        "cmd-alt-[": "space.prev",
        "cmd-]": "agent.next",
        "cmd-[": "agent.prev",
        "cmd-n": "space.new",
        "cmd-shift-p": "app.palette",
        "cmd-d": "pane.split:right",
        "cmd-shift-d": "pane.split:down",
        "cmd-shift-w": "pane.close",
        "cmd-shift-enter": "pane.zoom",
        "cmd-alt-left": "pane.go:left",
        "cmd-alt-right": "pane.go:right",
        "cmd-alt-up": "pane.go:up",
        "cmd-alt-down": "pane.go:down",
        "cmd-alt-shift-left": "pane.swap:left",
        "cmd-alt-shift-right": "pane.swap:right",
        "cmd-alt-shift-up": "pane.swap:up",
        "cmd-alt-shift-down": "pane.swap:down",
        "f2": "tab.rename",
        "shift-f2": "space.rename",
        "cmd-/": "app.help",
        "cmd-shift-/": "app.help",
        "cmd-=": "app.zoom_in",
        "cmd-+": "app.zoom_in",
        "cmd--": "app.zoom_out",
        "cmd-0": "app.zoom_reset",
        "cmd-1": "tab.select:1",
        "cmd-2": "tab.select:2",
        "cmd-3": "tab.select:3",
        "cmd-4": "tab.select:4",
        "cmd-5": "tab.select:5",
        "cmd-6": "tab.select:6",
        "cmd-7": "tab.select:7",
        "cmd-8": "tab.select:8",
        "cmd-9": "tab.select:9",
        "ctrl-1": "space.select:1",
        "ctrl-2": "space.select:2",
        "ctrl-3": "space.select:3",
        "ctrl-4": "space.select:4",
        "ctrl-5": "space.select:5",
        "ctrl-6": "space.select:6",
        "ctrl-7": "space.select:7",
        "ctrl-8": "space.select:8",
        "ctrl-9": "space.select:9"
      },
      "terminal": {
        "cmd-c": "terminal.copy",
        "cmd-v": "terminal.paste",
        "ctrl-v": "terminal.paste_image",
        "alt-left": "send:\\u001bb",
        "alt-right": "send:\\u001bf",
        "alt-backspace": "send:\\u0017",
        "cmd-left": "send:\\u0001",
        "cmd-right": "send:\\u0005",
        "cmd-backspace": "send:\\u0015"
      }
    }
    """

    public static func parse(_ text: String) throws -> [KraalKeyBinding] {
        guard let data = text.data(using: .utf8) else { throw KraalKeymapError.notAnObject }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw KraalKeymapError.notAnObject
        }
        guard let sections = object as? [String: [String: String]] else {
            throw KraalKeymapError.notAnObject
        }
        // Deterministic output: section order does not decide precedence (the
        // window does), but help must not jump around between launches.
        var bindings: [KraalKeyBinding] = []
        for section in sections.keys.sorted() {
            try validate(section: section)
            for keys in sections[section, default: [:]].keys.sorted() {
                let rawAction = sections[section]?[keys] ?? ""
                let action = current(rawAction)
                if action == escapeHatch || keys == escapeHatch {
                    throw KraalKeymapError.reserved(keys)
                }
                try validate(action: action, keys: keys)
                bindings.append(KraalKeyBinding(
                    section: section,
                    keys: keys,
                    combo: try KraalKeyCombo(keys),
                    action: action
                ))
            }
        }
        return bindings
    }

    public static func load(path: URL) throws -> [KraalKeyBinding] {
        if !FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try defaultMacOS.write(to: path, atomically: true, encoding: .utf8)
        }
        return try parse(try String(contentsOf: path, encoding: .utf8))
    }

    /// 0.1.x names, kept working for an installed keys.json.
    static func current(_ action: String) -> String {
        if action == "mod.open:start" { return "tab.new" }
        let name = action.split(separator: ":", maxSplits: 1).first.map(String.init) ?? action
        guard KraalActions.find(name) == nil else { return action }
        for (old, new) in [("project.", "space."), ("context.", "tab.")] {
            guard let rest = action.dropFirst(old.count) as Substring? else { continue }
            let renamed = new + rest
            let renamedName = renamed.split(separator: ":", maxSplits: 1).first.map(String.init) ?? renamed
            if action.hasPrefix(old), KraalActions.find(renamedName) != nil {
                return renamed
            }
        }
        return action
    }

    private static func validate(section: String) throws {
        if section == "global" || section == "terminal" { return }
        if section.hasPrefix("layout:") || section.hasPrefix("mod:") {
            let name = section.dropFirst(section.hasPrefix("layout:") ? 7 : 4)
            if !name.isEmpty { return }
        }
        throw KraalKeymapError.badSection(section)
    }

    private static func validate(action: String, keys: String) throws {
        if action.hasPrefix("send:") || action == "terminal" { return }
        let name = action.split(separator: ":", maxSplits: 1).first.map(String.init) ?? action
        if KraalActions.find(name) != nil { return }
        // A mod command is syntactically valid even though Kraal has no mods;
        // the window filters it out of the runnable set.
        if name.contains("."), !name.hasPrefix("."), !name.hasSuffix(".") { return }
        throw KraalKeymapError.badAction(keys, action)
    }
}
