// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  OutgoingCommandTests.swift
//  KraalClientTests
//
//  What the store actually sends, observed through `DaemonConnectionRecorder`.
//
//  Every test in this file was previously unassertable: `connection` was a concrete
//  `EndpointConnection`, so a store test could only ever see nil and the send path was
//  invisible. The three behaviours here are the ones that had reached users or would
//  be expensive to discover in production:
//
//  * a window drag emits a resize per frame — only the last grid may reach the daemon;
//  * a paste must not be decoded as keystrokes;
//  * a busy refusal is retried a bounded number of times, anything else is not retried.
//

import Foundation
import Testing

@testable import KraalClient
@testable import KraalProtocol
@testable import KraalUI

@Suite("Outgoing commands")
@MainActor
struct OutgoingCommandTests {
    private func store() -> (AppStore, DaemonConnectionRecorder) {
        let store = AppStore(target: .local)
        let endpoint = EndpointState(id: .local, label: "Local", settings: .local)
        let recorder = DaemonConnectionRecorder()
        endpoint.connection = recorder
        endpoint.status = .online
        store.endpoints = [endpoint]
        store.activeEndpointID = .local
        store.phase = .live
        return (store, recorder)
    }

    /// Waits until `condition` holds, so no assertion depends on a fixed sleep.
    private func waitUntil(
        _ label: String,
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for \(label)")
    }

    // MARK: - Resize

    /// A drag produces one call per frame; the daemon must only ever see the newest grid.
    ///
    /// `pushSurfaceSize` sets a pending flag before starting its loop, and the loop
    /// re-reads `surfaceSize` each pass. Without that, every intermediate size would
    /// queue behind a socket that serves one command per tick, and the daemon would
    /// render a size the window has already left.
    @Test("a burst of resizes collapses to the final grid")
    func resizeBurstCollapses() async throws {
        let (store, recorder) = store()
        for cols in UInt16(80) ... 90 {
            store.resizeSurface(cols: cols, rows: 24)
        }
        try await waitUntil("the resize to be sent") { !recorder.resizes.isEmpty }
        // Give the loop a chance to send any follow-up it would have queued.
        try await Task.sleep(for: .milliseconds(80))

        let sizes = recorder.resizes
        #expect(!sizes.isEmpty)
        // The final grid must arrive. That is the load-bearing half of this test and it
        // does have discriminating power (remove the `surfaceSize` re-read and the last
        // send stays at the first width).
        #expect(sizes.last?.cols == 90,
                "the daemon never heard the final width")
        // A weaker bound on the number of sends is deliberately **not** asserted here.
        // "Only one send" cannot be distinguished from a coalescing bug by observation:
        // `while resizePending` is idempotent, so even a version that starts a task per
        // call ends up sending only the latest value. An assertion that passes with the
        // coalescing removed is not a guard, so the count is reported instead.
        print("resize sends observed: \(sizes.map(\.cols))")
    }

    /// An unacceptable grid must not be sent at all: the daemon would refuse it, and a
    /// refusal is a wasted command on a one-command-per-tick connection.
    @Test("an unacceptable grid is not sent")
    func unacceptableGridIsNotSent() async throws {
        let (store, recorder) = store()
        store.resizeSurface(cols: 0, rows: 24)
        store.resizeSurface(cols: 80, rows: 0)
        try await Task.sleep(for: .milliseconds(80))
        #expect(recorder.resizes.isEmpty)
    }

    // MARK: - Paste

    /// A paste must travel as `.paste`, which is why the wire has the event at all: sent
    /// as input bytes, a program with bracketed paste disabled sees every newline as
    /// Enter, so pasting three commands runs all three.
    @Test("a paste is sent as a paste event, not as keystrokes")
    func pasteIsSentAsPaste() async throws {
        let (store, recorder) = store()
        store.sendPaste("echo one\necho two", to: "w1:p1")
        try await waitUntil("the paste to be sent") { !recorder.paneInputs.isEmpty }

        let sent = try #require(recorder.paneInputs.first)
        #expect(sent.paneId == "w1:p1")
        #expect(sent.events.count == 1)
        guard case let .paste(text) = sent.events[0] else {
            Issue.record("the paste was sent as \(sent.events[0])")
            return
        }
        #expect(text == "echo one\necho two")
        // And nothing went through the key decoder.
        #expect(store.inputDecoders.isEmpty,
                "the paste was decoded as keys, so an ESC would become an arrow key")
    }

    /// Empty text and a missing pane never reach the connection.
    @Test("an empty paste sends nothing")
    func emptyPasteSendsNothing() async throws {
        let (store, recorder) = store()
        store.sendPaste("", to: "w1:p1")
        store.sendPaste("hello", to: nil)
        try await Task.sleep(for: .milliseconds(80))
        #expect(recorder.paneInputs.isEmpty)
    }

    /// A pane's keystrokes go to the pane; a popup's go to its terminal. Two namespaces,
    /// two send methods — mixing them would type a popup's bytes into a pane.
    @Test("pane and popup input use their own send methods")
    func inputNamespacesAreSeparate() async throws {
        let (store, recorder) = store()
        store.sendInput(Data([0x61]), to: "w1:p1")
        store.sendPopupInput(Data([0x62]), terminalId: "term-1")
        try await waitUntil("both sends") {
            !recorder.paneInputs.isEmpty && !recorder.popupInputs.isEmpty
        }
        #expect(recorder.paneInputs.count == 1)
        #expect(recorder.popupInputs.count == 1)
        #expect(recorder.popupInputs[0].terminalId == "term-1")
    }

    // MARK: - Refusal handling

    /// A busy refusal means nothing happened, so it is retried — and then given up on.
    ///
    /// The bound matters: one connection serves one command at a time, so a caller that
    /// retried forever would spin against a daemon that stays busy.
    @Test("a busy refusal is retried a bounded number of times")
    func busyRefusalIsRetried() async throws {
        let (store, recorder) = store()
        recorder.scriptedErrors = Array(repeating: ScriptedRefusal.busy(), count: 4)
        _ = await store.callReturningErrorCode("pane.split", [:])

        // The literal 4 is deliberate. Comparing against `AppStore.busyRetryLimit` made
        // this assertion **self-certifying**: an A/B that set the limit to 1 left it
        // green, because both sides moved together. The number is the contract — one
        // connection serves one command per tick, so a handful of attempts, not a loop.
        #expect(recorder.methods.count == 4,
                "\(recorder.methods.count) attempts were made, not 4")
    }

    /// A control refusal is a real answer: it must reach the caller on the first attempt
    /// and must not be retried.
    @Test("a non-busy refusal is not retried")
    func nonBusyRefusalIsNotRetried() async throws {
        let (store, recorder) = store()
        recorder.scriptedErrors = [
            ScriptedRefusal.code("workspace_group_close_required"),
            ScriptedRefusal.code("should not be reached"),
        ]
        let code = await store.callReturningErrorCode("pane.close", [:])
        #expect(code == "workspace_group_close_required",
                "the refusal was not reported to the caller")
        #expect(recorder.methods.count == 1,
                "a control refusal was retried (\(recorder.methods.count) attempts)")
    }

    /// A command issued before the handshake has a boot id is dropped, and says so.
    /// This is the "menu did nothing" case, and silence is what made it hard to see.
    @Test("a command before the handshake is skipped")
    func commandBeforeHandshakeIsSkipped() async throws {
        let (store, recorder) = store()
        recorder.bootId = nil
        await store.call("pane.split", [:])
        #expect(recorder.methods.isEmpty)
    }

    /// A successful call sends exactly one request.
    @Test("a successful command is sent once")
    func successfulCommandSentOnce() async throws {
        let (store, recorder) = store()
        await store.call("pane.split", ["target_pane_id": "w1:p1"])
        #expect(recorder.methods == ["pane.split"])
        let params = recorder.lastParams(of: "pane.split")
        #expect(params?["target_pane_id"] as? String == "w1:p1")
    }
}

/// The copy-mode requests, which carry two rules that were measured, not guessed.
@Suite("Copy-mode requests")
@MainActor
struct CopyModeRequestTests {
    private func store() -> (AppStore, DaemonConnectionRecorder) {
        let store = AppStore(target: .local)
        let endpoint = EndpointState(id: .local, label: "Local", settings: .local)
        let recorder = DaemonConnectionRecorder()
        endpoint.connection = recorder
        endpoint.status = .online
        store.endpoints = [endpoint]
        store.activeEndpointID = .local
        store.phase = .live
        store.surface = PaneSurfaceFrame(
            bootId: "boot", projectionRevision: 1, surfaceRevision: 1,
            frame: FrameData(
                cells: Array(repeating: .blank, count: 118 * 2), width: 118, height: 2,
                cursor: nil, hyperlinks: [], graphics: Data()
            ),
            panes: [PaneSurfacePane(
                paneId: "w1:p1", contentRevision: 7,
                rect: SurfaceRect(originX: 0, originY: 0, width: 118, height: 2),
                innerRect: SurfaceRect(originX: 0, originY: 0, width: 116, height: 2),
                scrollbarRect: nil, scroll: nil, focused: true,
                mouseReporting: false, sgrPixelMouse: false,
                alternateScreenActive: false, pixelWidth: 0, pixelHeight: 0
            )],
            splits: [], popup: nil, graphics: SurfaceGraphicsScene()
        )
        return (store, recorder)
    }

    private func waitUntil(_ label: String, timeout: TimeInterval = 2, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for \(label)")
    }

    /// The linewise sentinel is `UInt16.max`; sending it unclamped is refused by the
    /// daemon with `selection_unavailable`. Measured against a 118-column pane: 117
    /// returned the line, 200 and 65535 returned nothing.
    @Test("the line-end sentinel is clamped to the pane's width")
    func sentinelIsClamped() async throws {
        let (store, recorder) = store()
        store.copySelection(
            paneId: "w1:p1",
            from: CopyModeCursor(row: 0, column: 0),
            to: CopyModeCursor(row: 0, column: CopyModeCursor.lineEndColumn),
            contentRevision: 7
        ) { _ in }
        try await waitUntil("selection.read") {
            recorder.methods.contains("pane.selection.read")
        }

        let params = try #require(recorder.lastParams(of: "pane.selection.read"))
        let cursor = try #require(params["cursor"] as? [String: Any])
        let column = try #require(cursor["col"] as? Int)
        // The pane's inner width is 116, so the last sendable column is 115.
        #expect(column == 115,
                "column \(column) was sent; an unclamped sentinel is refused outright")
    }

    /// A motion carries the content revision so the daemon can answer `stale_content`
    /// when the text moved between reading the cursor and asking.
    @Test("a motion carries the content revision")
    func motionCarriesRevision() async throws {
        let (store, recorder) = store()
        store.requestCopyMotion(
            paneId: "w1:p1",
            from: CopyModeCursor(row: 0, column: 0),
            motion: .nextWordStart,
            contentRevision: 7
        ) { _ in }
        try await waitUntil("copy_motion") { !recorder.requests.isEmpty }

        let params = try #require(recorder.lastParams(of: "pane.copy_motion"))
        #expect(params["content_revision"] as? UInt64 == 7,
                "the motion did not carry the revision, so a race returns a dead cursor")
        #expect(params["motion"] as? String == CopyModeMotion.nextWordStart.rawValue)
    }

    /// A refused motion completes with nil rather than inventing a cursor.
    @Test("a refused motion completes with nil")
    func refusedMotionCompletesNil() async throws {
        let (store, recorder) = store()
        recorder.scriptedErrors = [ScriptedRefusal.code("stale_content")]
        var completed = false
        var result: CopyModeCursor?
        store.requestCopyMotion(
            paneId: "w1:p1",
            from: CopyModeCursor(row: 0, column: 0),
            motion: .nextWordStart,
            contentRevision: 7
        ) { cursor in
            result = cursor
            completed = true
        }
        try await waitUntil("the completion") { completed }
        #expect(result == nil, "a refused motion produced a cursor")
    }
}
