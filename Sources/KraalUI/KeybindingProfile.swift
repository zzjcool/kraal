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

        // Statements, not lines.
        //
        // TOML lets a value span lines, and an array-valued binding is the case
        // that actually happens here — `prefix = [\n"ctrl+a",\n"alt+a"\n]` is
        // legal and a human editing the config will produce it. Splitting on
        // newlines first meant such a binding was dropped entirely: the `[` line
        // has no closing `]`, the parser skipped it, and every continuation line
        // had no `=`. The key silently vanished from the panel, which reads as
        // "my config was ignored".
        //
        // Continuation is therefore tracked here: while a value's brackets are
        // unbalanced, keep appending lines to it.
        var pendingName: String?
        var pendingValue = ""
        var bracketDepth = 0

        func flush() {
            defer {
                pendingName = nil
                pendingValue = ""
                bracketDepth = 0
            }
            guard let name = pendingName, !pendingValue.isEmpty else { return }
            // An unbalanced value is a truncated document: emitting nothing for it
            // is the only non-guess, and the bindings read *before* it are already
            // in `entries` so they survive. Reported rather than silent so the
            // panel can fall back instead of showing a half-read combo.
            guard bracketDepth <= 0 else { return }
            let rawValue = pendingValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let binding = scalar(rawValue) {
                entries.append(Entry(name: name, binding: binding))
            } else if let list = stringArray(rawValue), !list.isEmpty {
                // One row per name, so the help panel can still be keyed by name.
                entries.append(Entry(name: name, binding: list.joined(separator: " / ")))
            }
            // Anything else (numbers, nested inline tables) is not a binding and
            // is skipped rather than guessed at.
        }

        for rawLine in toml.split(whereSeparator: \.isNewline) {
            // Comment first, then trim: `[keys]  # the keys table` has to read as
            // the header, and `new_tab = "prefix+t"  # note` as one binding.
            let line = Self.stripComment(rawLine.trimmingCharacters(in: .whitespaces))
                .trimmingCharacters(in: .whitespaces)
            // Comments and blanks carry nothing.
            guard !line.isEmpty else { continue }

            if bracketDepth > 0, pendingName != nil {
                // Inside a multi-line value: the text is part of it, brackets and
                // all, until they balance.
                pendingValue += line
                bracketDepth += bracketDelta(line)
                if bracketDepth <= 0 { flush() }
                continue
            }

            // Any table header ends the `[keys]` region: `[keys]` is the only one
            // with scalar bindings, and staying "in" past a later header would
            // read e.g. `[[keys.command]]` fields as bindings — which is exactly
            // the custom-command noise the daemon already stripped.
            if line.hasPrefix("[") {
                flush()
                // `[keys]` only, not `[[keys.command]]`. Inner whitespace is
                // stripped because `[ keys ]` is legal TOML (`std-table-open =
                // %x5B ws`), and treating it as "some other table" silently
                // zeroed the whole panel.
                let header = line.replacingOccurrences(of: " ", with: "")
                inKeys = header == "[keys]"
                continue
            }
            guard inKeys else { continue }
            guard let equals = line.firstIndex(of: "=") else { continue }

            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            let rawValue = line[line.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !rawValue.isEmpty else { continue }

            pendingName = name
            pendingValue = rawValue
            bracketDepth = bracketDelta(rawValue)
            if bracketDepth <= 0 { flush() }
        }
        // A file that ends mid-array: flush what was read rather than dropping it,
        // so a truncated config still contributes the bindings it did have.
        flush()
        return entries
    }

    /// The text before an unquoted `#`.
    ///
    /// TOML comments run to end of line and are legal after a value, so
    /// `new_tab = "prefix+t"  # see [docs` is a comment, not an unterminated
    /// array. Without this, three separate things went wrong in the same way —
    /// silently dropping bindings, which the user reads as "my config was
    /// ignored":
    ///
    /// - a `[` inside the comment made `bracketDelta` report depth 1, so the
    ///   parser treated **every following line** as a continuation and the whole
    ///   `[keys]` table vanished;
    /// - any trailing comment on an array value made it fail `hasSuffix("]")`
    ///   and the binding was dropped;
    /// - `[keys]  # the keys table` failed the exact-match header test, so the
    ///   table was never entered at all.
    ///
    /// String-aware on purpose: a `#` inside a quoted value is not a comment.
    /// `split(separator: "#")` would be a new way to lose data, and the same
    /// mistake this whole file is here to avoid.
    static func stripComment(_ line: String) -> String {
        var result = ""
        var insideString = false
        var escaped = false
        for character in line {
            if escaped {
                result.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\" where insideString:
                result.append(character)
                escaped = true
            case "\"":
                insideString.toggle()
                result.append(character)
            case "#" where !insideString:
                // Everything after an unquoted `#` is a comment.
                return result.trimmingCharacters(in: .whitespaces)
            default:
                result.append(character)
            }
        }
        // Trimmed on both exits: the `#` branch below returns a trimmed string,
        // and having the fall-through not trim meant every caller had to remember
        // to. There is one caller today; a second one would have inherited the
        // inconsistency silently.
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Net `[` minus `]` outside quoted strings.
    ///
    /// Counting outside strings matters: a keybinding can legitimately be the
    /// literal `[` (`split_vertical = "prefix+["`), and counting it would make
    /// the parser wait for a closing bracket that never comes.
    private static func bracketDelta(_ text: String) -> Int {
        var depth = 0
        var insideString = false
        var escaped = false
        for character in text {
            if escaped {
                escaped = false
                continue
            }
            switch character {
            case "\\" where insideString:
                escaped = true
            case "\"":
                insideString.toggle()
            case "[" where !insideString:
                depth += 1
            case "]" where !insideString:
                depth -= 1
            default:
                break
            }
        }
        return depth
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

    /// A double-quoted TOML string.
    ///
    /// Escapes are resolved rather than rejected. The first version refused any
    /// value containing an inner quote, which threw away the entirely legal
    /// `key = "a\"b"` and — worse — turned a *correct* config into a missing row,
    /// which the user reads as "my setting was ignored".
    ///
    /// Only the basic TOML escapes are handled (`\\`, `\"`, `\n`, `\t`). A keybinding
    /// is a short combo string; the unicode/hex forms exist in the spec but have
    /// no business in one, and inventing them here would be guessing.
    private static func scalar(_ value: String) -> String? {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return nil }
        var result = ""
        var escaped = false
        var sawClosingQuote = false
        for character in value.dropFirst().dropLast() {
            if escaped {
                escaped = false
                switch character {
                case "\\": result.append("\\")
                case "\"": result.append("\"")
                case "n": result.append("\n")
                case "t": result.append("\t")
                default:
                    // Unknown escape: keep both characters rather than dropping
                    // the backslash, so a binding reads the way it was written.
                    result.append("\\")
                    result.append(character)
                }
                continue
            }
            if character == "\\" {
                escaped = true
            } else if character == "\"" {
                // A quote we did not escape: this is not a single scalar, it is
                // something we do not model. Refuse rather than truncate.
                sawClosingQuote = true
            } else {
                result.append(character)
            }
        }
        guard !sawClosingQuote, !escaped else { return nil }
        // Same rule as the array case: a binding is a single line, so a decoded
        // newline means this is not a binding at all.
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isNewline) else { return nil }
        return trimmed
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
                switch character {
                case "\\": current.append("\\")
                case "\"": current.append("\"")
                case "n": current.append("\n")
                case "t": current.append("\t")
                default:
                    current.append("\\")
                    current.append(character)
                }
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
        // A combo is one line by definition. A `\n` escape decodes to a real
        // newline, which SwiftUI renders as a row of uneven height; an item that
        // is only whitespace renders as a gap. Trimming is not enough — the
        // newline in `"a\nb"` is in the *middle*, so the whole item is refused
        // rather than silently squashed into `ab`, which would show a binding
        // that does not exist.
        return items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains(where: \.isNewline) }
    }
}
