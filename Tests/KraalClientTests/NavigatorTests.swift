// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Tests for the Go To index and the keybinding profile reader.
//
// Both replace something that used to be a hard-coded guess:
//
// - the sidebar was the only way to reach a pane, so "go to the pane running the
//   tests" required knowing which machine it was on;
// - the shortcut panel was a hand-written table that had already drifted from the
//   bindings the app honours.
//
// The tests that matter here are the ordering ones. A navigator that lists
// everything is easy; one whose first row is "where you already are" and whose
// second is "on the machine you are looking at" is the version that does not make
// Enter jump to another machine.
//

import Foundation
import Testing

@testable import KraalProtocol
@testable import KraalUI

@Suite("Navigator")
struct NavigatorTests {
    /// Two machines, decoded from JSON so the field names are the daemon's.
    private func machines() throws -> [NavigatorMachine] {
        [
            NavigatorMachine(
                id: "local",
                label: "this-mac",
                snapshot: try snapshot(active: true),
                isActive: true
            ),
            NavigatorMachine(
                id: "ssh:vps",
                label: "vps-01",
                snapshot: try snapshot(active: false),
                isActive: false
            ),
        ]
    }

    private func snapshot(active: Bool) throws -> ClientShellSnapshot {
        // The active machine has the focused ids; the remote one does not, so
        // "current" cannot accidentally match on both.
        let focused = active ? "w1:t1\"" : "w2:t1\""
        _ = focused
        let json = """
        {
          "boot_id": "b1",
          "revision": 1,
          "update_install_command": "",
          "latest_release_notes_available": false,
          "integration_updates_available": false,
          "worktree_directory": "",
          "tab_bar_right": [],
          "tab_bar_right_separator": " ",
          "focused_workspace_id": "\(active ? "w1" : "w2")",
          "focused_tab_id": "\(active ? "w1:t1" : "w2:t1")",
          "focused_pane_id": "\(active ? "w1:p1" : "w2:p1")",
          "agent_order": [],
          "workspaces": [
            {"workspace_id": "\(active ? "w1" : "w2")", "number": 1}
          ],
          "tabs": [
            {"tab_id": "\(active ? "w1:t1" : "w2:t1")",
             "workspace_id": "\(active ? "w1" : "w2")", "number": 1}
          ],
          "panes": [
            {"pane_id": "\(active ? "w1:p1" : "w2:p1")",
             "workspace_id": "\(active ? "w1" : "w2")",
             "tab_id": "\(active ? "w1:t1" : "w2:t1")",
             "label": "\(active ? "editor" : "logs")",
             "focused": \(active ? "true" : "false")},
            {"pane_id": "\(active ? "w1:p2" : "w2:p2")",
             "workspace_id": "\(active ? "w1" : "w2")",
             "tab_id": "\(active ? "w1:t1" : "w2:t1")",
             "label": "shell",
             "focused": false}
          ],
          "agents": [], "commands": []
        }
        """
        return try JSONDecoder().decode(ClientShellSnapshot.self, from: Data(json.utf8))
    }

    /// Pane titles win the label, and a machine that never connected contributes
    /// nothing: inventing rows for it would make Enter land in an empty window.
    @Test("targets cover every machine's panes, tabs and workspaces")
    func targetsCoverEverything() throws {
        let targets = Navigator.targets(for: try machines())
        #expect(targets.filter { $0.kind == .pane }.count == 4)
        #expect(targets.filter { $0.kind == .tab }.count == 2)
        #expect(targets.filter { $0.kind == .workspace }.count == 2)

        var withOffline = try machines()
        withOffline.append(NavigatorMachine(
            id: "ssh:down", label: "offline", snapshot: nil, isActive: false
        ))
        #expect(Navigator.targets(for: withOffline).count == targets.count)
    }

    /// The first row must be where the user already is: opening the palette and
    /// pressing Enter should be a no-op, not a jump.
    @Test("the current pane is the first target")
    func currentPaneFirst() throws {
        let targets = Navigator.targets(for: try machines())
        #expect(targets.first?.isCurrent == true)
        #expect(targets.first?.kind == .pane)
        #expect(targets.first?.title == "editor")
        #expect(targets.first?.machineId == "local")
    }

    /// Panes before tabs before workspaces. "Go to" almost always means a pane,
    /// and burying panes under every workspace row would make the first page of
    /// results useless.
    @Test("panes outrank tabs, which outrank workspaces")
    func kindOrder() throws {
        let kinds = Navigator.targets(for: try machines()).map(\.kind)
        let firstTab = try #require(kinds.firstIndex(of: .tab))
        let firstWorkspace = try #require(kinds.firstIndex(of: .workspace))
        #expect(kinds[..<firstTab].allSatisfy { $0 == .pane })
        #expect(firstTab < firstWorkspace)
    }

    /// The active machine wins ties within a kind, so browsing does not hop
    /// machines. The current pane is already pinned first; this is about the rest.
    @Test("the active machine sorts ahead of the others within a kind")
    func activeMachineWinsTies() throws {
        let panes = Navigator.targets(for: try machines()).filter { $0.kind == .pane }
        let machineIds = panes.map(\.machineId)
        // Both local panes precede both remote ones (except that the current pane
        // is first, which is local anyway).
        #expect(machineIds.prefix(2).allSatisfy { $0 == "local" })
        #expect(machineIds.suffix(2).allSatisfy { $0 == "ssh:vps" })
    }

    /// Search covers the machine label too: "vps" has to find everything on that
    /// machine, which is the question you ask when you cannot remember where a
    /// pane lives.
    @Test("search matches titles and machine labels")
    func searchMatchesBoth() throws {
        let targets = Navigator.targets(for: try machines())
        #expect(Navigator.filtered(targets, query: "shell").count == 2)
        #expect(Navigator.filtered(targets, query: "vps").allSatisfy { $0.machineId == "ssh:vps" })
        // Two panes + one tab + one workspace all live on vps-01.
        #expect(Navigator.filtered(targets, query: "VPS").count == 4)
        // An empty query is everything, not nothing: opening the palette shows
        // where you are.
        #expect(Navigator.filtered(targets, query: "   ").count == targets.count)
        #expect(Navigator.filtered(targets, query: "zzz").isEmpty)
    }

    /// A pane with no label falls back to its cwd's last component, so an unnamed
    /// shell is findable as "kraal" rather than as "w1:p3".
    @Test("an unnamed pane is named after its directory")
    func unnamedPaneUsesDirectory() throws {
        let json = """
        {
          "boot_id": "b1", "revision": 1, "update_install_command": "",
          "latest_release_notes_available": false,
          "integration_updates_available": false, "worktree_directory": "",
          "tab_bar_right": [], "tab_bar_right_separator": " ",
          "agent_order": [], "workspaces": [], "tabs": [],
          "panes": [
            {"pane_id": "w1:p3", "workspace_id": "w1", "tab_id": "w1:t1",
             "foreground_cwd": "/Users/me/code/kraal", "focused": false}
          ],
          "agents": [], "commands": []
        }
        """
        let snapshot = try JSONDecoder().decode(ClientShellSnapshot.self, from: Data(json.utf8))
        let targets = Navigator.targets(for: [
            NavigatorMachine(id: "local", label: "this-mac", snapshot: snapshot, isActive: true)
        ])
        #expect(targets.first?.title == "kraal")
    }
}

@Suite("Keybinding profile")
struct KeybindingProfileTests {
    /// The shape upstream's `local_keybindings_profile_toml` produces
    /// (`config.rs:178-189`): a `[keys]` table of `name = "combo"`.
    private let profile = """
    [keys]
    prefix = "ctrl+a"
    new_tab = "prefix+t"
    next_tab = "prefix+n"
    split_vertical = "prefix+|"
    """

    @Test("scalar bindings are read")
    func scalars() {
        let entries = KeybindingProfile.entries(in: profile)
        // prefix, new_tab, next_tab, split_vertical.
        #expect(entries.count == 4)
        #expect(entries.first == KeybindingProfile.Entry(name: "prefix", binding: "ctrl+a"))
        #expect(KeybindingProfile.binding(for: "new_tab", in: profile) == "prefix+t")
        #expect(KeybindingProfile.binding(for: "split_vertical", in: profile) == "prefix+|")
    }

    /// A `prefix` that accepts several keys is serialised as an array. One row is
    /// what the help panel wants: a user pressing "the prefix" does not care that
    /// there are two of them.
    @Test("an array-valued binding is flattened into one row")
    func arrays() {
        let toml = """
        [keys]
        prefix = ["ctrl+a", "alt+a"]
        new_tab = "prefix+t"
        """
        let entries = KeybindingProfile.entries(in: toml)
        #expect(entries.count == 2)
        #expect(entries.first?.name == "prefix")
        #expect(entries.first?.binding == "ctrl+a / alt+a")
    }

    /// `[[keys.command]]` entries are custom commands, and the daemon already
    /// strips them. Reading them as bindings would fill the panel with command
    /// names that are not shortcuts for anything in it.
    @Test("custom command tables are not read as bindings")
    func customCommandsIgnored() {
        let toml = """
        [keys]
        new_tab = "prefix+t"

        [[keys.command]]
        key = "prefix+g"
        command = "lazygit"
        """
        let entries = KeybindingProfile.entries(in: toml)
        #expect(entries.count == 1)
        #expect(entries.first?.binding == "prefix+t")
        #expect(entries.allSatisfy { $0.name != "key" && $0.name != "command" })
    }

    /// A missing profile is not an error: it means the daemon has no opinion, and
    /// the panel falls back to the built-in table.
    @Test("no profile yields no entries")
    func absentProfile() {
        #expect(KeybindingProfile.entries(in: nil).isEmpty)
        #expect(KeybindingProfile.entries(in: "").isEmpty)
        #expect(KeybindingProfile.entries(in: "[other]\nx = \"y\"").isEmpty)
        #expect(KeybindingProfile.binding(for: "new_tab", in: nil) == nil)
    }

    /// Comments, blank lines and non-string values are skipped rather than
    /// guessed at — an upstream addition must add unknown keys, not break the
    /// panel.
    @Test("comments and non-binding values are skipped")
    func commentsAndNoise() {
        let toml = """
        # leading comment
        [keys]
        # new_tab = "commented-out"
        new_tab = "prefix+t"

        scrollback = 10000
        """
        let entries = KeybindingProfile.entries(in: toml)
        #expect(entries.count == 1)
        #expect(entries.first?.binding == "prefix+t")
    }

    /// A truncated array (unterminated string) must not surface half a combo: the
    /// built-in label is better than a wrong one.
    @Test("a malformed array is refused instead of half-read")
    func malformedArray() {
        let toml = """
        [keys]
        prefix = ["ctrl+a"
        new_tab = "prefix+t"
        """
        let entries = KeybindingProfile.entries(in: toml)
        #expect(entries.count == 1)
        #expect(entries.first?.name == "new_tab")
    }
}
