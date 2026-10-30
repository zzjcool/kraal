// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The native menu bar.
//
// The app is a hand-written `NSApplication` with no nib and no SwiftUI `Scene`,
// so `.commands` — the usual way to add menu items — never applies here. The
// menu is therefore built by hand. That is also why this file has to supply what
// AppKit would otherwise get for free from a nib: the About item, the standard
// Edit menu (without it there is no ⌘C/⌘V/⌘A outside the terminal, and ⌘Q does
// not exist at all), and the Window menu.
//
// Item titles and the shortcut set follow Herdr's own action list. Herdr ships
// one `<id><Title>` pair per action in its binary (e.g. `split_rightSplit Right`,
// `close_paneClose Pane`, `new_tabNew Tab`), and its File menu is grouped as
// New / Go To / Close. Reproducing that grouping — rather than inventing one —
// means a user moving between the two clients finds the same words in the same
// places.

import AppKit
import KraalUI

/// Builds and owns the main menu. One instance per app; it holds a weak store
/// because the menu outlives window rebuilds but the store can be replaced.
@MainActor
final class MacMenuBar: NSObject, NSMenuItemValidation {
    private weak var store: AppStore?
    private let actions: MenuActions

    /// Window-level toggles the menu has no way to reach on its own.
    struct MenuActions {
        var toggleSidebar: () -> Void = {}
        var toggleStatusBar: () -> Void = {}
        var showCommands: () -> Void = {}
        var showShortcuts: () -> Void = {}
        var showSettings: () -> Void = {}
        var showThemePicker: () -> Void = {}
        var adjustFontSize: (FontScale.Change) -> Void = { _ in }
        var toggleDensity: () -> Void = {}
        var showDebugInfo: () -> Void = {}
        var enterCopyMode: (String) -> Void = { _ in }
    }

    init(store: AppStore, actions: MenuActions) {
        self.store = store
        self.actions = actions
        super.init()
    }

    func install() {
        let mainMenu = NSMenu()
        mainMenu.addItem(submenu(title: "Kraal", build: appMenu))
        mainMenu.addItem(submenu(title: "File", build: fileMenu))
        mainMenu.addItem(submenu(title: "Edit", build: editMenu))
        mainMenu.addItem(submenu(title: "View", build: viewMenu))
        mainMenu.addItem(submenu(title: "Window", build: windowMenu))
        mainMenu.addItem(submenu(title: "Help", build: helpMenu))
        NSApplication.shared.mainMenu = mainMenu
        kraalLog("menu: installed \(mainMenu.items.count) top-level menus")
    }

    // MARK: - Menu construction

    private func submenu(title: String, build: (NSMenu) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        build(menu)
        item.submenu = menu
        return item
    }

    private func appMenu(_ menu: NSMenu) {
        menu.addItem(
            withTitle: "About Kraal",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        // Settings sits in the app menu with ⌘, because that is where macOS users
        // look for it and what their fingers already press. Machines moved into
        // it as a tab: they were under File, wedged between Rename and Close,
        // which read as a document action rather than configuration.
        menu.addItem(command: .settings, target: self)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Command Palette", action: #selector(showCommandPalette), keyEquivalent: "k")
        menu.addItem(withTitle: "Keyboard Shortcuts", action: #selector(showShortcuts), keyEquivalent: "/")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reload Config", action: #selector(reloadConfig), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide Kraal", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Kraal", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func fileMenu(_ menu: NSMenu) {
        // New — Herdr's File menu opens with its "New …" group.
        menu.addItem(command: .newWorkspace, target: self)
        menu.addItem(command: .newTab, target: self)
        menu.addItem(.separator())

        menu.addItem(command: .renameWorkspace, target: self)
        menu.addItem(command: .renameTab, target: self)
        menu.addItem(command: .renamePane, target: self)
        menu.addItem(.separator())

        // Close — pane, then tab, then workspace, widening scope. Herdr labels
        // these "Close Pane…", "Close Tab…"; the ellipsis is dropped here so the
        // items read as plain verbs (Kraal closes immediately, no confirmation).
        menu.addItem(command: .closePane, target: self)
        menu.addItem(command: .closeTab, target: self)
        menu.addItem(command: .closeWorkspace, target: self)
    }

    private func editMenu(_ menu: NSMenu) {
        // Without these the standard responder chain has no way in: a bare
        // NSApplication with no nib has no Edit menu at all.
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        // Paste is a Kraal command, not `NSText.paste`: the responder chain has
        // nobody in the pane to receive it (the terminal view does not implement
        // it), and even if it did, the text has to reach the daemon as a paste
        // event rather than as keystrokes. See `AppStore.sendPaste`.
        menu.addItem(command: .paste, target: self)
        menu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        menu.addItem(.separator())
        // Copy mode is not `⌘C`: that copies the local surface's mouse selection, one
        // screenful. This reaches the pane's history, which only the daemon has. `⌘F`
        // because that is what "find/select in the terminal" already means to macOS
        // users, and this mode is where the search keys live.
        menu.addItem(command: .copyMode, target: self)
        menu.addItem(.separator())
        menu.addItem(command: .clearPane, target: self)
    }

    private func viewMenu(_ menu: NSMenu) {
        menu.addItem(command: .toggleSidebar, target: self)
        menu.addItem(command: .toggleStatusBar, target: self)
        menu.addItem(command: .changeTheme, target: self)
        menu.addItem(command: .increaseFontSize, target: self)
        menu.addItem(command: .decreaseFontSize, target: self)
        menu.addItem(command: .resetFontSize, target: self)
        menu.addItem(command: .toggleDensity, target: self)
        menu.addItem(.separator())

        menu.addItem(command: .splitRight, target: self)
        menu.addItem(command: .splitDown, target: self)
        menu.addItem(.separator())

        // Pane movement, grouped the way Herdr groups its directional actions.
        let focusMenu = NSMenu(title: "Focus Pane")
        for command in AppCommand.paneMoveItems {
            focusMenu.addItem(command: command, target: self)
        }
        let focusItem = NSMenuItem(title: "Focus Pane", action: nil, keyEquivalent: "")
        focusItem.submenu = focusMenu
        menu.addItem(focusItem)

        let swapMenu = NSMenu(title: "Swap Pane")
        for command in AppCommand.paneSwapItems {
            swapMenu.addItem(command: command, target: self)
        }
        let swapItem = NSMenuItem(title: "Swap Pane", action: nil, keyEquivalent: "")
        swapItem.submenu = swapMenu
        menu.addItem(swapItem)

        menu.addItem(command: .toggleZoom, target: self)
        menu.addItem(.separator())
        menu.addItem(command: .previousWorkspace, target: self)
        menu.addItem(command: .nextWorkspace, target: self)
        menu.addItem(command: .previousTab, target: self)
        menu.addItem(command: .nextTab, target: self)
        menu.addItem(command: .previousPane, target: self)
        menu.addItem(command: .nextPane, target: self)
    }

    private func windowMenu(_ menu: NSMenu) {
        menu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        menu.addItem(
            withTitle: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        NSApplication.shared.windowsMenu = menu
    }

    private func helpMenu(_ menu: NSMenu) {
        let debugMenu = NSMenu(title: "Debug")
        let showInfo = NSMenuItem(
            title: "Show Debug Info…",
            action: #selector(showDebugInfo),
            keyEquivalent: ""
        )
        // F12 via AppKit private-use scalar (same pattern as arrow keys in MenuShortcuts).
        if let scalar = UnicodeScalar(NSF12FunctionKey) {
            showInfo.keyEquivalent = String(Character(scalar))
            showInfo.keyEquivalentModifierMask = []
        }
        showInfo.target = self
        debugMenu.addItem(showInfo)

        let toggleLog = NSMenuItem(
            title: "Toggle Verbose Logging",
            action: #selector(toggleVerboseLogging),
            keyEquivalent: ""
        )
        toggleLog.target = self
        toggleLog.state = KraalLog.shared.isEnabled ? .on : .off
        debugMenu.addItem(toggleLog)

        let debugItem = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        debugItem.submenu = debugMenu
        menu.addItem(debugItem)
    }

    // MARK: - Actions

    @objc private func showCommandPalette() { actions.showCommands() }
    @objc private func showShortcuts() { actions.showShortcuts() }
    @objc private func showDebugInfo() { actions.showDebugInfo() }

    @objc private func toggleVerboseLogging(_ sender: NSMenuItem) {
        let next = !KraalLog.shared.isEnabled
        KraalLog.shared.setEnabled(next)
        sender.state = next ? .on : .off
        let state = next ? "on" : "off"
        kraalLog("debug: verbose logging \(state)")
    }
    @objc private func reloadConfig() {
        store?.reloadServerConfig()
    }

    /// Every command item routes through here. The title carries the command's
    /// `AppCommand.rawValue` so one selector can serve the whole menu — this is
    /// also what makes `validateMenuItem` able to reason about availability.
    @objc func runCommand(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let command = AppCommand(rawValue: raw) else { return }
        // A context menu carries the pane it was raised over, and that is more
        // trustworthy than "whatever is focused now": the menu bar's items mean
        // the focused pane, but a right-click means the pane under the pointer.
        //
        // The id is handed to `perform` instead of being applied by focussing
        // first. `store.focus(paneId:)` only *sends* a request on a Task, so
        // calling it here and then reading `actionPaneId` inside the command
        // still saw the previous focus — every pane action from a context menu
        // ran against the wrong pane, which is why split and close appeared to
        // do nothing when the menu was raised over an unfocused pane.
        let target = command.isPaneScoped ? sender.menu?.owningPaneId : nil
        dispatch(command, target: target)
    }

    /// The one place a menu command becomes a store action.
    private func dispatch(_ command: AppCommand, target: String?) {
        guard let store else { return }
        // The command below is dispatched with `target`, so focus does not have
        // to be applied first — and must not be: one connection serves one
        // command at a time, so firing `pane.focus` and the real action in the
        // same tick made the daemon refuse the *action* with `endpoint_busy`.
        // The refused split then looked like a split that did nothing.
        //
        // Focus still follows the click, after the command has been sent, so a
        // pane action lands on the pane the user chose and the focused pane
        // catches up afterwards.
        kraalLog("runCommand: \(command.rawValue) target=\(target ?? "nil") "
            + "focused=\(store.actionPaneId ?? "nil")")
        KraalUI.perform(
            command,
            on: store,
            env: commandEnvironment(targetPaneId: target)
        )
        if let target {
            store.focus(paneId: target)
        }
    }

    private func commandEnvironment(targetPaneId: String? = nil) -> CommandEnvironment {
        CommandEnvironment(
            prompt: { [weak self] prompt in self?.presentRename(prompt) },
            toggleSidebar: actions.toggleSidebar,
            toggleStatusBar: actions.toggleStatusBar,
            showCommands: actions.showCommands,
            showShortcuts: actions.showShortcuts,
            showSettings: actions.showSettings,
            showThemePicker: actions.showThemePicker,
            adjustFontSize: actions.adjustFontSize,
            toggleDensity: actions.toggleDensity,
            targetPaneId: targetPaneId,
            enterCopyMode: { [weak self] paneId in self?.actions.enterCopyMode(paneId) }
        )
    }

    /// Rename needs an editable field, which a menu item cannot provide. A small
    /// modal alert is the least surprising place: it is in front of the menu the
    /// user just clicked, and it cannot outlive the window like a stray sheet.
    private func presentRename(_ prompt: CommandPrompt) {
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = "Enter a new name."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = prompt.currentValue
        alert.accessoryView = field

        // `runModal` blocks until the user answers, which is correct here: the
        // menu click has already finished and nothing else owns the interaction.
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != prompt.currentValue, let store else { return }

        switch prompt {
        case .renameTab(let tabId, _): store.rename(tabId: tabId, to: name)
        case .renameWorkspace(let workspaceId, _): store.rename(workspaceId: workspaceId, to: name)
        case .renamePane(let paneId, _): store.rename(paneId: paneId, to: name)
        }
    }

    // MARK: - Validation

    /// Disables what cannot run so the menu reflects reality instead of failing
    /// silently on click. Pane items need a pane, tab items a tab, and the
    /// move-tab pair needs somewhere to move to.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleVerboseLogging) {
            item.state = KraalLog.shared.isEnabled ? .on : .off
            return true
        }
        guard let raw = item.representedObject as? String,
              let command = AppCommand(rawValue: raw) else { return true }
        guard let store else { return false }

        switch command {
        case _ where command.isPaneScoped:
            guard store.actionPaneId != nil else { return false }
            // Swapping needs a neighbour in that direction; with a single pane
            // there is nothing to swap with, so the item is pointless.
            if command.isSwap { return store.visiblePanes.count > 1 }
            return true

        case .closeTab, .renameTab:
            return store.actionTabId != nil

        case .moveTabPrevious:
            return tabIndex(in: store).map { $0 > 0 } ?? false
        case .moveTabNext:
            return tabIndex(in: store).map { $0 < store.visibleTabs.count - 1 } ?? false

        case .closeWorkspace, .renameWorkspace:
            return store.focusedWorkspace != nil

        case .previousTab, .nextTab, .previousWorkspace, .nextWorkspace:
            return true

        default:
            return true
        }
    }

    private func tabIndex(in store: AppStore) -> Int? {
        store.visibleTabs.firstIndex { $0.focused }
            ?? store.visibleTabs.firstIndex { $0.tabId == store.actionTabId }
    }
}

extension AppCommand {
    /// Commands that need a focused pane to act on.
    var isPaneScoped: Bool { AppCommand.paneScopedCommands.contains(self) }

    var isSwap: Bool {
        switch self {
        case .swapPaneLeft, .swapPaneRight, .swapPaneUp, .swapPaneDown: return true
        default: return false
        }
    }
}

// MARK: - Menu item construction helpers

private extension NSMenu {
    /// Adds an item bound to `command`, with the shortcut the app documents.
    func addItem(command: AppCommand, target: AnyObject) {
        let item = NSMenuItem(
            title: command.title,
            action: #selector(MacMenuBar.runCommand(_:)),
            keyEquivalent: ""
        )
        item.representedObject = command.rawValue
        item.target = target
        if let shortcut = MenuShortcuts.shortcut(for: command) {
            item.keyEquivalent = shortcut.key
            item.keyEquivalentModifierMask = shortcut.modifiers
        }
        addItem(item)
    }
}
