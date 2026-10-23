// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Issue #67: a machine that hangs on its handshake used to enter a dead state and
// stay there — never retried, and Refresh could not rescue it either.
//
// Two independent defects are pinned here, both at the store level. The handshake
// timeout itself (#66) is already fixed inside `EndpointConnection`; these tests
// are about what happens *above* it, which is the part that has to survive the
// layer below failing to bound something.
//
//  A. `connectEndpoint` delegated the whole "is this machine stuck?" question to
//     `EndpointConnection.start()`'s own deadline. A watchdog now races it and
//     abandons a machine that never answers.
//  B. The Refresh button / `.reconnect` called `connect()`, which looks only at
//     the active machine and returns early while `connectionTask != nil` — so it
//     did nothing in every case it existed for. `reconnectAllEndpoints()` is the
//     entry point those two call sites now use.
//
// The peers are real listening sockets that accept and then stay silent (the
// same `ScriptedSocketPeer` `HandshakeDeadlineTests` uses), so "stuck" is the real
// condition and not a stub that reports it.

import Foundation
import Testing

import KraalClient
import KraalProtocol
import KraalTransport

@testable import KraalUI

@Suite("Hung handshake recovery", .serialized)
@MainActor
struct HungHandshakeTests {
    /// Short enough that a stuck handshake is abandoned inside a test, long enough
    /// that a healthy one is not cut off. The connection below is given a *long*
    /// `handshakeTimeout`, on purpose: the watchdog is supposed to be the thing
    /// that notices, so if the two were close the test could not tell which one
    /// fired.
    private static let watchdog: TimeInterval = 0.5
    /// Generous slack for a loaded machine; the assertion is "recovered", not
    /// "recovered to the millisecond".
    private static let slack: TimeInterval = 5.0

    /// A store whose machines dial a silent peer described by `path`.
    private static func store(dialling path: String) -> AppStore {
        let store = AppStore(target: .local)
        store.handshakeWatchdog = watchdog
        store.discoveryEnvironment = ["KRAAL_HERDR_SOCKET": path]
        return store
    }

    /// Polls `condition` until it holds, or gives up after `slack`.
    @discardableResult
    private static func eventually(
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(slack)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    // MARK: - A. the watchdog

    /// **The decisive test for the first half of #67.**
    ///
    /// A peer that accepts and then says nothing, with the connection's own
    /// deadline set far beyond the test, must still be given up on, and the machine
    /// must come out of it able to retry.
    ///
    /// What the assertions deliberately do *not* say is "`connectionTask` becomes
    /// nil", even though that reads like the dead state. It never is nil during a
    /// backoff: `scheduleEndpointRetry` installs its own sleep task there, so the
    /// field is occupied from the first attempt until the machine connects. The
    /// dead state is not "task is set" — it is "task is set and nothing ever
    /// happens again", which is what the retry and the changed epoch pin. Measured
    /// timeline for this very test (watchdog 0.5 s):
    ///
    ///     [0.5s] epoch=1 attempt=0 taskSet=true  cancelled=false status=online
    ///     [0.6s] epoch=1 attempt=2 taskSet=true  cancelled=false status=reconnecting   <- watchdog
    ///     [1.6s] epoch=2 attempt=2 taskSet=true  cancelled=false status=reconnecting   <- retry handshake
    ///
    /// A/B: leave `connectEndpoint` calling `connection.start()` directly and the
    /// trace stays on the first line — `attempt=0` forever, no retry, the machine
    /// never tries again.
    @Test("a hung handshake is abandoned by the watchdog")
    func hungHandshakeIsAbandoned() async throws {
        let peer = try ScriptedSocketPeer()
        peer.startAccepting()
        defer { peer.stop() }

        let store = Self.store(dialling: peer.path)
        let endpoint = EndpointState(
            id: .local, label: "Local", status: .online, settings: .local
        )
        store.endpoints = [endpoint]
        store.activeEndpointID = .local
        store.intentionalStop = false
        let epochBefore = endpoint.connectionEpoch
        let attemptsBefore = endpoint.reconnectAttempt

        store.connectEndpoint(endpoint)
        #expect(endpoint.connectionTask != nil, "the attempt did not even start")
        #expect(endpoint.reconnectAttempt == attemptsBefore, "a retry appeared before the watchdog")
        // The epoch the *first* attempt stamped, so "a retry ran" cannot be
        // satisfied by the first attempt itself.
        let stuckEpoch = endpoint.connectionEpoch
        #expect(stuckEpoch > epochBefore)

        // The machine must be declared broken and rescheduled. Before the watchdog
        // neither happens, and the row sits on `connecting` forever.
        let gaveUp = await Self.eventually {
            guard case .reconnecting = endpoint.status else { return false }
            return endpoint.reconnectAttempt > attemptsBefore
        }
        print("watchdog: gaveUp=\(gaveUp) status=\(endpoint.status) attempt=\(endpoint.reconnectAttempt)")
        #expect(gaveUp, "the hung handshake was never declared a failure")
        #expect(endpoint.connection == nil, "the dead connection was left attached")
        #expect(
            endpoint.reconnectAttempt > attemptsBefore,
            "no retry was scheduled: attempt \(attemptsBefore) -> \(endpoint.reconnectAttempt)"
        )
        // Exactly one retry, not two. A failed handshake reports twice — the
        // `catch` in `connectEndpoint` and the `.disconnected` event that
        // `stop()` raises — and scheduling on both counted the failure twice, so
        // the backoff opened at 2 instead of 1 (2, 4, 8, 16 rather than 1, 2, 4, 8).
        // The first retry after a failed handshake then waited twice as long as the
        // one after a dropped connection, for no reason a user could see.
        let counts = endpoint.reconnectAttempt - attemptsBefore
        #expect(
            counts == 1,
            "one failure was counted \(counts) times, so the backoff opened at \(1 << (counts - 1))s"
        )

        // And the retry must actually run: the epoch moves *past* the stuck
        // attempt's stamp, which only a fresh `connectEndpoint` does. A retry that
        // scheduled but never connected would still be the dead state.
        let retried = await Self.eventually {
            endpoint.connectionEpoch > stuckEpoch
        }
        print("watchdog: retried=\(retried) epoch \(stuckEpoch) -> \(endpoint.connectionEpoch)")
        #expect(retried, "the retry never started a new handshake")

        store.disconnectAllEndpoints()
    }

    /// The other direction: a peer that answers is not touched by the watchdog.
    ///
    /// Without this, a watchdog that tore down every handshake would pass the test
    /// above while making every machine unusable.
    @Test("a peer that answers still connects")
    func healthyPeerConnects() async throws {
        let peer = try ScriptedSocketPeer(reply: try HandshakeDeadlineTests.welcomeFrame())
        peer.startAccepting()
        defer { peer.stop() }

        let store = Self.store(dialling: peer.path)
        let endpoint = EndpointState(
            id: .local, label: "Local", status: .online, settings: .local
        )
        store.endpoints = [endpoint]
        store.activeEndpointID = .local
        store.intentionalStop = false

        store.connectEndpoint(endpoint)
        let taskCleared = await Self.eventually { endpoint.connectionTask == nil }
        print("healthy: task cleared=\(taskCleared) status=\(endpoint.status)")
        #expect(taskCleared)
        #expect(endpoint.connection != nil, "the watchdog tore down a handshake that worked")
        #expect(endpoint.reconnectAttempt == 0, "a healthy handshake scheduled a retry")
        store.disconnectAllEndpoints()
    }

    // MARK: - B. reconnectAllEndpoints

    /// Every enabled machine is reconnected, not just the selected one.
    ///
    /// This is the half of the bug a user could see without a hung machine at all:
    /// with one broken background machine, pressing Refresh did nothing to it.
    ///
    /// A/B: change `reconnectAllEndpoints` back to `connect()` and this goes red on
    /// the background machine's epoch.
    @Test("reconnectAllEndpoints reconnects every machine")
    func reconnectAllCoversEveryMachine() async throws {
        let store = AppStore(target: .local)
        // Nothing listens on either path, so both fail fast and cannot park this
        // test on a real socket. What is asserted is that the attempt *started*.
        store.discoveryEnvironment = [
            "KRAAL_HERDR_SOCKET": "/tmp/kraal-nobody-\(UUID().uuidString).sock",
        ]
        let local = EndpointState(id: .local, label: "Local", settings: .local)
        let remote = EndpointState(
            id: .ssh(id: "hung-host"),
            label: "hung-host",
            settings: ConnectionSettings(
                name: "hung-host", transport: .local, session: "default"
            )
        )
        store.endpoints = [local, remote]
        store.activeEndpointID = .local
        store.intentionalStop = false

        let epochsBefore = store.endpoints.map { ($0.id, $0.connectionEpoch) }
        store.reconnectAllEndpoints()

        for (id, epoch) in epochsBefore {
            let endpoint = try #require(store.endpoints.first { $0.id == id })
            #expect(
                endpoint.connectionEpoch > epoch,
                "\(id.storageKey) was not reconnected: epoch \(epoch) -> \(endpoint.connectionEpoch)"
            )
            #expect(endpoint.connectionTask != nil, "\(id.storageKey) has no task in flight")
        }
        #expect(store.intentionalStop == false)
        store.disconnectAllEndpoints()
    }

    /// The case the issue measured: a machine with a task already in flight and
    /// never finishing. `connect()` is built to return early there, so a reconnect
    /// that reused it could never break out.
    ///
    /// A/B: swap the method back to `connect()` and the epoch does not move.
    @Test("reconnectAllEndpoints breaks a stuck machine out")
    func reconnectAllBreaksStuckMachine() async throws {
        let peer = try ScriptedSocketPeer()
        peer.startAccepting()
        defer { peer.stop() }

        // A long watchdog on purpose: this test is about the reconnect, and the
        // machine has to still be stuck when the call arrives.
        let store = AppStore(target: .local)
        store.handshakeWatchdog = 60
        store.discoveryEnvironment = ["KRAAL_HERDR_SOCKET": peer.path]
        let endpoint = EndpointState(id: .local, label: "Local", settings: .local)
        let remote = EndpointState(
            id: .ssh(id: "elsewhere"),
            label: "elsewhere",
            settings: ConnectionSettings(
                name: "elsewhere", transport: .local, session: "default"
            )
        )
        store.endpoints = [endpoint, remote]
        store.activeEndpointID = .local
        store.intentionalStop = false

        store.connectEndpoint(endpoint)
        // Give the handshake time to reach its blocking read.
        try? await Task.sleep(nanoseconds: 300_000_000)
        let stuckTask = try #require(endpoint.connectionTask, "the attempt did not start")
        let stuckEpoch = endpoint.connectionEpoch
        #expect(!stuckTask.isCancelled)

        store.reconnectAllEndpoints()

        #expect(
            endpoint.connectionEpoch > stuckEpoch,
            "the epoch did not move: \(stuckEpoch) -> \(endpoint.connectionEpoch)"
        )
        #expect(stuckTask.isCancelled, "the stuck task was left running")
        let replacement = try #require(endpoint.connectionTask, "no fresh attempt was started")
        print("stuck machine: epoch \(stuckEpoch) -> \(endpoint.connectionEpoch), new task in place")
        #expect(endpoint.status != EndpointStatus.attention("! error"), "the machine was left in the failed state")

        store.disconnectAllEndpoints()
        _ = replacement
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    /// Disabled machines and unreadable targets are skipped, not dialled.
    ///
    /// Both reach the catalog with `enabled == false` (`rebuildEndpoints`), and
    /// dialling them would replace a `! check target` badge with a generic error
    /// the user cannot act on.
    @Test("reconnectAllEndpoints skips disabled machines")
    func reconnectAllSkipsDisabled() async {
        let store = AppStore(target: .local)
        store.discoveryEnvironment = [
            "KRAAL_HERDR_SOCKET": "/tmp/kraal-nobody-\(UUID().uuidString).sock",
        ]
        let local = EndpointState(id: .local, label: "Local", settings: .local)
        let off = EndpointState(
            id: .ssh(id: "off"),
            label: "off",
            status: .disabled,
            settings: ConnectionSettings(name: "off", transport: .local),
            enabled: false
        )
        store.endpoints = [local, off]
        store.activeEndpointID = .local
        let offEpoch = off.connectionEpoch

        store.reconnectAllEndpoints()

        #expect(off.connectionEpoch == offEpoch, "a disabled machine was reconnected")
        #expect(off.connectionTask == nil, "a disabled machine was given a connection task")
        #expect(off.status == .disabled, "a disabled machine's status was overwritten")
        store.disconnectAllEndpoints()
    }

    // MARK: - The old contract, unchanged

    /// `connect()` must keep looking only at the active machine.
    ///
    /// It means "connect the target the user just named in the connection panel",
    /// and the three call sites in `ConnectionViews` rely on that. This is the
    /// regression guard for the fix: the temptation is to make Refresh work by
    /// widening `connect()`, which would silently change what those three do.
    @Test("connect() still only touches the active machine")
    func connectOnlyTouchesActive() async {
        let store = AppStore(target: .local)
        store.discoveryEnvironment = [
            "KRAAL_HERDR_SOCKET": "/tmp/kraal-nobody-\(UUID().uuidString).sock",
        ]
        let local = EndpointState(id: .local, label: "Local", settings: .local)
        let remote = EndpointState(
            id: .ssh(id: "elsewhere"),
            label: "elsewhere",
            settings: ConnectionSettings(name: "elsewhere", transport: .local)
        )
        store.endpoints = [local, remote]
        store.activeEndpointID = .local
        store.intentionalStop = false
        let remoteEpoch = remote.connectionEpoch

        store.connect()

        #expect(
            remote.connectionEpoch == remoteEpoch,
            "connect() reached a background machine: it is not just the active one"
        )
        #expect(remote.connectionTask == nil, "connect() started a background connection")
        #expect(local.connectionTask != nil, "connect() did not start the active machine")
        store.disconnectAllEndpoints()
    }

    /// And it still returns early when the active machine already has an attempt in
    /// flight — the behaviour the reconnect path deliberately does not inherit.
    @Test("connect() is still a no-op while the active machine is connecting")
    func connectStillReturnsEarlyWhileConnecting() async throws {
        let store = AppStore(target: .local)
        store.discoveryEnvironment = [
            "KRAAL_HERDR_SOCKET": "/tmp/kraal-nobody-\(UUID().uuidString).sock",
        ]
        let local = EndpointState(id: .local, label: "Local", settings: .local)
        store.endpoints = [local]
        store.activeEndpointID = .local
        store.intentionalStop = false

        // A task that never clears on its own is what "connecting" looks like.
        let blocker = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            while true { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        }
        local.connectionTask = blocker
        let epoch = local.connectionEpoch

        store.connect()
        #expect(local.connectionEpoch == epoch, "connect() replaced the in-flight attempt")

        local.connectionTask = nil
        blocker.cancel()
        store.disconnectAllEndpoints()
    }
}

// MARK: - The watchdog constant

@Suite("Handshake watchdog constant")
struct HandshakeWatchdogConstantTests {
    /// Larger than every bound it backstops, on purpose: firing first would abort
    /// handshakes that are still legitimately inside their own budgets.
    ///
    /// The SSH bridge's ready deadline is the 30 s one (`SSHProcessTransport`)
    /// that a handshake actually spends its time in before the endpoint protocol
    /// even starts.
    @Test("the watchdog outlives every deadline it backstops")
    @MainActor
    func outlivesTheDeadlinesBelow() {
        #expect(ConnectionLimits.handshakeWatchdog > ConnectionLimits.handshakeTimeout)
        #expect(ConnectionLimits.handshakeWatchdog > 30, "must exceed the SSH ready handshake")
    }
}
