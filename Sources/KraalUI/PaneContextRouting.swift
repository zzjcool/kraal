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
    /// True when the program inside the pane owns the right button, so the pane
    /// menu must stay out of the way.
    public static func ownsRightClick(programReportsMouse: Bool) -> Bool {
        // A pane that enabled mouse reporting is handling buttons itself. TUIs
        // (editors, pagers, tmux) do exactly this, and they use the right button
        // for their own menus; a Kraal menu on top of that would be unreachable
        // and would eat the click.
        programReportsMouse
    }

    /// True when a right-click should raise the pane menu.
    public static func shouldShowPaneMenu(programReportsMouse: Bool) -> Bool {
        !ownsRightClick(programReportsMouse: programReportsMouse)
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
