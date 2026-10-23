// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Where the daemon's client socket lives, and how to reach a remote one.
//
// The local rules are adapted from `herdr-client/src/discovery.rs` (Apache-2.0),
// which in turn follows Herdr `src/server/socket_paths.rs`. Both ends must
// resolve the same path or the app silently dials nothing, so the environment
// overrides and the named-session layout are reproduced exactly.

import Foundation

public enum HerdrTransportKind: String, Sendable, Codable, CaseIterable {
    /// A unix socket on this machine.
    case local
    /// `ssh <host> herdr remote-client-bridge`.
    case ssh

    public var displayName: String {
        switch self {
        case .local: "This Mac"
        case .ssh: "SSH"
        }
    }
}

/// A resolved connection target.
public enum HerdrTarget: Equatable, Sendable {
    case unixSocket(path: String)
    case sshShell(user: String?, host: String, port: UInt16?, session: String)

    public var displayName: String {
        switch self {
        case let .unixSocket(path):
            return (path as NSString).abbreviatingWithTildeInPath
        case let .sshShell(user, host, port, _):
            let prefix = user.map { "\($0)@" } ?? ""
            let suffix = port.map { ":\($0)" } ?? ""
            return "\(prefix)\(host)\(suffix)"
        }
    }
}

/// Turns user-facing connection settings into a concrete target, applying the
/// same defaults as the daemon.
public enum HerdrDiscovery {
    public static let defaultSession = "default"

    /// The configuration root, honouring `XDG_CONFIG_HOME` exactly as the
    /// daemon does (falling back to `~/.config`).
    public static func configRoot(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> String {
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return xdg
        }
        let home = environment["HOME"] ?? NSHomeDirectory()
        return (home as NSString).appendingPathComponent(".config")
    }

    /// `~/.config/herdr`, or `.../herdr-dev` for a development build.
    public static func configDirectory(
        development: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        (configRoot(environment: environment) as NSString)
            .appendingPathComponent(development ? "herdr-dev" : "herdr")
    }

    /// The `herdr-client.sock` for a named session.
    ///
    /// A named session nests under `sessions/<name>/`; `default` sits in the
    /// root. A name that could escape the root is rejected, matching upstream.
    public static func sessionSocket(
        name: String,
        development: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        guard isValidSessionName(name) else {
            throw DiscoveryError.invalidSessionName(name)
        }
        let path = socketPath(
            name: name, development: development, environment: environment
        )
        // A name can be legal and still produce a path the socket cannot carry: the
        // two limits are unrelated (issue #90). Checked here, where both the name
        // and the path are known, and refused with an error that names the field the
        // user actually typed into — a bare `pathTooLong` would arrive far from the
        // input and say nothing about it.
        let bytes = path.utf8.count
        guard bytes <= unixSocketMaxPathBytes else {
            throw DiscoveryError.sessionNameTooLongForSocket(
                name: name,
                pathBytes: bytes,
                limit: unixSocketMaxPathBytes,
                budget: maxSessionNameLength(development: development, environment: environment)
            )
        }
        return path
    }

    /// How long a session name can be before its socket path overflows.
    ///
    /// Not a constant, because it depends on `$HOME` and on whether this is a
    /// development build: the same name is fine on one machine and too long on
    /// another (measured — a 12-byte home allows 49 characters, a 20-byte one
    /// allows 41). Returns 0 when even an empty name would overflow, which can
    /// happen with a pathologically long home directory.
    public static func maxSessionNameLength(
        development: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        // Measured with a one-character name and extrapolated: everything around
        // the name is fixed for a given configuration, and the alphabet this rule
        // allows is ASCII-only, so one character is one byte.
        let probe = "a"
        let fixed = socketPath(
            name: probe, development: development, environment: environment
        ).utf8.count - probe.utf8.count
        return min(64, max(0, unixSocketMaxPathBytes - fixed))
    }

    /// The path for a session, without the length check.
    ///
    /// Split out so `sessionSocket` and `maxSessionNameLength` cannot disagree
    /// about how a path is built — the budget is only meaningful if both compute
    /// the same string.
    private static func socketPath(
        name: String,
        development: Bool,
        environment: [String: String]
    ) -> String {
        var directory = configDirectory(development: development, environment: environment)
        if name != defaultSession {
            directory = (directory as NSString)
                .appendingPathComponent("sessions/\(name)")
        }
        return (directory as NSString).appendingPathComponent("herdr-client.sock")
    }

    public static func isValidSessionName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64, name != ".", name != ".." else {
            return false
        }
        return name.allSatisfy { character in
            character.isASCII
                && (character.isLetter || character.isNumber || character == "."
                    || character == "_" || character == "-")
        }
    }

    /// Resolves a saved connection into a target.
    ///
    /// Environment overrides are honoured for `.local` only, which is what the
    /// daemon does: a remote target always derives the session path remotely.
    public static func resolve(
        _ settings: ConnectionSettings,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> HerdrTarget {
        switch settings.transport {
        case .local:
            // `KRAAL_HERDR_SOCKET` is Kraal's own override and wins: it exists so a
            // development build can be pointed at a sandbox daemon without
            // inheriting the daemon's own variables.
            if let override = environment["KRAAL_HERDR_SOCKET"], !override.isEmpty {
                return .unixSocket(path: override)
            }
            if settings.session == defaultSession,
               let override = environment["HERDR_CLIENT_SOCKET_PATH"], !override.isEmpty {
                return .unixSocket(path: override)
            }
            if settings.session == defaultSession,
               let apiOverride = environment["HERDR_SOCKET_PATH"], !apiOverride.isEmpty {
                // Mirror the daemon: `herdr.sock` -> `herdr-client.sock`.
                let url = URL(fileURLWithPath: apiOverride)
                let stem = url.deletingPathExtension().lastPathComponent
                let client = url.deletingLastPathComponent()
                    .appendingPathComponent("\(stem)-client.sock")
                return .unixSocket(path: client.path)
            }
            let name = settings.session.isEmpty ? defaultSession : settings.session
            return .unixSocket(
                path: try sessionSocket(name: name, environment: environment)
            )

        case .ssh:
            // The same rule as the local branch, and for a sharper reason: upstream
            // `herdr --session <name>` *creates* a session that does not exist, so an
            // unchecked name is not rejected remotely — it silently leaves a fresh
            // daemon behind and connects to it. A typo then looks exactly like
            // "wrong machine": an empty workspace with no error (issue #70).
            //
            // Only the empty case is defaulted; `default` is itself a valid name, so
            // the "session field left blank" path is unaffected.
            let session = settings.session.isEmpty ? defaultSession : settings.session
            guard isValidSessionName(session) else {
                throw DiscoveryError.invalidSessionName(session)
            }
            return .sshShell(
                user: settings.sshUser,
                host: settings.sshHost,
                port: settings.sshPort,
                session: session
            )
        }
    }
}

public enum DiscoveryError: Error, CustomStringConvertible {
    case invalidSessionName(String)

    /// The name is legal but the socket path it produces is too long.
    ///
    /// Carries the numbers because the user cannot act on "path too long" — they
    /// need to know which name, by how much, and what the ceiling is. The ceiling
    /// depends on `$HOME`, so it is not something the UI can compute on its own.
    case sessionNameTooLongForSocket(name: String, pathBytes: Int, limit: Int, budget: Int)

    public var description: String {
        switch self {
        case let .invalidSessionName(name):
            "\"\(name)\" is not a valid session name (letters, digits, '.', '-', '_'; "
                + "at most 64 characters)"
        case let .sessionNameTooLongForSocket(name, pathBytes, limit, budget):
            "\"\(name)\" is a valid session name, but its socket path is \(pathBytes) "
                + "bytes and this platform allows \(limit). Shorten the name to at most "
                + "\(budget) characters for this machine."
        }
    }
}

/// Persisted connection settings for one saved host.
public struct ConnectionSettings: Equatable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var transport: HerdrTransportKind
    public var session: String
    public var sshHost: String
    public var sshUser: String?
    public var sshPort: UInt16?

    public init(
        id: UUID = UUID(),
        name: String,
        transport: HerdrTransportKind = HerdrTransportKind.local,
        session: String = HerdrDiscovery.defaultSession,
        sshHost: String = "",
        sshUser: String? = nil,
        sshPort: UInt16? = nil
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.session = session
        self.sshHost = sshHost
        self.sshUser = sshUser
        self.sshPort = sshPort
    }

    /// The default "this Mac" entry: no stored state, always present.
    public static let local = ConnectionSettings(
        name: "This Mac",
        transport: .local
    )
}
