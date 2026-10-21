// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Regression tests for the pane right-click menu.
//
// The bug: right-clicking inside a terminal pane did nothing at all. Ghostty's
// terminal view owns `rightMouseDown` — it offers its own Copy item when text is
// selected, and otherwise forwards the press to the program running in the pane.
// Kraal's mouse monitor only relayed the click to the daemon, and only for panes
// that had enabled mouse reporting. With no selection and no mouse reporting the
// click reached nobody: no menu, no event, no action.
//
// SwiftUI's `.contextMenu` cannot cover this, because the terminal is an `NSView`
// consuming the event before any SwiftUI gesture sees it. That is why the sidebar
// had working pane menus while the pane itself had none.
//
// These tests pin the ownership rule, which is the part of the fix that can be
// wrong in a user-visible way in either direction.

import CoreGraphics
import Testing

import KraalProtocol
import KraalUI

@Suite("Pane context menu routing")
struct PaneContextMenuRoutingTests {
    /// The plain case: a shell has not enabled mouse reporting, so nobody is
    /// using the right button and the pane menu must appear.
    @Test("a shell that ignores the mouse gets the pane menu")
    func shellGetsMenu() {
        #expect(PaneContextRouting.shouldShowPaneMenu(programReportsMouse: false))
    }

    /// The case the bug was reported against: no menu at all. If this ever
    /// regresses the pane is back to a dead right-click.
    @Test("no mouse reporting means the click is not forwarded to the program")
    func noMouseReportingDoesNotOwnClick() {
        #expect(!PaneContextRouting.ownsRightClick(programReportsMouse: false))
    }

    /// A TUI that enabled mouse reporting is using the button itself; a menu on
    /// top would swallow a click the program is waiting for.
    @Test("a program reporting the mouse keeps the right button")
    func tuiKeepsRightButton() {
        #expect(PaneContextRouting.ownsRightClick(programReportsMouse: true))
    }

    /// And symmetrically: no menu in that case.
    @Test("a program reporting the mouse suppresses the pane menu")
    func tuiSuppressesMenu() {
        #expect(!PaneContextRouting.shouldShowPaneMenu(programReportsMouse: true))
    }

    /// The two entry points must stay exact complements, or a click could both
    /// raise a menu and be forwarded.
    @Test("menu and program ownership are mutually exclusive")
    func mutuallyExclusive() {
        for reportsMouse in [true, false] {
            let owns = PaneContextRouting.ownsRightClick(programReportsMouse: reportsMouse)
            let shows = PaneContextRouting.shouldShowPaneMenu(programReportsMouse: reportsMouse)
            #expect(owns != shows, "exactly one side must claim the click")
        }
    }
}

// MARK: - The menu itself

import AppKit

/// A stand-in target: the menu only stores it, so any object works.
@MainActor
private final class StubTarget: NSObject, PaneContextTarget {
    @objc func runCommand(_ sender: NSMenuItem) {}
    @objc func focusPane(_ sender: NSMenuItem) {}
    @objc func copySelection(_ sender: NSMenuItem) {}
    @objc func pasteIntoPane(_ sender: NSMenuItem) {}
    @objc func renamePane(_ sender: NSMenuItem) {}
}

/// The target the command items are actually bound to. Kept distinct from
/// `StubTarget` so the routing test below can tell the two apart.
@MainActor
private final class StubCommandTarget: NSObject, NSMenuItemValidation {
    @objc func runCommand(_ sender: NSMenuItem) {}
    func validateMenuItem(_ item: NSMenuItem) -> Bool { true }
}

@Suite("Pane context menu contents")
@MainActor
struct PaneContextMenuContentsTests {
    /// `NSMenuItem.target` is unretained, so the targets have to outlive the call
    /// that binds them. Holding them in the struct keeps them alive for the whole
    /// test; without that the items come back with a nil target and look broken
    /// when they are not.
    private let commandTarget = StubCommandTarget()
    private let paneTarget = StubTarget()

    private func makeMenu() -> NSMenu {
        PaneContextMenuBar.menu(
            paneId: "w1:p7",
            target: paneTarget,
            commandTarget: commandTarget,
            commandSelector: #selector(StubCommandTarget.runCommand(_:))
        )
    }

    /// The bug was "no menu at all", so the first thing to pin is that a menu
    /// with items now exists.
    @Test("the pane menu is not empty")
    func menuHasItems() {
        let menu = makeMenu()
        #expect(menu.items.count > 10, "got \(menu.items.count) items")
    }

    /// The pane it acts on must travel with the menu: without this, every item
    /// would act on whichever pane happened to be focused.
    @Test("the menu remembers which pane it was raised over")
    func menuCarriesPaneId() {
        #expect(makeMenu().owningPaneId == "w1:p7")
    }

    /// Submenu items resolve their pane through the parent, which is how an item
    /// like "Swap Left" knows what to swap.
    @Test("submenu items resolve the pane through the parent menu")
    func submenuResolvesPane() throws {
        let menu = makeMenu()
        let submenu = try #require(menu.items.compactMap(\.submenu).first)
        #expect(submenu.owningPaneId == "w1:p7")
        #expect(submenu.items.isEmpty == false)
    }

    /// The actions a user right-clicks a pane for. Split and close are the two
    /// that make the menu worth opening; losing either silently would restore a
    /// version of the original bug.
    @Test("split, zoom, clear, rename and close are all offered")
    func coreActionsPresent() {
        let titles = makeMenu().items.map(\.title)
        for expected in ["Split Right", "Split Down", "Toggle Pane Zoom", "Clear Pane"] {
            #expect(titles.contains(expected), "missing \(expected) in \(titles)")
        }
        #expect(titles.contains { $0.hasPrefix("Rename Pane") })
        #expect(titles.contains { $0.hasPrefix("Close Pane") })
    }

    /// Copy and Paste are Ghostty's and the pasteboard's rather than the
    /// daemon's, so they are built by hand — and are exactly what a user expects
    /// from a right-click in a terminal.
    @Test("copy and paste are offered")
    func clipboardActionsPresent() {
        let titles = makeMenu().items.map(\.title)
        #expect(titles.contains("Copy"))
        #expect(titles.contains("Paste"))
    }

    /// Every command item must carry its command on `representedObject`, or the
    /// shared selector has nothing to dispatch on and the item does nothing when
    /// clicked — the same silent failure this change exists to fix.
    @Test("command items carry a dispatchable command")
    func commandItemsCarryCommands() {
        let menu = makeMenu()
        let commandItems = menu.items.filter {
            $0.representedObject is String && $0.action != nil
        }
        #expect(!commandItems.isEmpty)
        for item in commandItems {
            let raw = item.representedObject as? String
            #expect(raw.flatMap(AppCommand.init(rawValue:)) != nil, "bad command on \(item.title)")
        }
    }

    /// Regression test for panes whose menu opened with Split Right greyed out.
    ///
    /// `NSMenu.autoenablesItems` is on by default, so AppKit asks the *target*
    /// whether each item is enabled and disables anything whose target does not
    /// respond to the selector. The command items were pinned to the app delegate,
    /// which relays to the menu bar through `representedObject` and therefore
    /// implements neither `runCommand:` nor `validateMenuItem:` — every command
    /// item rendered disabled while the pane-scoped ones (Focus, Copy, Paste,
    /// Rename) stayed live, because those really are the delegate's selectors.
    ///
    /// The rule this pins: command items must target an object that both responds
    /// to the command selector and validates menu items.
    @Test("command items are bound to a target that can enable them")
    func commandItemsTargetAValidatingObject() {
        let menu = makeMenu()
        let commandItems = menu.items.filter { $0.representedObject is String }
        #expect(!commandItems.isEmpty)
        for item in commandItems {
            guard let target = item.target as? NSObject else {
                Issue.record("command item \(item.title) has no target")
                continue
            }
            #expect(target.responds(to: #selector(StubCommandTarget.runCommand(_:))),
                    "\(item.title) targets an object that cannot receive its action")
            #expect(target is NSMenuItemValidation,
                    "\(item.title) targets an object AppKit cannot validate, so it stays greyed out")
        }
    }
}
