// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  WindowTitleTemplate.swift
//  Kraal
//
//  Turns the daemon-pushed `WindowTitle` into the title this window shows.
//
//  Why a template and not just "set the title to whatever arrived": Kraal is a
//  client, so the daemon's title describes *a pane on some machine*, while the
//  window belongs to the user's desktop. Upstream (`app/window_title.rs`) renders
//  a configurable template server-side and pushes the result; we receive one
//  string and have no idea which part of it is the pane's shell title and which
//  part is the workspace name.
//
//  So the rule here is deliberately dumb and testable: the daemon's string is the
//  title, and this window's own session suffix is appended so two Kraal windows
//  (a dev session and the user's) are tellable apart in a window switcher. Doing
//  it in a pure function is what makes that rule assertable — `NSWindow.title`
//  itself is only observable through AppKit.
//

import Foundation

public enum WindowTitleTemplate {
    /// The title to show for a pane-reported title.
    ///
    /// - Parameters:
    ///   - reported: What the daemon sent, i.e. the pane's own `OSC 0`/`OSC 2`
    ///     title. `nil` or blank means "the pane has no title" — for example a
    ///     fresh shell that has not set one — and falls back to `fallback`.
    ///   - fallback: The name to use when nothing was reported (`Local`, a
    ///     machine label). Never empty in practice; treated as "Kraal" if it is.
    ///   - sessionSuffix: `DevSession.windowTitleSuffix`, appended verbatim.
    public static func title(
        reported: String?,
        fallback: String,
        sessionSuffix: String
    ) -> String {
        // A pane can set its title to a single space or to whitespace while a TUI
        // redraws. Blank is not a title: using it would blank the window for a
        // frame, which reads as a flicker.
        let trimmed = reported?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base: String
        if trimmed.isEmpty {
            let fallbackTrimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
            base = fallbackTrimmed.isEmpty ? "Kraal" : fallbackTrimmed
        } else {
            base = trimmed
        }
        return base + sessionSuffix
    }

    /// Whether a newly reported title should replace what is on screen.
    ///
    /// Only meaningful because panes re-send their title on every relevant
    /// redraw: assigning `NSWindow.title` unconditionally makes AppKit invalidate
    /// the titlebar on every frame. `nil` vs empty are the same thing here — both
    /// mean "no title" — so a switch between them must not count as a change.
    public static func isChange(from current: String?, to next: String?) -> Bool {
        let lhs = current?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rhs = next?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return lhs != rhs
    }
}
