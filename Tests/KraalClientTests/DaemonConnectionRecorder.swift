// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  DaemonConnectionRecorder.swift
//  KraalClientTests
//
//  A `DaemonConnection` that records instead of sending.
//
//  This is the piece that was missing for every "did we send the right thing" test in
//  `KraalUI`. Without it a store test could only observe a `nil` connection, so the
//  behaviours that matter most on the send path were unassertable:
//
//  * a window drag emits a resize per frame, and only the **last** grid may be sent
//    (the intermediate ones would let the daemon render a size the window already left);
//  * a paste must travel as `.paste`, not as keystrokes, or a program with bracketed
//    paste disabled sees every newline as Enter;
//  * `call` retries a **busy** refusal and gives up on anything else — the retry count
//    is invisible from the store.
//
//  Two simplifications, both deliberate:
//
//  * `request` answers with an empty JSON object and an optional scripted error, rather
//    than decoding a real reply. The store discards the body on every path that is
//    tested here; a fake reply body would only add a decoder to the test.
//  * `sendResize` does **not** dedupe like the real actor does. The real one returns
//    early when the size is unchanged, so a test asserting "only one resize was sent"
//    would pass against the fake and fail in production for a different reason. The
//    recorder keeps every call, and the tests assert on deduplication at the store,
//    where it actually happens.

import Foundation

@testable import KraalClient
@testable import KraalProtocol

/// Records what a `DaemonConnection` received.
@MainActor
final class DaemonConnectionRecorder: DaemonConnection, @unchecked Sendable {
    /// Requests the store made, in order.
    private(set) var requests: [(method: String, params: [String: Any])] = []
    /// Every resize the store asked for, in order.
    private(set) var resizes: [ClientSurfaceSize] = []
    /// Pane input batches, in order.
    private(set) var paneInputs: [(paneId: String, events: [ClientPaneInputEvent])] = []
    /// Popup input batches, in order.
    private(set) var popupInputs: [(terminalId: String, events: [ClientPaneInputEvent])] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var abortCount = 0

    /// What `currentBootId` answers. `nil` models "handshake has not finished".
    var bootId: String? = "boot"

    /// Errors to throw from successive `request` calls, consumed in order.
    ///
    /// A refusal is a normal outcome here, not a failure: the daemon answers in band,
    /// so the store sees a thrown `BridgeError.daemon` and decides whether to retry.
    var scriptedErrors: [Error] = []

    var currentBootId: String? { get async { bootId } }

    func start() async throws { startCount += 1 }
    func stop() async { stopCount += 1 }
    nonisolated func abort() { Task { @MainActor in abortCount += 1 } }

    func sendResize(to size: ClientSurfaceSize) async throws {
        resizes.append(size)
    }

    func sendPaneInput(_ paneId: String, events: [ClientPaneInputEvent]) async throws {
        paneInputs.append((paneId, events))
    }

    func sendPopupInput(_ terminalId: String, events: [ClientPaneInputEvent]) async throws {
        popupInputs.append((terminalId, events))
    }

    func request(_ method: String, params: [String: Any]) async throws -> Data {
        requests.append((method, params))
        if !scriptedErrors.isEmpty {
            throw scriptedErrors.removeFirst()
        }
        return Data("{}".utf8)
    }

    // MARK: - Helpers

    /// The methods requested, in order. The usual assertion shape.
    var methods: [String] { requests.map(\.method) }

    /// The params of the last request for `method`, if any.
    func lastParams(of method: String) -> [String: Any]? {
        requests.last { $0.method == method }?.params
    }
}

/// A refusal the daemon sends in band.
///
/// `BridgeError.daemon` rather than a socket error, because that is what actually
/// arrives: a complete, valid frame whose payload says `{"error":{"code":...}}`.
enum ScriptedRefusal {
    static func busy() -> Error {
        BridgeError.daemon(method: "x", code: "endpoint_busy", message: "busy")
    }

    static func code(_ code: String) -> Error {
        BridgeError.daemon(method: "x", code: code, message: "refused")
    }
}
