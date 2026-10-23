// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Talking to `herdr machine …`.
//
// Why a subprocess and not the daemon: machine profiles are a *client-side*
// concern. They live in the Herdr CLI's own config, describe how to reach other
// Herdr servers over SSH, and are read/written before any server connection
// exists. The daemon's protocol has no `machine.*` method at all — its 102
// methods cover workspaces, tabs, panes, agents, plugins, integrations and
// worktrees, and nothing about saved hosts. So the only honest implementation is
// to drive the same CLI the user would type.
//
// `--json` is used wherever the CLI offers it. Text scraping of a table whose
// columns are separated by tabs would break the moment a label contains a tab;
// `herdr machine list --json` gives real fields.

import Foundation

/// One saved SSH machine, as `herdr machine list --json` reports it.
public struct HerdrMachine: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var target: String
    public var session: String?
    public var enabled: Bool
    /// True for the machine Herdr currently treats as the default destination.
    public var selected: Bool?

    public init(
        id: String,
        label: String,
        target: String,
        session: String? = nil,
        enabled: Bool,
        selected: Bool? = nil
    ) {
        self.id = id
        self.label = label
        self.target = target
        self.session = session
        self.enabled = enabled
        self.selected = selected
    }

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case target
        case session
        case enabled
        case selected
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        target = try container.decode(String.self, forKey: .target)
        session = try container.decodeIfPresent(String.self, forKey: .session)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        selected = try container.decodeIfPresent(Bool.self, forKey: .selected)
    }

    /// What to show when a label is absent — the profile id is ugly but truthful.
    public var displayLabel: String {
        label.isEmpty ? id : label
    }
}

// MARK: - Status

/// One row of `herdr machine status --json`: is this saved machine reachable
/// *now*, and if not, what did the CLI say.
///
/// This is a different fact from `EndpointStatus` in the UI, which describes
/// Kraal's own connection to a machine. A machine can be gone while our
/// connection object still exists, and vice versa.
///
/// `status` is a `String`, **not** an enum, on purpose. Upstream builds it as a
/// plain `&'static str` (`src/cli/machine.rs:136-150`) with four values today —
/// `reachable`, `error`, `disabled`, `auth required` — and no declared Rust enum,
/// so a new state can appear in any herdr release without a protocol change. An
/// `enum` without a fallback would make one unrecognised row fail the *array*
/// decode (`JSONDecoder` fails the whole array, not just the element), blanking
/// the reachability column at exactly the moment it becomes interesting. Hence:
/// keep the wire value verbatim, and let `Reachability` interpret it with an
/// `.other` arm that still renders.
public struct MachineStatus: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var label: String
    /// The CLI's own word: `reachable` / `error` / `disabled` / `auth required`.
    public var status: String
    /// The CLI's explanation when the machine is not reachable, e.g. the command
    /// to run to bring it back. `null` (or absent) when there is nothing wrong.
    public var error: String?

    /// What the raw status string means, with a fallback that does not lose it.
    public enum Reachability: Hashable, Sendable {
        case reachable
        /// Upstream's `error`: SSH worked or did not, but the remote Herdr server
        /// is not there in a usable state.
        case unreachable
        /// Upstream's `auth required`: a distinct state from `error`, because the
        /// fix is `herdr machine reconnect`, not "start the server".
        case authRequired
        case disabled
        /// A status this build does not know. Kept verbatim so a newer herdr
        /// shows its own word instead of an empty cell.
        case other(String)

        public init(rawStatus: String) {
            switch rawStatus {
            case "reachable": self = .reachable
            case "error": self = .unreachable
            case "auth required": self = .authRequired
            case "disabled": self = .disabled
            default: self = .other(rawStatus)
            }
        }

        /// Whether this state is something the user could act on. `disabled` and
        /// `reachable` are not; a dead server and a rejected key are, and they need
        /// different actions — which is why `authRequired` is not folded into
        /// `unreachable`.
        public var needsAttention: Bool {
            switch self {
            case .unreachable, .authRequired: true
            case .reachable, .disabled, .other: false
            }
        }
    }

    public init(id: String, label: String, status: String, error: String? = nil) {
        self.id = id
        self.label = label
        self.status = status
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case status
        case error
    }

    /// Lenient on everything except `id`, which is the only field with no
    /// substitute: it is the join key against `herdr machine list`. A row that
    /// cannot be joined is not worth failing the whole probe over.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        // `null` and "no such key" both mean "nothing to report"; measured shape
        // is `"error": null` for a healthy machine and a string otherwise.
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }

    public var reachability: Reachability { Reachability(rawStatus: status) }
}

/// Probe results keyed by profile id, so a roster row can find its own answer.
///
/// The two CLI commands answer different questions and can disagree by design:
/// `machine list` is the roster on disk, `machine status` is a live probe. A
/// machine that was just added has no status row yet; a status can name a profile
/// that `list` no longer has (removed between the two calls). Both are handled by
/// merging on `id` and treating a missing entry as "not probed", never as
/// "broken".
public struct MachineStatusIndex: Equatable, Sendable {
    private var byID: [String: MachineStatus]

    public init(_ rows: [MachineStatus] = []) {
        byID = [:]
        for row in rows {
            byID[row.id] = row
        }
    }

    public var isEmpty: Bool { byID.isEmpty }

    public var count: Int { byID.count }

    public func status(for id: String) -> MachineStatus? { byID[id] }

    /// `nil` for a row nobody has probed — including this Mac, which is never in
    /// the CLI's status output because it is not a saved profile.
    public func reachability(for id: String) -> MachineStatus.Reachability? {
        byID[id]?.reachability
    }
}

// MARK: - Errors

public enum HerdrMachineError: Error, CustomStringConvertible, Sendable {
    /// The `herdr` executable could not be found on this machine.
    case executableNotFound
    case launchFailed(String)
    case failed(status: Int32, message: String)
    case undecodable(String)

    public var description: String {
        switch self {
        case .executableNotFound:
            return "herdr not found. Install it, or set KRAAL_HERDR_BIN to its path."
        case .launchFailed(let message):
            return "Could not start herdr: \(message)"
        case .failed(_, let message):
            return message
        case .undecodable(let message):
            return "Unexpected output from herdr: \(message)"
        }
    }
}

// MARK: - Client

/// Runs `herdr machine …` and returns parsed results.
///
/// Every method is synchronous and meant to be called off the main actor: `herdr
/// machine add` performs an SSH round trip and can take seconds, so blocking a
/// UI thread on it would freeze the window.
public struct HerdrMachineClient: Sendable {
    /// Absolute path to the `herdr` executable, resolved once at init.
    public let executable: URL

    /// Directory to present to `herdr` as `$HOME`, or nil to inherit ours.
    ///
    /// Machine profiles are **not** scoped to a daemon: they live in one file,
    /// `~/.local/state/herdr/client/endpoints.json`, that every Herdr process on
    /// the account shares. `herdr machine` has no `--socket` flag and never opens
    /// a connection, so pointing the app at an isolated daemon does *not* isolate
    /// this list. Adding a throwaway machine for a test would therefore write into
    /// the real roster, and every other Herdr window would pick it up.
    ///
    /// `KRAAL_HERDR_HOME` fixes that: `herdr` honours `$HOME` for this path
    /// (verified — a fake home with an empty `endpoints.json` reports "No saved SSH
    /// machines." while the real roster is untouched), so a dev session can point
    /// it at a scratch directory and manage its own machines in isolation.
    ///
    /// Only the child process gets this home; the app's own window frame and log
    /// paths keep using the real one.
    public let home: String?

    public init(executable: URL, home: String? = nil) {
        self.executable = executable
        self.home = home
    }

    /// Resolves `herdr` from the environment, then from the usual install spots.
    ///
    /// A GUI app launched from Finder does not inherit the shell's PATH, so
    /// relying on PATH alone would make machine management mysteriously missing
    /// in the packaged app while working in a terminal.
    public static func discover(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> HerdrMachineClient? {
        if let override = environment["KRAAL_HERDR_BIN"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return HerdrMachineClient(executable: url, home: isolatedHome(environment))
            }
        }

        var candidates: [String] = []
        if let path = environment["PATH"] {
            for directory in path.split(separator: ":") {
                candidates.append(String(directory) + "/herdr")
            }
        }
        let home = environment["HOME"] ?? NSHomeDirectory()
        candidates.append(contentsOf: [
            home + "/.local/bin/herdr",
            "/opt/homebrew/bin/herdr",
            "/usr/local/bin/herdr",
            "/usr/bin/herdr",
        ])

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return HerdrMachineClient(
                executable: URL(fileURLWithPath: candidate),
                home: isolatedHome(environment)
            )
        }
        return nil
    }

    /// Absolute path of the file `herdr machine list` reads.
    ///
    /// Derived, not asked for, because the CLI has no command that prints it and
    /// `list --json` gives no hint. Three facts pin it down, all verified against
    /// herdr 0.9.5 and its source:
    ///
    ///  - Upstream calls `crate::config::state_dir().join("client").join("endpoints.json")`
    ///    (`src/client/endpoint/catalog.rs:373-377`).
    ///  - `state_dir()` is `$XDG_STATE_HOME/<app>` when `XDG_STATE_HOME` is set, and
    ///    otherwise `$HOME/.local/state/<app>` on every non-Windows platform
    ///    (`src/config/io.rs:37-97`). `<app>` is `herdr`, or `herdr-dev` in a debug
    ///    build.
    ///  - Measured: with `HOME=/tmp/probe-home` and a hand-written
    ///    `~/.local/state/herdr/client/endpoints.json`, `herdr machine list --json`
    ///    printed that file's machines; the real roster was untouched. With
    ///    `XDG_STATE_HOME=/tmp/probe-xdg` the file under `$XDG_STATE_HOME/herdr/`
    ///    won instead — including over a non-empty `HOME` — which is why that
    ///    variable is honoured here rather than assumed absent.
    ///
    /// `home` is the same `$HOME` the child process is given (`KRAAL_HERDR_HOME`),
    /// so a dev session watches the roster it is actually listed from instead of
    /// the user's real one.
    ///
    /// Returns nil only when there is no `$HOME` to build the path from at all,
    /// which would leave the child and this path disagreeing.
    public func rosterPath(
        development: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let app = development ? "herdr-dev" : "herdr"
        let stateDirectory: String
        if let xdg = environment["XDG_STATE_HOME"], !xdg.isEmpty {
            stateDirectory = (xdg as NSString).appendingPathComponent(app)
        } else {
            // Same fallback order `discover()` uses, so the path and the child's
            // `$HOME` cannot diverge.
            let home = home ?? environment["HOME"] ?? NSHomeDirectory()
            stateDirectory = ((home as NSString).appendingPathComponent(".local/state") as NSString)
                .appendingPathComponent(app)
        }
        return ((stateDirectory as NSString).appendingPathComponent("client") as NSString)
            .appendingPathComponent("endpoints.json")
    }

    /// `KRAAL_HERDR_HOME`, when set, becomes `$HOME` for the `herdr` child only.
    ///
    /// Empty is treated as unset: an empty `$HOME` would make "$HOME/.local/..."
    /// resolve to a filesystem-root path, which is a worse failure than inheriting.
    private static func isolatedHome(_ environment: [String: String]) -> String? {
        guard let home = environment["KRAAL_HERDR_HOME"], !home.isEmpty else { return nil }
        return home
    }

    // MARK: Reads

    /// All saved machines.
    public func list() throws -> [HerdrMachine] {
        let data = try run(["machine", "list", "--json"])
        // An empty profile list prints `[]`; a missing config prints nothing at
        // all on some versions, which is the same thing to a caller.
        let blank = data.allSatisfy { $0 == UInt8(ascii: "\n") || $0 == UInt8(ascii: " ") }
        guard !blank else { return [] }
        do {
            return try JSONDecoder().decode([HerdrMachine].self, from: data)
        } catch {
            throw HerdrMachineError.undecodable(Self.text(data, limit: 200))
        }
    }

    /// Connectivity of every saved machine (or one, when `labelOrId` is given).
    ///
    /// Runs without prompting for authentication — this is the non-blocking
    /// check, unlike `reconnect`.
    ///
    /// This is the **only** method that tolerates a non-zero exit, and only
    /// because the output is complete and valid in that case. The exit code is a
    /// summary — `machine.rs:184` returns
    /// `i32::from(rows.iter().any(|row| row.error.is_some()))` — while the rows
    /// carry the answer. Treating exit 1 as a failure would discard the `error`
    /// field, which is the only place that says what to run to fix the machine.
    ///
    /// The tolerance is not a blanket "ignore the status": if the stdout does
    /// not decode, a non-zero run is reported as a failure with the CLI's stderr,
    /// which is where a usage error (`unknown machine 'x'`, exit 2, empty stdout)
    /// explains itself.
    public func status(_ labelOrId: String? = nil) throws -> [MachineStatus] {
        var arguments = ["machine", "status", "--json"]
        if let labelOrId, !labelOrId.isEmpty {
            arguments.append(labelOrId)
        }
        let result = try invoke(arguments)
        do {
            return try JSONDecoder().decode([MachineStatus].self, from: result.stdout)
        } catch {
            // No usable answer. `undecodable` would hide "unknown machine", so a
            // non-zero exit keeps its own message.
            guard result.status == 0 else {
                throw HerdrMachineError.failed(status: result.status, message: result.failureMessage)
            }
            throw HerdrMachineError.undecodable(Self.text(result.stdout, limit: 200))
        }
    }

    // MARK: Writes

    /// Saves a machine, preparing the remote Herdr server first.
    ///
    /// This is slow by nature: it opens SSH, checks the remote server, and may
    /// start one. Callers must not hold the main actor while it runs.
    @discardableResult
    public func add(target: String, label: String?, remoteSession: String?) throws -> String {
        var arguments = ["machine", "add", target]
        if let label, !label.isEmpty {
            arguments.append(contentsOf: ["--label", label])
        }
        if let remoteSession, !remoteSession.isEmpty {
            arguments.append(contentsOf: ["--remote-session", remoteSession])
        }
        return Self.text(try run(arguments))
    }

    /// Renames a machine.
    ///
    /// Argument order is `<profile-id> --label <label>`, which is *not* what
    /// `herdr machine rename --help` prints (it advertises
    /// `--label <LABEL> <PROFILE_ID>`). The help text is wrong; the parser takes
    /// the positional first and rejects the other order with a usage message.
    /// Verified against herdr 0.9.5.
    public func rename(id: String, label: String) throws {
        try run(["machine", "rename", id, "--label", label])
    }

    public func remove(id: String) throws {
        try run(["machine", "remove", id])
    }

    public func setEnabled(id: String, enabled: Bool) throws {
        try run(["machine", enabled ? "enable" : "disable", id])
    }

    // MARK: Process plumbing

    /// UTF-8 view of CLI output. Lossy on invalid bytes on purpose: a warning
    /// printed in some other encoding should not turn into a decode failure that
    /// hides the real result.
    private static func text(_ data: Data, limit: Int? = nil) -> String {
        let slice = limit.map { Data(data.prefix($0)) } ?? data
        // Invalid UTF-8 falls back to an empty string rather than throwing: a
        // stray byte in a warning must not mask the real result.
        return String(bytes: slice, encoding: .utf8) ?? ""
    }

    /// One invocation: what came back, before anyone has judged the exit status.
    private struct Invocation {
        var status: Int32
        var stdout: Data
        var stderr: String

        /// What to report when a caller decides this run failed.
        var failureMessage: String {
            stderr.isEmpty ? "herdr exited with status \(status)" : stderr
        }
    }

    /// Runs the CLI and returns stdout, throwing on a non-zero exit.
    ///
    /// stderr is folded into the thrown message because that is where `herdr`
    /// reports every user-facing failure ("no such profile", ssh errors), and a
    /// bare exit code would leave the UI with nothing to show.
    ///
    /// Writes (`add` / `rename` / `remove` / `enable` / `disable`) keep this
    /// strict path: their non-zero exits are real failures with nothing useful on
    /// stdout. `status` is the one reader that goes through `invoke` directly.
    private func run(_ arguments: [String]) throws -> Data {
        let result = try invoke(arguments)
        guard result.status == 0 else {
            throw HerdrMachineError.failed(status: result.status, message: result.failureMessage)
        }
        return result.stdout
    }

    /// Runs the CLI and hands back both streams plus the exit status, without
    /// judging it.
    ///
    /// Both pipes are read to EOF before waiting, because a child that fills a
    /// pipe buffer while the parent sits in `waitUntilExit` deadlocks.
    private func invoke(_ arguments: [String]) throws -> Invocation {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // A GUI process may have no HOME-derived config path set up the way a
        // shell does; passing the environment through unchanged keeps `herdr`
        // reading the same config the user's terminal would.
        var childEnvironment = ProcessInfo.processInfo.environment
        if let home {
            childEnvironment["HOME"] = home
        }
        process.environment = childEnvironment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Some prompts read from the terminal; with no stdin they would hang.
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw HerdrMachineError.launchFailed(error.localizedDescription)
        }

        // Read both pipes before waiting: a full pipe buffer deadlocks a child
        // that is still writing while the parent sits in waitUntilExit.
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Invocation(
            status: process.terminationStatus,
            stdout: stdoutData,
            stderr: Self.text(stderrData).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
