// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The one place an action name becomes a model call. Menus, the palette and
// `kraal do` all enter here; none of them re-implement the space/tab rules.

import AppKit
import Foundation
import KraalActions
import KraalHC
import KraalModel

public struct HcActionOutcome: Sendable, Equatable {
    public let reply: JSONValue
    public let error: String?

    public var isOK: Bool { error == nil }

    static func ok(_ extra: [String: JSONValue] = [:]) -> HcActionOutcome {
        var value = extra
        value["ok"] = .bool(true)
        return HcActionOutcome(reply: .object(value), error: nil)
    }

    static func asked(_ what: String) -> HcActionOutcome {
        HcActionOutcome(reply: .object(["asked": .string(what)]), error: nil)
    }

    static func fail(_ message: String) -> HcActionOutcome {
        HcActionOutcome(reply: .object(["error": .string(message)]), error: message)
    }
}

extension HcWorkspaceModel {
    /// Menus validate against this rather than reaching into the transport.
    public var isConnected: Bool { client.isConnected }

    /// Actions the runner can execute today. The palette and menus hide the
    /// rest until their phase lands; the catalog still describes them.
    public static let implementedActions: Set<String> = [
        "space.new", "space.close", "space.rename", "space.move", "space.select",
        "space.next", "space.prev",
        "tab.new", "tab.close", "tab.rename", "tab.move", "tab.select",
        "tab.settle", "tab.unsettle", "tab.next", "tab.prev",
        "pane.split", "pane.close", "pane.zoom", "pane.focus",
        "terminal.open", "terminal.keep", "terminal.park", "terminal.pin",
        "terminal.kill", "terminal.peek", "terminal.show",
        "agent.focus", "agent.next", "agent.prev",
        "app.palette", "app.help", "app.quit", "app.hide",
        "app.hide_others", "app.show_all",
        "window.close", "window.minimize", "window.maximize",
    ]

    public func canPerformAction(_ name: String) -> Bool {
        Self.implementedActions.contains(name)
    }

    /// Validate and execute one catalog action. Busy/no-window errors are the
    /// caller's problem; this returns the same `{ok|error}` shape as `hc`/the
    /// official app so a CLI can print it unchanged.
    public func performAction(_ name: String, arguments: JSONValue? = nil) async -> HcActionOutcome {
        guard let action = KraalActions.find(name) else {
            return .fail(KraalActionError.unknownAction(name).description)
        }
        if case let .unsupported(reason) = action.support {
            return .fail("\(name) is not supported by Kraal: \(reason)")
        }
        guard canPerformAction(name) else {
            return .fail("\(name) is not implemented in this window yet")
        }
        do {
            return await dispatch(name, try action.validate(arguments))
        } catch {
            return .fail(String(describing: error))
        }
    }

    private func dispatch(_ name: String, _ values: [String: JSONValue]) async -> HcActionOutcome {
        switch name.split(separator: ".").first.map(String.init) ?? "" {
        case "space": return await dispatchSpace(name, values)
        case "tab": return await dispatchTab(name, values)
        case "pane": return await dispatchPane(name, values)
        case "terminal": return await dispatchTerminal(name, values)
        case "agent": return await dispatchAgent(name, values)
        case "app", "window": return await dispatchSystem(name, values)
        default: return .fail("\(name) is not implemented in this window yet")
        }
    }

    private func dispatchSpace(_ name: String, _ values: [String: JSONValue]) async -> HcActionOutcome {
        switch name {
        case "space.new":
            await newSpace(
                name: values["name"]?.stringValue,
                folder: values["folder"]?.stringValue,
                tabName: values["tab"]?.stringValue,
                argv: argv(values),
                machine: values["machine"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            )
            return layoutError.map(HcActionOutcome.fail) ?? .ok()
        case "space.close":
            guard let space = targetSpace(values, id: "id") else {
                return .fail("space.close: no space to close")
            }
            await closeSpace(space, confirmed: values["confirmed"]?.boolValue ?? false)
            return closeRequest.map { _ in .asked("confirm") } ?? .ok()
        case "space.rename":
            guard let space = targetSpace(values, id: "id") else {
                return .fail("space.rename: no space to rename")
            }
            guard let newName = values["name"]?.stringValue else {
                return .fail("space.rename needs name (empty: automatic)")
            }
            await renameSpace(space, name: newName)
            return layoutError.map(HcActionOutcome.fail) ?? .ok()
        case "space.move":
            guard let space = values["id"]?.stringValue, let index = values["index"]?.intValue else {
                return .fail("space.move needs id and index")
            }
            await moveSpace(space, index: index)
            return layoutError.map(HcActionOutcome.fail) ?? .ok()
        case "space.select":
            guard let space = targetSpace(values, id: "id") else {
                return .fail("space.select: no such space")
            }
            selectSpace(space)
            return .ok()
        case "space.next":
            nextSpace()
            return .ok()
        case "space.prev":
            previousSpace()
            return .ok()

        default:
            return .fail("\(name) is not implemented in this window yet")
        }
    }

    private func dispatchTab(_ name: String, _ values: [String: JSONValue]) async -> HcActionOutcome {
        switch name {
        case "tab.new":
            if values["mod"] != nil || values["props"] != nil {
                return .fail("tab.new: mods are not supported by Kraal")
            }
            await newTab(
                tabName: values["name"]?.stringValue,
                folder: values["folder"]?.stringValue,
                space: values["space"]?.stringValue,
                argv: argv(values)
            )
            return layoutError.map(HcActionOutcome.fail) ?? .ok()
        case "tab.close":
            guard let tab = targetTab(values, id: "id") else {
                return .fail("tab.close: no tab to close")
            }
            await closeTab(tab, confirmed: values["confirmed"]?.boolValue ?? false)
            return closeRequest.map { _ in .asked("confirm") } ?? .ok()
        case "tab.rename":
            guard let tab = targetTab(values, id: "id") else {
                return .fail("tab.rename: no tab to rename")
            }
            guard let newName = values["name"]?.stringValue else {
                return .fail("tab.rename needs name (empty: its number)")
            }
            await renameTab(tab, name: newName)
            return layoutError.map(HcActionOutcome.fail) ?? .ok()
        case "tab.move":
            guard let tab = values["id"]?.stringValue, let index = values["index"]?.intValue else {
                return .fail("tab.move needs id and index")
            }
            await moveTab(tab, index: index)
            return layoutError.map(HcActionOutcome.fail) ?? .ok()
        case "tab.select":
            guard let tab = targetTab(values, id: "id") else {
                return .fail("tab.select: no such tab")
            }
            selectTab(tab)
            return .ok()
        case "tab.settle":
            settleTab(values["id"]?.stringValue)
            return .ok()
        case "tab.unsettle":
            unsettleTab(values["id"]?.stringValue)
            return .ok()
        case "tab.next":
            nextTab()
            return .ok()
        case "tab.prev":
            previousTab()
            return .ok()

        default:
            return .fail("\(name) is not implemented in this window yet")
        }
    }

    private func dispatchPane(_ name: String, _ values: [String: JSONValue]) async -> HcActionOutcome {
        switch name {
        case "pane.split":
            if values["mod"] != nil || values["props"] != nil {
                return .fail("pane.split: mods are not supported by Kraal")
            }
            let direction = values["direction"]?.stringValue ?? "right"
            let axis: KraalAxis = direction == "down" ? .column : .row
            if let pane = values["pane"]?.stringValue {
                guard workspace.tab(ofPane: pane) != nil else {
                    return .fail("pane.split: no such pane")
                }
                focusPane(pane)
            }
            await splitFocusedPane(axis, argv: argv(values))
            return layoutError.map(HcActionOutcome.fail) ?? .ok()
        case "pane.close":
            guard let pane = targetPane(values) else {
                return .fail("pane.close: no pane to close")
            }
            if pane != workspace.focusedPane { focusPane(pane) }
            await closeFocusedPane()
            return layoutError.map(HcActionOutcome.fail) ?? .ok()
        case "pane.zoom":
            guard let pane = targetPane(values) else {
                return .fail("pane.zoom: no pane to zoom")
            }
            if pane != workspace.focusedPane { focusPane(pane) }
            toggleZoom()
            return .ok()
        case "pane.focus":
            guard let pane = targetPane(values) else {
                return .fail("pane.focus: no pane to focus")
            }
            focusPane(pane)
            return .ok()

        default:
            return .fail("\(name) is not implemented in this window yet")
        }
    }

    private func dispatchTerminal(_ name: String, _ values: [String: JSONValue]) async -> HcActionOutcome {
        switch name {
        case "terminal.open":
            if values["place"]?.stringValue == "right" || values["place"]?.stringValue == "down" {
                await splitFocusedPane(
                    values["place"]?.stringValue == "down" ? .column : .row,
                    argv: argv(values)
                )
            } else {
                await newTab(
                    name: values["name"]?.stringValue,
                    folder: values["folder"]?.stringValue,
                    argv: argv(values)
                )
            }
            return layoutError.map(HcActionOutcome.fail) ?? .ok()
        case "terminal.keep":
            guard let address = values["terminal"]?.stringValue else {
                return .fail("terminal.keep needs terminal")
            }
            await keepTerminal(address)
            return layoutError.map(HcActionOutcome.fail) ?? .ok()
        case "terminal.park":
            guard let address = values["terminal"]?.stringValue else {
                return .fail("terminal.park needs terminal")
            }
            await parkTerminal(address)
            return layoutError.map(HcActionOutcome.fail) ?? .ok()
        case "terminal.pin":
            guard let address = values["terminal"]?.stringValue,
                  let pinned = values["pinned"]?.boolValue
            else { return .fail("terminal.pin needs terminal and pinned") }
            await setPinned(address, pinned: pinned)
            return .ok()
        case "terminal.kill":
            guard let address = values["terminal"]?.stringValue else {
                return .fail("terminal.kill needs terminal")
            }
            await killTerminal(address)
            return .ok()
        case "terminal.peek":
            guard let address = values["terminal"]?.stringValue else {
                return .fail("terminal.peek needs terminal")
            }
            await peek(address)
            return .ok()
        case "terminal.show":
            guard let address = values["terminal"]?.stringValue else {
                return .ok()
            }
            if let pane = workspace.paneID(ofTerminal: address) {
                focusPane(pane)
            } else {
                await peek(address)
            }
            return .ok()

        default:
            return .fail("\(name) is not implemented in this window yet")
        }
    }

    private func dispatchAgent(_ name: String, _ values: [String: JSONValue]) async -> HcActionOutcome {
        switch name {
        case "agent.focus":
            guard let address = values["terminal"]?.stringValue,
                  let agent = agents.first(where: { $0.address == address })
            else { return .fail("agent.focus needs a live agent") }
            await selectAgent(agent)
            return .ok()
        case "agent.next":
            await stepAgent(forward: true)
            return .ok()
        case "agent.prev":
            await stepAgent(forward: false)
            return .ok()

        default:
            return .fail("\(name) is not implemented in this window yet")
        }
    }

    private func dispatchSystem(_ name: String, _ values: [String: JSONValue]) async -> HcActionOutcome {
        switch name {
        case "app.palette":
            showPalette.toggle()
            return .ok()
        case "app.help":
            showHelp = true
            return .ok()
        case "app.quit":
            NSApp?.terminate(nil)
            return .ok()
        case "app.hide":
            NSApp?.hide(nil)
            return .ok()
        case "app.hide_others":
            NSApp?.hideOtherApplications(nil)
            return .ok()
        case "app.show_all":
            NSApp?.unhideAllApplications(nil)
            return .ok()
        case "window.close":
            activeWindow?.performClose(nil)
            return .ok()
        case "window.minimize":
            activeWindow?.miniaturize(nil)
            return .ok()
        case "window.maximize":
            activeWindow?.zoom(nil)
            return .ok()
        default:
            return .fail("\(name) is not implemented in this window yet")
        }
    }

    // MARK: Arguments and targets

    private func argv(_ values: [String: JSONValue]) -> [String] {
        values["argv"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    private func targetSpace(_ values: [String: JSONValue], id key: String) -> String? {
        if let id = values[key]?.stringValue {
            return workspace.space(id)?.id
        }
        if let index = values["index"]?.intValue {
            let spaces = workspace.spaces
            guard spaces.indices.contains(index - 1) else { return nil }
            return spaces[index - 1].id
        }
        return workspace.activeSpace?.id
    }

    private func targetTab(_ values: [String: JSONValue], id key: String) -> String? {
        if let id = values[key]?.stringValue {
            return workspace.tab(id)?.id
        }
        if let index = values["index"]?.intValue {
            let tabs = workspace.activeSpace?.tabs.filter { $0.settled == nil } ?? []
            guard tabs.indices.contains(index - 1) else { return nil }
            return tabs[index - 1].id
        }
        return workspace.activeTab?.id
    }

    private func targetPane(_ values: [String: JSONValue]) -> String? {
        if let pane = values["pane"]?.stringValue {
            return workspace.tab(ofPane: pane) != nil ? pane : nil
        }
        if let terminal = values["terminal"]?.stringValue {
            return workspace.paneID(ofTerminal: terminal)
        }
        return workspace.focusedPane
    }

    private var activeWindow: NSWindow? {
        NSApp?.keyWindow ?? NSApp?.windows.first { $0.isVisible }
    }

    private func stepAgent(forward: Bool) async {
        guard !agents.isEmpty else { return }
        let current = workspace.focusedPane.flatMap { workspace.terminal(ofPane: $0) }
        let index = agents.firstIndex { $0.address == current } ?? (forward ? -1 : 0)
        let next = (index + (forward ? 1 : -1) + agents.count) % agents.count
        await selectAgent(agents[next])
    }
}
