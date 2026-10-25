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
    /// - `rightClickPassthrough`: the user explicitly set this pane's
    ///   `right_click = "pane"` (`pane.input.set`, persisted by the daemon and
    ///   reported back as `right_click_passthrough` in the snapshot). This is the
    ///   **only** thing that hands the button to the program. It works whether or
    ///   not the program reports the mouse: a plain shell that ignores the button
    ///   may still want the sequence, and a TUI that wants its own menu says so
    ///   here.
    /// - `programReportsMouse`: **not** a reason on its own. Enabling mouse
    ///   reporting means the program wants the *pointer* — clicks, drags, wheel —
    ///   which is what makes a TUI usable at all. Upstream treats the right button
    ///   separately, and the pane menu stays reachable by default
    ///   (`src/client/shell/mouse.rs:1805-1807`):
    ///
    ///   ```rust
    ///   if hit.mouse_reporting
    ///       && (pane_owns_right_click || configured_modifiers.is_some())
    ///   ```
    ///
    ///   Treating "reports the mouse" as "owns the right button" made every TUI
    ///   pane unreachable: the menu never opened there, and there was no way for
    ///   the user to get it back either, because the same flag also raised the
    ///   bar for `right_click = "herdr"`. Measured: right-click in a TUI pane
    ///   logged no menu line at all, while a plain shell in the same session did.
    ///
    /// - Note: upstream gates this on `hit.mouse_reporting` too
    ///   (`mouse.rs:1806`), so a pane whose program ignores the mouse but whose
    ///   `right_click` is `"pane"` gets the *menu* there and the *click* here. That
    ///   difference is deliberate: the setting says "send this pane's right button
    ///   to the program", and honouring it for a program that does read the raw
    ///   sequence is the only way the setting can do what it says. Upstream's own
    ///   docs describe `right_click = "pane"` as handing the click over
    ///   unconditionally. Not verified against a real TUI that reads raw sequences
    ///   with reporting off — no such program was available.
    ///
    /// - Note: upstream also requires `mouse.modifiers.is_empty()` and supports a
    ///   `right_click_passthrough_modifier` config. Neither is implemented here;
    ///   Kraal has no equivalent setting, so a right-click that carries a modifier
    ///   is treated like any other. Recorded as a known gap rather than guessed at.
    public static func ownsRightClick(rightClickPassthrough: Bool = false) -> Bool {
        rightClickPassthrough
    }

    /// True when a right-click should raise the pane menu.
    public static func shouldShowPaneMenu(rightClickPassthrough: Bool = false) -> Bool {
        !ownsRightClick(rightClickPassthrough: rightClickPassthrough)
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
