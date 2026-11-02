// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Where a herdr-core session lives.
//
// Mirrors crates/herdr-core/src/paths.rs: HC_SESSION names the session, HC_SOCKET
// overrides the endpoint, then `socket` in config.toml, then the runtime dir.
// Getting this wrong does not fail loudly — it dials a socket that does not
// exist while the core is running somewhere else — so the rules are reproduced
// exactly and covered by tests.

import Foundation
import KraalSocket

public enum HcPathError: Error, Equatable, CustomStringConvertible {
    case invalidSession(String)
    case socketPathTooLong(path: String, bytes: Int, limit: Int)

    public var description: String {
        switch self {
        case let .invalidSession(name):
            "HC_SESSION \(quoted(name)) can't be a folder name; use letters, digits, - _ ."
        case let .socketPathTooLong(path, bytes, limit):
            "the socket path for this session is \(bytes) bytes; this system allows \(limit): \(path)"
        }
    }

    private func quoted(_ name: String) -> String {
        "\"\(name)\""
    }
}

public struct HcPaths: Sendable, Equatable {
    public let session: String
    public let socket: String
    public let stateDirectory: String
    public let configFile: String

    public var lockFile: String {
        stateDirectory + "/core.lock"
    }

    /// Resolves the same paths the core would.
    ///
    /// `fileExists`/`readText` are injectable so tests can describe a machine
    /// without touching it.
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        uid: UInt32 = getuid(),
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        readText: (String) -> String? = { path in
            guard let data = FileManager.default.contents(atPath: path) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    ) throws -> HcPaths {
        let session = try validatedSession(environment["HC_SESSION"])

        let stateHome = nonEmpty(environment["XDG_STATE_HOME"]) ?? home + "/.local/state"
        let configHome = nonEmpty(environment["XDG_CONFIG_HOME"]) ?? home + "/.config"
        let stateDirectory = stateHome + "/herdr-core/" + session
        let configFile = configHome + "/herdr-core/config.toml"

        let runDirectory: String
        if let runtime = nonEmpty(environment["XDG_RUNTIME_DIR"]) {
            runDirectory = runtime + "/herdr-core"
        } else {
            let perUser = "/run/user/\(uid)"
            // Logins without XDG_RUNTIME_DIR (some ssh setups) still find the core
            // only when the per-user runtime dir exists. Same rule as the core.
            runDirectory = fileExists(perUser) ? perUser + "/herdr-core" : stateDirectory
        }

        let configured = nonEmpty(environment["HC_SOCKET"])
            ?? configSocket(readText(configFile))
        let socket = configured ?? runDirectory + "/" + session + ".sock"

        try checkPathBudget(socket)
        return HcPaths(
            session: session,
            socket: socket,
            stateDirectory: stateDirectory,
            configFile: configFile
        )
    }

    /// The socket the core last wrote into `core.lock`, when it differs from the
    /// one we computed. Turning "connection refused" into "the core is actually
    /// at <path>" is the difference between a five-second fix and a hunt.
    public func recordedSocket() -> String? {
        guard let text = try? String(contentsOfFile: lockFile, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != socket else { return nil }
        return trimmed
    }

    public static func validatedSession(_ raw: String?) throws -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "default" : trimmed
        if name == "." || name == ".." {
            throw HcPathError.invalidSession(name)
        }
        let forbidden = Set(#"/\:*?"<>|"#)
        for scalar in name.unicodeScalars {
            if scalar.properties.generalCategory == .control || forbidden.contains(Character(scalar)) {
                throw HcPathError.invalidSession(name)
            }
        }
        return name
    }

    static func configSocket(_ text: String?) -> String? {
        guard let text else { return nil }
        var section = ""
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                section = line
                continue
            }
            guard section.isEmpty else { continue }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard key == "socket" else { continue }
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else {
                return nil
            }
            return unescape(String(value.dropFirst().dropLast()))
        }
        return nil
    }

    private static func stripComment(_ line: String) -> String {
        var inString = false
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" && inString {
                escaped = true
                continue
            }
            if character == "\"" {
                inString.toggle()
                continue
            }
            if character == "#" && !inString {
                return String(line[..<index])
            }
        }
        return line
    }

    private static func unescape(_ value: String) -> String {
        var result = ""
        var iterator = value.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                result.append(character)
                continue
            }
            guard let next = iterator.next() else { break }
            switch next {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "\"": result.append("\"")
            case "\\": result.append("\\")
            default:
                result.append("\\")
                result.append(next)
            }
        }
        return result
    }

    private static func checkPathBudget(_ socket: String) throws {
        let holder = (socket as NSString).deletingPathExtension + ".holder.sock"
        // The core also budgets the holder's random suffix (8 bytes) and the dot.
        let longest = max(socket.utf8.count, holder.utf8.count + 1 + 8)
        guard longest <= unixSocketMaxPathBytes else {
            throw HcPathError.socketPathTooLong(
                path: socket,
                bytes: longest,
                limit: unixSocketMaxPathBytes
            )
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
