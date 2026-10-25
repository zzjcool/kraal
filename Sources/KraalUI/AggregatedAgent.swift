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

    public init(
        endpointID: String,
        machineLabel: String,
        agent: ClientShellAgent,
        stale: Bool
    ) {
        self.endpointID = endpointID
        self.machineLabel = machineLabel
        self.agent = agent
        self.stale = stale
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

    /// Label for the sort control.
    public var title: String {
        switch self {
        case .spaces: "Daemon order"
        case .priority: "Priority (blocked first)"
        }
    }
}
