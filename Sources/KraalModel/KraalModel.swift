// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The client model: spaces/tabs/panes merged from one shared document per
// machine, plus this screen's private view state.
//
// Shared documents store machine-local ids; the model qualifies them with the
// machine name so a terminal address, a pane id and a view entry all read the
// same. Writing projects a machine's spaces back to local ids.

import Foundation
import KraalHC

public struct KraalModel: Equatable, Sendable {
    /// Spaces with qualified ids, in display order. Each one came from exactly
    /// one machine's `herdr-app` document.
    public internal(set) var spacesValue: JSONValue
    public internal(set) var view: KraalView
    public var home: String
    /// Pane id → the folder its program is in now.
    public var paneFolders: [String: String]
    /// Terminal address → its repo (worktree top) and branch.
    public var terminalFolders: [String: KraalFolderInfo]

    public init(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        view: KraalView = KraalView(),
        recent: [KraalRecent]? = nil
    ) {
        self.home = home
        self.view = view
        self.view.recent = recent ?? view.recent
        spacesValue = .array([])
        paneFolders = [:]
        terminalFolders = [:]
        pruneView()
    }

    /// Spaces closed on this screen, newest first. Part of the private view,
    /// so it travels in `view.json` and never in the shared document.
    public var recent: [KraalRecent] {
        get { view.recent }
        set { view.recent = newValue }
    }

    // MARK: Reading

    public var sharedValue: JSONValue { .object(["spaces": spacesValue]) }

    /// Every space, local first, then by machine name; document order within one.
    public var spaces: [KraalSpace] {
        orderedSpaces().enumerated().map { buildSpace($0.element, number: $0.offset) }
    }

    public var activeSpace: KraalSpace? {
        if let active = view.activeSpace, let space = spaces.first(where: { $0.id == active }) {
            return space
        }
        return spaces.first
    }

    public var activeTab: KraalTab? { activeSpace?.active }

    public var focusedPane: String? { activeTab?.focusedPane }

    public func space(_ id: String) -> KraalSpace? {
        spaces.first { $0.id == id }
    }

    public func tab(_ id: String) -> KraalTab? {
        spaces.lazy.flatMap(\.tabs).first { $0.id == id }
    }

    /// The tab a pane belongs to, anywhere in the model.
    public func tab(ofPane pane: String) -> KraalTab? {
        spaces.lazy.flatMap(\.tabs).first { $0.root.find(pane) != nil }
    }

    public var machines: [String?] {
        var seen: [String?] = []
        for space in spaces where !seen.contains(space.machine) {
            seen.append(space.machine)
        }
        return seen
    }

    // MARK: Documents

    /// Replaces one machine's spaces with `document`'s, qualifying their ids.
    ///
    /// View state is keyed by the qualified ids and is kept across a reconnect;
    /// entries whose spaces/tabs are gone are pruned.
    public mutating func apply(_ document: HcLayoutDocument, for machine: String? = nil) {
        let incoming = (document.value["spaces"]?.arrayValue ?? []).map { qualify(space: $0, machine: machine) }
        let kept = (spacesValue.arrayValue ?? []).filter { machineOf(space: $0) != machine }
        spacesValue = .array(ordered(kept + incoming))
        pruneView(for: machine)
    }

    /// This machine's spaces as its shared document stores them (local ids).
    public func project(for machine: String? = nil) -> HcLayoutDocument? {
        let spaces = (spacesValue.arrayValue ?? [])
            .filter { machineOf(space: $0) == machine }
            .map { unqualify(space: $0, machine: machine) }
        return try? HcLayoutDocument(value: .object(["spaces": .array(spaces)]))
    }

    // MARK: View persistence

    public func encodedView() throws -> Data { try view.encoded() }

    /// Loads this screen's private view. Entries for machines whose documents
    /// have not arrived yet are kept: they are not stale, they are unloaded.
    public mutating func loadView(_ data: Data) throws {
        view = try KraalView(data: data)
    }

    /// Drops view entries for every machine that has no document loaded.
    public mutating func pruneView() {
        let machines = Set((spacesValue.arrayValue ?? []).map { machineOf(space: $0) ?? "" })
        for machine in machines {
            pruneView(for: machine.isEmpty ? nil : machine)
        }
    }

    /// A document that is gone takes that machine's view entries with it.
    /// Other machines' entries stay untouched: their documents may just not
    /// have loaded yet.
    public mutating func pruneView(for machine: String?) {
        let spaces = (spacesValue.arrayValue ?? []).filter { machineOf(space: $0) == machine }
        let spaceIDs = Set(spaces.compactMap { $0["id"]?.stringValue })
        let tabIDs = Set(spaces.flatMap { space in
            (space["tabs"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
        })
        func belongs(_ id: String) -> Bool {
            guard let machine else { return !id.contains("/") }
            return id.hasPrefix(machine + "/")
        }
        view.activeTabs = view.activeTabs.filter { entry in
            guard belongs(entry.key) else { return true }
            return spaceIDs.contains(entry.key) && tabIDs.contains(entry.value)
        }
        view.tabs = view.tabs.filter { entry in
            guard belongs(entry.key) else { return true }
            return tabIDs.contains(entry.key)
        }
        if let active = view.activeSpace, belongs(active), !spaceIDs.contains(active) {
            view.activeSpace = nil
        }
    }

    // MARK: Naming

    public static func folderName(_ path: String, home: String) -> String {
        let full = path
        let trimmedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
        let trimmedHome = home.trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
        if full.isEmpty || trimmedPath == trimmedHome { return "~" }
        if trimmedPath.isEmpty { return String(full.prefix(1)) }
        let components = trimmedPath.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        return components.last.map(String.init) ?? trimmedPath
    }

    /// Space title: its name, else the first terminal's repo, else its folder.
    public func displayName(for space: KraalSpace) -> String {
        if !space.name.isEmpty { return space.name }
        let first = space.tabs.lazy.flatMap(\.root.panes).first { $0.terminal != nil }
        let folder = first?.terminal.flatMap { terminalFolders[$0]?.top }
            ?? first.flatMap { paneFolders[$0.id] }
            ?? space.folder
        return Self.folderName(folder, home: home)
    }

    // MARK: Ids

    public func freshID(_ prefix: String, machine: String? = nil) -> String {
        let suffix = String(UInt64.random(in: 0 ..< UInt64.max), radix: 16).prefix(12)
        let local = prefix + suffix
        return qualify(local, machine)
    }

    public func freshSpaceID(machine: String? = nil) -> String { freshID("sp", machine: machine) }
    public func freshTabID(machine: String? = nil) -> String { freshID("tb", machine: machine) }
    public func freshPaneID(machine: String? = nil) -> String { freshID("p", machine: machine) }

    // MARK: Internals

    func orderedSpaces() -> [JSONValue] { ordered(spacesValue.arrayValue ?? []) }

    func ordered(_ spaces: [JSONValue]) -> [JSONValue] {
        spaces.enumerated().sorted { lhs, rhs in
            let left = machineOf(space: lhs.element) ?? ""
            let right = machineOf(space: rhs.element) ?? ""
            if left != right { return left < right }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// The machine part of a qualified id (`rohan/t7` → `rohan`), nil for local.
    func machineOf(id: String) -> String? {
        let parts = id.split(separator: "/", maxSplits: 1)
        return parts.count == 2 ? String(parts[0]) : nil
    }

    func machineOf(space: JSONValue) -> String? {
        space["id"]?.stringValue.flatMap(machineOf(id:))
    }

    /// Prefixes every id/terminal in a machine's (local) document.
    func qualify(space: JSONValue, machine: String?) -> JSONValue {
        guard var object = space.objectValue else { return space }
        object["id"] = .string(qualify(object["id"]?.stringValue ?? "", machine))
        if var tabs = object["tabs"]?.arrayValue {
            for index in tabs.indices {
                guard var tab = tabs[index].objectValue else { continue }
                tab["id"] = .string(qualify(tab["id"]?.stringValue ?? "", machine))
                if let root = tab["root"] { tab["root"] = qualify(node: root, machine: machine) }
                tabs[index] = .object(tab)
            }
            object["tabs"] = .array(tabs)
        }
        return .object(object)
    }

    func qualify(node: JSONValue, machine: String?) -> JSONValue {
        guard machine != nil, var object = node.objectValue else { return node }
        object["id"] = .string(qualify(object["id"]?.stringValue ?? "", machine))
        if var content = object["content"]?.objectValue {
            if let terminal = content["terminal"]?.stringValue {
                content["terminal"] = .string(qualify(terminal, machine))
            }
            object["content"] = .object(content)
        }
        if let active = object["active"]?.stringValue {
            object["active"] = .string(qualify(active, machine))
        }
        if let children = object["children"]?.arrayValue {
            object["children"] = .array(children.map { qualify(node: $0, machine: machine) })
        }
        return .object(object)
    }

    /// Strips the machine prefix for a write; local documents keep their ids.
    func unqualify(space: JSONValue, machine: String?) -> JSONValue {
        guard var object = space.objectValue else { return space }
        object["id"] = .string(unqualify(object["id"]?.stringValue ?? "", machine))
        if var tabs = object["tabs"]?.arrayValue {
            for index in tabs.indices {
                guard var tab = tabs[index].objectValue else { continue }
                tab["id"] = .string(unqualify(tab["id"]?.stringValue ?? "", machine))
                if let root = tab["root"] { tab["root"] = unqualify(node: root, machine: machine) }
                tabs[index] = .object(tab)
            }
            object["tabs"] = .array(tabs)
        }
        return .object(object)
    }

    func unqualify(node: JSONValue, machine: String?) -> JSONValue {
        guard machine != nil, var object = node.objectValue else { return node }
        object["id"] = .string(unqualify(object["id"]?.stringValue ?? "", machine))
        if var content = object["content"]?.objectValue {
            if let terminal = content["terminal"]?.stringValue {
                content["terminal"] = .string(unqualify(terminal, machine))
            }
            object["content"] = .object(content)
        }
        if let active = object["active"]?.stringValue {
            object["active"] = .string(unqualify(active, machine))
        }
        if let children = object["children"]?.arrayValue {
            object["children"] = .array(children.map { unqualify(node: $0, machine: machine) })
        }
        return .object(object)
    }

    func qualify(_ id: String, _ machine: String?) -> String {
        guard let machine, !id.isEmpty, !id.hasPrefix(machine + "/") else { return id }
        return "\(machine)/\(id)"
    }

    func unqualify(_ id: String, _ machine: String?) -> String {
        guard let machine, id.hasPrefix(machine + "/") else { return id }
        return String(id.dropFirst(machine.count + 1))
    }

    private func buildSpace(_ raw: JSONValue, number: Int) -> KraalSpace {
        let space = HcLayoutSpace(raw: raw)
        let tabs = space.tabs.enumerated().map { index, tab -> KraalTab in
            let state = view.tabs[tab.id] ?? KraalTabView()
            return KraalTab(
                id: tab.id,
                name: tab.name,
                root: KraalNode(raw: tab.root?.raw ?? .object(["type": .string("row"),
                                                               "children": .array([])])),
                focused: state.focused,
                before: state.before,
                zoomed: state.zoomed,
                settled: state.settled,
                number: index + 1
            )
        }
        let activeTab = view.activeTabs[space.id] ?? tabs.first?.id
        let machine = machineOf(space: raw)
        let result = KraalSpace(
            id: space.id,
            name: space.name,
            folder: space.folder,
            machine: machine,
            tabs: tabs,
            activeTab: activeTab,
            displayName: ""
        )
        return KraalSpace(
            id: result.id,
            name: result.name,
            folder: result.folder,
            machine: result.machine,
            tabs: result.tabs,
            activeTab: result.activeTab,
            displayName: displayName(for: result)
        )
    }
}
