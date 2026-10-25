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
        activeEndpointID: String
    ) -> [AggregatedAgent] {
        var result: [AggregatedAgent] = []
        for source in sources {
            let isActive = source.endpointID == activeEndpointID
            for agent in orderedAgents(in: source.snapshot, isActive: isActive) {
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

    private static func orderedAgents(
        in snapshot: ClientShellSnapshot,
        isActive: Bool
    ) -> [ClientShellAgent] {
        let byPane = Dictionary(
            uniqueKeysWithValues: snapshot.agents.map { ($0.paneId, $0) }
        )
        let ordered = snapshot.agentOrder.isEmpty
            ? snapshot.agents
            : snapshot.agentOrder.compactMap { byPane[$0] }
        guard !isActive else { return ordered }
        return ordered.map { agent in
            guard agent.focused else { return agent }
            var cleared = agent
            cleared.focused = false
            return cleared
        }
    }
}
