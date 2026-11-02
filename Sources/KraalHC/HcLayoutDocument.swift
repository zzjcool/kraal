// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The shared `herdr-app` layout: spaces → tabs → a row/column/stack tree.
//
// It is edited as raw JSON. A node carries fields Kraal does not understand
// (mods, floats, look, future additions); rebuilding nodes from a typed struct
// would drop them, so every mutation copies the original object and touches
// only `children`/`size`. Focus, zoom and settle are private to a screen and
// are not part of this document.

import Foundation

public enum HcLayoutError: Error, Sendable, Equatable, CustomStringConvertible {
    case corrupt(String)
    case invalidNode(String)

    public var description: String {
        switch self {
        case let .corrupt(reason): "layout document: \(reason)"
        case let .invalidNode(reason): "layout node: \(reason)"
        }
    }
}

public enum HcLayoutAxis: String, Sendable, Equatable {
    case row
    case column

    var type: String { rawValue }
}

public struct HcLayoutSpace: Sendable, Equatable, Identifiable {
    public let raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var id: String { raw["id"]?.stringValue ?? "" }
    public var name: String { raw["name"]?.stringValue ?? "" }
    public var folder: String { raw["folder"]?.stringValue ?? "" }
    public var tabs: [HcLayoutTab] { (raw["tabs"]?.arrayValue ?? []).map(HcLayoutTab.init(raw:)) }
}

public struct HcLayoutTab: Sendable, Equatable, Identifiable {
    public let raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var id: String { raw["id"]?.stringValue ?? "" }
    public var name: String { raw["name"]?.stringValue ?? "" }
    public var root: HcLayoutNode? {
        guard let root = raw["root"], !root.isNull else { return nil }
        return HcLayoutNode(raw: root)
    }
}

public struct HcLayoutNode: Sendable, Equatable, Identifiable {
    public let raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var id: String { raw["id"]?.stringValue ?? "" }
    /// `block`, `row`, `column`, `stack`, or a kind this build does not know.
    public var type: String { raw["type"]?.stringValue ?? "" }
    public var children: [HcLayoutNode] { (raw["children"]?.arrayValue ?? []).map(HcLayoutNode.init(raw:)) }
    public var terminal: String? { raw["content"]?["terminal"]?.stringValue }
    public var isContainer: Bool { ["row", "column", "stack"].contains(type) }
    public var isTerminal: Bool { type == "block" && terminal != nil }
}

public struct HcLayoutSplit: Sendable, Equatable {
    public let spaceID: String
    public let tabID: String
    public let paneID: String
    public let axis: HcLayoutAxis
    public let newNode: JSONValue
    public let containerID: String

    public init(
        space spaceID: String,
        tab tabID: String,
        pane paneID: String,
        axis: HcLayoutAxis,
        newNode: JSONValue,
        containerID: String
    ) {
        self.spaceID = spaceID
        self.tabID = tabID
        self.paneID = paneID
        self.axis = axis
        self.newNode = newNode
        self.containerID = containerID
    }
}

public struct HcLayoutDocument: Sendable, Equatable {
    public static let empty = JSONValue.object(["spaces": .array([])])

    public private(set) var value: JSONValue

    public init(value: JSONValue?) throws {
        guard let value, !value.isNull else {
            self.value = Self.empty
            return
        }
        guard value.objectValue != nil else {
            throw HcLayoutError.corrupt("the root is not an object")
        }
        if let spaces = value["spaces"] {
            guard let list = spaces.arrayValue else {
                throw HcLayoutError.corrupt("spaces is not an array")
            }
            for (index, space) in list.enumerated() {
                guard space.objectValue != nil else {
                    throw HcLayoutError.corrupt("spaces[\(index)] is not an object")
                }
                if let tabs = space["tabs"] {
                    guard let tabs = tabs.arrayValue else {
                        throw HcLayoutError.corrupt("spaces[\(index)].tabs is not an array")
                    }
                    for (tabIndex, tab) in tabs.enumerated() where tab.objectValue == nil {
                        throw HcLayoutError.corrupt("spaces[\(index)].tabs[\(tabIndex)] is not an object")
                    }
                }
            }
        }
        self.value = value
    }

    public var spaces: [HcLayoutSpace] {
        (value["spaces"]?.arrayValue ?? []).map(HcLayoutSpace.init(raw:))
    }

    /// Splits `paneID` with `newNode`, reusing the parent when it already has
    /// `axis` (the new node takes half of the target's weight); otherwise the
    /// pane is wrapped in a new container whose id is `containerID`.
    ///
    /// Returns false when the space/tab/pane does not exist. The document is
    /// left untouched then.
    @discardableResult
    public mutating func split(_ request: HcLayoutSplit) -> Bool {
        guard request.newNode["id"]?.stringValue?.isEmpty == false else { return false }
        guard var spaces = value["spaces"]?.arrayValue,
              let spaceIndex = spaces.firstIndex(where: { $0["id"]?.stringValue == request.spaceID }),
              var space = spaces[spaceIndex].objectValue,
              var tabs = space["tabs"]?.arrayValue,
              let tabIndex = tabs.firstIndex(where: { $0["id"]?.stringValue == request.tabID }),
              var tab = tabs[tabIndex].objectValue,
              let root = tab["root"]
        else { return false }

        guard let updated = Self.split(node: root, target: request.paneID, axis: request.axis,
                                       newNode: request.newNode, containerID: request.containerID)
        else { return false }
        tab["root"] = updated
        tabs[tabIndex] = .object(tab)
        space["tabs"] = .array(tabs)
        spaces[spaceIndex] = .object(space)
        value = .object(["spaces": .array(spaces)])
        return true
    }

    /// A terminal block for `split`, with no fields beyond what the core reads.
    public static func terminalNode(id: String, terminal: String) -> JSONValue {
        .object([
            "id": .string(id),
            "type": .string("block"),
            "content": .object(["terminal": .string(terminal)]),
        ])
    }

    // MARK: Tree

    private static func split(
        node: JSONValue,
        target: String,
        axis: HcLayoutAxis,
        newNode: JSONValue,
        containerID: String
    ) -> JSONValue? {
        guard var object = node.objectValue else { return nil }

        // The parent already runs along this axis: insert beside the target and
        // halve its weight (a pixel-sized pane keeps its pixels).
        if object["type"]?.stringValue == axis.type,
           var children = object["children"]?.arrayValue,
           let index = children.firstIndex(where: { $0["id"]?.stringValue == target }) {
            var targetNode = children[index]
            let share = targetNode["size"]?["weight"]?.doubleValue ?? 1
            if targetNode["size"]?["px"] == nil {
                targetNode.setSize(weight: share / 2)
                children[index] = targetNode
            }
            var inserted = newNode
            inserted.setSize(weight: share / 2)
            children.insert(inserted, at: index + 1)
            object["children"] = .array(children)
            return .object(object)
        }

        if let children = object["children"]?.arrayValue {
            for (index, child) in children.enumerated() {
                if let updated = split(node: child, target: target, axis: axis,
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
        // herdr-app (a 0.5 weight would render the same but not serialize alike).
        var wrapper: [String: JSONValue] = [
            "id": .string(containerID),
            "type": .string(axis.type),
            "children": .array([.object(object), newNode]),
        ]
        if let slotSize { wrapper["size"] = slotSize }
        return .object(wrapper)
    }
}

private extension JSONValue {
    mutating func setSize(weight: Double) {
        guard var object = objectValue else { return }
        object["size"] = .object(["weight": .number(weight)])
        self = .object(object)
    }
}
