// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Raw-JSON tree operations for the herdr-app layout.
//
// Every function copies the original objects and changes only the fields the
// operation owns. Unknown fields (look, floats, mods, future keys) survive.

import Foundation

public enum HcLayoutTree {
    public static func find(_ root: JSONValue, id: String) -> JSONValue? {
        guard let object = root.objectValue else { return nil }
        if object["id"]?.stringValue == id { return root }
        for child in object["children"]?.arrayValue ?? [] {
            if let found = find(child, id: id) { return found }
        }
        return nil
    }

    /// Leaf blocks in tree order, including mod/agent blocks.
    public static func panes(_ root: JSONValue) -> [JSONValue] {
        guard let object = root.objectValue else { return [] }
        if object["type"]?.stringValue == "block" { return [root] }
        return (object["children"]?.arrayValue ?? []).flatMap(panes)
    }

    /// Terminal addresses under this node, in tree order.
    public static func terminals(_ root: JSONValue) -> [String] {
        panes(root).compactMap { $0["content"]?["terminal"]?.stringValue }
    }

    /// Puts `newNode` beside `target` along `axis`; see `HcLayoutDocument.split`.
    public static func split(
        _ root: JSONValue,
        target: String,
        axis: HcLayoutAxis,
        newNode: JSONValue,
        containerID: String
    ) -> JSONValue? {
        guard var object = root.objectValue else { return nil }

        if object["type"]?.stringValue == axis.type,
           var children = object["children"]?.arrayValue,
           let index = children.firstIndex(where: { $0["id"]?.stringValue == target }) {
            var targetNode = children[index]
            let share = targetNode["size"]?["weight"]?.doubleValue ?? 1
            if targetNode["size"]?["px"] == nil {
                targetNode.setLayoutSize(weight: share / 2)
                children[index] = targetNode
            }
            var inserted = newNode
            inserted.setLayoutSize(weight: share / 2)
            children.insert(inserted, at: index + 1)
            object["children"] = .array(children)
            return .object(object)
        }

        if let children = object["children"]?.arrayValue {
            for (index, child) in children.enumerated() {
                if let updated = split(child, target: target, axis: axis,
                                       newNode: newNode, containerID: containerID) {
                    var children = children
                    children[index] = updated
                    object["children"] = .array(children)
                    return .object(object)
                }
            }
        }

        guard object["id"]?.stringValue == target else { return nil }
        let slotSize = object["size"]
        object.removeValue(forKey: "size")

        // A fresh container's children start equal: no size on either, as in
        // herdr-app (a 0.5 weight renders the same but does not serialize alike).
        var wrapper: [String: JSONValue] = [
            "id": .string(containerID),
            "type": .string(axis.type),
            "children": .array([.object(object), newNode]),
        ]
        if let slotSize { wrapper["size"] = slotSize }
        return .object(wrapper)
    }

    /// Removes `id` and returns the new root plus the removed node.
    ///
    /// A removed pane's share goes to the sibling before it (else the next one).
    /// Empty rows/columns disappear and a row/column left with one child gives
    /// way to it; a stack keeps its children. The root itself is never collapsed.
    public static func removing(_ root: JSONValue, id: String) -> (root: JSONValue, removed: JSONValue)? {
        guard var object = root.objectValue, object["id"]?.stringValue != id else { return nil }
        guard let removed = removeInner(&object, id: id) else { return nil }
        var newRoot = JSONValue.object(object)
        collapse(&newRoot)
        return (newRoot, removed)
    }

    /// Replaces the weights of one row/column. Unknown fields on the container
    /// and its children stay as they are; only `size.weight` changes.
    public static func resizing(_ root: JSONValue, container: String, weights: [Double]) -> JSONValue? {
        guard let targetPath = path(to: container, in: root),
              var target = node(at: targetPath, in: root),
              let type = target["type"]?.stringValue, type == "row" || type == "column",
              var children = target["children"]?.arrayValue,
              children.count == weights.count,
              weights.allSatisfy({ $0 > 0 })
        else { return nil }
        for index in children.indices {
            var child = children[index]
            child.setLayoutSize(weight: weights[index])
            children[index] = child
        }
        guard var object = target.objectValue else { return nil }
        object["children"] = .array(children)
        target = .object(object)
        var updated = root
        guard setNode(target, at: targetPath, in: &updated) else { return nil }
        return updated
    }

    /// Exchanges two nodes' places; sizes stay with the places, ids with the content.
    /// Makes `child` the visible block of a stack.
    public static func selecting(_ root: JSONValue, stack: String, child: String) -> JSONValue? {
        guard let stackPath = path(to: stack, in: root),
              let node = node(at: stackPath, in: root),
              node["type"]?.stringValue == "stack",
              node["children"]?.arrayValue?.contains(where: { $0["id"]?.stringValue == child }) == true
        else { return nil }
        var updated = node
        updated.setLayoutActive(child)
        var newRoot = root
        guard setNode(updated, at: stackPath, in: &newRoot) else { return nil }
        return newRoot
    }

    public static func swapping(_ root: JSONValue, _ first: String, _ second: String) -> JSONValue? {
        guard first != second,
              let firstPath = path(to: first, in: root),
              let secondPath = path(to: second, in: root),
              !isPrefix(firstPath, of: secondPath),
              !isPrefix(secondPath, of: firstPath),
              let firstNode = node(at: firstPath, in: root),
              let secondNode = node(at: secondPath, in: root)
        else { return nil }

        let firstSize = firstNode["size"]
        let secondSize = secondNode["size"]
        var newRoot = root
        var placedSecond = secondNode
        if let firstSize { placedSecond.setLayoutSizeJSON(firstSize) } else { placedSecond.removeLayoutSize() }
        var placedFirst = firstNode
        if let secondSize { placedFirst.setLayoutSizeJSON(secondSize) } else { placedFirst.removeLayoutSize() }
        guard setNode(placedSecond, at: firstPath, in: &newRoot),
              setNode(placedFirst, at: secondPath, in: &newRoot)
        else { return nil }
        return newRoot
    }

    // MARK: Helpers

    private static func removeInner(_ node: inout [String: JSONValue], id: String) -> JSONValue? {
        guard var children = node["children"]?.arrayValue else { return nil }
        if let index = children.firstIndex(where: { $0["id"]?.stringValue == id }) {
            let removed = children.remove(at: index)
            switch node["type"]?.stringValue {
            case "row", "column":
                let gone = weight(removed)
                let neighbor = index > 0 ? index - 1 : index
                if let gone, children.indices.contains(neighbor), let current = weight(children[neighbor]) {
                    children[neighbor].setLayoutSize(weight: current + gone)
                }
            case "stack":
                if node["active"]?.stringValue == id {
                    let active = children.indices.contains(index) ? children[index] : children.last
                    node["active"] = active?["id"] ?? .null
                }
            default:
                break
            }
            node["children"] = .array(children)
            return removed
        }
        for index in children.indices {
            guard var child = children[index].objectValue else { continue }
            if let removed = removeInner(&child, id: id) {
                children[index] = .object(child)
                node["children"] = .array(children)
                return removed
            }
        }
        return nil
    }

    private static func collapse(_ node: inout JSONValue) {
        guard var object = node.objectValue, var children = object["children"]?.arrayValue else { return }
        for index in children.indices {
            collapse(&children[index])
        }
        if object["type"]?.stringValue != "stack" {
            children.removeAll { child in
                isContainer(child) && (child["children"]?.arrayValue ?? []).isEmpty
            }
            for index in children.indices {
                guard isContainer(children[index]),
                      let only = children[index]["children"]?.arrayValue?.first,
                      children[index]["children"]?.arrayValue?.count == 1
                else { continue }
                var replacement = only
                if let size = children[index]["size"] { replacement.setLayoutSizeJSON(size) }
                children[index] = replacement
            }
        }
        object["children"] = .array(children)
        node = .object(object)
    }

    private static func isContainer(_ node: JSONValue) -> Bool {
        ["row", "column"].contains(node["type"]?.stringValue)
    }

    private static func weight(_ node: JSONValue) -> Double? {
        if let weight = node["size"]?["weight"]?.doubleValue { return weight }
        if node["size"]?["px"] != nil { return nil }
        return 1
    }

    private static func path(to id: String, in node: JSONValue) -> [Int]? {
        guard let object = node.objectValue else { return nil }
        if object["id"]?.stringValue == id { return [] }
        for (index, child) in (object["children"]?.arrayValue ?? []).enumerated() {
            if let tail = path(to: id, in: child) { return [index] + tail }
        }
        return nil
    }

    private static func node(at path: [Int], in root: JSONValue) -> JSONValue? {
        var current = root
        for index in path {
            guard let child = current["children"]?[index] else { return nil }
            current = child
        }
        return current
    }

    private static func setNode(_ value: JSONValue, at path: [Int], in root: inout JSONValue) -> Bool {
        if path.isEmpty {
            root = value
            return true
        }
        guard var object = root.objectValue, var children = object["children"]?.arrayValue else { return false }
        let index = path[0]
        guard children.indices.contains(index) else { return false }
        if path.count == 1 {
            children[index] = value
        } else if !setNode(value, at: Array(path.dropFirst()), in: &children[index]) {
            return false
        }
        object["children"] = .array(children)
        root = .object(object)
        return true
    }

    private static func isPrefix(_ prefix: [Int], of other: [Int]) -> Bool {
        prefix.count < other.count && Array(other.prefix(prefix.count)) == prefix
    }
}

extension JSONValue {
    fileprivate mutating func setLayoutSize(weight: Double) {
        setLayoutSizeJSON(.object(["weight": .number(weight)]))
    }

    fileprivate mutating func setLayoutSizeJSON(_ size: JSONValue) {
        guard var object = objectValue else { return }
        object["size"] = size
        self = .object(object)
    }

    fileprivate mutating func setLayoutActive(_ child: String) {
        guard var object = objectValue else { return }
        object["active"] = .string(child)
        self = .object(object)
    }

    fileprivate mutating func removeLayoutSize() {
        guard var object = objectValue else { return }
        object.removeValue(forKey: "size")
        self = .object(object)
    }
}
