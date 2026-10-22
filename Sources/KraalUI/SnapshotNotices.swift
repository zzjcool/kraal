// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  SnapshotNotices.swift
//  Kraal
//
//  Turns the snapshot fields that describe the *daemon's own condition* into
//  something the window can show.
//
//  Why these were unused, and what "use" means here: `ClientShellSnapshot`
//  carries eleven fields this client decoded and ignored — a config diagnostic,
//  an available update (plus the command that installs it), release notes, a
//  product announcement, pending integration updates, the worktree directory, the
//  server's keybinding TOML, and agent view labels. They are all **information
//  the daemon already rendered**, so "using" them means surfacing them, not
//  recomputing them.
//
//  This type decides *what is worth interrupting the user for*, in one place, as
//  a pure value. The views only render what it says. Upstream has the same
//  division (`ui/status.rs` renders a config diagnostic banner from state it was
//  handed) and it is the reason these fields are testable at all.
//
//  Deliberately not done here: no new modal panels, no update banners on launch
//  for `latestReleaseNotesAvailable` alone, and no `productAnnouncement` popup.
//  Those are policy decisions that need a dismissal store to avoid nagging, and
//  the honest first step is a read-only surface the user can look at when they
//  want to. `docs/GAP-VS-HERDR.md` calls the opposite mistake "adding UI to make
//  a warning go away".
//

import Foundation
import KraalProtocol

/// A single thing the daemon wants the user to know about.
public struct SnapshotNotice: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        /// The daemon's config file has a problem (`config_diagnostic`).
        case configDiagnostic
        /// A newer daemon is available (`update_available`).
        case update
        /// The daemon has release notes for a version (`release_notes`).
        case releaseNotes
        /// A product announcement (`product_announcement`).
        case announcement
        /// Integration manifest updates are pending.
        case integrations

        /// Whether this kind is the user's problem right now.
        ///
        /// A config diagnostic stops their configuration from working, so it is
        /// an issue. An available update is not: the daemon runs fine today.
        public var isIssue: Bool { self == .configDiagnostic }
    }

    public var kind: Kind
    public var id: String
    /// One line for a status bar.
    public var summary: String
    /// The full text, when the daemon provided one.
    public var detail: String?

    public init(kind: Kind, id: String, summary: String, detail: String? = nil) {
        self.kind = kind
        self.id = id
        self.summary = summary
        self.detail = detail
    }
}

public enum SnapshotNotices {
    /// Every notice worth showing, most urgent first.
    ///
    /// Pure: same snapshot, same notices. That is what lets the ordering and the
    /// "don't invent a notice for an empty string" rules be asserted.
    public static func notices(in snapshot: ClientShellSnapshot?) -> [SnapshotNotice] {
        guard let snapshot else { return [] }
        var found: [SnapshotNotice] = []

        // Empty means "no diagnostic", not "a diagnostic that says nothing".
        // The daemon sends `None` for the healthy case, but a defaulted field
        // decodes to `""` and an empty yellow banner is worse than none.
        if let diagnostic = trimmed(snapshot.configDiagnostic) {
            found.append(SnapshotNotice(
                kind: .configDiagnostic,
                id: "config-diagnostic",
                summary: "config: \(firstLine(diagnostic))",
                detail: diagnostic
            ))
        }

        if let version = trimmed(snapshot.updateAvailable) {
            found.append(SnapshotNotice(
                kind: .update,
                id: "update-\(version)",
                summary: "herdr \(version) available",
                // The install command is what makes the notice actionable; it is
                // shown verbatim because the daemon owns how its own binary is
                // installed.
                detail: trimmed(snapshot.updateInstallCommand)
            ))
        }

        if let notes = snapshot.releaseNotes, let body = trimmed(notes.body) {
            found.append(SnapshotNotice(
                kind: .releaseNotes,
                id: "release-notes-\(notes.version)",
                summary: "release notes: \(notes.version)",
                detail: body
            ))
        }

        if let announcement = snapshot.productAnnouncement, let body = trimmed(announcement.body) {
            found.append(SnapshotNotice(
                kind: .announcement,
                id: "announcement-\(announcement.id)",
                summary: trimmed(announcement.title) ?? "announcement",
                detail: body
            ))
        }

        if snapshot.integrationUpdatesAvailable {
            found.append(SnapshotNotice(
                kind: .integrations,
                id: "integration-updates",
                summary: "integration updates available"
            ))
        }

        return found
    }

    /// The one notice the status bar shows, or `nil` when there is nothing.
    ///
    /// A config diagnostic wins even when an update is also available: one of
    /// them is breaking the user's setup and the other is not.
    public static func statusBarNotice(in snapshot: ClientShellSnapshot?) -> SnapshotNotice? {
        notices(in: snapshot).first
    }

    /// Whether the status bar should draw it as a problem rather than a note.
    public static func isIssue(in snapshot: ClientShellSnapshot?) -> Bool {
        statusBarNotice(in: snapshot)?.kind.isIssue ?? false
    }

    /// `server_keybindings_toml`, when the daemon sent one.
    ///
    /// Kept separate from `notices`: it is not something to tell the user, it is
    /// a document another view reads (#38's shortcut help). Exposed here so the
    /// "is it usable" rule lives next to the other snapshot-field rules instead
    /// of being re-derived at the call site.
    public static func serverKeybindings(in snapshot: ClientShellSnapshot?) -> String? {
        trimmed(snapshot?.serverKeybindingsToml)
    }

    /// `worktree_directory`, normalised.
    ///
    /// The daemon always sends it (`decodeIfPresent` defaults it to `""`), so an
    /// empty string means "not configured", not "the root directory".
    public static func worktreeDirectory(in snapshot: ClientShellSnapshot?) -> String? {
        trimmed(snapshot?.worktreeDirectory)
    }

    /// Agent rows in the daemon's own order, named the daemon's way.
    ///
    /// `agent_order` is a list of pane ids in display order
    /// (`server/client_shell.rs:183-190`) and `agent_view_label` is *not* a
    /// per-agent name: it is the label of the active agent-view **filter**
    /// (`client_shell.rs:180-183`), e.g. "filtered". Both were decoded and
    /// ignored, so an agent list built from this client's own guess disagreed
    /// with the daemon about ordering, and nothing told the user their view was
    /// filtered.
    ///
    /// Returns the panes the order mentions, with whatever name is available.
    public static func agentRows(in snapshot: ClientShellSnapshot?) -> [(paneId: String, label: String)] {
        guard let snapshot else { return [] }
        var names: [String: String] = [:]
        for agent in snapshot.agents {
            if let name = trimmed(agent.name) ?? trimmed(agent.displayAgent) ?? trimmed(agent.agent) {
                names[agent.id] = name
            }
        }
        return snapshot.agentOrder.compactMap { paneId in
            // A pane in the order but with no agent row is not an agent; showing
            // it would invent a row the daemon deliberately left out.
            guard let label = names[paneId] else { return nil }
            return (paneId: paneId, label: label)
        }
    }

    /// The label of the active agent-view filter, when one is applied.
    ///
    /// Non-nil means the agent list on screen is filtered, which is the one piece
    /// of context a user cannot infer from the rows themselves.
    public static func agentViewFilterLabel(in snapshot: ClientShellSnapshot?) -> String? {
        trimmed(snapshot?.agentViewLabel)
    }

    // MARK: - Helpers

    private static func trimmed(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? text
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        // A single pathological line would push everything else out of the status
        // bar; the detail view carries the full text.
        return trimmedLine.count > 60 ? String(trimmedLine.prefix(60)) + "…" : trimmedLine
    }
}
