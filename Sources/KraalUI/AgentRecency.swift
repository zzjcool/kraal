// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  AgentRecency.swift
//  KraalUI
//
//  A monotonic "which agent changed most recently" counter, shared across machines.
//
//  `state_change_seq` is per-daemon: each one counts its own agents from zero, so the
//  numbers from two machines are not comparable — an agent that changed "three
//  changes ago" on machine A and one that changed "three changes ago" on machine B
//  can be minutes apart. Upstream avoids the comparison entirely by keeping a
//  client-side counter per endpoint whose next value is one past the *global* maximum
//  (`src/client/shell/endpoints.rs:594-604`), so every machine's changes land in one
//  ordering.
//
//  This is that counter. Without it, sorting the agents pane by priority across
//  machines interleaves them by an unshared number, which is worse than not sorting:
//  the list looks ordered and is not.
//

import Foundation
import KraalProtocol

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
