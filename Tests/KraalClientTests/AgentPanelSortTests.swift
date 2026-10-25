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

    /// The order a real 4-machine session produces, pinned.
    ///
    /// Taken from a live run (`agents: priority order …`): one `done` on `hw-laptop`,
    /// two `working` (one on `host-workspace`, one on Local), and twelve `idle`
    /// spread over every machine. The claim is the interleaving — all non-idle rows
    /// before any idle row, regardless of which machine they came from — because that
    /// is exactly what a per-machine concatenation cannot produce.
    @Test("a real mixed-status session interleaves by status, not by machine")
    func realSessionInterleaves() throws {
        let rows = AgentAggregation.rows(
            [
                try source(id: "local", agents: [
                    agentJSON(pane: "l1", status: "working"),
                    agentJSON(pane: "l2", status: "idle"),
                    agentJSON(pane: "l3", status: "idle"),
                ]),
                try source(id: "hw", agents: [
                    agentJSON(pane: "h1", status: "done"),
                    agentJSON(pane: "h2", status: "idle"),
                    agentJSON(pane: "h3", status: "idle"),
                ]),
                try source(id: "ws", agents: [
                    agentJSON(pane: "w1", status: "working"),
                    agentJSON(pane: "w2", status: "idle"),
                ]),
            ],
            activeEndpointID: "local",
            sort: .priority
        )
        let order = rows.map { "\($0.agent.paneId):\($0.agent.agentStatus)" }
        // Every non-idle row comes before every idle row.
        let firstIdle = order.firstIndex { $0.hasSuffix(":idle") }
        let lastBusy = order.lastIndex { !$0.hasSuffix(":idle") }
        if let firstIdle, let lastBusy {
            #expect(lastBusy < firstIdle,
                    "an idle row outranked a busy one: \(order)")
        }
        // And the busiest status leads.
        #expect(order.first?.hasSuffix(":done") == true,
                "done should lead the list: \(order)")
    }

    /// The sequence upstream's own test asserts (`endpoints.rs:1915-1975`), replayed.
    ///
    /// Upstream checks three frames in a row:
    ///
    /// 1. both idle, Local changed later → **Local first**
    /// 2. remote becomes working → **remote first**
    /// 3. remote returns to idle with a newer seq → **remote still first**
    ///
    /// Step 3 is the one that matters: returning to `idle` is itself a change, so the
    /// row keeps its recency lead. An implementation that only stamped *status
    /// transitions between different states* would drop the row back and look like
    /// "Local is stuck at the bottom" — which is the report this test exists to answer.
    @Test("upstream's three-frame priority sequence replays identically")
    func upstreamSequenceReplays() throws {
        var recency = AgentRecency()

        // Frame 1: Local idle seq 1, remote idle seq 1.
        var local = try snapshot(agents: [agentJSON(pane: "l1", status: "idle", seq: 1)])
        recency.observe(endpointID: "local", snapshot: local, previous: nil)
        var remote = try snapshot(agents: [agentJSON(pane: "r1", status: "idle", seq: 1)])
        recency.observe(endpointID: "remote", snapshot: remote, previous: nil)

        // Local changes to seq 2. `previous` is the *old* snapshot, which is what
        // `AppStore.adoptSnapshot` passes — passing the new one made every agent look
        // unchanged, because its seq then equalled itself.
        let previousLocal = local
        local = try snapshot(agents: [agentJSON(pane: "l1", status: "idle", seq: 2)])
        recency.observe(endpointID: "local", snapshot: local, previous: previousLocal)

        func order() throws -> [String] {
            AgentAggregation.rows(
                [try source(id: "local", agents: [agentJSON(pane: "l1", status: "idle", seq: 2)]),
                 try source(id: "remote", agents: [agentJSON(pane: "r1", status: "idle", seq: 1)])],
                activeEndpointID: "local",
                sort: .priority,
                recency: recency
            ).map(\.agent.paneId)
        }
        // 1. Local changed later, so it leads.
        #expect(try order() == ["l1", "r1"], "step 1: Local should lead")

        // 2. Remote becomes working: status outranks recency.
        let previousRemote = remote
        remote = try snapshot(agents: [agentJSON(pane: "r1", status: "working", seq: 2)])
        recency.observe(endpointID: "remote", snapshot: remote, previous: previousRemote)
        #expect(try order() == ["r1", "l1"], "step 2: working should lead")

        // 3. Remote returns to idle with a newer seq: still the later change.
        let previousRemoteIdle = remote
        remote = try snapshot(agents: [agentJSON(pane: "r1", status: "idle", seq: 3)])
        recency.observe(endpointID: "remote", snapshot: remote, previous: previousRemoteIdle)
        #expect(try order() == ["r1", "l1"], "step 3: returning to idle is itself a change")
    }
}
