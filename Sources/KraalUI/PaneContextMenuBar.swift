// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The pane's own context menu, built in AppKit.
//
// SwiftUI's `.contextMenu` cannot serve a terminal pane: Ghostty's terminal view
// is an `NSView` that handles `rightMouseDown` itself (to forward the press to the
// program running inside the pane, and to offer its own Copy item over a
// selection), so the right-click never reaches a SwiftUI gesture. The pane is the
// one place in the window where the menu has to be raised from AppKit's own
// event path rather than declared in the view tree.
//
// The items are the same set the sidebar offers through `PaneContextMenu`, and
// they run through the same `MacMenuBar.runCommand` channel, so a pane behaves
// the same whether it was reached from the sidebar or the terminal itself.

import AppKit

/// Builds the context menu raised by a right-click inside a terminal pane.
///
/// It deliberately does not reuse `PaneContextMenu`: that is a SwiftUI view whose
/// body is turned into items by SwiftUI, and the only way to obtain those items
/// from AppKit would be to host the view and read its menu back — far more
/// machinery than declaring the same command list twice, and it would make the
/// two menus silently diverge the moment one changed.
@MainActor
public enum PaneContextMenuBar {
    /// Builds the menu for `paneId`.
    ///
    /// Two targets, because the two halves of this menu travel different paths:
    ///
    /// * `target` receives the `PaneContextTarget` selectors — the actions that
    ///   only a pane can serve (the clipboard reaches a Ghostty surface, and the
    ///   rename prompt belongs to the window).
    /// * `commandTarget` receives the `AppCommand` items and must implement
    ///   `validateMenuItem` and the selector, because `autoenablesItems` is on by
    ///   default: AppKit asks the target whether an item is enabled, and a target
    ///   that does not respond to the selector gets its item greyed out. Routing
    ///   commands to a target without menu validation makes every one of them
    ///   permanently disabled, which is what this parameter exists to prevent.
    public static func menu(
        paneId: String,
        target: AnyObject,
        commandTarget: AnyObject,
        commandSelector: Selector
    ) -> NSMenu {
        let menu = NSMenu()
        // The menu bar's own menus disable AppKit's automatic validation because
        // their items are driven by `validateMenuItem` on a target that always
        // exists. A context menu has no such luxury: without this, AppKit asks
        // the target about every item as the menu opens, and an item whose
        // answer is "no" is silently greyed out — which looks exactly like a
        // split that does nothing. Enabling is decided once, when the menu is
        // built, from state the caller already knows.
        menu.autoenablesItems = false
        // Pinning the pane id here is what makes the commands act on the pane that
        // was clicked rather than whichever one happened to be focused.
        menu.paneId = paneId

        // Focus first: a right-click in a pane the user is not typing into should
        // be able to make that pane the active one before anything else.
        let focus = NSMenuItem(
            title: "Focus Pane",
            action: #selector(PaneContextTarget.focusPane(_:)),
            keyEquivalent: ""
        )
        focus.target = target
        menu.addItem(focus)
        menu.addItem(.separator())

        menu.addItem(command: .splitRight, target: commandTarget, selector: commandSelector)
        menu.addItem(command: .splitDown, target: commandTarget, selector: commandSelector)
        menu.addItem(command: .toggleZoom, target: commandTarget, selector: commandSelector)
        menu.addItem(.separator())

        let focusDirection = NSMenu(title: "Focus Pane")
        for command in AppCommand.paneMoveItems {
            focusDirection.addItem(command: command, target: commandTarget, selector: commandSelector)
        }
        menu.addItem(submenu: focusDirection, title: "Focus Pane Direction")

        let swap = NSMenu(title: "Swap Pane")
        for command in AppCommand.paneSwapItems {
            swap.addItem(command: command, target: commandTarget, selector: commandSelector)
        }
        menu.addItem(submenu: swap, title: "Swap Pane")

        menu.addItem(.separator())
        // Copy is Ghostty's, not the daemon's: the selection lives in the terminal
        // surface, so the menu item has to reach that view. `autoenablesItems` is
        // off for this menu, so its enabled state has to be set here instead of
        // being asked for at open time.
        let copy = NSMenuItem(
            title: "Copy",
            action: #selector(PaneContextTarget.copySelection(_:)),
            keyEquivalent: ""
        )
        copy.target = target
        if let validating = target as? PaneContextMenuValidating {
            copy.isEnabled = validating.paneHasSelection(paneId)
        }
        menu.addItem(copy)

        let paste = NSMenuItem(
            title: "Paste",
            action: #selector(PaneContextTarget.pasteIntoPane(_:)),
            keyEquivalent: ""
        )
        paste.target = target
        menu.addItem(paste)

        menu.addItem(.separator())
        menu.addItem(command: .clearPane, target: commandTarget, selector: commandSelector)
        let rename = NSMenuItem(
            title: "Rename Pane…",
            action: #selector(PaneContextTarget.renamePane(_:)),
            keyEquivalent: ""
        )
        rename.target = target
        menu.addItem(rename)

        menu.addItem(.separator())
        menu.addItem(command: .closePane, target: commandTarget, selector: commandSelector)
        return menu
    }
}

/// Selectors the pane menu can use to reach the pane it was raised over.
///
/// Only the few pane-scoped actions that are not already `AppCommand`s need a
/// selector here; everything else is routed by `MacMenuBar.runCommand` through
/// the item's represented command.
@MainActor
@objc
public protocol PaneContextTarget: AnyObject {
    func focusPane(_ sender: NSMenuItem)
    func copySelection(_ sender: NSMenuItem)
    func pasteIntoPane(_ sender: NSMenuItem)
    func renamePane(_ sender: NSMenuItem)
}

/// What the menu needs to know about a pane before it opens.
///
/// Separate from `PaneContextTarget` because it is a question about state, not
/// an action, and the caller may answer it without being the action target.
@MainActor
public protocol PaneContextMenuValidating: AnyObject {
    /// Whether the pane has a selection to copy.
    func paneHasSelection(_ paneId: String) -> Bool
}

// MARK: - Pane identity on the menu

private enum PaneMenuKey {
    /// Associated objects cannot be stored on a Swift enum, so the pane id rides
    /// on the menu itself. Storing it on the menu rather than on every item keeps
    /// the call sites free of the id, and a submenu inherits it by lookup.
    nonisolated(unsafe) static var storage: [ObjectIdentifier: String] = [:]
}

extension NSMenu {
    /// The pane this menu was raised over.
    public var paneId: String? {
        get { PaneMenuKey.storage[ObjectIdentifier(self)] }
        set { PaneMenuKey.storage[ObjectIdentifier(self)] = newValue }
    }

    /// The pane id of the nearest enclosing menu, so an action fired from a
    /// submenu can still tell which pane it belongs to.
    public var owningPaneId: String? {
        if let paneId { return paneId }
        return supermenu?.owningPaneId
    }

    /// Adds an item bound to `command`.
    ///
    /// The selector is supplied by the caller rather than hard-coded: the menu bar
    /// and the pane context menu live in different modules, and neither should
    /// have to know the other's selector name. The command travels on
    /// `representedObject`, so one selector serves every item.
    public func addItem(command: AppCommand, target: AnyObject, selector: Selector) {
        let item = NSMenuItem(title: command.title, action: selector, keyEquivalent: "")
        item.representedObject = command.rawValue
        item.target = target
        addItem(item)
    }

    /// Adds a titled submenu.
    public func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
