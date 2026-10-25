// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  AgentPanelSortTests.swift
//  KraalClientTests
//
//  The agents pane orders by priority across *every* machine, not within each one.
//
//  Upstream flattens all endpoints' agents and only then sorts
//  (`src/client/shell/aggregate_navigation.rs:161-184`), with the key
//
//      (stale, Reverse(priority), Reverse(recency))
//
//  where `recency` is a client-side stamp on a scale shared by all machines
//  (`endpoints.rs:594-604`) — not `state_change_seq`, which each daemon counts from
//  zero and which is therefore not comparable between machines.
//
//  Sorting inside each machine and concatenating (what this used to do) looks right
//  on one machine and is wrong on several, which is exactly the reported bug.
//

import Foundation
import Testing

@testable import KraalProtocol
@testable import KraalUI

@Suite("Agent panel sorting")
struct AgentPanelSortTests {
    private func agentJSON(
        pane: String,
        status: String,
        seq: UInt64 = 0
    ) -> String {
        """
        {"pane_id": "\(pane)", "workspace_id": "w", "tab_id": "t",
         "agent_status": "\(status)", "state_change_seq": \(seq), "focused": false}
        """
    }

    private func snapshot(
        agents: [String],
        order: [String] = [],
        viewLabel: String? = nil
    ) throws -> ClientShellSnapshot {
        let agentList = agents.joined(separator: ",")
        let orderList = order.map { "\"\($0)\"" }.joined(separator: ",")
        let label = viewLabel.map { "\"agent_view_label\": \"\($0)\"," } ?? ""
        let json = """
        {"boot_id": "boot", "revision": 1, "workspaces": [], "tabs": [], "panes": [],
         \(label)
         "agents": [\(agentList)], "agent_order": [\(orderList)], "commands": []}
        """
        return try JSONDecoder().decode(ClientShellSnapshot.self, from: Data(json.utf8))
    }

    private func source(
        id: String,
        agents: [String],
        order: [String] = [],
        connected: Bool = true,
        viewLabel: String? = nil
    ) throws -> AgentAggregationSource {
        AgentAggregationSource(
            endpointID: id,
            label: id,
            isConnected: connected,
            snapshot: try snapshot(agents: agents, order: order, viewLabel: viewLabel)
        )
    }

    /// The ranking itself, so a reordering of the enum cannot silently change it.
    @Test("the ranking matches upstream")
    func ranking() {
        #expect(AgentStatus.blocked.priority == 4)
        #expect(AgentStatus.done.priority == 3)
        #expect(AgentStatus.working.priority == 2)
        #expect(AgentStatus.idle.priority == 1)
        #expect(AgentStatus.unknown.priority == 0)
    }

    @Test("each mode has the label upstream prints")
    func shortTitlesMatchUpstream() {
        #expect(AgentPanelSort.spaces.shortTitle == "grouped")
        #expect(AgentPanelSort.priority.shortTitle == "priority")
    }

    @Test("the header toggle alternates between the two modes")
    func toggleAlternates() {
        #expect(AgentPanelSort.spaces.toggled == .priority)
        #expect(AgentPanelSort.priority.toggled == .spaces)
    }

    /// The reported bug: a `blocked` agent on the second machine must outrank a
    /// `working` one on the first. Per-machine sorting cannot do this — it emits all
    /// of machine A, then all of machine B.
    @Test("priority orders across machines, not within them")
    func priorityCrossesMachines() throws {
        let rows = AgentAggregation.rows(
            [
                try source(id: "alpha", agents: [
                    agentJSON(pane: "a1", status: "working"),
                    agentJSON(pane: "a2", status: "idle"),
                ]),
                try source(id: "beta", agents: [
                    agentJSON(pane: "b1", status: "blocked"),
                ]),
            ],
            activeEndpointID: "alpha",
            sort: .priority
        )
        #expect(rows.map(\.agent.paneId) == ["b1", "a1", "a2"],
                "a blocked agent on the other machine did not come first")
    }

    /// `spaces` keeps each machine's own daemon order and only concatenates.
    @Test("the spaces mode does not reorder across machines")
    func spacesKeepsMachineOrder() throws {
        let rows = AgentAggregation.rows(
            [
                try source(id: "alpha", agents: [
                    agentJSON(pane: "a1", status: "idle"),
                    agentJSON(pane: "a2", status: "blocked"),
                ]),
                try source(id: "beta", agents: [agentJSON(pane: "b1", status: "done")]),
            ],
            activeEndpointID: "alpha",
            sort: .spaces
        )
        #expect(rows.map(\.agent.paneId) == ["a1", "a2", "b1"])
    }

    /// Within one priority, the more recent change comes first — using the shared
    /// stamp, so two machines can be interleaved correctly.
    @Test("ties break on the shared recency stamp")
    func tiesBreakOnRecency() throws {
        var recency = AgentRecency()
        let older = try snapshot(agents: [agentJSON(pane: "a1", status: "blocked", seq: 1)])
        recency.observe(endpointID: "alpha", snapshot: older, previous: nil)
        let newer = try snapshot(agents: [agentJSON(pane: "b1", status: "blocked", seq: 1)])
        recency.observe(endpointID: "beta", snapshot: newer, previous: nil)

        let rows = AgentAggregation.rows(
            [
                try source(id: "alpha", agents: [agentJSON(pane: "a1", status: "blocked")]),
                try source(id: "beta", agents: [agentJSON(pane: "b1", status: "blocked")]),
            ],
            activeEndpointID: "alpha",
            sort: .priority,
            recency: recency
        )
        #expect(rows.map(\.agent.paneId) == ["b1", "a1"],
                "the later change should come first, across machines")
    }

    /// A disconnected machine's rows go last: their status is the last known one, and
    /// they are drawn dimmed, so they should not head the list even when `blocked`.
    @Test("stale rows sort behind live ones")
    func staleRowsSortLast() throws {
        let rows = AgentAggregation.rows(
            [
                try source(id: "alpha", agents: [agentJSON(pane: "a1", status: "idle")]),
                try source(
                    id: "beta",
                    agents: [agentJSON(pane: "b1", status: "blocked")],
                    connected: false
                ),
            ],
            activeEndpointID: "alpha",
            sort: .priority
        )
        #expect(rows.map(\.agent.paneId) == ["a1", "b1"],
                "a stale blocked row outranked a live idle one")
    }

    /// A filtered view carries its own order, so sorting is skipped entirely.
    @Test("a view label disables sorting")
    func viewLabelDisablesSorting() throws {
        let rows = AgentAggregation.rows(
            [
                try source(
                    id: "alpha",
                    agents: [agentJSON(pane: "a1", status: "idle"),
                             agentJSON(pane: "a2", status: "blocked")],
                    viewLabel: "mine"
                ),
            ],
            activeEndpointID: "alpha",
            sort: .priority
        )
        #expect(rows.map(\.agent.paneId) == ["a1", "a2"], "a filtered view was re-sorted")
    }

    /// An unknown status from a newer daemon decodes to `.unknown` and sorts last
    /// rather than crashing.
    @Test("an unrecognised status sorts last")
    func unknownStatusSortsLast() throws {
        let rows = AgentAggregation.rows(
            [
                try source(id: "alpha", agents: [
                    agentJSON(pane: "a1", status: "something-new"),
                    agentJSON(pane: "a2", status: "idle"),
                ]),
            ],
            activeEndpointID: "alpha",
            sort: .priority
        )
        #expect(rows.map(\.agent.paneId) == ["a2", "a1"])
    }
}
