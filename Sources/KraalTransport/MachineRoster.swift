// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The roster the UI shows: this Mac, plus every SSH machine herdr saved.
//
// Why this is not just `herdr machine list`:
//
// Herdr's saved-machine list only ever contains *remote* profiles. On disk that
// is `~/.local/state/herdr/client/endpoints.json`, whose shape is
// `{"version": 1, "ssh": [...]}` — a single `ssh` array, and nothing else. The
// local daemon is not an entry in that array; it is implicit, reached over
// `~/.config/herdr/herdr-client.sock`. Herdr's own TUI treats "this Mac" the same
// way: a built-in destination that is never serialised.
//
// A client that renders only `machine list` therefore shows a machine roster
// with the machine you are actually sitting at missing from it — the reported
// bug. Since the local destination cannot come from herdr's config, it has to be
// synthesised here, kept separate from the remote list, and never written back:
// a synthesised row must not become a phantom profile that later shows up in
// `herdr machine list` or in the user's real config.

import Foundation

/// One row of the roster: either this Mac, or a saved SSH machine.
public enum MachineEntry: Identifiable, Hashable, Sendable {
    /// The daemon on this machine. Not a saved profile; never persisted.
    case local(LocalMachineDescriptor)
    /// A profile from `herdr machine list`.
    case remote(HerdrMachine)

    public var id: String {
        switch self {
        case let .local(descriptor): descriptor.id
        case let .remote(machine): machine.id
        }
    }

    public var displayLabel: String {
        switch self {
        case let .local(descriptor): descriptor.label
        case let .remote(machine): machine.displayLabel
        }
    }

    /// What to show under the label: a socket path locally, an SSH target remotely.
    public var targetDescription: String {
        switch self {
        case let .local(descriptor): descriptor.target
        case let .remote(machine): machine.target
        }
    }

    public var enabled: Bool {
        switch self {
        case .local: true
        case let .remote(machine): machine.enabled
        }
    }

    /// True for this Mac, which the roster always keeps and never edits.
    public var isLocal: Bool {
        if case .local = self { return true }
        return false
    }

    public var machine: HerdrMachine? {
        if case let .remote(machine) = self { return machine }
        return nil
    }

    /// The actions a row's context menu offers.
    ///
    /// This is a type rather than a `View` for one reason: a `.contextMenu` whose
    /// body renders nothing still installs a menu, and AppKit then opens an empty
    /// one — a right-click that does nothing at all. That is indistinguishable
    /// from "the menu is broken", and it is what this Mac's row used to do, because
    /// its body was `if !isLocal { ... }` with nothing in the else branch. Naming
    /// the actions makes "every row has at least one" checkable without a UI test.
    public enum MenuAction: Hashable, Sendable {
        /// Only this Mac: the roster cannot rename or remove the local daemon.
        case copySocketPath
        case copyLabel
        /// Only a saved profile.
        case rename
        case toggleEnabled
        case remove
    }

    /// What a right-click on this row should offer. Never empty.
    public var menuActions: [MenuAction] {
        switch self {
        case .local:
            // No `herdr machine` command can edit the local daemon, so the row
            // offers identity instead of write controls. Two items, and neither
            // is destructive.
            return [.copySocketPath, .copyLabel]
        case .remote:
            return [.rename, .toggleEnabled, .remove]
        }
    }
}

/// How this Mac is presented and reached.
///
/// Split out so the label and the socket are testable without a running daemon:
/// the socket path is exactly what `HerdrDiscovery.resolve` would dial, so a row
/// that claims "this Mac" cannot point somewhere else.
public struct LocalMachineDescriptor: Hashable, Sendable {
    /// Stable id, distinct in shape from herdr's 32-hex profile ids so a
    /// synthesised row can never collide with a real profile.
    public static let stableId = "kraal:local"

    public var id: String
    public var label: String
    /// The socket path, shown as the row's subtitle.
    public var target: String

    public init(label: String = "This Mac", socketPath: String) {
        self.id = Self.stableId
        self.label = label
        self.target = socketPath
    }

    /// Resolves this Mac the same way a connection would.
    ///
    /// Passing the settings through `HerdrDiscovery` rather than re-deriving the
    /// path here keeps the row honest: if the app is pointed at a sandbox socket
    /// by an environment override, the roster says so instead of claiming the
    /// default path.
    public static func resolve(
        settings: ConnectionSettings = .local,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LocalMachineDescriptor {
        let path: String
        if let target = try? HerdrDiscovery.resolve(settings, environment: environment) {
            switch target {
            case let .unixSocket(socketPath): path = socketPath
            case .sshShell: path = ""
            }
        } else {
            path = ""
        }
        let label = settings.name.isEmpty ? "This Mac" : settings.name
        return LocalMachineDescriptor(label: label, socketPath: path)
    }
}

/// Builds the roster shown to the user.
public enum MachineRoster {
    /// This Mac first, then the saved machines in the order given.
    ///
    /// Local-first is deliberate: it is the destination that always exists, so
    /// putting it at the top gives the list a stable anchor even while the
    /// remote list is still loading or failed to load.
    public static func compose(
        local: LocalMachineDescriptor,
        remote: [HerdrMachine]
    ) -> [MachineEntry] {
        [.local(local)] + remote.map(MachineEntry.remote)
    }

    /// The label to show for the machine a sidebar row belongs to.
    ///
    /// Sidebar rows describe panes on whichever machine the app is connected to,
    /// so every row on a connection carries the same name. Falls back to
    /// `fallback` when the settings have no name, and never returns an empty
    /// string: the `machine` token is rendered verbatim, so empty would leave a
    /// gap in the row.
    public static func sidebarMachineName(
        settings: ConnectionSettings,
        fallback: String = "local"
    ) -> String {
        let name = settings.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        return fallback
    }
}
