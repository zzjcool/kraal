// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  EffectAndFocusSendingTests.swift
//  KraalClientTests
//
//  The send paths that were added last and never exercised: focus, report-all, errors.
//
//  `sendPaneFocus` is the one action on the per-keystroke path (issue #55): an
//  unconditional `pane.focus` per key cost 7x the socket time of the keystroke itself.
//  The deduplication lives in `FocusConfirmation`, but what `sendPaneFocus` returns is
//  what feeds it — `true` records the belief, `false` leaves it unrecorded so the next
//  keystroke retries. Returning `true` for a refusal would leave the pane permanently
//  unfocused, which is worse than the redundant request it replaced.
//
//  `applyKeyboardReportAll` has a two-window shape that is easy to get wrong: the
//  per-machine record must be updated for *every* machine, but only the selected
//  machine's value may become the one the decoders use.
//

import Foundation
import Testing

@testable import KraalClient
@testable import KraalProtocol
@testable import KraalUI

@Suite("Effects and focus sending")
@MainActor
struct EffectAndFocusSendingTests {
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

    // MARK: - Focus

    /// An accepted focus reports success, which is what lets `FocusConfirmation` skip
    /// the next request. A `true` for a refusal would freeze the belief.
    @Test("an accepted focus reports success")
    func acceptedFocusReportsSuccess() async {
        let (store, recorder) = store()
        let accepted = await store.sendPaneFocus("w1:p1")
        #expect(accepted, "a successful pane.focus was reported as a failure")
        #expect(recorder.methods == ["pane.focus"])
        #expect(recorder.lastParams(of: "pane.focus")?["pane_id"] as? String == "w1:p1")
    }

    /// A refusal must report `false` so the belief is not recorded.
    @Test("a refused focus reports failure")
    func refusedFocusReportsFailure() async {
        let (store, recorder) = store()
        recorder.scriptedErrors = [ScriptedRefusal.code("endpoint_busy")]
        // The busy path retries until the bound, so script every attempt.
        recorder.scriptedErrors = Array(
            repeating: ScriptedRefusal.code("endpoint_busy"), count: 4
        )
        let accepted = await store.sendPaneFocus("w1:p1")
        #expect(!accepted,
                "a refused focus reported success, so the next keystroke would skip it")
    }

    /// No connection yet: the call is skipped and reported as not accepted.
    @Test("focus with no connection is not accepted")
    func focusWithNoConnection() async {
        let store = AppStore(target: .local)
        store.endpoints = [EndpointState(id: .local, label: "Local", settings: .local)]
        store.activeEndpointID = .local
        let accepted = await store.sendPaneFocus("w1:p1")
        #expect(!accepted)
    }

    // MARK: - Report-all

    /// Every machine records its own value; only the selected one feeds the decoders.
    ///
    /// The two-window shape matters because report-all is a per-daemon setting: machine
    /// B claiming it does not change what machine A's terminals expect.
    @Test("report-all is recorded per machine but only the active one applies")
    func reportAllPerMachine() {
        let store = AppStore(target: .local)
        let local = EndpointState(id: .local, label: "Local", settings: .local)
        let remote = EndpointState(id: .ssh(id: "a"), label: "remote", settings: .local)
        store.endpoints = [local, remote]
        store.activeEndpointID = .local

        store.applyKeyboardReportAll(true, from: remote, isActive: false)
        #expect(remote.keyboardReportAll, "the non-selected machine did not record its value")
        #expect(!store.keyboardReportAll,
                "a background machine changed what the active machine's decoders use")

        store.applyKeyboardReportAll(true, from: local, isActive: true)
        #expect(store.keyboardReportAll, "the active machine's value did not reach the decoders")
    }

    /// Turning it off again must also propagate.
    @Test("report-all off propagates for the active machine")
    func reportAllOff() {
        let store = AppStore(target: .local)
        let local = EndpointState(id: .local, label: "Local", settings: .local)
        store.endpoints = [local]
        store.activeEndpointID = .local

        store.applyKeyboardReportAll(true, from: local, isActive: true)
        #expect(store.keyboardReportAll)
        store.applyKeyboardReportAll(false, from: local, isActive: true)
        #expect(!store.keyboardReportAll)
        #expect(!local.keyboardReportAll)
    }

    // MARK: - Copy-mode errors

    /// A copy-mode failure must reach the banner. The alternative observed in practice
    /// is a motion that does nothing with no explanation.
    @Test("a copy-mode message reaches lastError")
    func copyModeMessageReachesBanner() {
        let store = AppStore(target: .local)
        store.endpoints = [EndpointState(id: .local, label: "Local", settings: .local)]
        store.activeEndpointID = .local
        store.reportCopyModeMessage("word motion failed")
        #expect(store.lastError == "word motion failed")
    }
}
