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

    /// A trailing comment containing `[` used to make the parser treat every
    /// following line as a continuation, so the **entire** `[keys]` table
    /// vanished. Verified before the fix: 0 entries for a 2-binding table.
    @Test("a comment containing a bracket does not swallow the table")
    func commentWithBracket() {
        let toml = """
        [keys]
        new_tab = "prefix+t"  # see [docs
        next_tab = "prefix+n"
        """
        let entries = KeybindingProfile.entries(in: toml)
        #expect(entries.count == 2)
        #expect(KeybindingProfile.binding(for: "new_tab", in: toml) == "prefix+t")
        #expect(KeybindingProfile.binding(for: "next_tab", in: toml) == "prefix+n")
    }

    /// A trailing comment on an array value made it fail the `]` suffix test, so
    /// that one binding was dropped while the rest survived — the least
    /// detectable version of the bug.
    @Test("a trailing comment does not drop its value")
    func trailingCommentOnValue() {
        let toml = """
        [keys]
        prefix = ["ctrl+a"]  # note
        new_tab = "prefix+t"
        """
        #expect(KeybindingProfile.binding(for: "prefix", in: toml) == "ctrl+a")
        #expect(KeybindingProfile.binding(for: "new_tab", in: toml) == "prefix+t")
    }

    /// `[ keys ]` is legal TOML (`std-table-open = %x5B ws`), and an exact-match
    /// header test treated it as an unrelated table — zeroing the panel.
    @Test("a commented or spaced table header is still the keys table")
    func headerVariants() {
        let commented = """
        [keys]  # the keys table
        new_tab = "prefix+t"
        """
        #expect(KeybindingProfile.binding(for: "new_tab", in: commented) == "prefix+t")

        let spaced = """
        [ keys ]
        new_tab = "prefix+t"
        """
        #expect(KeybindingProfile.binding(for: "new_tab", in: spaced) == "prefix+t")
    }

    /// A `#` inside a quoted value is not a comment. Stripping comments with a
    /// plain `split(separator: "#")` would be a new way to lose data.
    @Test("a hash inside a quoted binding is kept")
    func hashInsideString() {
        let toml = """
        [keys]
        custom = "prefix+#"
        new_tab = "prefix+t"
        """
        #expect(KeybindingProfile.binding(for: "custom", in: toml) == "prefix+#")
    }

    /// A decoded `\n` is a real newline, which renders as a broken row. A combo
    /// is one line, so such an item is not a binding.
    @Test("an escape-decoded newline does not become a multi-line binding")
    func newlineEscapeRejected() {
        // Built by concatenation so the backslash-n stays two characters in the
        // TOML text. Inside a `"""` literal it would be a real newline, which
        // splits the statement and turns this into a truncated-document case
        // rather than an escape case.
        let backslash = "\\"
        let toml = "[keys]\n"
            + "prefix = [\"a" + backslash + "nb\", \"ctrl+a\"]\n"
            + "new_tab = \"prefix+t\""
        let binding = KeybindingProfile.binding(for: "prefix", in: toml)
        // What must not happen is a newline in the displayed value.
        #expect(binding?.contains("\n") != true)
        #expect(binding?.contains("ctrl+a") == true)
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

    /// A multi-line array is legal TOML and is what a human editing the config
    /// produces. Splitting on newlines first dropped the whole binding, which
    /// reads as "my config was ignored" — the exact complaint this panel exists
    /// to answer.
    @Test("a multi-line array binding is not dropped")
    func multiLineArray() {
        let toml = """
        [keys]
        prefix = [
        "ctrl+a",
        "alt+a"
        ]
        new_tab = "prefix+t"
        """
        let entries = KeybindingProfile.entries(in: toml)
        #expect(entries.count == 2)
        #expect(KeybindingProfile.binding(for: "prefix", in: toml) == "ctrl+a / alt+a")
        #expect(KeybindingProfile.binding(for: "new_tab", in: toml) == "prefix+t")
    }

    /// A keybinding can legitimately *be* the literal `[`, and counting it as an
    /// opening bracket would make the parser wait for a closer that never comes —
    /// swallowing every binding after it.
    @Test("a bracket inside a quoted binding is not a bracket")
    func bracketInsideString() {
        let toml = """
        [keys]
        split_vertical = "prefix+["
        new_tab = "prefix+t"
        """
        let entries = KeybindingProfile.entries(in: toml)
        #expect(entries.count == 2)
        #expect(KeybindingProfile.binding(for: "split_vertical", in: toml) == "prefix+[")
    }

    /// `key = "a\"b"` is legal TOML. The first parser rejected any value
    /// containing an inner quote, which turned a correct config into a missing
    /// row.
    @Test("an escaped quote inside a binding is resolved, not rejected")
    func escapedQuote() {
        // Built by concatenation so the escape stays a single backslash-then-quote
        // in the TOML text, which is what the daemon writes for a literal quote.
        let escapedQuote = #"custom = "a\"b""#
        let toml = "[keys]\n" + escapedQuote + "\n" + #"new_tab = "prefix+t""#
        #expect(KeybindingProfile.binding(for: "custom", in: toml) == "a\"b")
        #expect(KeybindingProfile.binding(for: "new_tab", in: toml) == "prefix+t")
    }

    /// A document ending mid-array must still contribute the bindings it did
    /// have. The truncated array itself is dropped (there is no way to know what
    /// it contained), but everything read before it survives.
    @Test("a truncated multi-line array does not lose earlier bindings")
    func truncatedArray() {
        let toml = """
        [keys]
        new_tab = "prefix+t"
        next_tab = "prefix+n"
        prefix = [
        "ctrl+a"
        """
        let entries = KeybindingProfile.entries(in: toml)
        #expect(entries.count == 2)
        #expect(KeybindingProfile.binding(for: "new_tab", in: toml) == "prefix+t")
        #expect(KeybindingProfile.binding(for: "next_tab", in: toml) == "prefix+n")
        #expect(KeybindingProfile.binding(for: "prefix", in: toml) == nil)
    }

    /// An unclosed array makes the rest of the document part of that array.
    ///
    /// This used to assert the opposite (skip the `[` line, keep `new_tab`), and
    /// that expectation was wrong: `prefix = ["ctrl+a"` followed by a new
    /// statement is a **TOML syntax error**, so the daemon never produces it. What
    /// this parser actually faces is a truncated document — a cut-off write — and
    /// once the brackets are unbalanced there is no way to tell a continuation
    /// from a new key. Treating the rest as array contents is the only
    /// interpretation that is not a guess, and it cannot corrupt a well-formed
    /// document.
    @Test("an unclosed array absorbs the rest instead of guessing")
    func unclosedArrayAbsorbs() {
        let toml = """
        [keys]
        prefix = ["ctrl+a"
        new_tab = "prefix+t"
        """
        let entries = KeybindingProfile.entries(in: toml)
        // Nothing is invented: neither the truncated array nor the text it
        // swallowed becomes a binding.
        #expect(entries.isEmpty)
    }
}
