// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The one AppKit hook the terminal needs. Ghostty deliberately leaves the
// context menu to its host; returning a point makes it ask us even when there
// is no text selection. Everything in the menu goes back through the model, so
// the keyboard, the palette and this menu cannot drift apart.

import AppKit
import GhosttyTerminal

@MainActor
final class HcTerminalPlatformView: TerminalView {
    var menuProvider: (() -> NSMenu?)?
    var onFocusRequest: (() -> Void)?

    /// Right click belongs to the client by default. A program that asks for
    /// the right button (`terminal.right_click=program`) is a later policy;
    /// until then every right click opens the pane menu rather than being
    /// forwarded to a TUI.
    override func mouseDown(with event: NSEvent) {
        onFocusRequest?()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onFocusRequest?()
        super.rightMouseDown(with: event)
    }

    override func selectionMenuPoint(at point: CGPoint) -> CGPoint? {
        point
    }

    override func selectionContextMenu() -> NSMenu {
        menuProvider?() ?? super.selectionContextMenu()
    }
}

/// NSMenuItem does not retain its target. The model keeps one of these alive
/// for as long as its menu is open, which is exactly the menu's lifetime.
@MainActor
final class HcMenuAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run(_: Any?) {
        handler()
    }
}
