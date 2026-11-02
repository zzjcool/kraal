// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The client's shared world: spaces, each with tabs, each holding a tree of
// panes. Values only; every rule lives in `KraalModel`.
//
// Ids are qualified with the machine that owns them (`rohan/sp…`), matching the
// core's terminal addresses. A machine's shared document stores them local; the
// model qualifies on load and strips on write.

import Foundation
import KraalHC

public typealias KraalAxis = HcLayoutAxis

public struct KraalRecent: Codable, Equatable, Sendable {
    public var name: String
    public var folder: String

    public init(name: String, folder: String) {
        self.name = name
        self.folder = folder
    }
}

/// A terminal's repo and branch, used for an unnamed space's title.
public struct KraalFolderInfo: Equatable, Sendable {
    public var top: String
    public var branch: String?

    public init(top: String, branch: String? = nil) {
        self.top = top
        self.branch = branch
    }
}

public enum KraalEdge: String, CaseIterable, Sendable {
    case top
    case right
    case bottom
    case left

    /// Left/right split a row; top/bottom a column.
    public var axis: KraalAxis {
        self == .left || self == .right ? .row : .column
    }

    /// The source goes before the target when dropped on the top or left edge.
    public var beforeTarget: Bool {
        self == .top || self == .left
    }
}

/// One node of a tab's arrangement, kept as the object the core stores.
public struct KraalNode: Identifiable, Equatable, Sendable {
    public let raw: JSONValue

    public init(raw: JSONValue) {
        self.raw = raw
    }

    public var id: String { raw["id"]?.stringValue ?? "" }
    public var type: String { raw["type"]?.stringValue ?? "" }
    public var terminal: String? { raw["content"]?["terminal"]?.stringValue }
    public var children: [KraalNode] { (raw["children"]?.arrayValue ?? []).map(KraalNode.init(raw:)) }
    public var isPane: Bool { type == "block" }
    public var isContainer: Bool { ["row", "column", "stack"].contains(type) }

    /// This node and its descendants, depth first.
    public var all: [KraalNode] {
        [self] + children.flatMap(\.all)
    }

    public var panes: [KraalNode] { all.filter(\.isPane) }

    public var terminals: [String] { all.compactMap(\.terminal) }

    public func find(_ id: String) -> KraalNode? {
        all.first { $0.id == id }
    }
}

public struct KraalTab: Identifiable, Equatable, Sendable {
    public let id: String
    /// The name stored in the shared document; empty means unnamed.
    public let name: String
    public let root: KraalNode
    public let focused: String?
    /// Most recent last, capped at 32 by the model.
    public let before: [String]
    public let zoomed: String?
    /// Put away at this time; still running.
    public let settled: UInt64?
    /// 1-based place in the space, for an unnamed tab.
    public let number: Int

    public var displayName: String { name.isEmpty ? "\(number)" : name }

    public var focusedPane: String? {
        if let focused, root.find(focused) != nil { return focused }
        return root.panes.first?.id
    }

    /// What to draw: the zoomed pane alone when one is zoomed.
    public var shown: KraalNode {
        if let zoomed, let node = root.find(zoomed) { return node }
        return root
    }

    public var panes: [KraalNode] { root.panes }

    public var terminals: [String] { root.terminals }
}

public struct KraalSpace: Identifiable, Equatable, Sendable {
    public let id: String
    /// The name stored in the shared document; empty means derived.
    public let name: String
    public let folder: String
    public let machine: String?
    public let tabs: [KraalTab]
    public let activeTab: String?
    /// What the sidebar calls it: the stored name, else the first terminal's folder.
    public let displayName: String

    public var active: KraalTab? {
        if let activeTab, let tab = tabs.first(where: { $0.id == activeTab }) { return tab }
        return tabs.first
    }

    public var terminals: [String] { tabs.flatMap(\.terminals) }
}

/// What a new tab starts with: one terminal pane.
public struct KraalTabSeed: Equatable, Sendable {
    public let id: String
    public let name: String
    public let paneID: String
    public let terminal: String

    public init(id: String, name: String = "", paneID: String, terminal: String) {
        self.id = id
        self.name = name
        self.paneID = paneID
        self.terminal = terminal
    }
}
