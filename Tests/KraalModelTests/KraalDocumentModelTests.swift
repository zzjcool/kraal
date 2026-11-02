// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import KraalHC
import Testing

@testable import KraalModel

@Suite("Model documents")
struct KraalDocumentModelTests {
    private func document(
        space: String, tab: String, pane: String, terminal: String, name: String = ""
    ) throws -> HcLayoutDocument {
        try HcLayoutDocument(value: .object([
            "spaces": .array([
                .object([
                    "id": .string(space),
                    "name": .string(name),
                    "folder": .string("/src/\(space)"),
                    "tabs": .array([
                        .object([
                            "id": .string(tab),
                            "name": .string(""),
                            "root": .object([
                                "id": .string(tab),
                                "type": .string("row"),
                                "children": .array([
                                    .object([
                                        "id": .string(pane),
                                        "type": .string("block"),
                                        "content": .object(["terminal": .string(terminal)]),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
        ]))
    }

    @Test("a local document loads with its ids unchanged")
    func localDocument() throws {
        var model = KraalModel(home: "/home/me")
        model.apply(try document(space: "sp1", tab: "tb1", pane: "p1", terminal: "t1"))
        let space = try #require(model.spaces.first)
        #expect(space.id == "sp1")
        #expect(space.machine == nil)
        #expect(space.tabs.first?.root.terminals == ["t1"])
        #expect(model.project(for: nil)?.value == (try document(
            space: "sp1", tab: "tb1", pane: "p1", terminal: "t1"
        )).value)
    }

    @Test("a remote document qualifies ids and projects them back")
    func remoteDocument() throws {
        var model = KraalModel(home: "/home/me")
        let remote = try document(space: "sp1", tab: "tb1", pane: "p1", terminal: "t1")
        model.apply(remote, for: "alpha")
        let space = try #require(model.spaces.first)
        #expect(space.id == "alpha/sp1")
        #expect(space.machine == "alpha")
        #expect(space.tabs.first?.id == "alpha/tb1")
        #expect(space.tabs.first?.root.panes.first?.id == "alpha/p1")
        #expect(space.tabs.first?.root.terminals == ["alpha/t1"])
        #expect(model.project(for: "alpha")?.value == remote.value)
        #expect(model.project(for: "beta")?.value == HcLayoutDocument.empty)
    }

    @Test("loading the same machine twice replaces, never duplicates")
    func replace() throws {
        var model = KraalModel(home: "/home/me")
        model.apply(try document(space: "sp1", tab: "tb1", pane: "p1", terminal: "t1"), for: "alpha")
        model.apply(try document(space: "sp2", tab: "tb2", pane: "p2", terminal: "t2"), for: "alpha")
        #expect(model.spaces.map(\.id) == ["alpha/sp2"])
        model.apply(try document(space: "sp3", tab: "tb3", pane: "p3", terminal: "t3"))
        #expect(model.spaces.map(\.id) == ["sp3", "alpha/sp2"])
    }

    @Test("view entries survive a reload and vanish with their tab")
    func prune() throws {
        var model = KraalModel(home: "/home/me")
        model.apply(try document(space: "sp1", tab: "tb1", pane: "p1", terminal: "t1"), for: "alpha")
        model.focus(pane: "alpha/p1", select: true)
        model.apply(try document(space: "sp1", tab: "tb1", pane: "p1", terminal: "t1"), for: "alpha")
        #expect(model.view.tabs["alpha/tb1"]?.focused == "alpha/p1")
        #expect(model.view.activeTabs["alpha/sp1"] == "alpha/tb1")
        model.apply(try document(space: "sp2", tab: "tb2", pane: "p2", terminal: "t2"), for: "alpha")
        #expect(model.view.tabs.isEmpty)
        #expect(model.view.activeTabs.isEmpty)
        #expect(model.view.activeSpace == nil)
    }

    @Test("split ids on a machine are fresh and project back without a prefix")
    func remoteSplit() throws {
        var model = KraalModel(home: "/home/me")
        model.apply(try document(space: "sp1", tab: "tb1", pane: "p1", terminal: "t1"), for: "alpha")
        let paneID = model.freshPaneID(machine: "alpha")
        #expect(paneID.hasPrefix("alpha/p"))
        let didSplit = model.split(pane: "alpha/p1", axis: .row, newPane: paneID, terminal: "t9")
        #expect(didSplit)
        #expect(model.focusedPane == paneID)
        let projected = try #require(model.project(for: "alpha"))
        let space = try #require(projected.value["spaces"]?[0])
        #expect(space["tabs"]?[0]?["root"]?["children"]?.arrayValue?.count == 2)
        let terminals = (space["tabs"]?[0]?["root"]?["children"]?.arrayValue ?? [])
            .compactMap { $0["content"]?["terminal"]?.stringValue }
        #expect(terminals.sorted() == ["t1", "t9"])
        #expect(terminals.allSatisfy { !$0.contains("/") })
    }

    @Test("view.json has only private fields")
    func viewShape() throws {
        var model = modelWithOne()
        model.split(pane: "p1", axis: .row, newPane: "p2", terminal: "t2")
        model.focus(pane: "p1", select: false)
        model.zoom("p2")
        model.settle("tb1", at: 42)
        let data = try model.encodedView()
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["active_space", "active_tabs", "tabs"])
        let tabs = try #require(json["tabs"] as? [String: Any])
        let tab = try #require(tabs["tb1"] as? [String: Any])
        #expect(Set(tab.keys) == ["focused", "before", "zoomed", "settled"])
        #expect(tab["focused"] as? String == "p1")
        #expect(tab["before"] as? [String] == ["p2"])
        #expect(tab["zoomed"] as? String == "p2")
        #expect(tab["settled"] as? UInt64 == 42)

        let text = try #require(String(data: data, encoding: .utf8))
        for shared in ["root", "folder", "terminal", "spaces", "children"] {
            #expect(!text.contains("\"\(shared)\""))
        }
    }

    @Test("a saved view round-trips and tolerates missing fields")
    func viewRoundTrip() throws {
        var model = modelWithOne()
        model.focus(pane: "p1", select: false)
        model.settle("tb1", at: 7)
        let data = try model.encodedView()
        var loaded = model
        try loaded.loadView(data)
        #expect(loaded.view == model.view)

        let sparse = Data(#"{"active_space":"sp1"}"#.utf8)
        try loaded.loadView(sparse)
        #expect(loaded.view.activeSpace == "sp1")
        #expect(loaded.view.activeTabs.isEmpty)
        #expect(loaded.view.tabs.isEmpty)
    }
}

@Suite("Model fixture")
struct KraalModelFixtureTests {
    private func fixture() throws -> HcLayoutDocument {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("KraalHCTests/Fixtures/herdr-app-layout.json")
        let data = try Data(contentsOf: url)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        return try HcLayoutDocument(value: value)
    }

    @Test("the official layout loads, qualifies and projects back unchanged")
    func officialLayout() throws {
        let document = try fixture()
        var model = KraalModel(home: "/Users/me")
        model.apply(document, for: "alpha")
        let space = try #require(model.spaces.first)
        #expect(space.id == "alpha/sp1")
        #expect(space.tabs.first?.root.id == "alpha/root")
        #expect(space.tabs.first?.root.terminals == ["alpha/t1", "alpha/t2"])
        #expect(space.tabs.first?.root.panes.count == 3)
        #expect(space.tabs.first?.root.children[0].raw["futureNodeField"] != nil)
        #expect(space.tabs.first?.root.children[1].raw["header"]?["show"]?.boolValue == true)
        #expect(model.project(for: "alpha")?.value == document.value)
    }

    @Test("editing a loaded layout keeps everything the model does not know")
    func editsKeepUnknownFields() throws {
        var model = KraalModel(home: "/Users/me")
        model.apply(try fixture(), for: "alpha")
        let didSplit = model.split(pane: "alpha/x1", axis: .column, newPane: "p9", terminal: "t3")
        #expect(didSplit)
        let projected = try #require(model.project(for: "alpha")?.value)
        #expect(projected["spaces"]?[0]?["futureSpaceField"]?["kept"]?.boolValue == true)
        let tab = try #require(projected["spaces"]?[0]?["tabs"]?[0])
        #expect(tab["futureTabField"]?.intValue == 7)
        let root = try #require(tab["root"])
        #expect(root["look"]?["font"]?.stringValue == "Berkeley Mono")
        #expect(root["floating"]?.arrayValue?.count == 1)
        #expect(root["children"]?.arrayValue?.count == 2)
        let node = try #require(KraalNode(raw: root).find("x1"))
        #expect(node.raw["futureNodeField"]?.arrayValue?.count == 4)
    }
}
