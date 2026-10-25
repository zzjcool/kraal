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
                    ),
                    // Resolved against *this* source's snapshot: the row's workspace
                    // lives on the machine the agent runs on, and the store's lists only
                    // describe the selected machine.
                    workspace: source.snapshot.workspaces.first {
                        $0.workspaceId == agent.workspaceId
                    },
                    // Only when it distinguishes anything. Upstream shows the tab
                    // label when the workspace has several tabs or this one was
                    // renamed (`agent_sidebar.rs:262-265`); otherwise it is the default
                    // `1` and every row would carry a meaningless number.
                    tab: {
                        let tabs = source.snapshot.tabs.filter {
                            $0.workspaceId == agent.workspaceId
                        }
                        guard let tab = tabs.first(where: { $0.tabId == agent.tabId })
                        else { return nil }
                        return tabs.count > 1 || tab.customLabel ? tab : nil
                    }()
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
        let ordered = rows.sorted { (left: AggregatedAgent, right: AggregatedAgent) -> Bool in
            if left.stale != right.stale {
                return !left.stale
            }
            if left.agent.agentStatus.priority != right.agent.agentStatus.priority {
                return left.agent.agentStatus.priority > right.agent.agentStatus.priority
            }
            return left.recency > right.recency
        }
        // Logged *after* ordering, so "why is this row above that one" is answerable
        // from a user's own run. The first version logged `rows` — the unsorted
        // parameter — and read as proof that cross-machine ordering was broken when it
        // was working: the log showed `idle` before `done` because it printed the input.
        if !ordered.isEmpty {
            let summary = ordered.map {
                "\($0.machineLabel)/\($0.agent.paneId)"
                    + ":\($0.agent.agentStatus)(p\($0.agent.agentStatus.priority),r\($0.recency))"
            }.joined(separator: " ")
            kraalLog("agents: priority order \(summary)")
        }
        return ordered
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

// MARK: - Recency

/// Per-machine recency stamps, keyed by pane id.
public struct AgentRecency: Equatable, Sendable {
    /// The whole store's stamps, one map per endpoint.
    private var byEndpoint: [String: [String: UInt64]] = [:]
    /// The highest stamp handed out so far, across every machine.
    private var highest: UInt64 = 0

    public init() {}

    /// Record a machine's new snapshot and stamp the agents whose state changed.
    ///
    /// `previous` is the machine's own previous snapshot; an agent counts as changed
    /// when its `state_change_seq` differs, or when it was not there before. Agents
    /// that disappeared are dropped, so the map cannot grow forever.
    ///
    /// Stamps strictly increase across machines, which is what makes them comparable.
    public mutating func observe(
        endpointID: String,
        snapshot: ClientShellSnapshot,
        previous: ClientShellSnapshot?
    ) {
        var stamps = byEndpoint[endpointID] ?? [:]
        // Agents are stamped in `state_change_seq` order so that within one snapshot
        // the most recently changed gets the highest stamp — a single snapshot can
        // report several changes at once.
        let agents = snapshot.agents.sorted { $0.stateChangeSeq < $1.stateChangeSeq }
        for agent in agents {
            let was = previous?.agents.first { $0.paneId == agent.paneId }
            guard was?.stateChangeSeq != agent.stateChangeSeq else { continue }
            highest += 1
            stamps[agent.paneId] = highest
        }
        let live = Set(snapshot.agents.map(\.paneId))
        stamps = stamps.filter { live.contains($0.key) }
        byEndpoint[endpointID] = stamps
    }

    /// The stamp for one agent, or `0` when it has never been seen changing.
    public func stamp(endpointID: String, paneId: String) -> UInt64 {
        byEndpoint[endpointID]?[paneId] ?? 0
    }

    /// Forget a machine entirely, e.g. when it is removed from the catalog.
    public mutating func forget(endpointID: String) {
        byEndpoint.removeValue(forKey: endpointID)
    }
}
