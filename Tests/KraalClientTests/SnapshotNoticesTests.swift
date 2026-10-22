// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Tests for the snapshot fields that used to be decoded and dropped.
//
// The bug this guards is not "a field was unused" — it is that a broken config
// file failed *silently*. `config_diagnostic` arrived, was decoded, and went
// nowhere, so a user with a typo in `config.toml` saw a perfectly working pane
// with every setting in that file ignored. That is not diagnosable from the
// outside, which is why it needs a test rather than a screenshot.
//
// Every snapshot here is built by **decoding JSON**, not by calling a memberwise
// initialiser: the snapshot types are `Decodable`-only on purpose, and going
// through JSON means a renamed key cannot silently keep these tests passing.
//

import Foundation
import Testing

@testable import KraalProtocol
@testable import KraalUI

@Suite("Snapshot notices")
struct SnapshotNoticesTests {
    /// Decodes a snapshot from JSON with `overrides` merged over a minimal base.
    ///
    /// `overrides` is raw JSON text so a test can set exactly one wire field and
    /// leave the rest at their defaults — the same way a real snapshot arrives.
    private func snapshot(_ overrides: String = "") throws -> ClientShellSnapshot {
        let base = """
        {
          "boot_id": "b1",
          "revision": 1,
          "update_install_command": "",
          "latest_release_notes_available": false,
          "integration_updates_available": false,
          "worktree_directory": "",
          "tab_bar_right": [],
          "tab_bar_right_separator": " ",
          "agent_order": [],
          "workspaces": [], "tabs": [], "panes": [], "agents": [], "commands": []
        }
        """
        guard !overrides.isEmpty else {
            return try JSONDecoder().decode(ClientShellSnapshot.self, from: Data(base.utf8))
        }
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(base.utf8)) as? [String: Any]
        )
        let extra = try #require(
            JSONSerialization.jsonObject(with: Data(overrides.utf8)) as? [String: Any]
        )
        object.merge(extra) { _, new in new }
        let merged = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(ClientShellSnapshot.self, from: merged)
    }

    // MARK: config diagnostic

    /// The whole point: a config problem must produce a notice, and it must be
    /// marked as an issue so the status bar draws it in the warning colour.
    @Test("a config diagnostic becomes an issue notice")
    func configDiagnosticBecomesNotice() throws {
        let snapshot = try snapshot(#"{"config_diagnostic": "ui.sidebar.rules: unknown field when"}"#)
        let notices = SnapshotNotices.notices(in: snapshot)
        #expect(notices.count == 1)
        #expect(notices.first?.kind == .configDiagnostic)
        #expect(notices.first?.kind.isIssue == true)
        #expect(notices.first?.detail == "ui.sidebar.rules: unknown field when")
    }

    /// A defaulted-to-`""` field means "healthy". An empty yellow banner would be
    /// worse than none, so it must not produce a notice.
    @Test("an empty diagnostic is not a notice")
    func emptyDiagnosticIgnored() throws {
        let snapshot = try snapshot(#"{"config_diagnostic": "   "}"#)
        #expect(SnapshotNotices.notices(in: snapshot).isEmpty)
    }

    @Test("the status bar summary is one line")
    func summaryIsSingleLine() throws {
        let snapshot = try snapshot(
            #"{"config_diagnostic": "line one is fine\nline two\nline three"}"#
        )
        let notice = try #require(SnapshotNotices.statusBarNotice(in: snapshot))
        #expect(!notice.summary.contains("\n"))
        #expect(notice.summary.contains("line one"))
        #expect(notice.detail?.contains("line three") == true)
    }

    /// CRLF, not just LF.
    ///
    /// In Swift `"\r\n"` is a *single* Character, so `split(separator: "\n")` never
    /// matches it and a Windows-written config's diagnostic stayed on one
    /// "line" with embedded newlines. `.lineLimit(1)` hides that visually, which
    /// is exactly why this needs an assertion rather than a screenshot.
    @Test("a CRLF diagnostic still summarises to one line")
    func crlfDiagnosticIsOneLine() throws {
        let snapshot = try snapshot(
            #"{"config_diagnostic": "line one\r\nline two\r\nline three"}"#
        )
        let notice = try #require(SnapshotNotices.statusBarNotice(in: snapshot))
        // The buggy version returned `"line one\r\nline two\r\nline three"` — a
        // single Swift Character per line break means neither `contains("\n")`
        // nor `contains("\r")` is true for it, so those two assertions passed
        // *while the summary still contained line breaks*. Asserting on
        // `isNewline` covers CR, LF and CRLF uniformly, which is the property
        // that actually matters.
        let hasLineBreak = notice.summary.contains { $0.isNewline }
        #expect(!hasLineBreak)
        #expect(notice.summary.contains("line one"))
        #expect(!notice.summary.contains("line two"))
        #expect(notice.detail?.contains("line three") == true)
    }

    /// A pathological single line would push everything else out of the bar.
    @Test("a long diagnostic line is truncated in the summary, kept in the detail")
    func longLineTruncated() throws {
        let long = String(repeating: "x", count: 200)
        let snapshot = try snapshot(#"{"config_diagnostic": "\#(long)"}"#)
        let notice = try #require(SnapshotNotices.statusBarNotice(in: snapshot))
        #expect(notice.summary.count < 100)
        #expect(notice.detail == long)
    }

    // MARK: ordering

    /// A config problem breaks what the user is trying to do; an available update
    /// does not. The more urgent one wins the single status-bar slot.
    ///
    /// This asserts the *notice list order* as well as the status-bar pick,
    /// because changing `statusBarNotice` from `first` to `last` still singled
    /// out a "config" notice in the earlier version of this test (the snapshot
    /// had no other notice to lose to). That made the test unable to fail for the
    /// reason it was written.
    @Test("a config diagnostic outranks every other notice")
    func configOutranksUpdate() throws {
        let snapshot = try snapshot("""
        {
          "config_diagnostic": "broken",
          "update_available": "0.9.6",
          "integration_updates_available": true,
          "release_notes": {"version": "0.9.6", "body": "notes", "preview": false}
        }
        """)
        let kinds = SnapshotNotices.notices(in: snapshot).map(\.kind)
        #expect(kinds.first == .configDiagnostic)
        #expect(kinds.count > 1)

        let notice = try #require(SnapshotNotices.statusBarNotice(in: snapshot))
        #expect(notice.kind == .configDiagnostic)
        #expect(notice.id == "config-diagnostic")
        #expect(SnapshotNotices.isIssue(in: snapshot))
    }

    /// The update slot is second: with the diagnostic gone, the update is what
    /// the status bar should show, not the announcement behind it.
    @Test("an update outranks notes and integrations")
    func updateOutranksTheRest() throws {
        let snapshot = try snapshot("""
        {
          "update_available": "0.9.6",
          "integration_updates_available": true,
          "release_notes": {"version": "0.9.6", "body": "notes", "preview": false}
        }
        """)
        let kinds = SnapshotNotices.notices(in: snapshot).map(\.kind)
        #expect(kinds.first == .update)
        #expect(SnapshotNotices.statusBarNotice(in: snapshot)?.kind == .update)
    }

    /// An update is informational: it must not be drawn as a problem.
    @Test("an available update is not an issue")
    func updateIsNotAnIssue() throws {
        let snapshot = try snapshot(#"{"update_available": "0.9.6"}"#)
        #expect(SnapshotNotices.isIssue(in: snapshot) == false)
        #expect(SnapshotNotices.statusBarNotice(in: snapshot)?.kind == .update)
    }

    /// The install command is what makes the notice actionable, and the daemon
    /// owns how its own binary is installed — so it is carried verbatim.
    @Test("the update notice carries the install command")
    func updateCarriesInstallCommand() throws {
        let snapshot = try snapshot(
            #"{"update_available": "0.9.6", "update_install_command": "brew upgrade herdr"}"#
        )
        let notice = try #require(SnapshotNotices.statusBarNotice(in: snapshot))
        #expect(notice.detail == "brew upgrade herdr")
    }

    // MARK: other fields

    @Test("release notes and announcements both surface")
    func releaseNotesAndAnnouncement() throws {
        let snapshot = try snapshot("""
        {
          "release_notes": {"version": "0.9.6", "body": "### Changed\\n- thing", "preview": false},
          "product_announcement": {
            "version": "0.9.6", "id": "a1", "title": "Hello",
            "body": "Announcement body", "preview": false
          }
        }
        """)
        // Order is the contract, not membership: with `contains` alone, swapping
        // the announcement and release-note blocks left every test green, so the
        // status bar could silently start showing the less urgent one.
        let kinds = SnapshotNotices.notices(in: snapshot).map(\.kind)
        #expect(kinds == [.releaseNotes, .announcement])
    }

    /// The tail of the priority list, pinned as a whole.
    @Test("notes outrank announcements, which outrank integrations")
    func tailOrderIsPinned() throws {
        let snapshot = try snapshot("""
        {
          "release_notes": {"version": "0.9.6", "body": "notes", "preview": false},
          "product_announcement": {
            "version": "0.9.6", "id": "a1", "title": "Hello",
            "body": "Announcement body", "preview": false
          },
          "integration_updates_available": true
        }
        """)
        #expect(SnapshotNotices.notices(in: snapshot).map(\.kind)
            == [.releaseNotes, .announcement, .integrations])
        #expect(SnapshotNotices.statusBarNotice(in: snapshot)?.kind == .releaseNotes)
    }

    /// An announcement title is truncated like every other summary.
    @Test("a long announcement title does not own the status bar")
    func longAnnouncementTitleTruncated() throws {
        let long = String(repeating: "y", count: 200)
        let snapshot = try snapshot("""
        {"product_announcement": {
          "version": "1", "id": "x", "title": "\(long)", "body": "b", "preview": false
        }}
        """)
        let notice = try #require(SnapshotNotices.statusBarNotice(in: snapshot))
        #expect(notice.summary.count < 100)
    }

    @Test("integration updates and empty bodies are handled")
    func integrationUpdates() throws {
        let withIntegrations = try snapshot(#"{"integration_updates_available": true}"#)
        #expect(SnapshotNotices.notices(in: withIntegrations).map(\.kind) == [.integrations])

        // An announcement with no body is not worth a row.
        let blankBody = try snapshot("""
        {"product_announcement": {
          "version": "1", "id": "x", "title": "t", "body": "  ", "preview": false
        }}
        """)
        #expect(!SnapshotNotices.notices(in: blankBody).map(\.kind).contains(.announcement))
    }

    /// `worktree_directory` defaults to `""` when absent, and an empty string must
    /// read as "not configured" rather than "the root directory".
    @Test("an empty worktree directory reads as not configured")
    func worktreeDirectory() throws {
        #expect(SnapshotNotices.worktreeDirectory(in: try snapshot()) == nil)
        let configured = try snapshot(#"{"worktree_directory": "/Users/me/worktrees"}"#)
        #expect(SnapshotNotices.worktreeDirectory(in: configured) == "/Users/me/worktrees")
    }

    @Test("server keybindings are exposed for the shortcut help")
    func serverKeybindings() throws {
        #expect(SnapshotNotices.serverKeybindings(in: try snapshot()) == nil)
        let configured = try snapshot(#"{"server_keybindings_toml": "[[keys]]\nkey = \"d\""}"#)
        #expect(SnapshotNotices.serverKeybindings(in: configured)?.contains("keys") == true)
    }

    /// `agent_view_label` is the label of the active **filter**, not a per-agent
    /// name (`server/client_shell.rs:180-183`). Getting this wrong would either
    /// mislabel rows or hide the one piece of context a filtered list cannot
    /// convey.
    @Test("the agent view filter label is reported separately from rows")
    func agentViewFilterLabel() throws {
        #expect(SnapshotNotices.agentViewFilterLabel(in: try snapshot()) == nil)
        let filtered = try snapshot(#"{"agent_view_label": "filtered"}"#)
        #expect(SnapshotNotices.agentViewFilterLabel(in: filtered) == "filtered")
    }

    /// Rows follow `agent_order`, and a pane in the order with no agent row is not
    /// an agent — showing it would invent a row the daemon left out.
    @Test("agent rows follow the daemon's order and skip unknown panes")
    func agentRowsFollowOrder() throws {
        let snapshot = try snapshot("""
        {
          "agent_order": ["w1:p2", "w1:ghost", "w1:p1"],
          "agents": [
            {"pane_id": "w1:p1", "name": "alpha", "agent_status": "unknown",
             "state_change_seq": 0, "state_labels": [], "tokens": [], "focused": false},
            {"pane_id": "w1:p2", "name": "beta", "agent_status": "unknown",
             "state_change_seq": 0, "state_labels": [], "tokens": [], "focused": false}
          ]
        }
        """)
        let rows = SnapshotNotices.agentRows(in: snapshot)
        #expect(rows.map(\.paneId) == ["w1:p2", "w1:p1"])
        #expect(rows.map(\.label) == ["beta", "alpha"])
    }

    /// A missing snapshot is not an error: the first frame arrives after the
    /// welcome, and these helpers run before that.
    @Test("no snapshot produces no notices")
    func nilSnapshotIsSafe() {
        #expect(SnapshotNotices.notices(in: nil).isEmpty)
        #expect(SnapshotNotices.statusBarNotice(in: nil) == nil)
        #expect(SnapshotNotices.isIssue(in: nil) == false)
        #expect(SnapshotNotices.agentRows(in: nil).isEmpty)
        #expect(SnapshotNotices.serverKeybindings(in: nil) == nil)
        #expect(SnapshotNotices.worktreeDirectory(in: nil) == nil)
        #expect(SnapshotNotices.agentViewFilterLabel(in: nil) == nil)
    }
}
