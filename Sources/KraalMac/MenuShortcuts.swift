// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The keyboard shortcuts advertised in the menu bar.
//
// Kept apart from the menu construction so the table can be read — and changed —
// on its own. Each entry is what the item shows on its right; the menu is the
// single place a shortcut is declared, and `ShortcutsView` documents the same
// chords so the reference cannot drift from what actually fires.

import AppKit
import KraalUI

/// The keyboard shortcuts shown in the menu. Kept beside the menu rather than in
/// the views so there is one place to change a binding; the views'
/// `.keyboardShortcut` buttons stay for shortcuts that must work when a terminal
/// has first responder and the menu bar is not consulted.
enum MenuShortcuts {
    struct Shortcut {
        var key: String
        var modifiers: NSEvent.ModifierFlags
    }

    /// Chords keyed by command. A table instead of a 29-branch switch: the same
    /// information, readable in one screen, and no cyclomatic-complexity warning.
    private static let table: [AppCommand: Shortcut] = {
        var map: [AppCommand: Shortcut] = [
            .newTab: Shortcut(key: "t", modifiers: .command),
            .newWorkspace: Shortcut(key: "n", modifiers: .command),
            .closePane: Shortcut(key: "w", modifiers: [.command, .shift]),
            .closeTab: Shortcut(key: "w", modifiers: .command),
            .renameTab: Shortcut(key: "r", modifiers: [.command, .shift]),

            // ⌘F, not ⌘C: ⌘C is the terminal's own copy (one screenful, mouse
            // selection). This opens the mode that can reach the pane's history.
            .copyMode: Shortcut(key: "f", modifiers: .command),

            // Ghostty's own chords, because a terminal user already has them in
            // their fingers. ⌘+ is shift+equals on a US layout, which is why the
            // key is "=" and not "+".
            .increaseFontSize: Shortcut(key: "=", modifiers: .command),
            .decreaseFontSize: Shortcut(key: "-", modifiers: .command),
            .resetFontSize: Shortcut(key: "0", modifiers: .command),

            .splitRight: Shortcut(key: "d", modifiers: .command),
            .splitDown: Shortcut(key: "d", modifiers: [.command, .shift]),
            .toggleZoom: Shortcut(key: "return", modifiers: [.command, .shift]),

            .nextTab: Shortcut(key: "]", modifiers: [.command, .shift]),
            .previousTab: Shortcut(key: "[", modifiers: [.command, .shift]),
            .nextWorkspace: Shortcut(key: "]", modifiers: .command),
            .previousWorkspace: Shortcut(key: "[", modifiers: .command),
            .nextPane: Shortcut(key: "]", modifiers: [.command, .option]),
            .previousPane: Shortcut(key: "[", modifiers: [.command, .option]),

            .moveTabPrevious: Shortcut(key: ",", modifiers: [.command, .shift]),
            .moveTabNext: Shortcut(key: ".", modifiers: [.command, .shift]),

            .focusLeft: Shortcut(key: arrowKey(NSLeftArrowFunctionKey), modifiers: [.command, .option]),
            .focusRight: Shortcut(key: arrowKey(NSRightArrowFunctionKey), modifiers: [.command, .option]),
            .focusUp: Shortcut(key: arrowKey(NSUpArrowFunctionKey), modifiers: [.command, .option]),
            .focusDown: Shortcut(key: arrowKey(NSDownArrowFunctionKey), modifiers: [.command, .option]),

            .toggleSidebar: Shortcut(key: "b", modifiers: .command),
            .toggleStatusBar: Shortcut(key: "b", modifiers: [.command, .shift]),
            .commandPalette: Shortcut(key: "k", modifiers: .command),
            .reconnect: Shortcut(key: "r", modifiers: .command),
            // ⌘, is the chord macOS users press for preferences, and it is what
            // every other Mac app binds it to — a settings window without it feels
            // broken before it is even opened.
            .settings: Shortcut(key: ",", modifiers: .command),
        ]

        // ⌘1…⌘9 focus tabs; ⌃⌘1…⌃⌘9 focus workspaces, so the two ranges do not
        // collide on the same chord.
        for number in 1...9 {
            if let command = AppCommand(rawValue: "focus_tab_\(number)") {
                map[command] = Shortcut(key: "\(number)", modifiers: .command)
            }
            if let command = AppCommand(rawValue: "focus_workspace_\(number)") {
                map[command] = Shortcut(key: "\(number)", modifiers: [.command, .control])
            }
        }
        return map
    }()

    static func shortcut(for command: AppCommand) -> Shortcut? {
        table[command]
    }

    /// AppKit encodes arrow keys as private-use scalars; building the string can
    /// fail, so an empty key (no shortcut shown) is the fallback.
    private static func arrowKey(_ code: Int) -> String {
        guard let scalar = UnicodeScalar(code) else { return "" }
        return String(Character(scalar))
    }
}
