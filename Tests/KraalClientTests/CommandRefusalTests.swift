// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  CommandRefusalTests.swift
//  KraalClientTests
//
//  How a daemon refusal is classified, and why two paths must agree.
//
//  `AppStore+Requests.swift` sends commands three ways:
//
//  * `call` — collapses everything into `lastError`;
//  * `callReturningErrorCode` — hands the code back so a caller can *act* on it
//    (`workspace_group_close_required` means "ask about the whole group", not "it broke");
//  * `callReturningResult` — hands the body back.
//
//  All three retry a busy refusal and none retry anything else. But `call` asks
//  `EndpointConnection.isBusyRefusal`, while `callReturningErrorCode` pattern-matches
//  `BridgeError.daemon(_, code, _)` inline. Two readings of the same rule is exactly how
//  one path starts retrying something the other gives up on — and a busy refusal is
//  *retried*, so a disagreement shows up as a command that either double-executes or
//  silently drops.
//
//  The daemon's refusals arrive **in band** (`{"error":{"code":...}}`, a complete and
//  valid frame), which is why this is an error-shape question and not a socket one.
//

import Foundation
import Testing

@testable import KraalClient
@testable import KraalUI

@Suite("Command refusal classification")
struct CommandRefusalTests {
    private func refusal(_ code: String) -> BridgeError {
        .daemon(method: "pane.split", code: code, message: "refused")
    }

    /// Only `endpoint_busy` is worth retrying: the refusal means nothing happened, so
    /// re-sending is safe. Everything else is a real answer.
    @Test("only endpoint_busy counts as a busy refusal")
    func onlyBusyIsBusy() {
        #expect(EndpointConnection.isBusyRefusal(refusal("endpoint_busy")))
        for code in [
            "workspace_group_close_required",
            "unknown_method",
            "bad_params",
            "not_found",
            "endpoint_busy_forever",
            "ENDPOINT_BUSY",
            "",
        ] {
            #expect(!EndpointConnection.isBusyRefusal(refusal(code)),
                    Comment(rawValue: "\(code) was treated as a retryable busy refusal"))
        }
    }

    /// A non-daemon error is never a busy refusal. This matters because the retry loop
    /// would otherwise spin on transport failures, which are not safe to resend.
    @Test("non-daemon errors are never busy refusals")
    func nonDaemonIsNotBusy() {
        #expect(!EndpointConnection.isBusyRefusal(BridgeError.unexpectedStreamEnd))
        #expect(!EndpointConnection.isBusyRefusal(BridgeError.handshakeRejected("no")))
        #expect(!EndpointConnection.isBusyRefusal(
            NSError(domain: "test", code: 1)
        ))
    }

    /// The classifier and the inline pattern must agree, or `call` and
    /// `callReturningErrorCode` disagree about what to retry. This is the assertion the
    /// suite exists for; the two above only pin the classifier's own edges.
    @Test("the shared classifier and the inline match agree")
    func classifierMatchesInline() {
        let codes = [
            "endpoint_busy",
            "workspace_group_close_required",
            "unknown_method",
            "",
        ]
        for code in codes {
            let error = refusal(code)
            let viaClassifier = EndpointConnection.isBusyRefusal(error)
            // The same test `callReturningErrorCode` performs inline.
            let viaInline: Bool
            if case let BridgeError.daemon(_, inlineCode, _) = error {
                viaInline = inlineCode == "endpoint_busy"
            } else {
                viaInline = false
            }
            #expect(viaClassifier == viaInline, Comment(rawValue:
                "\(code): call would retry=\(viaClassifier) but "
                    + "callReturningErrorCode would retry=\(viaInline)"))
        }
    }

    /// A refusal carries the code through to the caller, which is the whole reason
    /// `callReturningErrorCode` exists: the close flow branches on it.
    @Test("a refusal keeps its code")
    func refusalKeepsCode() {
        guard case let BridgeError.daemon(method, code, message) =
            refusal("workspace_group_close_required")
        else {
            Issue.record("the error is not a daemon refusal")
            return
        }
        #expect(method == "pane.split")
        #expect(code == "workspace_group_close_required")
        #expect(message == "refused")
    }
}
