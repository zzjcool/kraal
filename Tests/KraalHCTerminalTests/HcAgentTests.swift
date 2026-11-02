// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import KraalHC
import KraalModel
import Testing

@testable import KraalHCTerminal

@Suite("Agents")
struct HcAgentTests {
    private func terminal(
        _ address: String,
        word: String? = nil,
        turn: Int = 0,
        parent: String? = nil,
        seen: Int? = nil,
        pinned: Bool = false,
        app: String = "claude"
    ) -> HcTerminal {
        var object: [String: JSONValue] = [
            "address": .string(address),
            "state": .string("live"),
            "name": .string(address),
            "turn": .int(turn),
        ]
        if let word {
            object["status"] = .object(["state": .string(word), "app": .string(app)])
        }
        if let parent { object["parent"] = .string(parent) }
        var labels: [String: JSONValue] = [:]
        if let seen { labels["herdr.seen"] = .string(String(seen)) }
        if pinned { labels["herdr.pinned"] = .string("1") }
        if !labels.isEmpty { object["labels"] = .object(labels) }
        return HcTerminal(json: .object(object))
    }

    private func model() -> KraalModel {
        var model = KraalModel()
        _ = model.addSpace(
            id: "sp1",
            folder: "/tmp",
            tab: KraalTabSeed(id: "tb1", paneID: "p1", terminal: "t1")
        )
        return model
    }

    private func input(
        _ terminals: [HcTerminal],
        placed: Set<String>,
        visible: Set<String> = [],
        appActive: Bool = true,
        now: UInt64
    ) -> HcAgentInput {
        var input = HcAgentInput(model: model())
        input.terminals = terminals
        input.placed = placed
        input.visible = visible
        input.appActive = appActive
        input.now = now
        return input
    }

    @Test("OSC words and the turn counter decide the status")
    func statuses() {
        #expect(HcAgentTracker.status(word: "working", turn: 0, seenTurn: nil, seen: true) == .working)
        #expect(HcAgentTracker.status(word: "blocked", turn: 0, seenTurn: nil, seen: true) == .blocked)
        #expect(HcAgentTracker.status(word: "done", turn: 3, seenTurn: 2, seen: false) == .done)
        #expect(HcAgentTracker.status(word: "done", turn: 3, seenTurn: 3, seen: false) == .idle)
        #expect(HcAgentTracker.status(word: "idle", turn: 3, seenTurn: nil, seen: true) == .idle)
        #expect(HcAgentTracker.status(word: "idle", turn: 3, seenTurn: nil, seen: false) == .done)
        #expect(HcAgentTracker.childWord("done") == "idle")
        #expect(HcAgentTracker.childWord("error") == "blocked")
    }

    @Test("pinned first, then blocked, done, working, idle")
    func ordering() {
        var tracker = HcAgentTracker()
        let terminals = [
            terminal("t1", word: "idle", turn: 1),
            terminal("t2", word: "working", turn: 2),
            terminal("t3", word: "done", turn: 3, seen: 0),
            terminal("t4", word: "blocked", turn: 4),
            terminal("t5", word: "idle", turn: 5, pinned: true),
        ]
        let result = tracker.update(input(terminals, placed: ["t1", "t2", "t3", "t4", "t5"], now: 100))
        #expect(result.agents.map(\.address) == ["t5", "t4", "t3", "t2", "t1"])
    }

    @Test("a sub-agent is nested under its parent and an unplaced worker is hidden")
    func children() {
        var tracker = HcAgentTracker()
        let terminals = [
            terminal("t1", word: "working", turn: 1),
            terminal("t2", word: "done", turn: 2, parent: "t1"),
            terminal("t9", word: "blocked", turn: 1),
        ]
        let result = tracker.update(input(terminals, placed: ["t1"], now: 100))
        #expect(result.agents.map(\.address) == ["t1", "t2"])
        #expect(result.agents[1].depth == 1)
        #expect(result.agents[1].word == "idle")
        #expect(result.agents[1].parent == "t1")
        #expect(result.alerts.isEmpty)

        let blocked = tracker.update(input(
            [terminal("t1", word: "working", turn: 0), terminal("t2", word: "blocked", turn: 1, parent: "t1")],
            placed: ["t1"], now: 200
        ))
        #expect(blocked.agents.first { $0.address == "t2" }?.status == .blocked)
        #expect(blocked.alerts.isEmpty)
    }

    @Test("a background sub-agent never turns done")
    func childQuiet() {
        var tracker = HcAgentTracker()
        _ = tracker.update(input(
            [terminal("t1", word: "working", turn: 0), terminal("t2", word: "working", turn: 0, parent: "t1")],
            placed: ["t1"], now: 100
        ))
        var background = input(
            [terminal("t1", word: "working", turn: 0), terminal("t2", word: "done", turn: 1, parent: "t1")],
            placed: ["t1"], appActive: false, now: 200
        )
        background.visible = []
        let result = tracker.update(background)
        #expect(result.agents.first { $0.address == "t2" }?.word == "idle")
        #expect(result.agents.first { $0.address == "t2" }?.status == .idle)
        #expect(result.agents.first { $0.address == "t1" }?.status == .working)
    }

    @Test("the parent row takes the most urgent child status")
    func rollup() {
        var tracker = HcAgentTracker()
        let terminals = [
            terminal("t1", word: "idle", turn: 1),
            terminal("t2", word: "blocked", turn: 2, parent: "t1"),
        ]
        let result = tracker.update(input(terminals, placed: ["t1"], now: 100))
        #expect(result.agents.first?.status == .blocked)
    }

    @Test("alerts: new blocked, busy to quiet when not looking")
    func alerts() {
        #expect(HcAgentTracker.alert(previous: "working", new: "blocked", looking: false) == .blocked)
        #expect(HcAgentTracker.alert(previous: "idle", new: "blocked", looking: true) == .blocked)
        #expect(HcAgentTracker.alert(previous: "working", new: "idle", looking: false) == .done)
        #expect(HcAgentTracker.alert(previous: "working", new: "idle", looking: true) == nil)
        #expect(HcAgentTracker.alert(previous: nil, new: "blocked", looking: false) == .blocked)

        var tracker = HcAgentTracker()
        let first = tracker.update(input([terminal("t1", word: "working", turn: 1)], placed: ["t1"], now: 100))
        #expect(first.alerts.isEmpty)
        let second = tracker.update(input([terminal("t1", word: "blocked", turn: 2)], placed: ["t1"], now: 200))
        #expect(second.alerts.map(\.kind) == [.blocked])
        #expect(second.agents.first?.since == 200)
    }

    @Test("shared seen overrides an older label and never moves backward")
    func seen() {
        var tracker = HcAgentTracker()
        var firstInput = input([terminal("t1", word: "done", turn: 5, seen: 2)], placed: ["t1"], now: 100)
        firstInput.seenOverrides = ["t1": 4]
        let result = tracker.update(firstInput)
        #expect(result.agents.first?.seenTurn == 4)
        #expect(result.agents.first?.status == .done)

        var unreadInput = input([terminal("t1", word: "done", turn: 5, seen: 5)], placed: ["t1"], now: 200)
        unreadInput.unread = ["t1"]
        let unread = tracker.update(unreadInput)
        #expect(unread.agents.first?.status == .done)
    }

    @Test("a viewed done row stays done until focus leaves")
    func heldDone() {
        var tracker = HcAgentTracker()
        var working = input([terminal("t1", word: "working", turn: 0)], placed: ["t1"], now: 100)
        working.focused = "t1"
        working.visible = ["t1"]
        _ = tracker.update(working)

        var done = input([terminal("t1", word: "done", turn: 1, seen: 0)], placed: ["t1"], now: 200)
        done.focused = "t1"
        done.visible = ["t1"]
        _ = tracker.update(done)

        // Seeing it writes seen=1; the row would go Idle, but it is focused.
        var seen = input([terminal("t1", word: "done", turn: 1, seen: 1)], placed: ["t1"], now: 300)
        seen.focused = "t1"
        seen.visible = ["t1"]
        #expect(tracker.update(seen).agents.first?.status == .done)

        var left = input([terminal("t1", word: "done", turn: 1, seen: 1)], placed: ["t1"], now: 400)
        left.focused = nil
        #expect(tracker.update(left).agents.first?.status == .idle)
    }

    @Test("space view groups rows under their space")
    func bySpace() {
        var model = KraalModel()
        _ = model.addSpace(id: "sp1", folder: "/one", tab: KraalTabSeed(id: "tb1", paneID: "p1", terminal: "t1"))
        _ = model.addSpace(id: "sp2", folder: "/two", tab: KraalTabSeed(id: "tb2", paneID: "p2", terminal: "t2"))
        let agents = [
            HcAgent(
                address: "t1", pane: "p1", name: "a", detail: "one", spaceID: "sp1", spaceName: "one",
                tabName: "tb1", machine: nil, word: "working", app: nil, status: .working, turn: 0,
                seenTurn: 0, pinned: false, parent: nil, depth: 0, since: 0
            ),
            HcAgent(
                address: "t2", pane: "p2", name: "b", detail: "two", spaceID: "sp2", spaceName: "two",
                tabName: "tb2", machine: nil, word: "blocked", app: nil, status: .blocked, turn: 1,
                seenTurn: 0, pinned: false, parent: nil, depth: 0, since: 0
            ),
        ]
        let groups = HcAgentGrouping.bySpace(agents: agents, model: model)
        #expect(groups.map(\.title) == ["one", "two"])
        #expect(groups.map { $0.agents.map(\.address) } == [["t1"], ["t2"]])
    }

    @Test("groups keep local, machines, and orphans")
    func groups() {
        let agents = [
            HcAgent(
                address: "t1", pane: "p1", name: "a", detail: "", spaceID: "sp1", spaceName: "s",
                tabName: "1", machine: nil, word: "idle", app: nil, status: .idle, turn: 0,
                seenTurn: 0, pinned: false, parent: nil, depth: 0, since: 0
            ),
            HcAgent(
                address: "alpha/t2", pane: "p2", name: "b", detail: "", spaceID: "sp2", spaceName: "s",
                tabName: "1", machine: "alpha", word: "working", app: nil, status: .working, turn: 1,
                seenTurn: 0, pinned: false, parent: nil, depth: 0, since: 0
            ),
            HcAgent(
                address: "ghost/t3", pane: nil, name: "c", detail: "", spaceID: nil, spaceName: "",
                tabName: "", machine: "ghost", word: "blocked", app: nil, status: .blocked, turn: 2,
                seenTurn: 0, pinned: false, parent: nil, depth: 0, since: 0
            ),
        ]
        let machines = [
            HcMachine(json: .object([
                "name": .string("alpha"), "state": .string("connected"), "temporary": .bool(false),
            ])),
            HcMachine(json: .object([
                "name": .string("hidden"), "state": .string("connected"), "temporary": .bool(true),
            ])),
        ]
        let groups = HcAgentGrouping.groups(agents: agents, machines: machines, localName: "here")
        #expect(groups.map(\.title) == ["here", "alpha", "ghost"])
        #expect(groups.map { $0.agents.count } == [1, 1, 1])
    }
}
