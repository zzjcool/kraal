// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Sending wheel gestures to the daemon (issue #94).
//
// A trackpad emits one `scrollWheel` event per frame — dozens per second during a
// flick — and each of them used to become its own `pane.scroll` request. Two things
// went wrong with that, and they compounded:
//
//  1. **The requests raced.** One connection carries one command at a time, so the
//     second request in a tick is refused with `endpoint_busy`. `AppStore.call`
//     retries four times at 20/40/60 ms, which is right for a command the user just
//     triggered and wrong for a stream: the queue grew faster than it drained.
//     Measured on a real window: **281 refusals that ended in `gave up` against 791
//     successes** — roughly one wheel notch in four was dropped, which is the
//     stutter that was reported.
//
//  2. **Each request carried a stale target.** `pane.scroll` takes an *absolute*
//     `offset_from_bottom`, and the target was computed from the offset in the last
//     snapshot the daemon had sent. During a flick the snapshot is always behind, so
//     several in-flight requests all computed from the same old value and then
//     overwrote each other. The daemon's offset visibly jumped around — measured
//     `120 → 110 → 115 → 106 → 121` over one gesture — and the final resting
//     position was whichever request happened to land last.
//
// The fix is to stop treating a wheel gesture as a sequence of independent commands.
// It is a *velocity*, and the only thing worth telling the daemon is where the
// viewport should end up. So the pending movement for a pane is accumulated here,
// one request at a time is in flight, and the request that finally goes out carries
// the latest total — not a value read a moment ago.
//
// The accumulator is deliberately **not** the one in `MouseCoordinateMapper`: that
// one converts sub-line trackpad deltas into whole lines, and it stays where it is.
// This one is about time, not distance.

import Foundation
import KraalProtocol

/// Serialises and coalesces `pane.scroll` requests, one stream per pane.
///
/// Owned by `AppStore`; the wheel path enqueues and never awaits.
@MainActor
public final class PaneScrollQueue {
    /// What one pane still owes the daemon.
    private struct Pending {
        /// Lines accumulated but not yet sent. Positive scrolls up (into history).
        var lines: Int = 0
        /// The offset this queue last asked for, or nil when it has not asked yet.
        ///
        /// Kept because `pane.scroll` is absolute: the next request is computed from
        /// where *we* last put the viewport, not from a snapshot that lags behind.
        var target: UInt64?
        /// True while a request for this pane is in flight.
        var sending = false
    }

    private var pending: [String: Pending] = [:]
    /// Where this queue last put each pane's viewport, kept **after** `pending` is
    /// emptied.
    ///
    /// Without it the queue forgot its position the moment a gesture settled, and
    /// the next gesture re-seeded from the snapshot — which during continuous
    /// scrolling is the value from before the previous gesture, so the viewport
    /// jumped back. That is the same stale-snapshot bug this type exists to fix,
    /// just at gesture boundaries instead of inside one.
    private var lastSent: [String: UInt64] = [:]
    private let send: @MainActor (String, UInt64) async -> Void

    /// `send` performs one `pane.scroll`. Injected so tests can watch the sequence
    /// without a daemon.
    public init(send: @escaping @MainActor (String, UInt64) async -> Void) {
        self.send = send
    }

    /// Records `lines` of movement for `paneId` and starts a send if idle.
    ///
    /// Called once per wheel event. Never blocks and never discards movement: a
    /// burst of events becomes one request carrying their sum.
    public func scroll(paneId: String, lines: Int, current: UInt64, maxOffset: UInt64) {
        guard lines != 0, maxOffset > 0 else { return }
        var state = pending[paneId] ?? Pending()
        // Seed from what this queue last sent, falling back to the snapshot only the
        // very first time a pane is scrolled. The snapshot lags a gesture by design,
        // so using it at a gesture boundary rewinds the viewport.
        if state.target == nil {
            state.target = lastSent[paneId] ?? current
        }
        let from = state.target ?? current
        let target = PaneMouse.ScrollTarget.offset(
            current: from,
            lines: lines + state.lines,
            maxOffset: maxOffset
        )
        // Coalesced, so there is no "remaining lines" to carry: the next request is
        // computed from `target`, which is absolute. Movement that clamps away
        // (already against the end of the history) simply leaves `target` where it
        // was, so holding the wheel there builds up no debt to fire later.
        state.lines = 0
        state.target = target
        pending[paneId] = state
        guard !state.sending else { return }
        start(paneId)
    }

    /// Sends whatever `paneId` owes, then repeats until nothing is left.
    ///
    /// The loop is what makes coalescing real rather than nominal: a trackpad
    /// delivers a whole gesture within a few runloop turns, so by the time the
    /// first send returns the target has usually moved. Repeating until it stops
    /// moving turns ten notches into one or two requests instead of ten.
    ///
    /// `sending` is the single-flight flag. Without it the ten events of a burst
    /// each start their own task, which is exactly the flood this type exists to
    /// prevent.
    private func start(_ paneId: String) {
        guard let state = pending[paneId], !state.sending, let target = state.target else {
            return
        }
        pending[paneId]?.sending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drain(paneId, lastSent: target)
        }
    }

    /// One send, then decide whether another is owed.
    private func drain(_ paneId: String, lastSent sent: UInt64) async {
        await send(paneId, sent)
        lastSent[paneId] = sent
        guard var after = pending[paneId] else { return }
        after.sending = false
        // Movement that arrived while this request was in flight is already folded
        // into `target`; sending it now keeps the viewport from lagging a gesture.
        if let next = after.target, next != sent {
            after.sending = true
            pending[paneId] = after
            await drain(paneId, lastSent: next)
            return
        }
        pending.removeValue(forKey: paneId)
    }

    /// The offset this queue has asked for, for tests and for the wheel path's
    /// accumulator reset.
    public func target(for paneId: String) -> UInt64? {
        pending[paneId]?.target
    }

    /// Forgets a pane's stream, e.g. when its machine is switched away.
    public func reset(paneId: String) {
        pending.removeValue(forKey: paneId)
        lastSent.removeValue(forKey: paneId)
    }

    public func resetAll() {
        pending.removeAll()
        lastSent.removeAll()
    }
}
