// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The herdr-core window gets its own menu bar. It is deliberately built from
// the same action names as the palette, but menu items call the model directly
// so AppKit can validate and route them without parsing a catalog at click time.

import AppKit
import KraalHCTerminal
import KraalSupport

@MainActor
final class HcMenuBar: NSObject, NSMenuItemValidation {
    private weak var workspace: HcWorkspaceModel?
    private static var installed: HcMenuBar?

    static func install(workspace: HcWorkspaceModel) {
        let menu = HcMenuBar(workspace: workspace)
        installed = menu
        NSApp.mainMenu = menu.build()
        kraalLog("menu: installed herdr-core menus")
    }

    private init(workspace: HcWorkspaceModel) {
        self.workspace = workspace
    }

    private func build() -> NSMenu {
        let root = NSMenu()
        root.addItem(submenu("Kraal", appMenu()))
        root.addItem(submenu("File", fileMenu()))
        root.addItem(submenu("Edit", editMenu()))
        root.addItem(submenu("View", viewMenu()))
        root.addItem(submenu("Window", windowMenu()))
        root.addItem(submenu("Help", helpMenu()))
        return root
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        item.submenu = menu
        return item
    }

    private func appMenu() -> [NSMenuItem] {
        [
            target(nil, "About Kraal", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            target(self, "Settings…", #selector(openSettings), "comma"),
            .separator(),
            target(nil, "Services", nil).withSubmenu(NSMenu(title: "Services")),
            .separator(),
            target(nil, "Hide Kraal", #selector(NSApplication.hide(_:)), "h"),
            target(nil, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            target(nil, "Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            target(nil, "Quit Kraal", #selector(NSApplication.terminate(_:)), "q"),
        ]
    }

    private func fileMenu() -> [NSMenuItem] {
        [
            target(self, "New Space", #selector(newSpace), "n", [.command, .shift]),
            target(self, "New Tab", #selector(newTab), "t"),
            .separator(),
            target(self, "Split Right", #selector(splitRight), "d"),
            target(self, "Split Down", #selector(splitDown), "d", [.command, .shift]),
            .separator(),
            target(self, "Close Pane", #selector(closePane), "w", [.command, .shift]),
            target(self, "Close Tab", #selector(closeTab), "w"),
            target(self, "Close Space", #selector(closeSpace), "w", [.command, .option]),
            .separator(),
            target(self, "Rename Tab…", #selector(renameTab), "f2", []),
            target(self, "Rename Space…", #selector(renameSpace), "f2", [.shift]),
        ]
    }

    private func editMenu() -> [NSMenuItem] {
        [
            target(nil, "Undo", Selector(("undo:")), "z"),
            target(nil, "Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            target(nil, "Cut", #selector(NSText.cut(_:)), "x"),
            target(nil, "Copy", #selector(NSText.copy(_:)), "c"),
            target(nil, "Paste", #selector(NSText.paste(_:)), "v"),
            target(nil, "Select All", #selector(NSText.selectAll(_:)), "a"),
        ]
    }

    private func viewMenu() -> [NSMenuItem] {
        [
            target(self, "Command Palette…", #selector(openPalette), "k"),
            target(self, "Toggle Sidebar", #selector(toggleSidebar), "b"),
            target(self, "Next Space", #selector(nextSpace), "]"),
            target(self, "Previous Space", #selector(previousSpace), "[", [.command, .shift]),
            target(self, "Next Tab", #selector(nextTab), "]"),
            target(self, "Previous Tab", #selector(previousTab), "[", [.command, .shift]),
            .separator(),
            target(self, "Zoom Pane", #selector(toggleZoom), "return", [.command, .shift]),
        ]
    }

    private func windowMenu() -> [NSMenuItem] {
        [
            target(nil, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            target(nil, "Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            target(nil, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ]
    }

    private func helpMenu() -> [NSMenuItem] {
        [
            target(self, "Commands…", #selector(openPalette), "p", [.command, .shift]),
            target(self, "Keyboard Shortcuts", #selector(openHelp)),
        ]
    }

    private func target(
        _ target: AnyObject?,
        _ title: String,
        _ action: Selector?,
        _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        return item
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let workspace else { return false }
        switch item.action {
        case #selector(closePane), #selector(closeTab), #selector(closeSpace),
             #selector(splitRight), #selector(splitDown), #selector(toggleZoom):
            return workspace.workspace.activeTab != nil && workspace.isConnected
        case #selector(newSpace), #selector(newTab):
            return workspace.isConnected
        default:
            return true
        }
    }

    @objc private func newSpace() {
        Task { await workspace?.newSpace() }
    }

    @objc private func newTab() {
        Task { await workspace?.newTab() }
    }

    @objc private func splitRight() {
        Task { await workspace?.splitFocusedPane(.row) }
    }

    @objc private func splitDown() {
        Task { await workspace?.splitFocusedPane(.column) }
    }

    @objc private func closePane() {
        Task { await workspace?.closeFocusedPane() }
    }

    @objc private func closeTab() {
        Task { await workspace?.performAction("tab.close") }
    }

    @objc private func closeSpace() {
        Task { await workspace?.performAction("space.close") }
    }

    @objc private func nextSpace() { workspace?.nextSpace() }
    @objc private func previousSpace() { workspace?.previousSpace() }
    @objc private func nextTab() { workspace?.nextTab() }
    @objc private func previousTab() { workspace?.previousTab() }
    @objc private func toggleZoom() { workspace?.toggleZoom() }

    @objc private func openPalette() {
        workspace?.showPalette = true
    }

    @objc private func openSettings() {
        workspace?.showSettings = true
    }

    @objc private func toggleSidebar() {
        workspace?.sidebarVisible.toggle()
    }

    @objc private func renameTab() {
        if let id = workspace?.workspace.activeTab?.id { workspace?.requestRename(tab: id) }
    }

    @objc private func renameSpace() {
        if let id = workspace?.workspace.activeSpace?.id { workspace?.requestRename(space: id) }
    }

    @objc private func openHelp() {
        workspace?.showHelp = true
    }
}

private extension NSMenuItem {
    func withSubmenu(_ menu: NSMenu) -> NSMenuItem {
        submenu = menu
        return self
    }
}
