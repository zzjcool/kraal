// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Read-only projections for the `kraal ls` / `kraal status` control commands.
// They are pure views over the same model the window renders, so a CLI can
// never disagree with what the user sees.

import Foundation
import KraalActions
import KraalHC
import KraalModel

extension HcWorkspaceModel {
    public func handleControl(_ request: HcControlRequest) async -> JSONValue {
        switch request {
        case .list:
            return controlListing()
        case .status:
            return controlStatus()
        case let .doAction(name, arguments):
            let outcome = await performAction(name, arguments: arguments)
            if let asked = outcome.reply["asked"]?.stringValue {
                return .object([
                    "error": .string("\(name) needs explicit input (\(asked)); pass the missing argument"),
                ])
            }
            return outcome.reply
        case .shot, .raise:
            return .object(["error": .string("the window handles this request")])
        }
    }

    /// Same shape as `herdr-app ls`: spaces > tabs > terminal-bearing panes.
    public func controlListing() -> JSONValue {
        let spaces = workspace.spaces.map { space in
            JSONValue.object([
                "id": .string(space.id),
                "name": .string(space.displayName),
                "folder": .string(space.folder),
                "machine": space.machine.map(JSONValue.string) ?? .null,
                "active": .bool(workspace.activeSpace?.id == space.id),
                "tabs": .array(space.tabs.map { tab in
                    JSONValue.object([
                        "id": .string(tab.id),
                        "name": .string(tab.displayName),
                        "active": .bool(space.activeTab == tab.id),
                        "settled": .bool(tab.settled != nil),
                        "terminals": .array(tab.root.panes.compactMap { pane in
                            guard let terminal = workspace.terminal(ofPane: pane.id) else { return nil }
                            return terminalListing(pane: pane.id, address: terminal)
                        }),
                    ])
                }),
            ])
        }
        let recent = workspace.recent.map { item in
            JSONValue.object(["name": .string(item.name), "folder": .string(item.folder)])
        }
        return .object(["spaces": .array(spaces), "recent": .array(recent)])
    }

    /// A superset of `herdr-app status` with the fields this client actually
    /// owns: document load state and the control/window identity.
    public func controlStatus() -> JSONValue {
        let (state, version) = statusPair
        let active = workspace.activeTab
        let documents = documentStatus()
        let errors = [layoutError, openError, machineError].compactMap { $0 }
        let scrollback = paneSessions.keys.sorted().compactMap { pane -> JSONValue? in
            guard let bar = paneSessions[pane]?.state.scrollbar else { return nil }
            return .object([
                "pane": .string(pane),
                "total": .number(Double(bar.total)),
                "offset": .number(Double(bar.offset)),
                "len": .number(Double(bar.len)),
            ])
        }
        var fields: [String: JSONValue] = [:]
        fields["zoom"] = .number(((settings.fontSize / HcFontZoom.base) * 100).rounded() / 100)
        fields["font_size"] = .number(settings.fontSize)
        fields["scrollback"] = .array(scrollback)
        fields["ui_font_size"] = .number(settings.fontSize)
        fields["space"] = workspace.activeSpace.map { .string($0.id) } ?? .null
        fields["tab"] = active.map { .string($0.id) } ?? .null
        fields["focused_pane"] = workspace.focusedPane.map { .string($0) } ?? .null
        fields["layout"] = .string("herdr-app")
        fields["agent"] = focusedAgentAddress.map(JSONValue.string) ?? .null
        fields["floats"] = .object([:])
        fields["overlays"] = .array(openOverlays.map(JSONValue.string))
        fields["errors"] = .array(errors.map(JSONValue.string))
        fields["connected"] = .bool(isConnected)
        fields["heartbeat_stale"] = .bool(heartbeatStale)
        fields["snapshot_ready"] = .bool(hasSnapshot)
        fields["status"] = .string(state)
        fields["version"] = version.map(JSONValue.string) ?? .null
        fields["core"] = .object([
            "socket": .string(path),
            "name": .string(localName),
        ])
        fields["documents"] = .array(documents)
        fields["control"] = controlSocketPath.map(JSONValue.string) ?? .null
        fields["window"] = windowNumber.map { .int($0) } ?? .null
        return .object(fields)
    }

    private var statusPair: (String, String?) {
        switch status {
        case .idle: ("idle", nil)
        case .connecting: ("connecting", nil)
        case let .ready(version): ("ready", version)
        case .incompatible: ("incompatible", nil)
        case .failed: ("failed", nil)
        }
    }

    private var focusedAgentAddress: String? {
        if let peekAddress { return peekAddress }
        guard let pane = workspace.focusedPane, let address = workspace.terminal(ofPane: pane) else {
            return nil
        }
        return agents.first(where: { $0.address == address })?.address
    }

    private var openOverlays: [String] {
        var names: [String] = []
        if showPalette { names.append("palette") }
        if showHelp { names.append("help") }
        if showSettings { names.append("settings") }
        if renameRequest != nil { names.append("rename") }
        if closeRequest != nil { names.append("close") }
        if machineSheet != nil { names.append("machine") }
        return names
    }

    private func documentStatus() -> [JSONValue] {
        let keys = layoutLoaded.union(layoutVersions.keys)
        return keys.sorted().map { key in
            .object([
                "machine": key.isEmpty ? .null : .string(key),
                "loaded": .bool(layoutLoaded.contains(key)),
                "version": .int(Int(layoutVersions[key] ?? 0)),
            ])
        }
    }

    private func terminalListing(pane: String, address: String) -> JSONValue {
        let terminal = terminals.first(where: { $0.address == address })
        let agent = agents.first(where: { $0.address == address })
        let children = terminals
            .filter { $0.parent == address }
            .map(\.address)
            .sorted()
        let name = terminal?.raw["name"]?.stringValue ?? ""
        return .object([
            "terminal": .string(address),
            "pane": .string(pane),
            "status": agent.map { .string($0.status.rawValue) } ?? .null,
            "app": agent?.app.map(JSONValue.string) ?? .null,
            "name": name.isEmpty ? .null : .string(name),
            "sub_agents": .array(children.map(JSONValue.string)),
        ])
    }
}
