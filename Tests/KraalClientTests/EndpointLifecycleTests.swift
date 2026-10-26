// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  EndpointLifecycleTests.swift
//  KraalClientTests
//
//  The multi-machine state machine in `AppStore+Endpoints.swift`.
//
//  That file is 854 lines and had no test referring to it, even though it owns the
//  decisions that go wrong silently: which machines are connected, what "selected"
//  means, and what the outgoing machine keeps when the selection moves.
//
//  Nothing here needs a socket. Each test builds a store, hands it a roster or a set
//  of endpoints, and asserts the state that the SwiftUI views read.
//

import Foundation
import Testing

@testable import KraalClient
@testable import KraalProtocol
@testable import KraalTransport
@testable import KraalUI

@Suite("Endpoint lifecycle")
@MainActor
struct EndpointLifecycleTests {
    private func machine(
        id: String,
        label: String,
        target: String = "ssh://host/sock",
        enabled: Bool = true
    ) -> HerdrMachine {
        HerdrMachine(
            id: id, label: label, target: target, session: "default",
            enabled: enabled, selected: false
        )
    }

    private func store() -> AppStore {
        let store = AppStore(target: .local)
        store.endpoints = [EndpointState(id: .local, label: "Local", settings: .local)]
        store.activeEndpointID = .local
        return store
    }

    // MARK: - rebuildEndpoints

    /// Local is always first and always enabled, even when a profile list is empty.
    ///
    /// Upstream seeds `Local` before any saved profile and keeps it there
    /// (`endpoints.rs:47-56`); a list that reordered as the selection moved would make
    /// the sidebar jump.
    @Test("Local leads the list even with an empty roster")
    func localLeadsEmptyRoster() {
        let store = store()
        store.rebuildEndpoints(roster: [])
        #expect(store.endpoints.first?.id == .local)
        #expect(store.endpoints.first?.enabled == true)
        #expect(store.endpoints.count == 1)
    }

    @Test("roster entries become endpoints, after Local")
    func rosterBecomesEndpoints() {
        let store = store()
        store.rebuildEndpoints(roster: [
            .remote(machine(id: "a", label: "alpha")),
            .remote(machine(id: "b", label: "beta")),
        ])
        #expect(store.endpoints.map(\.label) == ["Local", "alpha", "beta"])
    }

    /// A roster change must not rebuild the machines that were already there.
    ///
    /// The identity of an endpoint is what its `connectionTask` and its snapshot hang
    /// off. Recreating the array wholesale would drop a live connection and blank the
    /// rows every time the roster file was rewritten — which happens whenever any
    /// `herdr machine` command runs.
    @Test("rebuilding keeps the existing row objects")
    func rebuildKeepsObjects() {
        let store = store()
        store.rebuildEndpoints(roster: [.remote(machine(id: "a", label: "alpha"))])
        let firstPass = store.endpoints.first { $0.label == "alpha" }
        #expect(firstPass != nil)

        store.rebuildEndpoints(roster: [
            .remote(machine(id: "a", label: "alpha")),
            .remote(machine(id: "b", label: "beta")),
        ])
        let secondPass = store.endpoints.first { $0.label == "alpha" }
        #expect(secondPass === firstPass, "the existing machine was rebuilt")
    }

    /// A machine whose SSH target cannot be parsed still gets a row, but is left
    /// unconnectable so every automatic path skips it.
    @Test("an unparseable target is listed but disabled")
    func unparseableTargetIsDisabled() {
        let store = store()
        store.rebuildEndpoints(roster: [
            .remote(machine(id: "a", label: "broken", target: "")),
        ])
        let row = store.endpoints.first { $0.label == "broken" }
        #expect(row != nil, "the row disappeared; the dialog and the sidebar would disagree")
        #expect(row?.enabled == false, "an unparseable target must not be dialed")
    }

    // MARK: - Retry

    /// A disabled machine never gets a retry scheduled.
    @Test("retries are skipped for a disabled machine")
    func disabledMachineNeverRetries() {
        let store = store()
        let endpoint = EndpointState(id: .ssh(id: "a"), label: "a", settings: .local)
        endpoint.enabled = false
        store.endpoints.append(endpoint)
        #expect(store.scheduleEndpointRetry(endpoint) == nil)
        #expect(endpoint.reconnectAttempt == 0, "a skipped retry must not count as one")
        #expect(endpoint.connectionTask == nil)
    }

    /// The backoff is computed in exactly one place, and `report` only decides whether
    /// the UI shows it. Reporting from a call site that computed its own delay is what
    /// produced an off-by-one countdown (see the doc comment on the function).
    @Test("the reported delay is the delay that was used")
    func reportedDelayMatches() {
        let store = store()
        let endpoint = store.endpoints[0]
        let delay = store.scheduleEndpointRetry(endpoint, report: true)
        #expect(delay != nil)
        guard case let .reconnecting(attempt, retryAt) = store.phase else {
            Issue.record("expected reconnecting, got \(store.phase)")
            return
        }
        #expect(attempt == 1)
        let shown = retryAt.timeIntervalSinceNow
        #expect(abs(shown - (delay ?? 0)) < 1.0, "the UI countdown disagrees with the sleep")
        endpoint.connectionTask?.cancel()
    }

    // MARK: - Selection

    /// Switching machines must leave the outgoing one drawing what it last saw.
    ///
    /// `snapshot` is the *selected* machine's; without taking a copy on the way out,
    /// the machine being left keeps a reference to the incoming one's state and its
    /// rows silently redraw as a different session.
    @Test("switching away preserves the outgoing machine's snapshot")
    func switchPreservesOutgoingSnapshot() throws {
        let store = store()
        store.rebuildEndpoints(roster: [
            .remote(machine(id: "a", label: "alpha")),
            .remote(machine(id: "b", label: "beta")),
        ])
        guard let alpha = store.endpoints.first(where: { $0.label == "alpha" }),
              let beta = store.endpoints.first(where: { $0.label == "beta" })
        else {
            Issue.record("roster did not produce both rows")
            return
        }

        let alphaSnapshot = try Self.snapshot(bootId: "alpha-boot")
        store.selectEndpoint(alpha)
        store.snapshot = alphaSnapshot

        store.selectEndpoint(beta)
        #expect(alpha.snapshot?.bootId == "alpha-boot",
                "the machine being left lost its snapshot")
    }

    /// Selecting the machine that is already selected is a no-op.
    @Test("selecting the current machine does nothing")
    func selectCurrentIsNoOp() {
        let store = store()
        let before = store.phase
        store.selectEndpoint(store.endpoints[0])
        #expect(store.activeEndpointID == .local)
        #expect(store.phase == before)
    }

    /// `activeEndpointID` and `activeEndpoint` must name the same machine. `nil` means
    /// "nothing selected yet", and then no row may claim to be focused.
    @Test("activeEndpoint follows activeEndpointID")
    func activeEndpointFollowsId() {
        let store = store()
        store.rebuildEndpoints(roster: [.remote(machine(id: "a", label: "alpha"))])
        guard let alpha = store.endpoints.first(where: { $0.label == "alpha" }) else {
            Issue.record("no alpha row")
            return
        }
        store.selectEndpoint(alpha)
        #expect(store.activeEndpoint?.id == store.activeEndpointID)
        #expect(store.activeEndpointID == alpha.id)
    }

    // MARK: - Fixtures

    /// A snapshot with only what these tests read.
    private static func snapshot(bootId: String) throws -> ClientShellSnapshot {
        let json = """
        {"boot_id": "\(bootId)", "revision": 1, "workspaces": [], "tabs": [],
         "panes": [], "agents": [], "agent_order": [], "commands": []}
        """
        return try JSONDecoder().decode(ClientShellSnapshot.self, from: Data(json.utf8))
    }
}
