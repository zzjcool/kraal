// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  AgentRecencyTests.swift
//  KraalClientTests
//
//  A machine's `state_change_seq` only counts that machine's changes, so two
//  machines' numbers are unrelated. The priority ordering needs a scale they share,
//  which is what this counter provides: each new observation gets a stamp one past
//  the *global* maximum (`src/client/shell/endpoints.rs:594-604`).
//

import Foundation
import Testing

@testable import KraalProtocol
@testable import KraalUI

@Suite("Agent recency")
struct AgentRecencyTests {
    private func snapshot(
        _ agents: [(pane: String, seq: UInt64)]
    ) throws -> ClientShellSnapshot {
        let list = agents.map { entry in
            """
            {"pane_id": "\(entry.pane)", "workspace_id": "w", "tab_id": "t",
             "agent_status": "idle", "state_change_seq": \(entry.seq), "focused": false}
            """
        }.joined(separator: ",")
        let json = """
        {"boot_id": "boot", "revision": 1, "workspaces": [], "tabs": [], "panes": [],
         "agents": [\(list)], "agent_order": [], "commands": []}
        """
        return try JSONDecoder().decode(ClientShellSnapshot.self, from: Data(json.utf8))
    }

    /// The core property: stamps from different machines are comparable, so a change
    /// on the second machine outranks an earlier one on the first.
    @Test("stamps are ordered across machines")
    func stampsAreComparableAcrossMachines() throws {
        var recency = AgentRecency()
        recency.observe(
            endpointID: "alpha",
            snapshot: try snapshot([("a1", seq: 1)]),
            previous: nil
        )
        recency.observe(
            endpointID: "beta",
            snapshot: try snapshot([("b1", seq: 1)]),
            previous: nil
        )
        let alpha = recency.stamp(endpointID: "alpha", paneId: "a1")
        let beta = recency.stamp(endpointID: "beta", paneId: "b1")
        #expect(beta > alpha, "the later machine's change did not outrank the earlier one")
        // Both sequences were 1, which is exactly why the raw value cannot be used.
        #expect(alpha > 0 && beta > 0)
    }

    /// An agent whose `state_change_seq` did not move keeps its stamp: the counter
    /// tracks *changes*, not snapshots. Bumping every agent on every snapshot would
    /// make the ordering depend on how often each daemon happens to send one.
    @Test("an unchanged agent keeps its stamp")
    func unchangedAgentKeepsItsStamp() throws {
        var recency = AgentRecency()
        let first = try snapshot([("a1", seq: 3)])
        recency.observe(endpointID: "alpha", snapshot: first, previous: nil)
        let before = recency.stamp(endpointID: "alpha", paneId: "a1")
        recency.observe(endpointID: "alpha", snapshot: first, previous: first)
        #expect(recency.stamp(endpointID: "alpha", paneId: "a1") == before)
    }

    /// A changed agent does move.
    @Test("a changed agent gets a new stamp")
    func changedAgentGetsNewStamp() throws {
        var recency = AgentRecency()
        let first = try snapshot([("a1", seq: 1)])
        recency.observe(endpointID: "alpha", snapshot: first, previous: nil)
        let before = recency.stamp(endpointID: "alpha", paneId: "a1")
        let second = try snapshot([("a1", seq: 2)])
        recency.observe(endpointID: "alpha", snapshot: second, previous: first)
        #expect(recency.stamp(endpointID: "alpha", paneId: "a1") > before)
    }

    /// Within one snapshot, agents are stamped in `state_change_seq` order, so the
    /// most recent change in that batch gets the highest stamp. Without this, a
    /// snapshot reporting two changes would order them arbitrarily.
    @Test("within one snapshot the later change stamps higher")
    func withinSnapshotOrderFollowsSequence() throws {
        var recency = AgentRecency()
        recency.observe(
            endpointID: "alpha",
            snapshot: try snapshot([("a1", seq: 9), ("a2", seq: 1)]),
            previous: nil
        )
        let newer = recency.stamp(endpointID: "alpha", paneId: "a1")
        let older = recency.stamp(endpointID: "alpha", paneId: "a2")
        #expect(newer > older)
    }

    /// A vanished agent's stamp is dropped, so the map cannot grow without bound as
    /// panes come and go.
    @Test("a gone agent is forgotten")
    func goneAgentIsForgotten() throws {
        var recency = AgentRecency()
        let first = try snapshot([("a1", seq: 1)])
        recency.observe(endpointID: "alpha", snapshot: first, previous: nil)
        #expect(recency.stamp(endpointID: "alpha", paneId: "a1") > 0)
        // Next snapshot has a different agent, so a1 is gone.
        let second = try snapshot([("a2", seq: 2)])
        recency.observe(endpointID: "alpha", snapshot: second, previous: first)
        #expect(recency.stamp(endpointID: "alpha", paneId: "a1") == 0)
    }

    /// An unseen agent has no stamp rather than a bogus one.
    @Test("an unseen agent stamps zero")
    func unseenAgentStampsZero() {
        let recency = AgentRecency()
        #expect(recency.stamp(endpointID: "alpha", paneId: "nope") == 0)
    }
}
