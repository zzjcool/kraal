// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Focus bookkeeping for the input path (issue #55).
//
// `KraalMacMain`'s input callback sends the keystroke and then asks the daemon to
// focus the pane it went to. That second request had no "already focused" check,
// so every key posted one: measured 0.036 ms for input alone against 0.248 ms for
// input plus focus, and the two compete for a single connection.
//
// The obvious fix — compare against `snapshot.focusedPaneId` — is wrong, and the
// issue says why: the call goes out on a `Task`, so the snapshot has not moved by
// the time the check would run. Comparing against it skips the *first* focus too,
// leaving the daemon with no focus at all. That is worse than the waste.
//
// So the belief is local and confirmed: a pane counts as focused only after a call
// succeeds, and the belief is dropped whenever the daemon's own answer could have
// overridden it (a snapshot naming another pane, a reconnect, a workspace switch).
// Getting this backwards is silent — the client would keep typing into a pane the
// daemon does not consider focused — which is why every invalidation path has a
// test.

import Foundation

/// Remembers which pane this client has successfully focused, so repeated input
/// for the same pane does not re-send a request per keystroke.
///
/// `@MainActor` because it is driven from the store's main-actor input path; the
/// in-flight set exists for the same reason, since awaiting the send lets other
/// keystrokes arrive before the first one is confirmed.
@MainActor
public final class FocusConfirmation {
    /// Sends the request and reports whether the daemon accepted it. Returning
    /// `false` means "not confirmed", so the next attempt sends again.
    public typealias Send = (String) async -> Bool

    private let send: Send
    /// The pane this client has confirmed. `nil` means "unknown", never "none".
    private var confirmed: String?
    /// Panes with a request in flight, so a burst collapses into one.
    private var inFlight: Set<String> = []

    public init(send: @escaping Send) {
        self.send = send
    }

    /// Focuses `paneId`, unless it is already confirmed or already being asked for.
    public func focus(paneId: String) async {
        if confirmed == paneId { return }
        if inFlight.contains(paneId) { return }
        inFlight.insert(paneId)
        defer { inFlight.remove(paneId) }

        let accepted = await send(paneId)
        // Only a confirmed focus may suppress the next request. Recording a refusal
        // would mean never retrying, which loses focus entirely instead of
        // occasionally re-sending it.
        if accepted {
            confirmed = paneId
        } else if confirmed == paneId {
            // A later refusal for the pane we believed in: the belief is wrong.
            confirmed = nil
        }
    }

    /// Drops the belief, so the next request goes out.
    ///
    /// Called for anything that changes focus behind this client's back: a
    /// reconnect, a workspace or tab switch, a pane closing.
    public func invalidate() {
        confirmed = nil
    }

    /// Reconciles the belief with a snapshot.
    ///
    /// A snapshot naming a different pane (or naming none) means the daemon's focus
    /// is not what this client believed. Silence is not news: while a request is in
    /// flight the snapshot still shows the old pane, and invalidating on that would
    /// re-send for every keystroke — the behaviour being removed.
    public func observe(focusedPaneId: String?) {
        guard let confirmed else { return }
        if focusedPaneId != confirmed {
            self.confirmed = nil
        }
    }
}
