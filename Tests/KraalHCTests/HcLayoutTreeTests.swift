// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import Testing

@testable import KraalHC

@Suite("Layout tree")
struct HcLayoutTreeTests {
    private func block(_ id: String, size: JSONValue? = nil) -> JSONValue {
        var node: [String: JSONValue] = [
            "id": .string(id),
            "type": .string("block"),
            "content": .object(["terminal": .string("t-\(id)")]),
        ]
        if let size { node["size"] = size }
        return .object(node)
    }

    private func container(_ id: String, _ type: String, _ children: [JSONValue], size: JSONValue? = nil) -> JSONValue {
        var node: [String: JSONValue] = ["id": .string(id), "type": .string(type), "children": .array(children)]
        if let size { node["size"] = size }
        return .object(node)
    }

    private func weight(_ value: Double) -> JSONValue { .object(["weight": .number(value)]) }

    @Test("a removed pane's weight goes to the sibling before it")
    func removeMiddle() throws {
        let root = container("root", "row", [
            block("a", size: weight(0.2)), block("b", size: weight(0.3)), block("c", size: weight(0.5)),
        ])
        let result = try #require(HcLayoutTree.removing(root, id: "b"))
        #expect(result.removed["id"]?.stringValue == "b")
        let children = result.root["children"]?.arrayValue ?? []
        #expect(children.map { $0["id"]?.stringValue } == ["a", "c"])
        #expect(children[0]["size"]?["weight"]?.doubleValue == 0.5)
        #expect(children[1]["size"]?["weight"]?.doubleValue == 0.5)
    }

    @Test("removing the first pane gives its weight to the next one")
    func removeFirst() throws {
        let root = container("root", "row", [
            block("a", size: weight(0.2)), block("b", size: weight(0.3)),
        ])
        let result = try #require(HcLayoutTree.removing(root, id: "a"))
        let children = result.root["children"]?.arrayValue ?? []
        #expect(children.map { $0["id"]?.stringValue } == ["b"])
        #expect(children[0]["size"]?["weight"]?.doubleValue == 0.5)
    }

    @Test("pixel-sized neighbors keep their pixels")
    func removeWithPixels() throws {
        let root = container("root", "row", [
            block("a", size: .object(["px": .number(200)])), block("b", size: weight(0.3)),
        ])
        let result = try #require(HcLayoutTree.removing(root, id: "b"))
        let children = result.root["children"]?.arrayValue ?? []
        #expect(children.count == 1)
        #expect(children[0]["size"]?["px"]?.doubleValue == 200)
        #expect(children[0]["size"]?["weight"] == nil)
    }

    @Test("a row left with one child gives way to it, inheriting its slot")
    func collapse() throws {
        let root = container("root", "row", [
            container("col", "column", [block("a"), block("b")], size: weight(0.7)),
            block("c", size: weight(0.3)),
        ])
        let result = try #require(HcLayoutTree.removing(root, id: "b"))
        // "col" is left with one child and is flattened; that child takes the
        // column's slot size, not a share of it.
        let children = result.root["children"]?.arrayValue ?? []
        #expect(children.map { $0["id"]?.stringValue } == ["a", "c"])
        #expect(children[0]["size"]?["weight"]?.doubleValue == 0.7)
    }

    @Test("empty rows and columns disappear; stacks keep their children")
    func emptyContainers() throws {
        let root = container("root", "row", [
            container("empty", "column", []),
            container("stack", "stack", [block("a"), block("b")]),
        ])
        let result = try #require(HcLayoutTree.removing(root, id: "a"))
        let children = result.root["children"]?.arrayValue ?? []
        #expect(children.map { $0["id"]?.stringValue } == ["stack"])
        #expect(children[0]["children"]?.arrayValue?.map { $0["id"]?.stringValue } == ["b"])
    }

    @Test("a closed stack child hands the stack to its neighbor")
    func stackActive() throws {
        var stack = container("stack", "stack", [block("a"), block("b"), block("c")])
        stack = .object({
            var object = stack.objectValue ?? [:]
            object["active"] = .string("b")
            return object
        }())
        let root = container("root", "row", [stack])
        let result = try #require(HcLayoutTree.removing(root, id: "b"))
        let active = result.root["children"]?[0]?["active"]?.stringValue
        #expect(active == "c")
    }

    @Test("swap exchanges places and keeps sizes with the places")
    func swap() throws {
        let root = container("root", "row", [
            block("a", size: weight(0.2)), block("b", size: weight(0.8)),
        ])
        let swapped = try #require(HcLayoutTree.swapping(root, "a", "b"))
        let children = swapped["children"]?.arrayValue ?? []
        #expect(children.map { $0["id"]?.stringValue } == ["b", "a"])
        #expect(children[0]["size"]?["weight"]?.doubleValue == 0.2)
        #expect(children[1]["size"]?["weight"]?.doubleValue == 0.8)
        #expect(children[0]["content"]?["terminal"]?.stringValue == "t-b")
    }

    @Test("an ancestor cannot swap with its descendant; the root cannot be removed")
    func invalid() {
        let root = container("root", "row", [container("col", "column", [block("a")])])
        #expect(HcLayoutTree.swapping(root, "col", "a") == nil)
        #expect(HcLayoutTree.removing(root, id: "root") == nil)
        #expect(HcLayoutTree.removing(root, id: "missing") == nil)
    }
}
