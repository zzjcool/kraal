// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The window control commands. They are intentionally parsed before the old
// Herdr 1 endpoint flags: `--json` already means "a literal params object" to
// `kraal call`, and reusing that parser here would turn `do --json` into a
// different command.

import Foundation
import KraalActions
import KraalHC

enum ControlCommand: Equatable {
    case commands(showHelp: Bool)
    case list
    case status
    case doAction(name: String, arguments: JSONValue)
    case shot(path: String)

    static func parse(_ arguments: [String]) -> ControlCommand? {
        guard let first = arguments.first else { return nil }
        let rest = Array(arguments.dropFirst())
        switch first {
        case "commands":
            return .commands(showHelp: rest.contains("--help") || rest.contains("-h"))
        case "ls":
            return .list
        case "status":
            return .status
        case "do":
            guard let name = rest.first, !name.hasPrefix("-") else { return nil }
            let raw = Array(rest.dropFirst())
            guard let arguments = parseArguments(raw) else { return nil }
            return .doAction(name: name, arguments: arguments)
        case "shot":
            return .shot(path: rest.first ?? "kraal-shot.png")
        default:
            return nil
        }
    }

    /// `--key value`, `--key=value`, or one raw JSON object. Values stay strings
    /// unless the raw-object form is used: upstream's `--tab 2` JSON sniffing
    /// turns a number into a number and then drops it because the command wants
    /// a string.
    static func parseArguments(_ raw: [String]) -> JSONValue? {
        if raw.count == 1, raw[0].trimmingCharacters(in: .whitespaces).hasPrefix("{") {
            guard let data = raw[0].data(using: .utf8),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data),
                  value.objectValue != nil || value.isNull
            else { return nil }
            return value
        }
        var values: [String: JSONValue] = [:]
        var index = 0
        while index < raw.count {
            let token = raw[index]
            index += 1
            guard token.hasPrefix("--") else { return nil }
            let key: String
            let value: String
            if let equals = token.firstIndex(of: "=") {
                key = String(token[token.index(token.startIndex, offsetBy: 2) ..< equals])
                value = String(token[token.index(after: equals)...])
            } else {
                key = String(token.dropFirst(2))
                guard index < raw.count else { return nil }
                value = raw[index]
                index += 1
            }
            guard !key.isEmpty else { return nil }
            values[key] = coerce(key, value: value)
        }
        return .object(values)
    }

    private static let boolArguments: Set<String> = ["confirmed", "pinned", "keep"]
    private static let numberArguments: Set<String> = ["index"]

    private static func coerce(_ key: String, value: String) -> JSONValue {
        if boolArguments.contains(key), let bool = Bool(value) {
            return .bool(bool)
        }
        if numberArguments.contains(key), let number = Int(value) {
            return .number(Double(number))
        }
        return .string(value)
    }
}

func runControlCommand(_ arguments: [String]) -> Bool {
    guard let command = ControlCommand.parse(arguments) else { return false }
    switch command {
    case let .commands(showHelp):
        if showHelp {
            printControlUsage()
        } else {
            printCommands()
        }
    case .list:
        printJSON(sendControl(.list))
    case .status:
        printJSON(sendControl(.status))
    case let .doAction(name, arguments):
        let response = sendControl(.doAction(name: name, arguments: arguments))
        printJSON(response)
        if response["error"]?.stringValue != nil { exit(1) }
    case let .shot(path):
        let absolute = URL(fileURLWithPath: path).standardizedFileURL
        let response = sendControl(.shot(path: absolute.path))
        printJSON(response)
        if response["error"]?.stringValue != nil { exit(1) }
    }
    return true
}

private func sendControl(_ request: HcControlRequest) -> JSONValue {
    let path: String
    do {
        path = try HcControlPaths.resolve()
    } catch {
        controlFail("cannot resolve control socket: \(error)")
    }
    do {
        return try HcControlClient.send(request, path: path, timeout: 35)
    } catch {
        controlFail("no running Kraal window at \(path): \(error)")
    }
}

private func printJSON(_ value: JSONValue) {
    do {
        let data = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        let pretty = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        print(String(data: pretty, encoding: .utf8) ?? "")
    } catch {
        controlFail("cannot encode reply: \(error)")
    }
}

private func controlFail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("kraal: " + message + "\n").utf8))
    exit(2)
}

func printControlUsage() {
    print("""
    kraal — control a running Kraal window

    USAGE
      kraal commands [--json]          list actions (works without a window)
      kraal ls [--json]                spaces, tabs and terminal panes
      kraal status [--json]            focus, zoom, documents and errors
      kraal do ACTION [--arg value | '<json>']
                                      run an action in the window
      kraal shot [PATH]                save a PNG of the window

    The control socket is KRAAL_CONTROL_SOCKET, else a sibling control.sock
    when KRAAL_HC_VIEW is set, else $XDG_CONFIG_HOME/kraal/control.sock.
    Exit codes: 0 ok · 1 action error · 2 no window / usage.
    """)
}
