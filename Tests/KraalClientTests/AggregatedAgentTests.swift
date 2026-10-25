// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  AggregatedAgentTests.swift
//  KraalClientTests
//
//  The agents pane lists every machine's agents, not just the connected one.
//
//  Upstream walks `state.endpoints` and attaches the machine label to each row
//  (`src/client/shell/endpoint_agents.rs:132-174`). The properties that make that
//  correct — and that a naive "cat all the agents" gets wrong — are here: `focused`
//  must not survive from a machine that is not selected, and a row id must not
//  collide across machines.
//
//  The fixtures build snapshots through the real decoder rather than memberwise
//  inits: `ClientShellAgent` and `ClientShellSnapshot` are `Decodable` only, because
//  they mirror the wire direction. Going through JSON also keeps the field names
//  honest.
//

import Foundation
import Testing

@testable import KraalProtocol
@testable import KraalUI

@Suite("Agents from every machine")
struct AggregatedAgentTests {
    /// One agent's JSON. `pane` doubles as the row's identity in these fixtures.
    private func agentJSON(
        pane: String,
        focused: Bool = false,
        seq: UInt64 = 0
    ) -> String {
        """
        {"pane_id": "\(pane)", "workspace_id": "w", "tab_id": "t",
         "agent_status": "idle", "state_change_seq": \(seq), "focused": \(focused)}
        """
    }

    private func snapshot(
        agents: [String],
        order: [String] = []
    ) throws -> ClientShellSnapshot {
        let agentList = agents.joined(separator: ",")
        let orderList = order.map { "\"\($0)\"" }.joined(separator: ",")
        let json = """
        {"boot_id": "boot", "revision": 1, "workspaces": [], "tabs": [], "panes": [],
         "agents": [\(agentList)], "agent_order": [\(orderList)], "commands": []}
        """
        return try JSONDecoder().decode(ClientShellSnapshot.self, from: Data(json.utf8))
    }

    private func source(
        id: String,
        label: String,
        connected: Bool = true,
        agents: [String],
        order: [String] = []
    ) throws -> AgentAggregationSource {
        AgentAggregationSource(
            endpointID: id,
            label: label,
            isConnected: connected,
            snapshot: try snapshot(agents: agents, order: order)
        )
    }

    private func rows(
        active: String,
        _ sources: [AgentAggregationSource]
    ) -> [AggregatedAgent] {
        AgentAggregation.rows(sources, activeEndpointID: active)
    }

    /// `AggregatedAgent.id` has to differ across machines, because pane ids do not.
    /// Two daemons both call their first pane `w1:p1`, so a pane-id-keyed row would
    /// collapse two real agents into one and `ForEach` would draw only one.
    @Test("rows from different machines do not collide")
    func idsAreUniqueAcrossMachines() throws {
        let first = try source(id: "local", label: "This Mac", agents: [agentJSON(pane: "w1:p1")])
        let second = try source(id: "ssh:alpha", label: "alpha", agents: [agentJSON(pane: "w1:p1")])
        let both = rows(active: "local", [first, second])
        #expect(both.count == 2)
        #expect(Set(both.map(\.id)).count == 2, "two machines' w1:p1 collapsed into one row")
        #expect(both[0].agent.paneId == both[1].agent.paneId)
    }

    /// A machine that is not selected must not contribute `focused`. Both daemons
    /// report their own focused pane, and honouring both highlights two rows.
    @Test("only the active machine's focus survives")
    func focusOnlyFromTheActiveMachine() throws {
        let all = rows(
            active: "local",
            [
                try source(
                    id: "local", label: "This Mac",
                    agents: [agentJSON(pane: "w1:p1", focused: true)]
                ),
                try source(
                    id: "ssh:alpha", label: "alpha",
                    agents: [agentJSON(pane: "w2:p1", focused: true)]
                ),
            ]
        )
        #expect(all.count == 2)
        #expect(all.first { $0.endpointID == "local" }?.agent.focused == true)
        #expect(all.first { $0.endpointID == "ssh:alpha" }?.agent.focused == false,
                "the other machine's focus leaked through")
    }

    /// The whole point of the issue: two machines, three agents, three rows.
    @Test("every machine contributes its agents")
    func everyMachineContributes() throws {
        let all = rows(
            active: "local",
            [
                try source(
                    id: "local", label: "This Mac",
                    agents: [agentJSON(pane: "w1:p1"), agentJSON(pane: "w1:p2")]
                ),
                try source(id: "ssh:alpha", label: "alpha", agents: [agentJSON(pane: "w2:p1")]),
            ]
        )
        #expect(all.count == 3)
        #expect(all.map(\.machineLabel) == ["This Mac", "This Mac", "alpha"])
    }

    /// A dropped connection keeps its rows and marks them stale, rather than making
    /// the agents disappear because the link blinked.
    @Test("a disconnected machine's rows are marked stale")
    func disconnectedRowsAreStale() throws {
        let all = rows(
            active: "local",
            [
                try source(id: "local", label: "This Mac", agents: [agentJSON(pane: "w1:p1")]),
                try source(
                    id: "ssh:alpha", label: "alpha", connected: false,
                    agents: [agentJSON(pane: "w2:p1")]
                ),
            ]
        )
        #expect(all.count == 2)
        #expect(all.first { $0.endpointID == "local" }?.stale == false)
        #expect(all.first { $0.endpointID == "ssh:alpha" }?.stale == true)
    }

    /// `agentOrder` is the daemon's ordering and must be honoured per machine.
    @Test("each machine keeps the daemon's order")
    func perMachineOrderIsHonoured() throws {
        let all = rows(
            active: "local",
            [
                try source(
                    id: "local", label: "This Mac",
                    agents: [agentJSON(pane: "w1:p1"), agentJSON(pane: "w1:p2")],
                    order: ["w1:p2", "w1:p1"]
                ),
            ]
        )
        #expect(all.map(\.agent.paneId) == ["w1:p2", "w1:p1"])
    }

    /// An empty `agent_order` falls back to the snapshot's own array, which is what
    /// a daemon that has not sorted anything sends.
    @Test("an empty order falls back to the snapshot array")
    func emptyOrderFallsBack() throws {
        let all = rows(
            active: "local",
            [try source(
                id: "local", label: "This Mac",
                agents: [agentJSON(pane: "w1:p1"), agentJSON(pane: "w1:p2")]
            )]
        )
        #expect(all.map(\.agent.paneId) == ["w1:p1", "w1:p2"])
    }

    /// No machines at all yields nothing, rather than a placeholder row.
    @Test("no sources means no rows")
    func noSourcesNoRows() {
        #expect(rows(active: "local", []).isEmpty)
    }
}
