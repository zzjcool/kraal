// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Issue #55: a `pane.focus` request per keystroke.
//
// `KraalMacMain`'s input callback sends the bytes and then calls
// `store.focus(paneId:)`, which had no "already focused" check, so every key
// posted a second request. Measured: 0.036 ms for input alone, 0.248 ms for input
// plus focus — 7x the socket cost per keystroke, and the two requests compete for
// one connection (a `pane.focus` rejected as `endpoint_busy` is retried, and a
// lost focus leaves the daemon disagreeing with the client about which pane is
// active).
//
// The trap the issue names: `snapshot.focusedPaneId` cannot be compared directly.
// The request goes out on a `Task`, so the snapshot has not moved when the check
// would run — comparing against it skips the *first* focus too, leaving the daemon
// with no focus at all, which is worse than the waste being fixed. So the guard
// is a locally confirmed pane, recorded only after a call succeeds and dropped
// whenever the daemon's own answer could have changed.

import Foundation
import Testing

@testable import KraalUI

@Suite("Focus is not re-sent for every keystroke", .serialized)
struct FocusCoalescingTests {
    /// Counts requests without a daemon, mirroring how `AppStore`'s own tests
    /// drive `call`.
    @MainActor
    final class FocusRecorder {
        private(set) var requests: [String] = []

        func record(_ paneId: String) {
            requests.append(paneId)
        }
    }

    @MainActor
    @Test("the first focus is sent, and typing into the same pane is not")
    func repeatedFocusIsSuppressed() async {
        let recorder = FocusRecorder()
        let tracker = FocusConfirmation(send: { paneId in
            recorder.record(paneId)
            return true
        })

        await tracker.focus(paneId: "w1:p1")
        await tracker.focus(paneId: "w1:p1")
        await tracker.focus(paneId: "w1:p1")

        #expect(recorder.requests == ["w1:p1"],
                "every keystroke sent its own pane.focus: \(recorder.requests)")
    }

    @MainActor
    @Test("focusing a different pane is sent immediately")
    func switchingPaneIsSent() async {
        let recorder = FocusRecorder()
        let tracker = FocusConfirmation(send: { paneId in
            recorder.record(paneId)
            return true
        })

        await tracker.focus(paneId: "w1:p1")
        await tracker.focus(paneId: "w1:p2")

        #expect(recorder.requests == ["w1:p1", "w1:p2"],
                "a real focus change must still reach the daemon: \(recorder.requests)")
    }

    @MainActor
    @Test("a refusal is not remembered as confirmed")
    func failedFocusIsRetried() async {
        // The guard must key on *confirmed* focus. If a failed call were recorded,
        // the next keystroke would skip the retry and the pane would never focus.
        let recorder = FocusRecorder()
        var attempts = 0
        let tracker = FocusConfirmation(send: { paneId in
            attempts += 1
            if attempts == 1 { return false }
            recorder.record(paneId)
            return true
        })

        await tracker.focus(paneId: "w1:p1")
        await tracker.focus(paneId: "w1:p1")

        #expect(attempts == 2, "a refused focus was treated as confirmed: \(attempts) attempts")
        #expect(recorder.requests == ["w1:p1"], "the retry must reach the daemon")
    }

    @MainActor
    @Test("invalidation makes the next focus send again")
    func invalidationForcesResend() async {
        // Anything that can change focus behind this client's back — a snapshot
        // reporting a different pane, a reconnect, a workspace switch — has to drop
        // the local belief, or the daemon and the client drift apart silently.
        let recorder = FocusRecorder()
        let tracker = FocusConfirmation(send: { paneId in
            recorder.record(paneId)
            return true
        })

        await tracker.focus(paneId: "w1:p1")
        tracker.invalidate()
        await tracker.focus(paneId: "w1:p1")

        #expect(recorder.requests == ["w1:p1", "w1:p1"],
                "focus was not re-sent after invalidation: \(recorder.requests)")
    }

    @MainActor
    @Test("a snapshot naming a different pane drops the belief")
    func snapshotDisagreementInvalidates() async {
        let recorder = FocusRecorder()
        let tracker = FocusConfirmation(send: { paneId in
            recorder.record(paneId)
            return true
        })

        await tracker.focus(paneId: "w1:p1")
        // The daemon says someone else is focused: this client's belief is stale,
        // so the next request for w1:p1 must go out.
        tracker.observe(focusedPaneId: "w1:p2")
        await tracker.focus(paneId: "w1:p1")

        #expect(recorder.requests == ["w1:p1", "w1:p1"],
                "a snapshot disagreeing with the local belief was ignored: \(recorder.requests)")
    }

    @MainActor
    @Test("a snapshot agreeing with the belief changes nothing")
    func snapshotAgreementKeepsBelief() async {
        let recorder = FocusRecorder()
        let tracker = FocusConfirmation(send: { paneId in
            recorder.record(paneId)
            return true
        })

        await tracker.focus(paneId: "w1:p1")
        tracker.observe(focusedPaneId: "w1:p1")
        await tracker.focus(paneId: "w1:p1")

        #expect(recorder.requests == ["w1:p1"],
                "an agreeing snapshot dropped the belief: \(recorder.requests)")
    }

    @MainActor
    @Test("an empty snapshot focus invalidates")
    func nilSnapshotFocusInvalidates() async {
        // `focusedPaneId` is nil while a session has no focus (before the first
        // frame, or after the focused pane closed). Treating nil as "no news" kept
        // a belief about a pane that no longer had focus.
        let recorder = FocusRecorder()
        let tracker = FocusConfirmation(send: { paneId in
            recorder.record(paneId)
            return true
        })

        await tracker.focus(paneId: "w1:p1")
        tracker.observe(focusedPaneId: nil)
        await tracker.focus(paneId: "w1:p1")

        #expect(recorder.requests == ["w1:p1", "w1:p1"],
                "nil focus did not invalidate: \(recorder.requests)")
    }

    @MainActor
    @Test("concurrent bursts for one pane send once")
    func concurrentBurstSendsOnce() async {
        // The input path hops to the main actor and awaits the call, so several
        // keystrokes can be in flight before the first confirmation lands. Without
        // in-flight coalescing each of them posts its own request — the same waste,
        // just under load instead of per keystroke.
        let recorder = FocusRecorder()
        let tracker = FocusConfirmation(send: { paneId in
            // Yield so the other tasks reach the guard while this one is pending.
            await Task.yield()
            recorder.record(paneId)
            return true
        })

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 5 {
                group.addTask { @MainActor in await tracker.focus(paneId: "w1:p1") }
            }
        }

        #expect(recorder.requests == ["w1:p1"],
                "a burst posted \(recorder.requests.count) requests for one pane")
    }
}
