// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// keys.json lives outside the action table; this controller reloads it live and
// turns AppKit key events into the same normalized combo the parser produces.

import AppKit
import KraalActions
import KraalHC
import SwiftUI

@MainActor
final class HcKeymapController: ObservableObject {
    @Published private(set) var bindings: [KraalKeyBinding] = []
    @Published private(set) var error: String?

    private weak var workspace: HcWorkspaceModel?
    private var monitor: Any?
    private var reloadTimer: Timer?
    private var modified: Date?
    private let path: URL

    nonisolated static var defaultPath: URL {
        if let override = ProcessInfo.processInfo.environment["KRAAL_KEYS"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/kraal/keys.json")
    }

    init(workspace: HcWorkspaceModel, path: URL = HcKeymapController.defaultPath) {
        self.workspace = workspace
        self.path = path
        reload(quiet: true)
    }

    func attach() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handle(event) else { return event }
            return nil
        }
        reloadTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reloadIfChanged() }
        }
    }

    func detach() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        reloadTimer?.invalidate()
        reloadTimer = nil
    }

    func reload(quiet: Bool = false) {
        do {
            let next = try KraalKeymap.load(path: path)
            bindings = next
            error = nil
            modified = try? FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate] as? Date
            if !quiet { workspace?.log?("keys: loaded \(next.count) bindings from \(path.path)") }
        } catch {
            // Keep the last working bindings: a broken edit must not take the
            // keyboard away from a running session.
            self.error = String(describing: error)
            workspace?.log?("keys: \(error)")
            if !quiet {
                workspace?.showToast(title: "keys.json", detail: String(describing: error), level: .error)
            }
        }
    }

    /// The reserved escape hatch. It restores the shipped keys so a broken
    /// `keys.json` cannot lock the window; the shared layout is left alone.
    func reset() {
        do {
            try KraalKeymap.defaultMacOS.write(to: path, atomically: true, encoding: .utf8)
            reload()
            workspace?.showToast(title: "Keys reset", detail: "Restored the default key bindings.", level: .info)
        } catch {
            workspace?.showToast(title: "Keys reset failed", detail: String(describing: error), level: .error)
        }
    }

    private func reloadIfChanged() {
        let date = try? FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate] as? Date
        guard let date, date != modified else { return }
        reload()
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let workspace, workspace.isConnected,
              !workspace.showPalette, !workspace.showHelp,
              workspace.machineSheet == nil, workspace.closeRequest == nil
        else { return false }
        guard let (modifiers, key) = Self.combo(event) else { return false }
        if key == "escape", modifiers == [.control, .option, .shift] {
            reset()
            return true
        }
        let terminal = terminalContext(workspace)
        for binding in Self.candidates(bindings, terminal: terminal) {
            guard binding.combo.matches(modifiers: modifiers, key: key) else { continue }
            if binding.action == "terminal" { return false }
            if binding.action.hasPrefix("send:") {
                guard terminal else { continue }
                workspace.sendToFocused(String(binding.action.dropFirst(5)))
                return true
            }
            guard runnable(binding.action, workspace: workspace) else { continue }
            run(binding.action, workspace: workspace)
            return true
        }
        return false
    }

    /// The terminal section is the more specific context, so it must be tried
    /// before global; `layout:`/`mod:` have no Kraal equivalent yet.
    nonisolated static func candidates(
        _ bindings: [KraalKeyBinding],
        terminal: Bool
    ) -> [KraalKeyBinding] {
        let global = bindings.filter { $0.section == "global" }
        guard terminal else { return global }
        return bindings.filter { $0.section == "terminal" } + global
    }

    private func terminalContext(_ workspace: HcWorkspaceModel) -> Bool {
        guard workspace.workspace.focusedPane != nil else { return false }
        if let responder = NSApp.keyWindow?.firstResponder,
           responder is NSText || responder is NSTextView || responder is NSTextField {
            return false
        }
        return true
    }

    private func runnable(_ action: String, workspace: HcWorkspaceModel) -> Bool {
        let parts = action.split(separator: ":", maxSplits: 1).map(String.init)
        let name = parts.first ?? action
        guard let catalog = KraalActions.find(name), catalog.isNative else { return false }
        guard workspace.canPerformAction(name) else { return false }
        if parts.count == 2, let first = catalog.args.first {
            return !first.required || !parts[1].isEmpty
        }
        if catalog.args.contains(where: \.required) {
            return workspace.canPromptAction(name)
        }
        return true
    }

    private func run(_ action: String, workspace: HcWorkspaceModel) {
        let parts = action.split(separator: ":", maxSplits: 1).map(String.init)
        let name = parts.first ?? action
        var arguments: JSONValue?
        if parts.count == 2, let first = KraalActions.find(name)?.args.first {
            arguments = .object([first.name: .string(parts[1])])
        }
        Task { @MainActor in
            let outcome = await workspace.performAction(name, arguments: arguments)
            if let error = outcome.error {
                workspace.showToast(title: name, detail: error, level: .error)
            }
        }
    }

    nonisolated static func combo(_ event: NSEvent) -> (Set<KraalKeyModifier>, String)? {
        var modifiers: Set<KraalKeyModifier> = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if let special = specialKeys[event.keyCode] {
            return (modifiers, special)
        }
        guard let characters = event.charactersIgnoringModifiers?.lowercased(),
              !characters.isEmpty
        else { return nil }
        return (modifiers, characters)
    }

    nonisolated private static let specialKeys: [UInt16: String] = [
        36: "enter", 76: "enter", 48: "tab", 51: "backspace", 53: "escape",
        115: "home", 116: "pageup", 117: "delete", 119: "end", 121: "pagedown",
        123: "left", 124: "right", 125: "down", 126: "up",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6",
        98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
    ]

}
