// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  KeybindingProfile.swift
//  Kraal
//
//  Reads the daemon's `server_keybindings_toml` (snapshot field
//  `server_keybindings_toml`) so the shortcut help can show the bindings the
//  daemon actually honours instead of a hand-written table.
//
//  The field is produced by upstream's `local_keybindings_profile_toml`
//  (`config.rs:178-189`): it serialises the **effective** keymap, defaults already
//  merged, custom `[[keys.command]]` entries stripped. Its shape is therefore
//  narrow — a `[keys]` table of `name = "combo"` plus a few array-valued keys such
//  as `prefix = ["ctrl+a", "alt+a"]`:
//
//      [keys]
//      prefix = ["ctrl+a"]
//      new_tab = "prefix+t"
//      next_tab = "prefix+n"
//
//  That narrowness is why this parses by hand rather than pulling in a TOML
//  reader: adding a dependency to read one table of strings, in a document the
//  daemon generates itself, is a poor trade. The parser is deliberately strict
//  about what it *ignores* (anything that is not `name = "value"` under `[keys]`)
//  so an upstream change adds unknown keys rather than breaking the panel.
//
//  What this is not: a validation pass. If the daemon sent a profile it already
//  parsed it successfully; anything unparseable here means this client and the
//  daemon disagree, and the right response is to fall back to the built-in table
//  rather than to explain TOML to the user.
//

import Foundation

public enum KeybindingProfile {
    /// One `name = "combo"` entry from the `[keys]` table.
    public struct Entry: Equatable, Sendable {
        /// The daemon's key name, e.g. `new_tab`.
        public var name: String
        /// The binding as the daemon's own help renders it, e.g. `prefix+t`.
        public var binding: String

        public init(name: String, binding: String) {
            self.name = name
            self.binding = binding
        }
    }

    /// Every scalar binding in the `[keys]` table, in document order.
    ///
    /// Array-valued keys (`prefix = ["ctrl+a", "alt+a"]`) are flattened into one
    /// entry per element under the same name joined with `/`, because that is how
    /// they are read on screen: a user pressing "the prefix" does not care that
    /// there are two of them.
    ///
    /// Returns an empty array for `nil`, an empty string, or a document with no
    /// `[keys]` table — all of which mean "the daemon has nothing to say", not
    /// "the user has no bindings".
    public static func entries(in toml: String?) -> [Entry] {
        guard let toml, !toml.isEmpty else { return [] }
        var entries: [Entry] = []
        var inKeys = false

        for rawLine in toml.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Comments and blanks carry nothing.
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            // Any table header ends the `[keys]` region: `[keys]` is the only one
            // with scalar bindings, and staying "in" past a later header would
            // read e.g. `[[keys.command]]` fields as bindings — which is exactly
            // the custom-command noise the daemon already stripped.
            if line.hasPrefix("[") {
                inKeys = line == "[keys]"
                continue
            }
            guard inKeys else { continue }
            guard let equals = line.firstIndex(of: "=") else { continue }

            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            let rawValue = line[line.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !rawValue.isEmpty else { continue }

            if let binding = scalar(rawValue) {
                entries.append(Entry(name: name, binding: binding))
            } else if let list = stringArray(rawValue), !list.isEmpty {
                // One row per name, so the help panel can still be keyed by name.
                entries.append(Entry(name: name, binding: list.joined(separator: " / ")))
            }
            // Anything else (numbers, nested inline tables) is not a binding and
            // is skipped rather than guessed at.
        }
        return entries
    }

    /// The binding for `name`, or `nil` when the daemon does not mention it.
    ///
    /// Used to overlay the built-in table: a binding the daemon did not include
    /// keeps its built-in label instead of going blank, so a partially-populated
    /// profile cannot make the panel look broken.
    public static func binding(for name: String, in toml: String?) -> String? {
        entries(in: toml).first { $0.name == name }?.binding
    }

    // MARK: - Value parsing

    /// A double-quoted TOML string on one line.
    private static func scalar(_ value: String) -> String? {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return nil }
        let inner = value.dropFirst().dropLast()
        // A line with an unescaped quote inside is not a single scalar; leaving it
        // alone beats mangling it.
        guard !inner.contains("\"") else { return nil }
        let unescaped = inner.replacingOccurrences(of: "\\\"", with: "\"")
        return unescaped.isEmpty ? nil : unescaped
    }

    /// An inline array of double-quoted TOML strings, possibly spanning lines.
    private static func stringArray(_ value: String) -> [String]? {
        guard value.hasPrefix("["), value.hasSuffix("]") else { return nil }
        let inner = value.dropFirst().dropLast()
        var items: [String] = []
        var current = ""
        var insideString = false
        var escaped = false

        for character in inner {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\" where insideString:
                escaped = true
            case "\"":
                if insideString {
                    items.append(current)
                    current = ""
                }
                insideString.toggle()
            case "," where !insideString:
                continue
            default:
                if insideString { current.append(character) }
            }
        }
        // An unterminated string means the line was truncated; reporting the
        // partial value as a binding would show half a combo, which is worse than
        // showing the built-in one.
        guard !insideString else { return nil }
        return items.filter { !$0.isEmpty }
    }
}
