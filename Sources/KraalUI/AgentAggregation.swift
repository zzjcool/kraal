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
        sort: AgentPanelSort = .default,
        recency: AgentRecency = AgentRecency()
    ) -> [AggregatedAgent] {
        var result: [AggregatedAgent] = []
        for source in sources {
            let isActive = source.endpointID == activeEndpointID
            for agent in orderedAgents(in: source.snapshot, isActive: isActive) {
                result.append(AggregatedAgent(
                    endpointID: source.endpointID,
                    machineLabel: source.label,
                    agent: agent,
                    stale: !source.isConnected,
                    recency: recency.stamp(
                        endpointID: source.endpointID,
                        paneId: agent.paneId
                    )
                ))
            }
        }
        return sorted(result, sort: sort, hasViewLabel: sources.contains {
            $0.snapshot.agentViewLabel != nil
        })
    }

    /// Orders the *whole* list, across machines.
    ///
    /// Upstream sorts after flattening every endpoint's agents
    /// (`src/client/shell/aggregate_navigation.rs:161-184`), so a `blocked` agent on
    /// machine B outranks a `working` one on machine A. Sorting inside each machine
    /// and then concatenating — which this used to do — can only ever order rows
    /// within a group, so the priority mode looked like it was working while the
    /// groups themselves were in machine order.
    ///
    /// The key is upstream's own:
    ///
    /// - `stale` first: a disconnected machine's rows go last, because their status
    ///   is the last known one rather than the current one *and* its rows are drawn
    ///   dimmed, so they should not head the list.
    /// - then higher priority (`blocked` before `done` before `working` ...).
    /// - then more recent change, using the client-side stamp rather than
    ///   `state_change_seq` — the latter is per-daemon and not comparable across
    ///   machines (`endpoints.rs:594-604`).
    ///
    /// Upstream orders this way only for `Priority`; `Spaces` keeps the daemon's own
    /// order, which is what `orderedAgents` already produced.
    static func sorted(
        _ rows: [AggregatedAgent],
        sort: AgentPanelSort,
        hasViewLabel: Bool
    ) -> [AggregatedAgent] {
        guard sort == .priority, !hasViewLabel else { return rows }
        return rows.sorted { (left: AggregatedAgent, right: AggregatedAgent) -> Bool in
            if left.stale != right.stale {
                return !left.stale
            }
            if left.agent.agentStatus.priority != right.agent.agentStatus.priority {
                return left.agent.agentStatus.priority > right.agent.agentStatus.priority
            }
            return left.recency > right.recency
        }
    }

    /// Applies `sort` unless a view label is present.
    ///
    /// Upstream returns `agent_order` untouched when `agent_view_label` is set
    /// (`src/client/shell/agent_sidebar.rs:23-31`): the label means "this list is a
    /// filtered view", and re-sorting it would fight the order the filter implies.
    private static func orderedAgents(
        in snapshot: ClientShellSnapshot,
        isActive: Bool
    ) -> [ClientShellAgent] {
        let byPane = Dictionary(
            uniqueKeysWithValues: snapshot.agents.map { ($0.paneId, $0) }
        )
        let daemonOrder = snapshot.agentOrder.isEmpty
            ? snapshot.agents
            : snapshot.agentOrder.compactMap { byPane[$0] }
        let ordered = daemonOrder
        guard !isActive else { return ordered }
        return ordered.map { agent in
            guard agent.focused else { return agent }
            var cleared = agent
            cleared.focused = false
            return cleared
        }
    }
}
