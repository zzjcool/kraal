// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  AgentAggregation.swift
//  KraalUI
//
//  Flattening several machines' agents into one list.
//
//  Split out from `AppStore` so the rules are testable without a live connection:
//  the interesting parts are "which rows survive" and "whose focus counts", not the
//  transport.
//

import Foundation
import KraalProtocol

/// One machine's agents, as the store holds them.
public struct AgentAggregationSource: Equatable, Sendable {
    public let endpointID: String
    public let label: String
    public let isConnected: Bool
    public let snapshot: ClientShellSnapshot

    public init(
        endpointID: String,
        label: String,
        isConnected: Bool,
        snapshot: ClientShellSnapshot
    ) {
        self.endpointID = endpointID
        self.label = label
        self.isConnected = isConnected
        self.snapshot = snapshot
    }
}

public enum AgentAggregation {
    /// Flattens every machine's agents into the list the pane draws.
    ///
    /// Rules, each mirroring upstream (`src/client/shell/endpoint_agents.rs:132-174`):
    ///
    /// - Every machine contributes, not only the selected one.
    /// - `agentOrder` is honoured per machine; an empty order falls back to the
    ///   snapshot's own array.
    /// - `focused` survives only on the selected machine. Two daemons each report a
    ///   focused pane, and honouring both highlights two rows at once.
    /// - A machine whose connection dropped keeps its rows, marked `stale`, rather
    ///   than having them vanish.
    public static func rows(
        _ sources: [AgentAggregationSource],
        activeEndpointID: String,
        sort: AgentPanelSort = .default
    ) -> [AggregatedAgent] {
        var result: [AggregatedAgent] = []
        for source in sources {
            let isActive = source.endpointID == activeEndpointID
            for agent in orderedAgents(in: source.snapshot, isActive: isActive, sort: sort) {
                result.append(AggregatedAgent(
                    endpointID: source.endpointID,
                    machineLabel: source.label,
                    agent: agent,
                    stale: !source.isConnected
                ))
            }
        }
        return result
    }

    /// Applies `sort` unless a view label is present.
    ///
    /// Upstream returns `agent_order` untouched when `agent_view_label` is set
    /// (`src/client/shell/agent_sidebar.rs:23-31`): the label means "this list is a
    /// filtered view", and re-sorting it would fight the order the filter implies.
    static func sorted(
        _ agents: [ClientShellAgent],
        sort: AgentPanelSort,
        hasViewLabel: Bool
    ) -> [ClientShellAgent] {
        guard sort == .priority, !hasViewLabel else { return agents }
        // `stateChangeSeq` breaks ties the same way upstream does (`agent_sidebar.rs:
        // 38-45`): within one status, the most recently changed agent comes first, so
        // a row that just went `blocked` does not sit behind one that went `blocked`
        // an hour ago.
        //
        // Sorting is stable in Swift, so equal `(priority, seq)` pairs keep the
        // daemon's order rather than being shuffled.
        return agents.sorted { (left: ClientShellAgent, right: ClientShellAgent) -> Bool in
            if left.agentStatus.priority != right.agentStatus.priority {
                return left.agentStatus.priority > right.agentStatus.priority
            }
            return left.stateChangeSeq > right.stateChangeSeq
        }
    }

    private static func orderedAgents(
        in snapshot: ClientShellSnapshot,
        isActive: Bool,
        sort: AgentPanelSort
    ) -> [ClientShellAgent] {
        let byPane = Dictionary(
            uniqueKeysWithValues: snapshot.agents.map { ($0.paneId, $0) }
        )
        let daemonOrder = snapshot.agentOrder.isEmpty
            ? snapshot.agents
            : snapshot.agentOrder.compactMap { byPane[$0] }
        let ordered = sorted(daemonOrder, sort: sort, hasViewLabel: snapshot.agentViewLabel != nil)
        guard !isActive else { return ordered }
        return ordered.map { agent in
            guard agent.focused else { return agent }
            var cleared = agent
            cleared.focused = false
            return cleared
        }
    }
}
