// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  CloseAndCycleTests.swift
//  KraalClientTests
//
//  Closing something that belongs to a group, and cycling through panes.
//
//  The close flow is the one place where a refusal is not an error: the daemon answers
//  `workspace_group_close_required` because closing one workspace alone would take
//  others down with it, and the client must **ask** rather than retry blindly.
//
//  The rule that matters: the first attempt never claims the group. If it did, a user
//  who clicked one row would lose several, with no question asked. Issue #21 stayed
//  hidden for a while because a refusal that only reached a tooltip looks exactly like
//  a menu that did nothing.
//
//  `cyclePane` looks trivial and is not: the modulo has to handle a negative step,
//  or `previous pane` on the first pane walks out of the array.
//

import Foundation
import Testing

@testable import KraalClient
@testable import KraalProtocol
@testable import KraalUI

@Suite("Close and cycle")
@MainActor
struct CloseAndCycleTests {
    private func store(panes: [String] = ["w1:p1", "w1:p2", "w1:p3"]) -> (AppStore, DaemonConnectionRecorder) {
        let store = AppStore(target: .local)
        let endpoint = EndpointState(id: .local, label: "Local", settings: .local)
        let recorder = DaemonConnectionRecorder()
        endpoint.connection = recorder
        endpoint.status = .online
        store.endpoints = [endpoint]
        store.activeEndpointID = .local
        store.phase = .live

        let paneJSON = panes.enumerated().map { index, paneId in
            """
            {"pane_id": "\(paneId)", "workspace_id": "w1", "tab_id": "w1:t1",
             "label": "p\(index)", "cwd": "/tmp", "focused": \(index == 0),
             "right_click_passthrough": false}
            """
        }.joined(separator: ",")
        let json = """
        {"boot_id": "boot", "revision": 1, "focused_tab_id": "w1:t1",
         "workspaces": [{"workspace_id": "w1", "active_tab_id": "w1:t1",
                         "new_workspace_cwd": "/tmp", "number": 1, "label": "one",
                         "custom_label": false, "focused": true, "tokens": []}],
         "tabs": [{"tab_id": "w1:t1", "workspace_id": "w1", "number": 1, "label": "1",
                   "focused": true, "zoomed": false, "agent_status": "idle"}],
         "panes": [\(paneJSON)],
         "agents": [], "agent_order": [], "commands": []}
        """
        // The fixture is decoded the way the connection does it.
        store.snapshot = try? JSONDecoder().decode(
            ClientShellSnapshot.self, from: Data(json.utf8)
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

    // MARK: - Close

    /// The first attempt must **not** claim the group: the user clicked one row, and
    /// the daemon is the authority on what the group contains.
    @Test("the first close does not claim the group")
    func firstCloseDoesNotClaimGroup() async throws {
        let (store, recorder) = store()
        store.close(workspaceId: "w1")
        try await waitUntil("workspace.close") {
            recorder.methods.contains("workspace.close")
        }
        let params = try #require(recorder.lastParams(of: "workspace.close"))
        #expect(params["workspace_id"] as? String == "w1")
        #expect(params["close_group"] as? Bool == false,
                "the first attempt claimed the whole group")
    }

    /// The group refusal is not an error: it becomes a question.
    @Test("a group refusal becomes a pending question, not a banner")
    func groupRefusalBecomesQuestion() async throws {
        let (store, recorder) = store()
        recorder.scriptedErrors = [ScriptedRefusal.code(AppStore.groupCloseRequired)]
        store.close(workspaceId: "w1")
        try await waitUntil("the pending question") { store.pendingGroupClose != nil }

        let pending = try #require(store.pendingGroupClose)
        #expect(pending.method == "workspace.close")
        #expect(pending.workspaceId == "w1")
        #expect(store.lastError == nil,
                "a group refusal was reported as an error instead of a question")
    }

    /// Any other refusal is a real error the user has to see.
    @Test("another refusal is reported as an error")
    func otherRefusalIsAnError() async throws {
        let (store, recorder) = store()
        recorder.scriptedErrors = [ScriptedRefusal.code("not_found")]
        store.close(workspaceId: "w1")
        try await waitUntil("the error") { store.lastError != nil }

        #expect(store.lastError?.contains("not_found") == true)
        #expect(store.pendingGroupClose == nil,
                "an unrelated refusal asked the user to confirm a group close")
    }

    /// Confirming retries **with** the group flag, and clears the question.
    @Test("confirming retries with close_group true")
    func confirmingClaimsGroup() async throws {
        let (store, recorder) = store()
        recorder.scriptedErrors = [ScriptedRefusal.code(AppStore.groupCloseRequired)]
        store.close(workspaceId: "w1")
        try await waitUntil("the pending question") { store.pendingGroupClose != nil }

        store.confirmPendingGroupClose()
        try await waitUntil("the second close") {
            recorder.requests.filter { $0.method == "workspace.close" }.count >= 2
        }
        let params = try #require(recorder.lastParams(of: "workspace.close"))
        #expect(params["close_group"] as? Bool == true,
                "confirming did not claim the group, so the retry is refused again")
        #expect(store.pendingGroupClose == nil, "the question outlived its answer")
    }

    /// Cancelling drops the question without sending anything.
    @Test("cancelling sends nothing")
    func cancellingSendsNothing() async throws {
        let (store, recorder) = store()
        recorder.scriptedErrors = [ScriptedRefusal.code(AppStore.groupCloseRequired)]
        store.close(workspaceId: "w1")
        try await waitUntil("the pending question") { store.pendingGroupClose != nil }

        let before = recorder.methods.count
        store.cancelPendingGroupClose()
        try await Task.sleep(for: .milliseconds(80))
        #expect(store.pendingGroupClose == nil)
        #expect(recorder.methods.count == before, "cancelling still sent a close")
    }

    /// `pane.close` / `tab.close` take no group flag; confirming resends the same
    /// request. The daemon accepts it once the client has shown the confirmation.
    @Test("confirming a pane close sends no group flag")
    func paneCloseConfirmHasNoGroupFlag() async throws {
        let (store, recorder) = store()
        recorder.scriptedErrors = [ScriptedRefusal.code(AppStore.confirmationRequired)]
        store.close(paneId: "w1:p1")
        try await waitUntil("the pending question") { store.pendingGroupClose != nil }

        store.confirmPendingGroupClose()
        try await waitUntil("the second close") {
            recorder.requests.filter { $0.method == "pane.close" }.count >= 2
        }
        let params = try #require(recorder.lastParams(of: "pane.close"))
        #expect(params["pane_id"] as? String == "w1:p1")
        #expect(params["close_group"] == nil,
                "pane.close was sent a close_group parameter the daemon does not take")
    }

    // MARK: - Cycle

    /// Forward from the first pane reaches the second.
    @Test("cycling forward moves to the next pane")
    func cycleForward() async throws {
        let (store, recorder) = store()
        store.cyclePane(by: 1)
        try await waitUntil("pane.focus") { !recorder.paneInputs.isEmpty || !recorder.methods.isEmpty }
        // `cyclePane` focuses through `FocusConfirmation`, which sends `pane.focus`.
        try await waitUntil("the focus request") { !recorder.methods.contains("pane.focus") == false }
        #expect(recorder.lastParams(of: "pane.focus")?["pane_id"] as? String == "w1:p2")
    }

    /// Backward from the first pane wraps to the last. Without the `+ count` in the
    /// modulo this indexes out of the array.
    @Test("cycling backward from the first pane wraps to the last")
    func cycleBackwardWraps() async throws {
        let (store, recorder) = store()
        store.cyclePane(by: -1)
        try await waitUntil("the focus request") {
            recorder.methods.contains("pane.focus")
        }
        #expect(recorder.lastParams(of: "pane.focus")?["pane_id"] as? String == "w1:p3",
                "a negative step did not wrap around")
    }

    /// No panes: nothing to cycle to, nothing sent.
    @Test("cycling with no panes sends nothing")
    func cycleWithNoPanes() async throws {
        let (store, recorder) = store(panes: [])
        store.cyclePane(by: 1)
        try await Task.sleep(for: .milliseconds(80))
        #expect(recorder.methods.isEmpty)
    }
}
