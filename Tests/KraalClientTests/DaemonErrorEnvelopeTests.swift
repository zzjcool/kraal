// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Regression tests for refusals reported in band.
//
// The bug: right-clicking a pane and choosing Split Right did nothing — for the
// third time, from a third cause. The first two were the request body
// (`pane_id` vs `target_pane_id`) and the async focus race. This one is the
// reply: the daemon *refuses* a request by answering it with an error envelope,
// not by failing the transport. The frame arrives complete, the body is valid
// JSON, and the refusal lives inside it:
//
//     {"id":"kraal-4","error":{"code":"endpoint_busy",
//      "message":"this endpoint is still processing another command"}}
//
// Every caller only checked for a thrown error, so `call()` logged `ok`, no pane
// appeared, and the menu looked dead. The trigger was structural: `runCommand`
// fired `pane.focus` and then the real command in the same tick, and one
// connection serves one command at a time — so the command the user asked for
// was the one that got refused.
//
// Two rules come out of this and both are pinned below:
//   1. an `error` envelope must become a thrown error;
//   2. only `endpoint_busy` is worth resending, because it alone means the
//      command did not run.

import Foundation
import Testing

import KraalClient
@testable import KraalUI

@Suite("Daemon error envelopes")
struct DaemonErrorEnvelopeTests {
    /// The exact body the daemon sent when the split was dropped.
    @Test("an error envelope is thrown, not returned as a result")
    func errorEnvelopeThrows() {
        let body = Data("""
        {"id":"kraal-4","error":{"code":"endpoint_busy",\
        "message":"this endpoint is still processing another command"}}
        """.utf8)

        #expect(throws: (any Error).self) {
            try EndpointConnection.throwIfErrorEnvelope(body, method: "pane.split")
        }
    }

    /// The refusal detail has to survive into the error, or the log says "failed"
    /// without saying why.
    @Test("the refusal code and message are preserved")
    func refusalDetailSurvives() {
        let body = Data("""
        {"id":"x","error":{"code":"pane_not_found","message":"pane wS:p1 not found"}}
        """.utf8)

        do {
            try EndpointConnection.throwIfErrorEnvelope(body, method: "pane.split")
            Issue.record("expected the envelope to throw")
        } catch let BridgeError.daemon(method, code, message) {
            #expect(method == "pane.split")
            #expect(code == "pane_not_found")
            #expect(message == "pane wS:p1 not found")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    /// A normal result must pass through untouched. This is the case that worked
    /// all along, and breaking it would fail every command.
    @Test("a success envelope is not treated as an error")
    func successPassesThrough() throws {
        let body = Data("""
        {"id":"kraal-1","result":{"type":"pane_info","pane":{"pane_id":"wS:p5"}}}
        """.utf8)

        try EndpointConnection.throwIfErrorEnvelope(body, method: "pane.focus")
    }

    /// `reprojectSurface` and the handshake both produce empty or odd bodies.
    @Test("an empty body is not an error", arguments: ["", " ", "\n"])
    func emptyBodyIsFine(body: String) throws {
        try EndpointConnection.throwIfErrorEnvelope(Data(body.utf8), method: "client_shell.surface.set")
    }

    /// Anything that is not JSON must not crash the reader either — the frame
    /// layer already validated it, so this is only about not throwing nonsense.
    @Test("a non-JSON body is ignored")
    func nonJSONIsIgnored() throws {
        try EndpointConnection.throwIfErrorEnvelope(Data("not json".utf8), method: "pane.focus")
    }

    /// Only the \"still processing\" refusal is safe to resend: it means the
    /// command never ran. A `pane_not_found` retried four times is just noise,
    /// and a retried destructive command that *did* run would run twice.
    @Test("only endpoint_busy is classified as retryable")
    func onlyBusyIsRetryable() {
        let busy = BridgeError.daemon(
            method: "pane.split",
            code: "endpoint_busy",
            message: "still processing"
        )
        let missing = BridgeError.daemon(
            method: "pane.split",
            code: "pane_not_found",
            message: "no such pane"
        )

        #expect(EndpointConnection.isBusyRefusal(busy))
        #expect(!EndpointConnection.isBusyRefusal(missing))
    }

    /// A transport failure is not a refusal, and must not be retried as one.
    @Test("a transport error is not a busy refusal")
    func transportIsNotBusy() {
        #expect(!EndpointConnection.isBusyRefusal(BridgeError.transport("socket closed")))
    }
}
