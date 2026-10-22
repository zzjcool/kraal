// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Who a right-click inside a terminal pane belongs to.
//
// This lives in KraalUI rather than next to the mouse monitor for two reasons:
// the rule is pure (it takes one flag and returns a decision), and the monitor
// lives in a module that links Ghostty's xcframework, which the test target
// cannot link. Keeping the decision here is what lets it be covered by tests.

import Foundation

/// Who a right-click belongs to.
///
/// Split out from the monitor so the rule is testable without a window: the
/// question is only ever "did the program ask for the button", and getting it
/// wrong in either direction is a user-visible bug — the menu either steals a
/// click a TUI is waiting for, or the click does nothing at all.
public enum PaneContextRouting {
    /// The daemon's `right_click` target for a pane, as the wire names it.
    ///
    /// Mirrors upstream's `PaneRightClickTarget` (`api/schema/panes.rs:15-19`).
    /// Kept as a type so the wire spelling lives in one place: `pane.input.set`
    /// takes `"pane"` or `"herdr"`, and a typo here silently reverts the pane to
    /// the daemon's default (the menu) rather than failing.
    public enum RightClickTarget: String, Sendable {
        /// The program inside the pane gets the click (no Kraal menu).
        case pane
        /// Kraal's own pane menu opens (the daemon's default).
        case herdr
    }

    /// True when the program inside the pane owns the right button, so the pane
    /// menu must stay out of the way.
    ///
    /// Two independent things can hand the button to the program:
    ///
    /// - `programReportsMouse`: the program enabled mouse reporting, so it is
    ///   handling buttons itself. TUIs (editors, pagers, tmux) do exactly this
    ///   and use the right button for their own menus; a Kraal menu on top of
    ///   that would be unreachable and would eat the click. This was the only
    ///   input, and it is why the per-pane `right_click` setting had no effect.
    /// - `rightClickPassthrough`: the user explicitly set this pane's
    ///   `right_click = "pane"` (`pane.input.set`, persisted by the daemon and
    ///   reported back as `right_click_passthrough` in the snapshot). It applies
    ///   even to a program that does *not* report the mouse: that is the whole
    ///   point of the setting — a plain shell whose program ignores the button
    ///   still wants the click sent to it (e.g. an app that reads the raw
    ///   sequence), and without it the click would open a menu instead.
    public static func ownsRightClick(
        programReportsMouse: Bool,
        rightClickPassthrough: Bool = false
    ) -> Bool {
        programReportsMouse || rightClickPassthrough
    }

    /// True when a right-click should raise the pane menu.
    public static func shouldShowPaneMenu(
        programReportsMouse: Bool,
        rightClickPassthrough: Bool = false
    ) -> Bool {
        !ownsRightClick(
            programReportsMouse: programReportsMouse,
            rightClickPassthrough: rightClickPassthrough
        )
    }

    /// The `right_click` value that would produce `passthrough`.
    ///
    /// Both the menu item's label and the `pane.input.set` body read this, so the
    /// two cannot disagree about which way round the toggle is.
    public static func target(for passthrough: Bool) -> RightClickTarget {
        passthrough ? .pane : .herdr
    }

    /// Whether a right-button release belongs to a menu this app just raised.
    ///
    /// The pane menu cannot open inside the `rightMouseDown` handler — a menu runs
    /// a modal event loop, and starting one mid-dispatch wedges the app — so it
    /// opens on the next runloop turn. By then the matching `rightMouseUp` has
    /// already been dispatched. AppKit's menu tracking reads the button as
    /// released and dismisses the menu the moment it appears, so the click looks
    /// like it did nothing.
    ///
    /// The press therefore has to claim its own release. This is a separate rule
    /// from `shouldShowPaneMenu` because it has to answer for the *release*: a
    /// program that owns the right button still gets its own up events, and eating
    /// those would break the TUI this routing exists to protect.
    public static func consumesRightUp(menuRaisedForPane: String?) -> Bool {
        menuRaisedForPane != nil
    }
}
