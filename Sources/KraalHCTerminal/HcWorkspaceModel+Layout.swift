// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The layout half of the window: one `herdr-app` document per machine, the
// terminals that belong to their panes, and the commands that change the
// arrangement. Terminals are placed by their `herdr.space`/`herdr.tab` labels;
// a worker without them stays out of the layout (and in the sidebar).

import Foundation
import KraalHC
import KraalModel

public struct HcCloseRequest: Identifiable, Equatable {
    public enum Kind: Equatable {
        case space(String)
        case tab(String)
    }

    public let id = UUID()
    public let kind: Kind
    public let title: String
    public let detail: String

    public init(kind: Kind, title: String, detail: String) {
        self.kind = kind
        self.title = title
        self.detail = detail
    }

    public var confirmTitle: String {
        switch kind {
        case .space: "Close space"
        case .tab: "Close tab"
        }
    }
}

extension HcWorkspaceModel {
    private func key(_ machine: String?) -> String { machine ?? "" }

    private func machineName(for key: String) -> String? { key.isEmpty ? nil : key }

    // MARK: Documents

    /// Reads one machine's layout. The local core and every connected machine
    /// have their own document; the model merges them, local spaces first.
    func loadLayout(machine: String?) async {
        guard client.isConnected else { return }
        let key = key(machine)
        layoutGenerations[key, default: 0] += 1
        let generation = layoutGenerations[key]
        let sync = layoutSyncs[key] ?? HcDocumentSync(client: client, name: "herdr-app", machine: machine)
        layoutSyncs[key] = sync
        do {
            let document = try await sync.load()
            guard generation == layoutGenerations[key], client.isConnected else { return }
            let parsed = try HcLayoutDocument(value: document.value)
            workspace.apply(parsed, for: machine)
            layoutLoaded.insert(key)
            layoutError = nil
            let tabs = parsed.spaces.reduce(0) { $0 + $1.tabs.count }
            let place = machine.map { " on \($0)" } ?? ""
            log?("hc: layout v\(document.version)\(place) spaces=\(parsed.spaces.count) tabs=\(tabs)")
            publish()
        } catch {
            // A layout this build cannot read must not take the terminals down.
            layoutError = "The layout\(machine.map { " on \($0)" } ?? "") is unavailable: \(error)"
            log?("hc: layout\(machine.map { " on \($0)" } ?? "") unavailable: \(error)")
        }
    }

    /// Writes the whole machine document. A conflict means someone else wrote
    /// first: their version is read and shown, not merged.
    func saveLayout(machine: String?) async {
        let key = key(machine)
        guard layoutLoaded.contains(key), let sync = layoutSyncs[key],
              let document = workspace.project(for: machine)
        else { return }
        do {
            let saved = try await sync.save(document.value)
            log?("hc: layout saved v\(saved.version)\(machine.map { " on \($0)" } ?? "")")
        } catch let HcDocumentError.conflict(latest) {
            layoutError = "The layout changed elsewhere; showing the latest version."
            log?("hc: layout conflict, latest v\(latest.version)")
            if let parsed = try? HcLayoutDocument(value: latest.value) {
                workspace.apply(parsed, for: machine)
                publish()
            }
        } catch {
            layoutError = "Could not save the layout: \(error)"
            log?("hc: layout save failed: \(error)")
        }
    }

    /// Loads documents for machines that just connected. Temporary machines
    /// stay out of the window entirely, so their document is not read.
    func ensureMachineLayouts() async {
        for machine in machines where !machine.temporary && machine.state.isConnected {
            let key = key(machine.name)
            guard layoutLoaded.contains(key) == false else { continue }
            await loadLayout(machine: machine.name)
        }
        for machine in machines where machine.temporary || !machine.state.isConnected {
            layoutLoaded.remove(key(machine.name))
        }
    }

    // MARK: Placement

    /// Drops panes whose terminal ended and adopts labeled terminals that are
    /// not in the layout yet. Called after every state change; it must be
    /// idempotent: events can arrive in any order around a run.
    func reconcile() {
        guard hasSnapshot else { return }
        var model = workspace
        let records = Dictionary(terminals.map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })
        var changedMachines: Set<String> = []
        var changed = false
        for address in closingTerminals where !(records[address]?.isLive ?? false) {
            closingTerminals.remove(address)
        }

        for space in model.spaces {
            for tab in space.tabs {
                for pane in tab.root.panes {
                    guard let address = pane.terminal else { continue }
                    let gone = records[address] == nil
                    let ended = records[address].map {
                        $0.state == "finished" && ["exited", "killed"].contains($0.reason ?? "")
                    } ?? false
                    if gone || ended {
                        let machine = space.machine
                        _ = model.removePane(pane.id)
                        changed = true
                        changedMachines.insert(key(machine))
                    }
                }
            }
        }

        let temporary = Set(machines.filter(\.temporary).map(\.name))
        for terminal in terminals {
            if closingTerminals.contains(terminal.address) {
                if !terminal.isLive { closingTerminals.remove(terminal.address) }
                continue
            }
            guard terminal.isLive,
                  let spaceLabel = terminal.labels["herdr.space"], !spaceLabel.isEmpty,
                  terminal.machine.map({ !temporary.contains($0) }) ?? true,
                  model.paneID(ofTerminal: terminal.address) == nil
            else { continue }
            let machine = terminal.machine
            guard layoutLoaded.contains(key(machine)) else { continue }
            let spaceID = qualify(spaceLabel, machine)
            let tabLabel = terminal.labels["herdr.tab"].flatMap { $0.isEmpty ? nil : $0 }
            let tabID = tabLabel.map { qualify($0, machine) }
            let folder = terminal.foreground?.cwd ?? terminal.cwd
            guard model.adopt(
                terminal: terminal.address,
                space: spaceID,
                tab: tabID,
                folder: folder,
                machine: machine
            ) != nil else { continue }
            changed = true
            changedMachines.insert(key(machine))
            log?("hc: adopted \(terminal.address) into \(spaceID)\(tabID.map { "/\($0)" } ?? "")")

            // An adopted terminal outlives its program; the next shell keeps
            // the pane instead of leaving a dead one.
            if !terminal.keep, !adoptedKeep.contains(terminal.address) {
                adoptedKeep.insert(terminal.address)
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        _ = try await self.client.keepTerminal(terminal.address, keep: true)
                    } catch {
                        self.log?("hc: keep \(terminal.address) failed: \(error)")
                    }
                }
            }
        }

        if changed {
            workspace = model
            publish()
            for key in changedMachines {
                let machine = machineName(for: key)
                Task { [weak self] in await self?.saveLayout(machine: machine) }
            }
        }
    }

    private func qualify(_ id: String, _ machine: String?) -> String {
        guard let machine, !id.hasPrefix(machine + "/") else { return id }
        return "\(machine)/\(id)"
    }

    // MARK: Sessions

    /// The terminals the active tab draws, in tree order (a zoomed tab draws
    /// one). Hidden tabs and settled tabs hold no stream.
    func visiblePaneTerminals() -> [(pane: String, terminal: String)] {
        guard let tab = workspace.activeTab else { return [] }
        return tab.shown.panes.compactMap { pane in
            pane.terminal.map { (pane.id, $0) }
        }
    }

    /// Brings attachments in line with what is on screen: one stream per
    /// visible terminal, no stream for anything else.
    func refreshPaneSessions() {
        let wanted = Dictionary(uniqueKeysWithValues: visiblePaneTerminals().map { ($0.pane, $0.terminal) })
        for (pane, session) in paneSessions {
            guard let address = wanted[pane], address == session.address else {
                session.close()
                paneSessions.removeValue(forKey: pane)
                attachingPanes.remove(pane)
                continue
            }
            let terminal = terminals.first { $0.address == address }
            if terminal == nil {
                session.close()
                paneSessions.removeValue(forKey: pane)
                attachingPanes.remove(pane)
            } else if terminal?.isLive == true, session.lost || session.end != nil {
                // A kept terminal came back as a fresh shell: the old stream is
                // over, attach to the new one.
                session.close()
                paneSessions.removeValue(forKey: pane)
                attachPane(pane: pane, terminal: address)
            }
        }
        for (pane, address) in wanted where paneSessions[pane] == nil {
            attachPane(pane: pane, terminal: address)
        }
        let focused = workspace.activeTab?.focusedPane
        for (pane, session) in paneSessions {
            session.focus(pane == focused)
        }
    }

    private func attachPane(pane: String, terminal address: String) {
        guard client.isConnected, !attachingPanes.contains(pane) else { return }
        let existing = terminals.first { $0.address == address }
        guard existing?.isLive == true else { return }
        attachingPanes.insert(pane)
        Task { [weak self] in
            guard let self else { return }
            defer { self.attachingPanes.remove(pane) }
            do {
                let session = try await HcTerminalSession.open(client: self.client, terminal: address)
                guard self.client.isConnected, self.workspace.activeTab?.shown.find(pane) != nil else {
                    session.close()
                    return
                }
                self.paneSessions[pane] = session
                self.log?("hc: attached \(address) to \(pane)")
            } catch {
                self.layoutError = "Could not attach \(address): \(error)"
                self.log?("hc: attach \(address) failed: \(error)")
            }
        }
    }

    // MARK: Commands

    public func selectSpace(_ id: String) {
        guard workspace.space(id) != nil else { return }
        workspace.setActiveSpace(id)
        publish()
    }

    public func selectTab(_ id: String) {
        guard workspace.selectTab(id) else { return }
        publish()
    }

    public func nextSpace() {
        guard workspace.nextSpace() else { return }
        publish()
    }

    public func previousSpace() {
        guard workspace.previousSpace() else { return }
        publish()
    }

    public func nextTab() {
        guard workspace.nextTab() else { return }
        publish()
    }

    public func previousTab() {
        guard workspace.previousTab() else { return }
        publish()
    }

    public func focusPane(_ id: String) {
        guard workspace.focus(pane: id) else { return }
        publish()
    }

    public func selectStackChild(stack: String, child: String) {
        guard let tab = workspace.tab(ofPane: stack), let space = workspace.space(of: tab.id),
              layoutLoaded.contains(key(space.machine))
        else {
            layoutError = "This machine's layout is unavailable. Try again when it reconnects."
            return
        }
        guard workspace.selectStackChild(stack: stack, child: child) else { return }
        publish()
        Task { [weak self] in await self?.saveLayout(machine: space.machine) }
    }

    public func toggleZoom() {
        guard let pane = workspace.focusedPane, workspace.toggleZoom(pane) else { return }
        publish()
    }

    public func newTab(name: String? = nil) async {
        guard client.isConnected else { return }
        let space = workspace.activeSpace
        let machine = space?.machine
        guard layoutLoaded.contains(key(machine)) else {
            layoutError = "This machine's layout is unavailable. Try again when it reconnects."
            return
        }
        let spaceID = space?.id ?? workspace.freshSpaceID(machine: machine)
        let tabID = workspace.freshTabID(machine: machine)
        let folder = space?.folder ?? workspace.home
        guard let terminal = await startTerminal(
            space: spaceID,
            tab: tabID,
            cwd: folder,
            name: name,
            machine: machine
        ) else { return }
        guard workspace.adopt(
            terminal: terminal.address,
            space: spaceID,
            tab: tabID,
            folder: folder,
            machine: machine
        ) != nil else {
            layoutError = "The terminal started, but its tab could not be added."
            await killCascade(terminal.address)
            return
        }
        publish()
        await saveLayout(machine: machine)
    }

    public func splitFocusedPane(_ axis: KraalAxis) async {
        guard client.isConnected, let tab = workspace.activeTab,
              let target = tab.focusedPane, let space = workspace.space(of: tab.id)
        else { return }
        guard layoutLoaded.contains(key(space.machine)) else {
            layoutError = "This machine's layout is unavailable. Try again when it reconnects."
            return
        }
        let paneID = workspace.freshPaneID(machine: space.machine)
        guard let terminal = await startTerminal(
            space: space.id,
            tab: tab.id,
            cwd: space.folder,
            machine: space.machine
        ) else { return }
        let placed = workspace.paneID(ofTerminal: terminal.address)
        let didPlace: Bool
        if let placed, placed != target {
            // Adoption may have added it before the run reply arrived; move it
            // beside the target instead of splitting a second time.
            didPlace = workspace.movePane(placed, to: target, edge: axis == .row ? .right : .bottom)
        } else {
            didPlace = workspace.split(
                pane: target,
                axis: axis,
                newPane: paneID,
                terminal: terminal.address
            )
        }
        guard didPlace else {
            layoutError = "The terminal started, but the split failed."
            await killCascade(terminal.address)
            return
        }
        publish()
        await saveLayout(machine: space.machine)
    }

    public func closeFocusedPane() async {
        guard let tab = workspace.activeTab,
              let pane = tab.focusedPane,
              let space = workspace.space(of: tab.id)
        else { return }
        guard layoutLoaded.contains(key(space.machine)) else {
            layoutError = "This machine's layout is unavailable. Try again when it reconnects."
            return
        }
        let address = workspace.terminal(ofPane: pane)
        if let address { closingTerminals.insert(address) }
        _ = workspace.removePane(pane)
        publish()
        if let address { await killCascade(address) }
        await saveLayout(machine: space.machine)
    }

    public func closeTab(_ id: String, confirmed: Bool = false) async {
        guard let space = workspace.space(of: id), let tab = workspace.tab(id) else { return }
        guard layoutLoaded.contains(key(space.machine)) else {
            layoutError = "This machine's layout is unavailable. Try again when it reconnects."
            return
        }
        if space.tabs.count == 1 {
            await closeSpace(space.id, confirmed: confirmed)
            return
        }
        if !confirmed, tab.terminals.count > 1 {
            closeRequest = HcCloseRequest(
                kind: .tab(id),
                title: "Close tab?",
                detail: "\(tab.displayName) — \(tab.terminals.count) terminals"
            )
            return
        }
        let addresses = workspace.removeTab(id).addresses
        closingTerminals.formUnion(addresses)
        publish()
        for address in addresses { await killCascade(address) }
        await saveLayout(machine: space.machine)
    }

    public func closeSpace(_ id: String, confirmed: Bool = false) async {
        guard let space = workspace.space(id) else { return }
        guard layoutLoaded.contains(key(space.machine)) else {
            layoutError = "This machine's layout is unavailable. Try again when it reconnects."
            return
        }
        let terminals = space.tabs.flatMap(\.terminals)
        if !confirmed, terminals.count > 1 {
            closeRequest = HcCloseRequest(
                kind: .space(id),
                title: "Close space?",
                detail: "\(space.displayName) — \(space.tabs.count) tabs, \(terminals.count) terminals"
            )
            return
        }
        let addresses = workspace.removeSpace(id)
        closingTerminals.formUnion(addresses)
        closeRequest = nil
        publish()
        for address in addresses { await killCascade(address) }
        await saveLayout(machine: space.machine)
    }

    /// Confirms a close the model was waiting on.
    public func confirmClose(_ request: HcCloseRequest) async {
        closeRequest = nil
        switch request.kind {
        case let .space(id): await closeSpace(id, confirmed: true)
        case let .tab(id): await closeTab(id, confirmed: true)
        }
    }

    public func closeRequestedSpace() async {
        guard let active = workspace.activeSpace else { return }
        await closeSpace(active.id)
    }

    public func closeRequestedTab() async {
        guard let active = workspace.activeTab else { return }
        await closeTab(active.id)
    }

    /// Ends the program and its unlabeled children. A child with its own
    /// `herdr.space` has its own pane and is kept, as the official app does.
    func killCascade(_ address: String) async {
        var doomed = [address]
        var index = 0
        while index < doomed.count {
            let parent = doomed[index]
            for terminal in terminals where terminal.parent == parent {
                let kept = terminal.labels["herdr.space"].map { !$0.isEmpty } ?? false
                if !kept, !doomed.contains(terminal.address) {
                    doomed.append(terminal.address)
                }
            }
            index += 1
        }
        for doomedAddress in doomed {
            do {
                _ = try await client.killTerminal(doomedAddress)
            } catch {
                closingTerminals.remove(doomedAddress)
                log?("hc: kill \(doomedAddress) failed: \(error)")
            }
        }
    }

    /// Takes a terminal out of the layout without ending it: empty labels and
    /// no keep. It becomes a worker in the sidebar.
    public func parkTerminal(_ address: String) async {
        guard let pane = workspace.paneID(ofTerminal: address),
              let tab = workspace.tab(ofPane: pane),
              let space = workspace.space(of: tab.id)
        else { return }
        do {
            _ = try await client.labelTerminal(address, labels: ["herdr.space": "", "herdr.tab": ""])
            _ = try await client.keepTerminal(address, keep: false)
        } catch {
            layoutError = "Could not park \(address): \(error)"
            return
        }
        _ = workspace.removePane(pane)
        publish()
        await saveLayout(machine: space.machine)
    }

    /// Gives a running worker a pane in the shown space (or focuses its pane).
    public func keepTerminal(_ address: String) async {
        if let pane = workspace.paneID(ofTerminal: address) {
            focusPane(pane)
            return
        }
        guard let space = workspace.activeSpace,
              let terminal = terminals.first(where: { $0.address == address }),
              terminal.isLive, terminal.machine == space.machine
        else {
            layoutError = "That terminal cannot be kept in this space."
            return
        }
        guard layoutLoaded.contains(key(space.machine)) else {
            layoutError = "This machine's layout is unavailable. Try again when it reconnects."
            return
        }
        let tabID = workspace.activeTab?.id ?? workspace.freshTabID(machine: space.machine)
        do {
            _ = try await client.labelTerminal(address, labels: [
                "herdr.space": local(space.id, machine: space.machine),
                "herdr.tab": local(tabID, machine: space.machine),
            ])
            _ = try await client.keepTerminal(address, keep: true)
        } catch {
            layoutError = "Could not keep \(address): \(error)"
            return
        }
        _ = workspace.adopt(
            terminal: address,
            space: space.id,
            tab: tabID,
            folder: terminal.foreground?.cwd ?? terminal.cwd,
            machine: space.machine
        )
        publish()
        await saveLayout(machine: space.machine)
    }

    // MARK: Starting terminals

    private func startTerminal(
        space: String,
        tab: String,
        cwd: String,
        name: String? = nil,
        machine: String?
    ) async -> HcTerminal? {
        let labels = [
            "herdr.space": local(space, machine: machine),
            "herdr.tab": local(tab, machine: machine),
            "herdr.seen": "0",
        ]
        let cleanName = name.map(HcTerminalName.suggested).flatMap { $0.isEmpty ? nil : $0 }
        if let name, cleanName == nil {
            layoutError = "A terminal name is 1–32 of a-z 0-9 - _."
            return nil
        }
        do {
            return try await client.runTerminal(
                cwd: cwd.isEmpty ? nil : cwd,
                env: Self.terminalEnvironment,
                labels: labels,
                name: cleanName,
                on: machine
            )
        } catch {
            layoutError = "Could not start a terminal: \(error)"
            log?("hc: terminal.run failed: \(error)")
            return nil
        }
    }

    private func local(_ id: String, machine: String?) -> String {
        guard let machine, id.hasPrefix(machine + "/") else { return id }
        return String(id.dropFirst(machine.count + 1))
    }

    static let terminalEnvironment = [
        "TERM": "xterm-ghostty",
        "TERM_PROGRAM": "Kraal",
        "COLORTERM": "truecolor",
    ]
}
