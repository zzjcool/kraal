// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Issue #94: fast scrolling stuttered, and the viewport jumped backwards
// mid-gesture. Two causes, both from treating a wheel gesture as a sequence of
// independent commands:
//
//  * one `pane.scroll` request per event, against a connection that carries one
//    command at a time — measured 281 `gave up` refusals against 791 successes;
//  * each request's absolute target computed from the same stale snapshot, so they
//    overwrote each other — measured offsets 120 → 110 → 115 → 106 → 121.
//
// The queue under test coalesces a burst into one request per in-flight window and
// carries the *latest* target, which is the only value that is not stale.

import Testing

@testable import KraalUI

@MainActor
@Suite("pane scroll queue")
struct PaneScrollQueueTests {
    /// Records every request the queue makes.
    ///
    /// `@MainActor` like the queue itself: `PaneScrollQueue.init(send:)` is
    /// main-actor isolated, so the recording closure runs there too and needs no
    /// locking.
    @MainActor
    final class Recorder {
        var sent: [(paneId: String, offset: UInt64)] = []

        func makeQueue() -> PaneScrollQueue {
            PaneScrollQueue { [weak self] paneId, offset in
                guard let self else { return }
                self.sent.append((paneId, offset))
            }
        }
    }

    /// Spins the main actor until `condition` holds, or fails after a bound.
    ///
    /// Coalescing is inherently asynchronous — the queue sends on a task and may
    /// send again when the target moved meanwhile — and counting `Task.yield()`
    /// calls is how the first version of these tests got it wrong. Waiting on a
    /// condition says what the test means.
    @MainActor
    func settle(until condition: () -> Bool, turns: Int = 200) async {
        for _ in 0..<turns {
            if condition() { return }
            await Task.yield()
        }
    }

    @Test("one wheel notch sends one request")
    func singleNotch() async {
        let recorder = Recorder()
        let queue = recorder.makeQueue()
        queue.scroll(paneId: "w1:p1", lines: 3, current: 100, maxOffset: 500)
        await settle(until: { !recorder.sent.isEmpty })
        #expect(recorder.sent.count == 1)
        #expect(recorder.sent.first?.offset == 103)
    }

    @Test("a burst coalesces instead of flooding the connection")
    func burstCoalesces() async {
        let recorder = Recorder()
        let queue = recorder.makeQueue()
        // Ten notches in the same turn — what a trackpad produces per frame.
        for _ in 0..<10 {
            queue.scroll(paneId: "w1:p1", lines: 2, current: 100, maxOffset: 500)
        }
        await settle(until: { recorder.sent.last?.offset == 120 })
        // The claim is not "exactly one" — the queue may send a second time for
        // movement that arrived while the first was in flight — but it must be far
        // fewer than the ten events, and the *last* offset must be the total.
        let sentCount = recorder.sent.count
        let landed = recorder.sent.last?.offset
        #expect(sentCount < 10)
        #expect(sentCount >= 1)
        #expect(landed == 120)
    }

    @Test("the target is tracked by the queue, not read from the stale snapshot")
    func staleSnapshotDoesNotRewind() async {
        let recorder = Recorder()
        let queue = recorder.makeQueue()
        // The snapshot never advances: this is the bug's precondition. Every event
        // is told `current: 100` while the queue has already asked for more.
        queue.scroll(paneId: "w1:p1", lines: 5, current: 100, maxOffset: 500)
        await settle(until: { !recorder.sent.isEmpty })
        queue.scroll(paneId: "w1:p1", lines: 5, current: 100, maxOffset: 500)
        await settle(until: { recorder.sent.last?.offset == 110 })
        let offsets = recorder.sent.map(\.offset)
        // Monotonic: never 110 then back to 105 because the snapshot said 100.
        #expect(offsets == offsets.sorted())
        #expect(offsets.last == 110)
    }

    @Test("movement clamps at the end of history and builds no debt")
    func clampsWithoutDebt() async {
        let recorder = Recorder()
        let queue = recorder.makeQueue()
        for _ in 0..<5 {
            queue.scroll(paneId: "w1:p1", lines: 10, current: 0, maxOffset: 12)
        }
        await settle(until: { recorder.sent.last?.offset == 12 })
        #expect(recorder.sent.last?.offset == 12)
        // Scrolling back down from the top must respond immediately, not spend the
        // first few notches repaying movement that never happened.
        queue.scroll(paneId: "w1:p1", lines: -1, current: 0, maxOffset: 12)
        await settle(until: { recorder.sent.last?.offset == 11 })
        #expect(recorder.sent.last?.offset == 11)
    }

    @Test("two panes keep separate streams")
    func panesAreIndependent() async {
        let recorder = Recorder()
        let queue = recorder.makeQueue()
        queue.scroll(paneId: "w1:p1", lines: 4, current: 0, maxOffset: 100)
        queue.scroll(paneId: "w1:p2", lines: -4, current: 50, maxOffset: 100)
        await settle(until: { recorder.sent.count >= 2 })
        let byPane = Dictionary(
            recorder.sent.map { ($0.paneId, $0.offset) }, uniquingKeysWith: { _, last in last }
        )
        #expect(byPane["w1:p1"] == 4)
        #expect(byPane["w1:p2"] == 46)
    }

    @Test("a pane with no history sends nothing")
    func noHistorySendsNothing() async {
        let recorder = Recorder()
        let queue = recorder.makeQueue()
        queue.scroll(paneId: "w1:p1", lines: 5, current: 0, maxOffset: 0)
        await settle(until: { false }, turns: 12)
        #expect(recorder.sent.isEmpty)
    }

    @Test("the queue can be reset when a machine is switched away")
    func resetForgets() async {
        let recorder = Recorder()
        let queue = recorder.makeQueue()
        queue.scroll(paneId: "w1:p1", lines: 5, current: 100, maxOffset: 500)
        await settle(until: { recorder.sent.first?.offset == 105 })
        #expect(recorder.sent.first?.offset == 105)
        queue.reset(paneId: "w1:p1")
        #expect(queue.target(for: "w1:p1") == nil)
        // After a reset the next gesture seeds from the snapshot again, which is
        // right: the pane may be a different machine now.
        queue.scroll(paneId: "w1:p1", lines: 1, current: 7, maxOffset: 500)
        await settle(until: { recorder.sent.last?.offset == 8 })
        #expect(recorder.sent.last?.offset == 8)
    }
}
