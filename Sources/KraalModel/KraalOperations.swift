// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// What a person does to spaces, tabs and panes. Shared arrangement changes the
// document; focus, zoom and settle only touch the private view.

import Foundation
import KraalHC

extension KraalModel {
    // MARK: Spaces

    /// Shows `id` without touching its tabs or terminals.
    @discardableResult
    public mutating func setActiveSpace(_ id: String) -> Bool {
        guard spaceIndex(id) != nil else { return false }
        view.activeSpace = id
        return true
    }

    @discardableResult
    public mutating func addSpace(
        id: String,
        name: String = "",
        folder: String,
        machine: String? = nil,
        tab: KraalTabSeed
    ) -> Bool {
        let spaceID = qualify(id, machine)
        guard spaceIndex(spaceID) == nil else { return false }
        let tabID = qualify(tab.id, machine)
        let paneID = qualify(tab.paneID, machine)
        guard tabLocation(tabID) == nil else { return false }

        let root: JSONValue = .object([
            "id": .string(tabID),
            "type": .string("row"),
            "children": .array([
                .object([
                    "id": .string(paneID),
                    "type": .string("block"),
                    "content": .object(["terminal": .string(qualify(tab.terminal, machine))]),
                ]),
            ]),
        ])
        let space: JSONValue = .object([
            "id": .string(spaceID),
            "name": .string(name),
            "folder": .string(folder),
            "tabs": .array([
                .object(["id": .string(tabID), "name": .string(tab.name), "root": root]),
            ]),
        ])
        spacesValue = .array(ordered((spacesValue.arrayValue ?? []) + [space]))
        view.activeTabs[spaceID] = tabID
        view.tabs[tabID] = KraalTabView(focused: paneID)
        view.activeSpace = spaceID
        recent.removeAll { $0.name == name }
        return true
    }

    @discardableResult
    public mutating func addTab(space spaceID: String, tab: KraalTabSeed) -> Bool {
        guard let spaceIndex = spaceIndex(spaceID),
              var space = spacesValue[spaceIndex]?.objectValue,
              var tabs = space["tabs"]?.arrayValue
        else { return false }
        let machine = machineOf(id: spaceID)
        let tabID = qualify(tab.id, machine)
        guard tabLocation(tabID) == nil else { return false }
        let paneID = qualify(tab.paneID, machine)
        let root: JSONValue = .object([
            "id": .string(tabID),
            "type": .string("row"),
            "children": .array([
                .object([
                    "id": .string(paneID),
                    "type": .string("block"),
                    "content": .object(["terminal": .string(qualify(tab.terminal, machine))]),
                ]),
            ]),
        ])
        let active = view.activeTabs[spaceID] ?? tabs.first?["id"]?.stringValue
        let insertion = active.flatMap { current in
            tabs.firstIndex { $0["id"]?.stringValue == current }
        }.map { $0 + 1 } ?? tabs.count
        tabs.insert(.object(["id": .string(tabID), "name": .string(tab.name), "root": root]), at: insertion)
        space["tabs"] = .array(tabs)
        var all = spacesValue.arrayValue ?? []
        all[spaceIndex] = .object(space)
        spacesValue = .array(all)
        view.activeTabs[spaceID] = tabID
        view.tabs[tabID] = KraalTabView(focused: paneID)
        return true
    }

    @discardableResult
    public mutating func renameSpace(_ id: String, to name: String) -> Bool {
        guard let index = spaceIndex(id), var space = spacesValue[index]?.objectValue else { return false }
        space["name"] = .string(name)
        var all = spacesValue.arrayValue ?? []
        all[index] = .object(space)
        spacesValue = .array(all)
        return true
    }

    @discardableResult
    public mutating func moveSpace(_ id: String, to target: Int) -> Bool {
        var spaces = ordered(spacesValue.arrayValue ?? [])
        guard let index = spaces.firstIndex(where: { $0["id"]?.stringValue == id }) else { return false }
        let machine = machineOf(space: spaces[index])
        let range = spaces.indices.filter { machineOf(space: spaces[$0]) == machine }
        guard let first = range.first, let last = range.last else { return false }
        let destination = min(max(target, first), last)
        let moved = spaces.remove(at: index)
        spaces.insert(moved, at: min(destination, spaces.count))
        spacesValue = .array(spaces)
        return true
    }

    // MARK: Tabs

    @discardableResult
    public mutating func selectTab(_ id: String) -> Bool {
        guard let location = tabLocation(id) else { return false }
        let spaceID = spacesValue[location.space]?["id"]?.stringValue ?? ""
        view.activeTabs[spaceID] = id
        view.activeSpace = spaceID
        if var state = view.tabs[id] {
            state.settled = nil
            view.tabs[id] = state
        }
        return true
    }

    @discardableResult
    public mutating func renameTab(_ id: String, to name: String) -> Bool {
        guard let location = tabLocation(id),
              var space = spacesValue[location.space]?.objectValue,
              var tabs = space["tabs"]?.arrayValue,
              var tab = tabs[location.tab].objectValue
        else { return false }
        tab["name"] = .string(name)
        tabs[location.tab] = .object(tab)
        space["tabs"] = .array(tabs)
        var all = spacesValue.arrayValue ?? []
        all[location.space] = .object(space)
        spacesValue = .array(all)
        return true
    }

    /// Move a tab to a 1-based position in its space, removing it first so a
    /// backward drag lands in the target's slot (the same rule as `tab.move`).
    @discardableResult
    public mutating func moveTab(_ id: String, to target: Int) -> Bool {
        guard let location = tabLocation(id),
              var space = spacesValue[location.space]?.objectValue,
              var tabs = space["tabs"]?.arrayValue,
              tabs.indices.contains(location.tab)
        else { return false }
        let moved = tabs.remove(at: location.tab)
        let destination = min(max(target - 1, 0), tabs.count)
        tabs.insert(moved, at: destination)
        space["tabs"] = .array(tabs)
        var all = spacesValue.arrayValue ?? []
        all[location.space] = .object(space)
        spacesValue = .array(all)
        return true
    }

    @discardableResult
    public mutating func settle(_ id: String, at now: UInt64) -> Bool {
        guard let location = tabLocation(id) else { return false }
        var state = view.tabs[id] ?? KraalTabView()
        state.settled = now
        view.tabs[id] = state

        let spaceID = spacesValue[location.space]?["id"]?.stringValue ?? ""
        let tabs = spacesValue[location.space]?["tabs"]?.arrayValue ?? []
        let active = view.activeTabs[spaceID] ?? tabs.first?["id"]?.stringValue
        guard active == id, tabs.count > 1 else { return true }
        for step in 1 ..< tabs.count {
            let candidate = tabs[(location.tab + step) % tabs.count]
            let candidateID = candidate["id"]?.stringValue ?? ""
            if view.tabs[candidateID]?.settled == nil {
                view.activeTabs[spaceID] = candidateID
                break
            }
        }
        return true
    }

    @discardableResult
    public mutating func unsettle(_ id: String) -> Bool {
        guard var state = view.tabs[id], state.settled != nil else { return false }
        state.settled = nil
        view.tabs[id] = state
        return true
    }

    @discardableResult
    public mutating func nextTab() -> Bool { cycleTab(forward: true) }

    @discardableResult
    public mutating func previousTab() -> Bool { cycleTab(forward: false) }

    private mutating func cycleTab(forward: Bool) -> Bool {
        guard let space = activeSpace, space.tabs.count > 1,
              let current = space.tabs.firstIndex(where: { $0.id == space.activeTab })
        else { return false }
        let count = space.tabs.count
        for step in 1 ..< count {
            let index = forward ? (current + step) % count : (current + count * step - step) % count
            if space.tabs[index].settled == nil {
                return selectTab(space.tabs[index].id)
            }
        }
        return false
    }

    @discardableResult
    public mutating func nextSpace() -> Bool { cycleSpace(forward: true) }

    @discardableResult
    public mutating func previousSpace() -> Bool { cycleSpace(forward: false) }

    private mutating func cycleSpace(forward: Bool) -> Bool {
        let spaces = self.spaces
        guard spaces.count > 1,
              let current = spaces.firstIndex(where: { $0.id == activeSpace?.id })
        else { return false }
        let index = forward
            ? (current + 1) % spaces.count
            : (current + spaces.count - 1) % spaces.count
        view.activeSpace = spaces[index].id
        return true
    }

    // MARK: Panes

    @discardableResult
    public mutating func split(
        pane: String,
        axis: KraalAxis,
        newPane: String,
        terminal: String,
        focus: Bool = true
    ) -> Bool {
        splitWith(
            pane: pane,
            axis: axis,
            node: HcLayoutDocument.terminalNode(id: newPane, terminal: terminal),
            focus: focus
        )
    }

    /// Splits `pane` with any block (a terminal, a mod, a future kind).
    ///
    /// `focus: false` leaves focus and zoom alone: adoption puts a terminal
    /// beside the last pane without stealing what the person is looking at.
    @discardableResult
    public mutating func splitWith(
        pane: String,
        axis: KraalAxis,
        node: JSONValue,
        focus: Bool = true
    ) -> Bool {
        guard let location = tabLocation(pane: pane),
              let root = root(at: location),
              let spaceID = spacesValue[location.space]?["id"]?.stringValue
        else { return false }
        let machine = machineOf(id: spaceID)
        let inserted = qualify(node: node, machine: machine)
        guard let newID = inserted["id"]?.stringValue, !newID.isEmpty,
              KraalNode(raw: root).find(newID) == nil
        else { return false }
        guard let updated = HcLayoutTree.split(
            root,
            target: pane,
            axis: axis,
            newNode: inserted,
            containerID: freshID("s", machine: machine)
        ) else { return false }
        setRoot(updated, at: location)
        guard focus else { return true }
        var state = view.tabs[location.id] ?? KraalTabView()
        self.focus(&state, pane: newID)
        state.zoomed = nil
        view.tabs[location.id] = state
        return true
    }

    @discardableResult
    public mutating func focus(pane: String, select: Bool = true) -> Bool {
        guard let location = tabLocation(pane: pane) else { return false }
        var state = view.tabs[location.id] ?? KraalTabView()
        focus(&state, pane: pane)
        view.tabs[location.id] = state
        if select {
            let spaceID = spacesValue[location.space]?["id"]?.stringValue ?? ""
            view.activeTabs[spaceID] = location.id
            view.activeSpace = spaceID
            state.settled = nil
            view.tabs[location.id] = state
        }
        return true
    }

    /// Replaces the weights of a row/column. The UI calls this on every drag
    /// change; only the final call should persist the document.
    @discardableResult
    public mutating func setSplitWeights(_ container: String, weights: [Double]) -> Bool {
        guard let location = tabLocation(node: container), let root = root(at: location),
              let updated = HcLayoutTree.resizing(root, container: container, weights: weights)
        else { return false }
        setRoot(updated, at: location)
        return true
    }

    /// The pane a directional move would land on. Walks up until an ancestor
    /// shares the direction's axis, then takes the sibling on that side and
    /// descends to the edge nearest the source.
    public func neighborPane(of id: String, direction: KraalEdge) -> String? {
        guard let tab = tab(ofPane: id), let path = panePath(id, in: tab.root) else { return nil }
        for depth in stride(from: path.count - 2, through: 0, by: -1) {
            let parent = path[depth]
            guard parent.isContainer, parent.type == direction.axis.rawValue,
                  let index = parent.children.firstIndex(where: { $0.id == path[depth + 1].id })
            else { continue }
            let next = direction == .left || direction == .top ? index - 1 : index + 1
            guard parent.children.indices.contains(next) else { continue }
            if let edge = edgePane(parent.children[next], from: direction) { return edge }
        }
        return nil
    }

    @discardableResult
    public mutating func focusNeighbor(_ id: String, direction: KraalEdge) -> Bool {
        guard let target = neighborPane(of: id, direction: direction) else { return false }
        return focus(pane: target)
    }

    @discardableResult
    public mutating func swapWithNeighbor(_ id: String, direction: KraalEdge) -> Bool {
        guard let target = neighborPane(of: id, direction: direction) else { return false }
        return movePane(id, to: target)
    }

    private func panePath(_ id: String, in node: KraalNode) -> [KraalNode]? {
        if node.id == id { return [node] }
        for child in node.children {
            if let rest = panePath(id, in: child) { return [node] + rest }
        }
        return nil
    }

    private func edgePane(_ node: KraalNode, from direction: KraalEdge) -> String? {
        var current = node
        while current.isContainer, !current.children.isEmpty {
            current = direction == .left || direction == .top
                ? current.children[current.children.count - 1]
                : current.children[0]
        }
        return current.isPane ? current.id : nil
    }

    /// Closes a pane. Returns whether its tab and space closed with it.
    @discardableResult
    public mutating func removePane(_ pane: String) -> (tabClosed: Bool, spaceClosed: Bool) {
        guard let location = tabLocation(pane: pane), let root = root(at: location) else {
            return (false, false)
        }
        let update = HcLayoutTree.removing(root, id: pane)
        let newRoot: JSONValue
        if let update {
            newRoot = update.root
        } else if KraalNode(raw: root).id == pane {
            // A tab loaded with a bare pane as its root: closing it empties the tab.
            newRoot = .object(["id": .string(location.id), "type": .string("row"),
                               "children": .array([])])
        } else {
            return (false, false)
        }
        setRoot(newRoot, at: location)

        var state = view.tabs[location.id] ?? KraalTabView()
        state.before.removeAll { $0 == pane }
        if state.zoomed == pane { state.zoomed = nil }
        let remaining = KraalNode(raw: newRoot)
        if remaining.panes.isEmpty {
            view.tabs[location.id] = state
            let result = removeTab(location.id)
            return (true, result.spaceClosed)
        }
        if state.focused == pane || state.focused.flatMap(remaining.find) == nil {
            state.before = state.before.filter { remaining.find($0) != nil }
            state.focused = state.before.popLast() ?? remaining.panes.first?.id
        }
        view.tabs[location.id] = state
        return (false, false)
    }

    @discardableResult
    public mutating func removeTab(_ id: String) -> (addresses: [String], spaceClosed: Bool) {
        guard let location = tabLocation(id),
              var space = spacesValue[location.space]?.objectValue,
              var tabs = space["tabs"]?.arrayValue
        else { return ([], false) }
        let addresses = KraalNode(raw: tabs[location.tab]["root"] ?? .null).terminals
        tabs.remove(at: location.tab)
        let spaceID = space["id"]?.stringValue ?? ""
        if tabs.isEmpty {
            space["tabs"] = .array([])
            var all = spacesValue.arrayValue ?? []
            all[location.space] = .object(space)
            spacesValue = .array(all)
            view.tabs.removeValue(forKey: id)
            removeSpace(spaceID)
            return (addresses, true)
        }
        space["tabs"] = .array(tabs)
        var all = spacesValue.arrayValue ?? []
        all[location.space] = .object(space)
        spacesValue = .array(all)
        view.tabs.removeValue(forKey: id)

        let active = view.activeTabs[spaceID] ?? id
        if active == id {
            let next = tabs[min(location.tab, tabs.count - 1)]
            view.activeTabs[spaceID] = next["id"]?.stringValue
        }
        return (addresses, false)
    }

    @discardableResult
    public mutating func removeSpace(_ id: String) -> [String] {
        guard let index = spaceIndex(id), let space = spacesValue[index] else { return [] }
        let addresses = (space["tabs"]?.arrayValue ?? []).flatMap {
            KraalNode(raw: $0["root"] ?? .null).terminals
        }
        for tab in space["tabs"]?.arrayValue ?? [] {
            if let tabID = tab["id"]?.stringValue {
                view.tabs.removeValue(forKey: tabID)
            }
        }
        let name = space["name"]?.stringValue ?? ""
        let folder = space["folder"]?.stringValue ?? ""
        view.activeTabs.removeValue(forKey: id)
        var spaces = spacesValue.arrayValue ?? []
        spaces.remove(at: index)
        spacesValue = .array(spaces)
        if view.activeSpace == id {
            view.activeSpace = spaces.indices.contains(index)
                ? spaces[index]["id"]?.stringValue
                : spaces.last?["id"]?.stringValue
        }
        recent.removeAll { $0.name == name }
        recent.insert(KraalRecent(name: name, folder: folder), at: 0)
        if recent.count > 20 { recent.removeLast(recent.count - 20) }
        return addresses
    }

    @discardableResult
    public mutating func zoom(_ pane: String) -> Bool {
        guard let location = tabLocation(pane: pane), let root = root(at: location) else { return false }
        let node = KraalNode(raw: root)
        guard node.panes.count > 1, node.find(pane) != nil else { return false }
        var state = view.tabs[location.id] ?? KraalTabView()
        state.zoomed = pane
        view.tabs[location.id] = state
        return true
    }

    /// Zooms a pane, or unzooms it when it already fills the tab.
    @discardableResult
    public mutating func toggleZoom(_ pane: String) -> Bool {
        guard let location = tabLocation(pane: pane), let root = root(at: location) else { return false }
        var state = view.tabs[location.id] ?? KraalTabView()
        if state.zoomed == pane {
            state.zoomed = nil
            view.tabs[location.id] = state
            return true
        }
        guard KraalNode(raw: root).panes.count > 1 else { return false }
        state.zoomed = pane
        view.tabs[location.id] = state
        return true
    }

    @discardableResult
    public mutating func unzoom() -> Bool {
        guard let tab = activeTab else { return false }
        var state = view.tabs[tab.id] ?? KraalTabView()
        guard state.zoomed != nil else { return false }
        state.zoomed = nil
        view.tabs[tab.id] = state
        return true
    }

    /// Shows another block of a stack.
    @discardableResult
    public mutating func selectStackChild(stack: String, child: String) -> Bool {
        guard let location = tabLocation(pane: stack), let root = root(at: location),
              let updated = HcLayoutTree.selecting(root, stack: stack, child: child)
        else { return false }
        setRoot(updated, at: location)
        return true
    }

    @discardableResult
    public mutating func swapPanes(_ first: String, _ second: String) -> Bool {
        guard let location = tabLocation(pane: first),
              let root = root(at: location),
              tabLocation(pane: second)?.id == location.id,
              let swapped = HcLayoutTree.swapping(root, first, second)
        else { return false }
        setRoot(swapped, at: location)
        return focus(pane: first, select: false)
    }

    /// Moves `source` beside `target` (`edge` nil swaps their places).
    @discardableResult
    public mutating func movePane(_ source: String, to target: String, edge: KraalEdge? = nil) -> Bool {
        guard source != target,
              let location = tabLocation(pane: source),
              tabLocation(pane: target)?.id == location.id,
              let root = root(at: location),
              let sourceNode = KraalNode(raw: root).find(source), sourceNode.isPane,
              let targetNode = KraalNode(raw: root).find(target), targetNode.isPane
        else { return false }

        if edge == nil {
            return swapPanes(source, target)
        }
        guard let edge, let removing = HcLayoutTree.removing(root, id: source) else { return false }
        var moved = removing.removed
        if var object = moved.objectValue {
            object.removeValue(forKey: "size")
            moved = .object(object)
        }
        let spaceID = spacesValue[location.space]?["id"]?.stringValue ?? ""
        guard let split = HcLayoutTree.split(
            removing.root,
            target: target,
            axis: edge.axis,
            newNode: moved,
            containerID: freshID("s", machine: machineOf(id: spaceID))
        ) else { return false }
        let final = edge.beforeTarget
            ? HcLayoutTree.swapping(split, source, target)
            : split
        guard let final else { return false }
        setRoot(final, at: location)
        return focus(pane: source, select: false)
    }

    // MARK: Internals

    func spaceIndex(_ id: String) -> Int? {
        (spacesValue.arrayValue ?? []).firstIndex { $0["id"]?.stringValue == id }
    }

    struct Location {
        let space: Int
        let tab: Int
        let id: String
    }

    func tabLocation(_ id: String) -> Location? {
        for (spaceIndex, space) in (spacesValue.arrayValue ?? []).enumerated() {
            for (tabIndex, tab) in (space["tabs"]?.arrayValue ?? []).enumerated()
            where tab["id"]?.stringValue == id {
                return Location(space: spaceIndex, tab: tabIndex, id: id)
            }
        }
        return nil
    }

    func tabLocation(node: String) -> Location? {
        for (spaceIndex, space) in (spacesValue.arrayValue ?? []).enumerated() {
            for (tabIndex, tab) in (space["tabs"]?.arrayValue ?? []).enumerated() {
                guard let id = tab["id"]?.stringValue,
                      KraalNode(raw: tab["root"] ?? .null).find(node) != nil
                else { continue }
                return Location(space: spaceIndex, tab: tabIndex, id: id)
            }
        }
        return nil
    }

    func tabLocation(pane: String) -> Location? {
        for (spaceIndex, space) in (spacesValue.arrayValue ?? []).enumerated() {
            for (tabIndex, tab) in (space["tabs"]?.arrayValue ?? []).enumerated() {
                guard let id = tab["id"]?.stringValue,
                      KraalNode(raw: tab["root"] ?? .null).find(pane) != nil
                else { continue }
                return Location(space: spaceIndex, tab: tabIndex, id: id)
            }
        }
        return nil
    }

    func root(at location: Location) -> JSONValue? {
        spacesValue[location.space]?["tabs"]?[location.tab]?["root"]
    }

    mutating func setRoot(_ root: JSONValue, at location: Location) {
        guard var space = spacesValue[location.space]?.objectValue,
              var tabs = space["tabs"]?.arrayValue,
              var tab = tabs[location.tab].objectValue
        else { return }
        tab["root"] = root
        tabs[location.tab] = .object(tab)
        space["tabs"] = .array(tabs)
        var all = spacesValue.arrayValue ?? []
        all[location.space] = .object(space)
        spacesValue = .array(all)
    }

    func focus(_ state: inout KraalTabView, pane: String) {
        if let old = state.focused, old != pane {
            state.before.removeAll { $0 == old || $0 == pane }
            state.before.append(old)
            if state.before.count > 32 { state.before.removeFirst(state.before.count - 32) }
        }
        state.focused = pane
    }
}
