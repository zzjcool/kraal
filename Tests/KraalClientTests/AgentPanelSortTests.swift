// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  AgentPanelSortTests.swift
//  KraalClientTests
//
//  The agents pane can order by `priority` instead of the daemon's own order.
//
//  Upstream's rule is `blocked > done > working > idle > unknown`, ties broken by
//  `state_change_seq` descending (`src/client/shell/agent_sidebar.rs:38-45`,
//  `src/client/shell.rs:203-212`). It also *skips* sorting entirely when
//  `agent_view_label` is set, because a filtered view carries its own order.
//

import Foundation
import Testing

@testable import KraalProtocol
@testable import KraalUI

@Suite("Agent panel sorting")
struct AgentPanelSortTests {
    private func agent(
        _ pane: String,
        _ status: String,
        seq: UInt64 = 0
    ) throws -> ClientShellAgent {
        let json = """
        {"pane_id": "\(pane)", "workspace_id": "w", "tab_id": "t",
         "agent_status": "\(status)", "state_change_seq": \(seq), "focused": false}
        """
        return try JSONDecoder().decode(ClientShellAgent.self, from: Data(json.utf8))
    }

    /// `blocked` first: an agent waiting on a human is the one that matters, which is
    /// the opposite of "most recently active first".
    @Test("priority puts blocked above everything")
    func blockedOutranksAll() throws {
        let agents = [
            try agent("a", "idle", seq: 99),
            try agent("b", "blocked", seq: 1),
            try agent("c", "working", seq: 50),
            try agent("d", "done", seq: 10),
            try agent("e", "unknown"),
        ]
        let sorted = AgentAggregation.sorted(agents, sort: .priority, hasViewLabel: false)
        #expect(sorted.map(\.agentStatus) == [.blocked, .done, .working, .idle, .unknown])
    }

    /// The exact ranking, so a reordering of the enum cannot silently change it.
    @Test("the ranking matches upstream")
    func ranking() {
        #expect(AgentStatus.blocked.priority == 4)
        #expect(AgentStatus.done.priority == 3)
        #expect(AgentStatus.working.priority == 2)
        #expect(AgentStatus.idle.priority == 1)
        #expect(AgentStatus.unknown.priority == 0)
    }

    /// Within one status the most recent change comes first.
    @Test("ties break on the most recent state change")
    func tiesBreakOnRecentChange() throws {
        let agents = [
            try agent("old", "blocked", seq: 1),
            try agent("new", "blocked", seq: 9),
            try agent("mid", "blocked", seq: 5),
        ]
        let sorted = AgentAggregation.sorted(agents, sort: .priority, hasViewLabel: false)
        #expect(sorted.map(\.paneId) == ["new", "mid", "old"])
    }

    /// A filtered view carries its own order, so sorting must be skipped.
    @Test("a view label disables sorting")
    func viewLabelDisablesSorting() throws {
        let agents = [
            try agent("a", "idle"),
            try agent("b", "blocked"),
        ]
        let untouched = AgentAggregation.sorted(agents, sort: .priority, hasViewLabel: true)
        #expect(untouched.map(\.paneId) == ["a", "b"], "a filtered view was re-sorted")
    }

    /// `spaces` is the default and must leave the daemon's order alone.
    @Test("the spaces sort changes nothing")
    func spacesLeavesOrderAlone() throws {
        let agents = [
            try agent("a", "idle", seq: 1),
            try agent("b", "blocked", seq: 2),
        ]
        let untouched = AgentAggregation.sorted(agents, sort: .spaces, hasViewLabel: false)
        #expect(untouched.map(\.paneId) == ["a", "b"])
    }

    /// Equal priorities and equal sequences keep the daemon's order — Swift's sort is
    /// stable, and a shuffled list would look arbitrary.
    @Test("fully tied agents keep their incoming order")
    func fullTiesKeepOrder() throws {
        let agents = [
            try agent("a", "working", seq: 3),
            try agent("b", "working", seq: 3),
            try agent("c", "working", seq: 3),
        ]
        let sorted = AgentAggregation.sorted(agents, sort: .priority, hasViewLabel: false)
        #expect(sorted.map(\.paneId) == ["a", "b", "c"])
    }

    /// An unknown status from a newer daemon decodes to `.unknown` and sorts last
    /// rather than crashing.
    @Test("an unrecognised status sorts last")
    func unknownStatusSortsLast() throws {
        let agents = [
            try agent("a", "something-new"),
            try agent("b", "idle"),
        ]
        #expect(agents[0].agentStatus == .unknown)
        let sorted = AgentAggregation.sorted(agents, sort: .priority, hasViewLabel: false)
        #expect(sorted.map(\.paneId) == ["b", "a"])
    }
}
