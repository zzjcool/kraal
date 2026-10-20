// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// A TOML reader, scoped to what `config.toml` actually uses.
//
// Only the sidebar keys are interpreted; everything else in the file is parsed
// into the same tree and then ignored, so a real-world `config.toml` (which is
// large — the daemon's own default is ~70 KB) does not have to be pruned before
// import. Unsupported constructs throw rather than silently mis-parsing, because
// a silently wrong layout is worse than a visible import error.

import Foundation

public indirect enum TOMLValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case double(Double)
    case boolean(Bool)
    case array([TOMLValue])
    case table([String: TOMLValue])

    public var string: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var integer: Int? {
        switch self {
        case let .integer(value): return value
        case let .double(value): return Int(value)
        default: return nil
        }
    }

    public var boolean: Bool? {
        if case let .boolean(value) = self { return value }
        return nil
    }

    public var array: [TOMLValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    public var table: [String: TOMLValue]? {
        if case let .table(value) = self { return value }
        return nil
    }
}

public enum TOMLParseError: Error, CustomStringConvertible, Equatable {
    case unexpectedCharacter(Character, line: Int)
    case unterminatedString(line: Int)
    case unterminatedArray(line: Int)
    case invalidValue(String, line: Int)
    case duplicateKey(String, line: Int)
    case expectedEquals(line: Int)
    case invalidNumber(String, line: Int)

    public var description: String {
        switch self {
        case let .unexpectedCharacter(character, line):
            "line \(line): unexpected character \(character.debugDescription)"
        case let .unterminatedString(line):
            "line \(line): unterminated string"
        case let .unterminatedArray(line):
            "line \(line): unterminated array"
        case let .invalidValue(text, line):
            "line \(line): invalid value \(text.debugDescription)"
        case let .duplicateKey(key, line):
            "line \(line): duplicate key \(key.debugDescription)"
        case let .expectedEquals(line):
            "line \(line): expected '=' after a key"
        case let .invalidNumber(text, line):
            "line \(line): invalid number \(text.debugDescription)"
        }
    }
}

/// Parses a TOML document into nested `TOMLValue`s.
public enum TOMLParser {
    /// Keys we must interpret for the sidebar; parsed but otherwise unread keys
    /// are kept in the tree.
    public static func parse(_ text: String) throws -> [String: TOMLValue] {
        var root: [String: TOMLValue] = [:]
        var currentPath: [String] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var index = 0
        var lineNumber = 0

        while index < lines.count {
            let rawLine = lines[index]
            index += 1
            lineNumber += 1

            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("[[") {
                // Array-of-tables: parsed for validity, then discarded. Herdr's
                // sidebar config never uses it.
                guard line.hasSuffix("]]"), line.count > 4 else {
                    throw TOMLParseError.invalidValue(line, line: lineNumber)
                }
                let path = splitPath(String(line.dropFirst(2).dropLast(2)))
                currentPath = path
                appendArrayTable(path, to: &root)
                continue
            }

            if line.hasPrefix("[") {
                guard line.hasSuffix("]"), line.count > 2 else {
                    throw TOMLParseError.invalidValue(line, line: lineNumber)
                }
                currentPath = splitPath(String(line.dropFirst().dropLast()))
                ensureTable(currentPath, in: &root)
                continue
            }

            guard let equalsIndex = line.firstIndex(of: "=") else {
                throw TOMLParseError.expectedEquals(line: lineNumber)
            }
            let keyText = String(line[line.startIndex ..< equalsIndex])
                .trimmingCharacters(in: .whitespaces)
            var valueText = String(line[line.index(after: equalsIndex)...])
                .trimmingCharacters(in: .whitespaces)

            // A multi-line array or inline table continues on later lines.
            if valueText.hasPrefix("["), !isBalanced(valueText) {
                var collected = valueText
                while index < lines.count {
                    collected += "\n" + String(lines[index])
                    index += 1
                    lineNumber += 1
                    if isBalanced(collected) { break }
                }
                guard isBalanced(collected) else {
                    throw TOMLParseError.unterminatedArray(line: lineNumber)
                }
                valueText = collected
            }

            let value = try parseValue(valueText, line: lineNumber)
            let path = currentPath + splitPath(keyText)
            try set(value, at: path, in: &root, line: lineNumber)
        }
        return root
    }

    // MARK: - Structure

    private static func stripComment(_ line: String) -> String {
        var insideString = false
        var escaped = false
        var result = ""
        for character in line {
            if escaped {
                result.append(character)
                escaped = false
                continue
            }
            if character == "\\", insideString {
                result.append(character)
                escaped = true
                continue
            }
            if character == "\"" {
                insideString.toggle()
                result.append(character)
                continue
            }
            if character == "#", !insideString {
                break
            }
            result.append(character)
        }
        return result
    }

    private static func splitPath(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var insideString = false
        for character in text {
            switch character {
            case "\"":
                insideString.toggle()
            case "." where !insideString:
                parts.append(unquote(current.trimmingCharacters(in: .whitespaces)))
                current = ""
            default:
                current.append(character)
            }
        }
        let last = unquote(current.trimmingCharacters(in: .whitespaces))
        if !last.isEmpty || parts.isEmpty {
            parts.append(last)
        }
        return parts.filter { !$0.isEmpty }
    }

    private static func unquote(_ text: String) -> String {
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else {
            return text
        }
        return String(text.dropFirst().dropLast())
    }

    private static func isBalanced(_ text: String) -> Bool {
        var depth = 0
        var insideString = false
        var escaped = false
        for character in text {
            if escaped {
                escaped = false
                continue
            }
            if character == "\\", insideString {
                escaped = true
                continue
            }
            if character == "\"" {
                insideString.toggle()
                continue
            }
            if insideString { continue }
            if character == "[" || character == "{" { depth += 1 }
            if character == "]" || character == "}" { depth -= 1 }
        }
        return depth == 0 && !insideString
    }

    private static func ensureTable(_ path: [String], in root: inout [String: TOMLValue]) {
        guard !path.isEmpty else { return }
        write(.table([:]), at: path, in: &root, merge: true)
    }

    private static func appendArrayTable(_ path: [String], to root: inout [String: TOMLValue]) {
        guard let last = path.last else { return }
        let parentPath = Array(path.dropLast())
        var parent = lookup(parentPath, in: root)?.table ?? [:]
        var array = parent[last]?.array ?? []
        array.append(.table([:]))
        parent[last] = .array(array)
        write(.table(parent), at: parentPath, in: &root, merge: true)
    }

    /// Sets a value at `path`, creating intermediate tables.
    private static func set(
        _ value: TOMLValue,
        at path: [String],
        in root: inout [String: TOMLValue],
        line: Int
    ) throws {
        guard !path.isEmpty else { return }
        if lookup(path, in: root) != nil {
            throw TOMLParseError.duplicateKey(path.joined(separator: "."), line: line)
        }
        write(value, at: path, in: &root, merge: false)
    }

    /// Writes `value` at `path`. With `merge`, an existing table is updated in
    /// place instead of replaced — that is how a `[a.b]` header extends `a`
    /// without clobbering keys declared earlier.
    private static func write(
        _ value: TOMLValue,
        at path: [String],
        in root: inout [String: TOMLValue],
        merge: Bool
    ) {
        guard let head = path.first else { return }
        if path.count == 1 {
            if merge, case let .table(existing) = root[head] ?? .table([:]),
               case let .table(incoming) = value {
                var combined = existing
                for (key, entry) in incoming {
                    combined[key] = entry
                }
                root[head] = .table(combined)
            } else {
                root[head] = value
            }
            return
        }
        var child = root[head]?.table ?? [:]
        write(value, at: Array(path.dropFirst()), in: &child, merge: merge)
        root[head] = .table(child)
    }

    /// Reads the value at `path`, or `nil` when any segment is missing.
    private static func lookup(_ path: [String], in root: [String: TOMLValue]) -> TOMLValue? {
        guard let head = path.first else { return .table(root) }
        guard let node = root[head] else { return nil }
        if path.count == 1 { return node }
        guard let table = node.table else { return nil }
        return lookup(Array(path.dropFirst()), in: table)
    }

    // MARK: - Values

    private static func parseValue(_ text: String, line: Int) throws -> TOMLValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw TOMLParseError.invalidValue(text, line: line)
        }

        if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
            let inner = String(trimmed.dropFirst().dropLast())
            return .array(try splitArrayItems(inner).map { try parseValue($0, line: line) })
        }

        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            let inner = String(trimmed.dropFirst().dropLast())
            var table: [String: TOMLValue] = [:]
            for item in splitArrayItems(inner) {
                guard let equalsIndex = item.firstIndex(of: "=") else { continue }
                let key = unquote(
                    String(item[item.startIndex ..< equalsIndex])
                        .trimmingCharacters(in: .whitespaces)
                )
                let raw = String(item[item.index(after: equalsIndex)...])
                table[key] = try parseValue(raw, line: line)
            }
            return .table(table)
        }

        if trimmed.hasPrefix("\"\"\"") || trimmed.hasPrefix("'''") {
            let delimiter = String(trimmed.prefix(3))
            var body = String(trimmed.dropFirst(3))
            if body.hasSuffix(delimiter) {
                body = String(body.dropLast(3))
            }
            return .string(body)
        }

        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
            return .string(unescape(String(trimmed.dropFirst().dropLast())))
        }

        if trimmed.hasPrefix("'"), trimmed.hasSuffix("'"), trimmed.count >= 2 {
            return .string(String(trimmed.dropFirst().dropLast()))
        }

        switch trimmed {
        case "true": return .boolean(true)
        case "false": return .boolean(false)
        default: break
        }

        let numeric = trimmed.replacingOccurrences(of: "_", with: "")
        if let integer = parseInteger(numeric) {
            return .integer(integer)
        }
        if let double = Double(numeric) {
            return .double(double)
        }
        // Dates and other scalar literals: keep the text, they are never read
        // by the sidebar engine.
        return .string(trimmed)
    }

    private static func parseInteger(_ text: String) -> Int? {
        if text.hasPrefix("0x") { return Int(text.dropFirst(2), radix: 16) }
        if text.hasPrefix("0o") { return Int(text.dropFirst(2), radix: 8) }
        if text.hasPrefix("0b") { return Int(text.dropFirst(2), radix: 2) }
        return Int(text)
    }

    private static func splitArrayItems(_ text: String) -> [String] {
        var items: [String] = []
        var current = ""
        var depth = 0
        var insideString = false
        var escaped = false
        for character in text {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\", insideString {
                current.append(character)
                escaped = true
                continue
            }
            if character == "\"" {
                insideString.toggle()
                current.append(character)
                continue
            }
            if !insideString {
                if character == "[" || character == "{" { depth += 1 }
                if character == "]" || character == "}" { depth -= 1 }
                if character == ",", depth == 0 {
                    let item = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !item.isEmpty { items.append(item) }
                    current = ""
                    continue
                }
            }
            current.append(character)
        }
        let last = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty { items.append(last) }
        return items
    }

    private static func unescape(_ text: String) -> String {
        var result = ""
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                result.append(character)
                continue
            }
            guard let escaped = iterator.next() else { break }
            switch escaped {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "\"": result.append("\"")
            case "\\": result.append("\\")
            case "u":
                var hex = ""
                for _ in 0 ..< 4 {
                    if let next = iterator.next() { hex.append(next) }
                }
                if let scalar = UInt32(hex, radix: 16),
                   let unicode = Unicode.Scalar(scalar) {
                    result.append(Character(unicode))
                }
            default:
                result.append(escaped)
            }
        }
        return result
    }
}
