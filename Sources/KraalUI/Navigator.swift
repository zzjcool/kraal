// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  Navigator.swift
//  Kraal
//
//  The "Go To" index: every pane, tab and workspace the user can jump to, across
//  every connected machine, as a flat searchable list.
//
//  Upstream builds the same thing from `client_navigator_rows(&self.endpoints,
//  &self.active_endpoint_id, &navigator)` (`client/shell/overlay_input.rs:200`),
//  i.e. from *all* endpoints and not only the active one. That is the part that
//  makes it a navigator rather than a sidebar filter: with six machines
//  configured, "go to the pane running the tests" has to be answerable without
//  knowing which machine it is on.
//
//  This client had no equivalent — the sidebar can only be clicked — so the
//  index is built here as a pure function over snapshots. Pure because the
//  interesting rules are all about *ordering and matching*, and a sidebar click
//  is not something a test can assert:
//
//  - the current pane must be findable (it is what the user is looking at);
//  - a pane the user named ranks above one they did not, whatever the machine;
//  - the active machine wins ties, so "next pane" does not jump machines.
//
//  Deliberately not here: no fuzzy scoring beyond case-insensitive substring,
//  and no ranking by recency. Both would need state that outlives the snapshot,
//  and the honest first step is a navigator whose ordering can be explained in
//  one sentence.
//

import Foundation
import KraalProtocol

/// One thing the navigator can jump to.
public struct NavigatorTarget: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case pane
        case tab
        case workspace
    }

    public var kind: Kind
    /// Stable across snapshots: machine + kind + id.
    public var id: String
    /// What the user types against and reads.
    public var title: String
    /// The machine this target lives on.
    public var machineLabel: String
    public var machineId: String
    /// The ids needed to focus it, in focus order.
    public var workspaceId: String
    public var tabId: String
    public var paneId: String?
    /// Whether this is where the user already is on the active machine.
    public var isCurrent: Bool

    public init(
        kind: Kind,
        id: String,
        title: String,
        machineLabel: String,
        machineId: String,
        workspaceId: String,
        tabId: String,
        paneId: String? = nil,
        isCurrent: Bool = false
    ) {
        self.kind = kind
        self.id = id
        self.title = title
        self.machineLabel = machineLabel
        self.machineId = machineId
        self.workspaceId = workspaceId
        self.tabId = tabId
        self.paneId = paneId
        self.isCurrent = isCurrent
    }
}

/// One machine's contribution: its snapshot plus the ids needed to name it.
public struct NavigatorMachine: Sendable {
    public var id: String
    public var label: String
    public var snapshot: ClientShellSnapshot?
    /// Whether this is the machine whose panes are on screen.
    public var isActive: Bool

    public init(
        id: String,
        label: String,
        snapshot: ClientShellSnapshot?,
        isActive: Bool
    ) {
        self.id = id
        self.label = label
        self.snapshot = snapshot
        self.isActive = isActive
    }
}

public enum Navigator {
    /// Every jumpable target, best first.
    ///
    /// Ordering is defined exactly:
    ///
    /// 1. the active machine's current pane (so Enter with no query is a no-op
    ///    rather than a surprise jump);
    /// 2. panes, because a pane is what "go to" almost always means;
    /// 3. tabs, then workspaces, as progressively wider targets;
    /// 4. within a kind: the active machine first, then machines in the order
    ///    given (which is the user's machine order), then the daemon's own id
    ///    order.
    ///
    /// Machines with no snapshot contribute nothing: a machine that has never
    /// connected has no panes to jump to, and inventing rows for it would make
    /// Enter land in an empty window.
    public static func targets(for machines: [NavigatorMachine]) -> [NavigatorTarget] {
        var panes: [NavigatorTarget] = []
        var tabs: [NavigatorTarget] = []
        var workspaces: [NavigatorTarget] = []

        for machine in machines {
            guard let snapshot = machine.snapshot else { continue }
            for pane in snapshot.panes {
                // The agent row carries the program's terminal title; the pane
                // record does not (`ClientShellPane` has no `terminal_title`), so
                // an unnamed pane with a running TUI is only findable by its
                // title if it comes from there.
                let agent = snapshot.agents.first { $0.paneId == pane.paneId }
                panes.append(NavigatorTarget(
                    kind: .pane,
                    id: "\(machine.id)/pane/\(pane.paneId)",
                    title: paneTitle(pane, agent: agent, fallback: pane.paneId),
                    machineLabel: machine.label,
                    machineId: machine.id,
                    workspaceId: pane.workspaceId,
                    tabId: pane.tabId,
                    paneId: pane.paneId,
                    isCurrent: machine.isActive && pane.focused
                ))
            }
            for tab in snapshot.tabs {
                tabs.append(NavigatorTarget(
                    kind: .tab,
                    id: "\(machine.id)/tab/\(tab.tabId)",
                    title: tabTitle(tab),
                    machineLabel: machine.label,
                    machineId: machine.id,
                    workspaceId: tab.workspaceId,
                    tabId: tab.tabId,
                    isCurrent: machine.isActive && tab.tabId == snapshot.focusedTabId
                ))
            }
            for workspace in snapshot.workspaces {
                workspaces.append(NavigatorTarget(
                    kind: .workspace,
                    id: "\(machine.id)/workspace/\(workspace.workspaceId)",
                    title: workspaceTitle(workspace),
                    machineLabel: machine.label,
                    machineId: machine.id,
                    workspaceId: workspace.workspaceId,
                    // Focusing a workspace does not need a tab; the store derives
                    // it. Empty rather than the focused tab: that tab belongs to
                    // whichever workspace was focused when the snapshot was taken.
                    tabId: "",
                    isCurrent: machine.isActive && workspace.workspaceId == snapshot.focusedWorkspaceId
                ))
            }
        }

        // `isCurrent` first, then active-machine targets, then keep arrival order.
        func rank(_ list: [NavigatorTarget]) -> [NavigatorTarget] {
            list.enumerated()
                .sorted { left, right in
                    if left.element.isCurrent != right.element.isCurrent {
                        return left.element.isCurrent
                    }
                    let leftActive = machines.first { $0.id == left.element.machineId }?.isActive == true
                    let rightActive = machines.first { $0.id == right.element.machineId }?.isActive == true
                    if leftActive != rightActive { return leftActive }
                    return left.offset < right.offset
                }
                .map(\.element)
        }

        return rank(panes) + rank(tabs) + rank(workspaces)
    }

    /// The targets matching `query`, case-insensitively.
    ///
    /// An empty query returns everything: the navigator opens showing where you
    /// are, which is also how you discover what the machine names are.
    ///
    /// Matching is against the title *and* the machine label, so "vps" finds
    /// everything on vps-01 and "vim" finds the pane running it. Substring rather
    /// than prefix: pane titles are usually `dir — program`, and the program name
    /// is the interesting half.
    public static func filtered(_ targets: [NavigatorTarget], query: String) -> [NavigatorTarget] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return targets }
        return targets.filter {
            $0.title.lowercased().contains(needle)
                || $0.machineLabel.lowercased().contains(needle)
        }
    }

    // MARK: - Titles

    /// A pane's title, in the order the daemon's own UI uses.
    ///
    /// `label` is what the user set (rename), `terminal_title` is what the
    /// program reported, `foreground_cwd`'s last component is the fallback for a
    /// plain shell that reported nothing. Falling straight to the pane id would
    /// make every unnamed pane read `w1:p3`, which is unsearchable.
    static func paneTitle(
        _ pane: ClientShellPane,
        agent: ClientShellAgent?,
        fallback: String
    ) -> String {
        if let label = nonEmpty(pane.label) { return label }
        // `terminal_title_stripped` first: it is the same title with the escape
        // sequences removed, which is what a searchable string needs.
        if let title = nonEmpty(agent?.terminalTitleStripped) ?? nonEmpty(agent?.terminalTitle) {
            return title
        }
        if let cwd = nonEmpty(pane.foregroundCwd) ?? nonEmpty(pane.cwd) {
            return (cwd as NSString).lastPathComponent
        }
        return fallback
    }

    static func tabTitle(_ tab: ClientShellTab) -> String {
        if let label = nonEmpty(tab.label) { return label }
        return "tab \(tab.number)"
    }

    static func workspaceTitle(_ workspace: ClientShellWorkspace) -> String {
        if let label = nonEmpty(workspace.label) { return label }
        return "w\(workspace.number)"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
