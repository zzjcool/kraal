// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  AggregatedAgent.swift
//  KraalUI
//
//  One agent row, with the machine it came from.
//
//  The agents pane lists every machine's agents, not just the connected one
//  (`src/client/shell/endpoint_agents.rs:132-174`). Two machines count their pane
//  ids independently, so "which agent is this" needs the endpoint as well — hence a
//  type rather than a bare `ClientShellAgent`.
//

import Foundation
import KraalProtocol

/// An agent plus the machine it belongs to.
public struct AggregatedAgent: Identifiable, Equatable, Sendable {
    /// Unique across machines. A pane id alone is not: two daemons both call their
    /// first pane `w1:p1`.
    public var id: String { "\(endpointID)/\(agent.paneId)" }

    public let endpointID: String
    public let machineLabel: String
    public let agent: ClientShellAgent
    /// The machine's snapshot is from a dropped connection.
    ///
    /// Upstream keeps such rows on screen and dims them (`agent_sidebar.rs`), rather
    /// than making an agent disappear because the SSH link blinked.
    public let stale: Bool

    /// When this agent last changed, on a scale shared by every machine.
    ///
    /// Not `agent.stateChangeSeq`: that counts each daemon's own changes from zero, so
    /// two machines' numbers are unrelated. See `AgentRecency`.
    public let recency: UInt64

    /// This agent's workspace, from **its own** machine's snapshot.
    ///
    /// Looked up here rather than by the view, because only the snapshot knows: the
    /// store's `workspaces` / `tabs` describe the *selected* machine, so a view that
    /// looked them up there found nothing for every other machine and drew a row with
    /// only a machine name — measured against a screenshot of the upstream client,
    /// which shows `machine · workspace` for rows on every machine.
    public let workspace: ClientShellWorkspace?
    /// This agent's tab, from its own machine's snapshot. See `workspace`.
    public let tab: ClientShellTab?

    public init(
        endpointID: String,
        machineLabel: String,
        agent: ClientShellAgent,
        stale: Bool,
        recency: UInt64 = 0,
        workspace: ClientShellWorkspace? = nil,
        tab: ClientShellTab? = nil
    ) {
        self.endpointID = endpointID
        self.machineLabel = machineLabel
        self.agent = agent
        self.stale = stale
        self.recency = recency
        self.workspace = workspace
        self.tab = tab
    }
}

/// How the agents pane is ordered.
///
/// Mirrors upstream's `AgentPanelSortConfig` (`src/config/model.rs:97-102`); the
/// default is `spaces`, which is the daemon's own `agent_order`.
public enum AgentPanelSort: String, Sendable, CaseIterable {
    case spaces
    case priority

    public static let `default`: AgentPanelSort = .spaces

    /// The label shown on the agents header — and, unlike a menu, it states which
    /// mode is active.
    ///
    /// Upstream's words are `"grouped"` and `"priority"` (`agent_sidebar.rs:122-125`);
    /// they are matched here so a screenshot of either client reads the same.
    public var shortTitle: String {
        switch self {
        case .spaces: "grouped"
        case .priority: "priority"
        }
    }

    /// The mode a click on the header label selects.
    ///
    /// A two-way toggle, matching upstream (`mouse.rs:2025-2032`): there is no third
    /// mode to cycle through, so a click always changes what the list looks like.
    public var toggled: AgentPanelSort {
        switch self {
        case .spaces: .priority
        case .priority: .spaces
        }
    }

    /// Longer description for the tooltip.
    public var title: String {
        switch self {
        case .spaces: "Grouped by space"
        case .priority: "Priority (blocked first)"
        }
    }
}
