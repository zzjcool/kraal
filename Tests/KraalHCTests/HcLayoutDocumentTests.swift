// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import Testing

@testable import KraalHC

@Suite("Shared layout document")
struct HcLayoutDocumentTests {
    private func fixture() throws -> JSONValue {
        let url = try #require(Bundle.module.url(
            forResource: "herdr-app-layout",
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }

    private func simple() -> JSONValue {
        .object(["spaces": .array([
            .object([
                "id": .string("sp1"),
                "name": .string("work"),
                "folder": .string("/tmp"),
                "tabs": .array([
                    .object([
                        "id": .string("tb1"),
                        "name": .string("one"),
                        "root": .object([
                            "id": .string("root"),
                            "type": .string("row"),
                            "look": .object(["theme": .string("dark")]),
                            "children": .array([
                                .object([
                                    "id": .string("x1"),
                                    "type": .string("block"),
                                    "content": .object(["terminal": .string("t1")]),
                                    "title": .string("shell"),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
        ])])
    }

    @Test("loads an official-shaped document and writes it back unchanged")
    func roundTrip() throws {
        let value = try fixture()
        let document = try HcLayoutDocument(value: value)
        #expect(document.value == value)
        #expect(document.spaces.map(\.id) == ["sp1"])
        #expect(document.spaces[0].tabs.map(\.id) == ["tb1"])
        let root = try #require(document.spaces[0].tabs[0].root)
        #expect(root.type == "row")
        #expect(root.children.map(\.id) == ["x1", "st1"])
        #expect(root.children[1].children.map(\.id) == ["m1", "x2"])
        #expect(root.children[1].children[0].type == "block")
        #expect(root.children[1].children[0].terminal == nil)
        #expect(root.children[1].children[0].raw["content"]?["mod"]?.stringValue == "markdown")
    }

    private func split(
        _ document: inout HcLayoutDocument,
        _ pane: String,
        _ axis: HcLayoutAxis,
        space: String = "sp1",
        tab: String = "tb1"
    ) -> Bool {
        document.split(HcLayoutSplit(
            space: space,
            tab: tab,
            pane: pane,
            axis: axis,
            newNode: HcLayoutDocument.terminalNode(id: "x2", terminal: "t2"),
            containerID: "s1"
        ))
    }

    @Test("splitting along the parent's axis divides the target's weight")
    func splitSameAxis() throws {
        var document = try HcLayoutDocument(value: simple())
        let didSplit = split(&document, "x1", .row)
        #expect(didSplit)
        let root = try #require(document.spaces[0].tabs[0].root)
        #expect(root.children.map(\.id) == ["x1", "x2"])
        #expect(root.children[0].raw["size"]?["weight"]?.doubleValue == 0.5)
        #expect(root.children[1].raw["size"]?["weight"]?.doubleValue == 0.5)
        #expect(root.children[0].raw["title"]?.stringValue == "shell")
        #expect(root.raw["look"]?["theme"]?.stringValue == "dark")
        #expect(document.spaces[0].tabs[0].raw["name"]?.stringValue == "one")
    }

    @Test("splitting across the axis wraps the pane and keeps its unknown fields")
    func splitAcrossAxis() throws {
        var document = try HcLayoutDocument(value: simple())
        let didSplit = split(&document, "x1", .column)
        #expect(didSplit)
        let root = try #require(document.spaces[0].tabs[0].root)
        #expect(root.children.map(\.id) == ["s1"])
        let wrapper = root.children[0]
        #expect(wrapper.type == "column")
        #expect(wrapper.children.map(\.id) == ["x1", "x2"])
        #expect(wrapper.children[0].raw["title"]?.stringValue == "shell")
        #expect(wrapper.children[1].raw["size"] == nil)
    }

    @Test("a missing space, tab, or pane changes nothing")
    func missingTargets() throws {
        let original = try HcLayoutDocument(value: simple())
        var document = original
        let missingSpace = split(&document, "x1", .row, space: "nope")
        #expect(!missingSpace)
        let missingTab = split(&document, "x1", .row, tab: "nope")
        #expect(!missingTab)
        let missingPane = split(&document, "nope", .row)
        #expect(!missingPane)
        #expect(document == original)
    }

    @Test("splitting the root wraps the whole tree")
    func splitRoot() throws {
        var document = try HcLayoutDocument(value: simple())
        let didSplit = split(&document, "root", .column)
        #expect(didSplit)
        let root = try #require(document.spaces[0].tabs[0].root)
        #expect(root.id == "s1")
        #expect(root.type == "column")
        #expect(root.children.map(\.id) == ["root", "x2"])
        #expect(root.children[0].raw["children"] != nil)
    }

    @Test("a malformed document names the bad part")
    func malformed() {
        #expect(throws: HcLayoutError.corrupt("the root is not an object")) {
            try HcLayoutDocument(value: .array([]))
        }
        #expect(throws: HcLayoutError.corrupt("spaces is not an array")) {
            try HcLayoutDocument(value: .object(["spaces": .string("nope")]))
        }
        #expect(throws: HcLayoutError.corrupt("spaces[0].tabs is not an array")) {
            try HcLayoutDocument(value: .object(["spaces": .array([
                .object(["id": .string("sp1"), "tabs": .string("nope")]),
            ])]))
        }
    }

    @Test("an unwritten document is empty and still writable")
    func unwritten() throws {
        let document = try HcLayoutDocument(value: nil)
        #expect(document.spaces.isEmpty)
        #expect(document.value == HcLayoutDocument.empty)
    }
}
