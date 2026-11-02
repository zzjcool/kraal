// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import KraalHC
import Testing

@testable import KraalModel

@Suite("Model placement")
struct KraalPlacementTests {
    @Test("adoption into a known tab appends without stealing focus")
    func existingTab() throws {
        var model = modelWithOne()
        model.split(pane: "p1", axis: .row, newPane: "p2", terminal: "t2")
        model.focus(pane: "p1", select: false)
        model.zoom("p2")
        let before = model.tab("tb1")

        let pane = model.adopt(terminal: "t3", space: "sp1", tab: "tb1")
        #expect(pane != nil)
        let tab = try #require(model.tab("tb1"))
        #expect(tab.root.terminals.sorted() == ["t1", "t2", "t3"])
        #expect(tab.focused == "p1")
        #expect(tab.before == before?.before)
        #expect(tab.zoomed == "p2")
    }

    @Test("an unknown space is made unnamed and does not take over the screen")
    func unknownSpace() throws {
        var model = modelWithOne()
        model.addSpace(
            id: "sp2", name: "web", folder: "/src/web",
            tab: KraalTabSeed(id: "tb2", paneID: "p2", terminal: "t2")
        )
        #expect(model.activeSpace?.id == "sp2")

        let pane = model.adopt(
            terminal: "alpha/t9", space: "alpha/sp9", tab: "alpha/tb9",
            folder: "/src/api", machine: "alpha"
        )
        let placed = try #require(pane)
        #expect(placed.hasPrefix("alpha/p"))
        #expect(model.paneID(ofTerminal: "alpha/t9") == placed)
        #expect(model.activeSpace?.id == "sp2")
        let space = try #require(model.space("alpha/sp9"))
        #expect(space.name.isEmpty)
        #expect(space.folder == "/src/api")
        #expect(space.machine == "alpha")
        #expect(space.tabs.map(\.id) == ["alpha/tb9"])
        #expect(space.tabs[0].panes.map(\.id) == [placed])
        #expect(space.tabs[0].terminals == ["alpha/t9"])
        #expect(model.spaces.map(\.id) == ["sp1", "sp2", "alpha/sp9"])
    }

    @Test("a space without a tab label gets a fresh tab")
    func freshTab() throws {
        var model = KraalModel(home: "/home/me")
        let pane = model.adopt(terminal: "t1", space: "sp1", folder: "/src/api")
        #expect(pane != nil)
        let space = try #require(model.space("sp1"))
        #expect(space.tabs.count == 1)
        #expect(space.tabs[0].terminals == ["t1"])
        #expect(space.tabs[0].name.isEmpty)
        #expect(space.tabs[0].displayName == "1")
    }

    @Test("a new tab goes after the shown one and leaves it shown")
    func newTab() throws {
        var model = modelWithOne()
        model.addTab(space: "sp1", tab: KraalTabSeed(id: "tb2", paneID: "p2", terminal: "t2"))
        model.selectTab("tb1")
        let pane = model.adopt(terminal: "t3", space: "sp1", tab: "tb9")
        #expect(pane != nil)
        let space = try #require(model.space("sp1"))
        #expect(space.tabs.map(\.id) == ["tb1", "tb9", "tb2"])
        #expect(space.activeTab == "tb1")
        #expect(space.tabs[1].terminals == ["t3"])
    }

    @Test("a tab label from another space does not move that tab")
    func foreignTab() throws {
        var model = modelWithOne()
        model.addSpace(
            id: "sp2", name: "web", folder: "/src/web",
            tab: KraalTabSeed(id: "tb2", paneID: "p2", terminal: "t2")
        )
        let pane = model.adopt(terminal: "t3", space: "sp1", tab: "tb2")
        #expect(pane != nil)
        #expect(model.space("sp2")?.tabs.map(\.id) == ["tb2"])
        #expect(model.space("sp1")?.tabs.count == 2)
        #expect(model.space("sp1")?.tabs[1].terminals == ["t3"])
        #expect(model.space("sp1")?.tabs[1].id != "tb2")
    }

    @Test("adopting the same terminal twice returns the first pane")
    func duplicate() throws {
        var model = modelWithOne()
        let first = model.adopt(terminal: "t2", space: "sp1", tab: "tb1")
        let second = model.adopt(terminal: "t2", space: "sp1", tab: "tb1")
        #expect(first == second)
        #expect(model.tab("tb1")?.root.panes.count == 2)
    }

    @Test("panes and terminals map both ways")
    func mapping() throws {
        var model = modelWithOne()
        model.split(pane: "p1", axis: .row, newPane: "p2", terminal: "t2")
        #expect(model.paneID(ofTerminal: "t1") == "p1")
        #expect(model.terminal(ofPane: "p2") == "t2")
        #expect(model.placedTerminals == ["t1": "p1", "t2": "p2"])
        #expect(model.terminal(ofPane: "missing") == nil)
        #expect(model.paneID(ofTerminal: "missing") == nil)
    }

    @Test("showing a space and a stack child are explicit, checked edits")
    func selection() throws {
        var model = modelWithOne()
        model.addSpace(
            id: "sp2", name: "web", folder: "/src/web",
            tab: KraalTabSeed(id: "tb2", paneID: "p2", terminal: "t2")
        )
        let didShow = model.setActiveSpace("sp2")
        #expect(didShow)
        #expect(model.activeSpace?.id == "sp2")
        let didShowMissing = model.setActiveSpace("missing")
        #expect(!didShowMissing)
        #expect(model.activeSpace?.id == "sp2")

        let stack: JSONValue = .object([
            "id": .string("st1"),
            "type": .string("stack"),
            "active": .string("a"),
            "children": .array([
                .object(["id": .string("a"), "type": .string("block"),
                         "content": .object(["terminal": .string("t8")])]),
                .object(["id": .string("b"), "type": .string("block"),
                         "content": .object(["terminal": .string("t9")])]),
            ]),
        ])
        let root: JSONValue = .object([
            "id": .string("tb3"), "type": .string("row"), "children": .array([stack]),
        ])
        let document = try HcLayoutDocument(value: .object([
            "spaces": .array([
                .object([
                    "id": .string("sp3"),
                    "tabs": .array([.object(["id": .string("tb3"), "root": root])]),
                ]),
            ]),
        ]))
        model.apply(document)
        let didSelect = model.selectStackChild(stack: "st1", child: "b")
        #expect(didSelect)
        #expect(model.tab("tb3")?.root.find("st1")?.raw["active"]?.stringValue == "b")
        let didSelectMissing = model.selectStackChild(stack: "st1", child: "missing")
        #expect(!didSelectMissing)
    }

    @Test("a split that must not focus leaves focus, history and zoom alone")
    func quietSplit() throws {
        var model = modelWithOne()
        model.split(pane: "p1", axis: .row, newPane: "p2", terminal: "t2")
        model.focus(pane: "p1", select: false)
        model.zoom("p2")
        let state = model.tab("tb1")
        let node = HcLayoutDocument.terminalNode(id: "p3", terminal: "t3")
        let inserted = model.splitWith(pane: "p2", axis: .row, node: node, focus: false)
        #expect(inserted)
        #expect(model.tab("tb1")?.focused == state?.focused)
        #expect(model.tab("tb1")?.before == state?.before)
        #expect(model.tab("tb1")?.zoomed == state?.zoomed)
        #expect(model.tab("tb1")?.root.panes.count == 3)
    }
}
