// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Focus, split out of `AppStore.swift` to keep that type under SwiftLint's
// type-length limit. Small enough to look like it belongs with the other actions,
// but it is the one action on the per-keystroke path, so it carries its own
// reasoning (issue #55).

import Foundation

extension AppStore {
    /// Focuses a pane, unless this client already has it confirmed.
    ///
    /// The input path calls this after every keystroke, so an unconditional request
    /// cost 7x the socket time of the keystroke itself (issue #55). The check lives
    /// in `focusConfirmation` because the obvious version — compare against
    /// `snapshot.focusedPaneId` — is wrong: the call is asynchronous, so the
    /// snapshot still shows the previous pane and the *first* focus would be
    /// skipped too, leaving the daemon with nothing focused.
    public func focus(paneId: String) {
        Task { await focusConfirmation.focus(paneId: paneId) }
    }

    /// Sends `pane.focus` and reports whether the daemon accepted it.
    ///
    /// Used by `focusConfirmation`; returns `false` for a refusal so the belief is
    /// not recorded and the next keystroke retries. A refusal must not be cached —
    /// that would leave the pane permanently unfocused, which is worse than the
    /// redundant request this replaced.
    func sendPaneFocus(_ paneId: String) async -> Bool {
        // A skipped call is **not** an accepted one.
        //
        // `callReturningErrorCode` returns nil both for "the daemon accepted it" and
        // for "there was no boot id yet, so nothing was sent", and it has to: from a
        // close flow's point of view a skipped close is not a failure to report. Here
        // the two cases are opposite. Reporting success for a skipped focus records the
        // belief, and `FocusConfirmation` then *skips* the request once the connection
        // is up — leaving the daemon with nothing focused until the user switches pane
        // by hand. That is the exact failure the belief logic exists to prevent.
        guard connection != nil, await connection?.currentBootId != nil else {
            return false
        }
        return await callReturningErrorCode("pane.focus", ["pane_id": paneId]) == nil
    }
}
