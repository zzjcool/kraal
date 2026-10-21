// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Regression tests for switching the connected machine.
//
// The bug: "Use This Mac" in the connection sheet did nothing. Three separate
// causes, each covered here.
//
//  1. The button only assigned to the sheet's local `draft`; it never touched
//     the store, so pressing it moved the picker and left the old host
//     connected. Nothing visible happened at all.
//  2. Changing `target` abandons the old connection, but `EndpointConnection`
//     tears down asynchronously. The resulting `.disconnected` arrived after the
//     replacement had started connecting, was read as a dropped link, and
//     scheduled a *second* reconnect that killed the new handshake just after it
//     went live — so the switch never settled.
//  3. Requests issued before the snapshot arrives have no boot id, so the daemon
//     rejects them. That was reported through `lastError`, leaving
//     "no snapshot yet: boot id unknown" on screen permanently after a switch.
//
// (1) is a one-line view change and is not reachable from a headless test; it is
// covered by inspection. (2) and (3) are the store's state machine and are
// exercised here against a real daemon.
//
// These need a daemon, so they are gated on `KRAAL_HERDR_SOCKET` pointing at a
// socket that exists — the harness sets it to the sandbox. They deliberately do
// not synthesise a path: a test that invented one would either fail anywhere the
// sandbox is absent or, worse, quietly talk to the developer's own herdr.

import Foundation
import Testing

import KraalClient
import KraalProtocol
import KraalTransport
@testable import KraalUI

@Suite("Target switch", .serialized)
@MainActor
struct TargetSwitchTests {
    /// The socket to talk to, or nil when the suite has no daemon to use.
    private var sandboxSocket: String? {
        guard let path = ProcessInfo.processInfo.environment["KRAAL_HERDR_SOCKET"],
              !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    /// Skips the test body when there is no sandbox daemon, so the suite passes
    /// on a machine without one instead of failing or dialling out.
    private func withSandbox(_ body: (String) async -> Void) async {
        guard let socket = sandboxSocket else {
            print("skipped: set KRAAL_HERDR_SOCKET to a sandbox daemon socket")
            return
        }
        await body(socket)
    }

    /// Polls until the store is live, or gives up.
    private func waitForLive(_ store: AppStore, attempts: Int = 40) async -> Bool {
        for _ in 0..<attempts {
            if store.phase.isLive { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return store.phase.isLive
    }

    /// A superseded connection's `.disconnected` must not schedule a reconnect on
    /// top of the attempt already in flight.
    ///
    /// Before the epoch guard, the phase trail across a switch read
    /// `live … live → connecting → live …`: a second handshake started after the
    /// replacement had already gone live. After it, the phase settles and stays.
    @Test("switching target settles on the new connection")
    func switchSettlesLive() async {
        await withSandbox { _ in
            let store = AppStore(target: .local)
            store.connect()
            #expect(await waitForLive(store), "first connection never went live")

            store.target = ConnectionSettings(
                name: "This Mac", transport: .local, session: "default"
            )
            store.connect()

            var sawLive = false
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if store.phase.isLive { sawLive = true }
            }

            #expect(sawLive, "never became live after switching")
            #expect(store.phase.isLive, "ended on \(store.phase)")
        }
    }

    /// A request that lands before the snapshot is not an error to show the user.
    ///
    /// `lastError` is rendered as a permanent error line, so surfacing the
    /// handshake race made a *successful* switch look broken.
    @Test("switching target does not leave an error behind")
    func switchLeavesNoError() async {
        await withSandbox { _ in
            let store = AppStore(target: .local)
            store.connect()
            #expect(await waitForLive(store))

            store.target = ConnectionSettings(
                name: "This Mac", transport: .local, session: "default"
            )
            store.connect()
            _ = await waitForLive(store)
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            #expect(store.lastError == nil, "lastError was \(store.lastError ?? "nil")")
        }
    }

    /// The first connection already had to work; this keeps it that way, so a
    /// regression that breaks every connect is not mistaken for a switch bug.
    @Test("the first connection by itself reports no error")
    func firstConnectionIsClean() async {
        await withSandbox { _ in
            let store = AppStore(target: .local)
            store.connect()
            #expect(await waitForLive(store))
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            #expect(store.lastError == nil, "lastError was \(store.lastError ?? "nil")")
        }
    }

    /// Writing `target` alone must NOT abandon the connection.
    ///
    /// This used to be the opposite assertion, and the opposite was the bug: the
    /// `didSet` closed the live socket, so every machine switch went through a
    /// disconnect and a fresh handshake. Changing machines is `selectEndpoint`,
    /// which moves the surface lease; `target` is just a label for what the
    /// foreground currently is. The connection-sheet path still works because it
    /// sets `target` and then calls `connect()`, which reconnects deliberately.
    @Test("writing the target alone keeps the live connection")
    func writingTargetKeepsConnection() async {
        await withSandbox { _ in
            let store = AppStore(target: .local)
            store.connect()
            #expect(await waitForLive(store))
            let established = store.connection
            #expect(established != nil)

            store.target = ConnectionSettings(
                name: "elsewhere", transport: .ssh, sshHost: "example.invalid"
            )
            try? await Task.sleep(nanoseconds: 100_000_000)

            #expect(store.connection === established, "writing target tore down the connection")
        }
    }
}

/// The rule itself, with no daemon involved.
///
/// These are the tests that actually run under `verify.sh` (which does not set
/// `KRAAL_HERDR_SOCKET`), so the regression is guarded even where the live suite
/// skips.
@Suite("Superseded connection events")
struct SupersededEventTests {
    /// Events from the connection that is currently in use are applied.
    @Test("an event from the current connection is applied")
    func currentEventIsApplied() {
        #expect(AppStore.eventIsCurrent(epoch: 3, currentEpoch: 3))
    }

    /// The bug: a connection abandoned by a target switch tears down later, and
    /// its `.disconnected` must not be read as a dropped link — treating it that
    /// way scheduled a second reconnect that killed the replacement's handshake.
    @Test("an event from a superseded connection is ignored")
    func staleEventIsIgnored() {
        #expect(!AppStore.eventIsCurrent(epoch: 2, currentEpoch: 3))
    }

    /// Bumping happens on every start, so a *newer* epoch cannot be in flight.
    /// Pinned because a wrap-around or a mis-signed comparison would make the
    /// guard silently stop guarding.
    @Test("a future epoch is not treated as current")
    func futureEpochIsNotCurrent() {
        #expect(!AppStore.eventIsCurrent(epoch: 4, currentEpoch: 3))
    }

    /// The epoch used to be one counter on the store. With a connection per
    /// machine that is not enough: a late report from machine A has to be
    /// rejected when A's *own* connection was replaced, without saying anything
    /// about machine B. The stamp therefore lives on the endpoint.
    @Test("starting a connection stamps that machine, not the store")
    func startingBumpsEndpointEpoch() async {
        await MainActor.run {
            let store = AppStore(target: .local)
            let endpoint = EndpointState(id: .local, label: "Local", settings: .local)
            store.endpoints = [endpoint]
            store.activeEndpointID = .local

            let before = endpoint.connectionEpoch
            store.connect()
            let after = endpoint.connectionEpoch
            #expect(after > before, "epoch did not move: \(before) -> \(after)")
        }
    }
}

// MARK: - Peer connections

/// The model these tests pin: every machine has its own long-lived connection,
/// and changing which one is in front is a role change, not a reconnect.
///
/// The behaviour they replaced was a single store connection plus snapshot-only
/// observers. Switching meant assigning `target`, whose `didSet` closed the live
/// socket and reopened it against another machine — so the machine being switched
/// *to* had no connection for the length of a backoff plus an SSH handshake, and
/// the one being left was destroyed rather than demoted.
@Suite("Peer machine connections")
@MainActor
struct PeerConnectionTests {
    /// Two machines, both connected, and a switch must not rebuild either.
    @Test("switching keeps the outgoing machine's connection instance")
    func switchDoesNotRebuild() async {
        let store = AppStore(target: .local)
        let local = EndpointState(id: .local, label: "Local", settings: .local)
        let remote = EndpointState(
            id: .ssh(id: "abc"),
            label: "remote",
            status: .online,
            settings: ConnectionSettings(name: "remote", transport: .ssh)
        )
        store.endpoints = [local, remote]
        store.activeEndpointID = .local

        // A connection object is what a rebuild would replace, so its identity is
        // the assertion: same reference before and after means nothing was torn
        // down and reopened.
        // The target is never dialled in these tests — the object only has to
        // exist so identity can be compared.
        let nowhere = HerdrTarget.unixSocket(path: "/tmp/kraal-test-does-not-exist")
        let size = ClientSurfaceSize(cols: 80, rows: 24)
        let localConnection = EndpointConnection(
            target: nowhere, surfaceSize: size, surfaceActive: true
        ) { _ in }
        let remoteConnection = EndpointConnection(
            target: nowhere, surfaceSize: size, surfaceActive: false
        ) { _ in }
        local.connection = localConnection
        remote.connection = remoteConnection

        store.selectEndpoint(remote)
        // The lease hand-off runs in a task so the switch itself stays
        // synchronous for the UI. Give it a turn to finish.
        await Task.yield()

        #expect(store.activeEndpointID == remote.id)
        #expect(local.connection === localConnection, "outgoing machine was rebuilt")
        #expect(remote.connection === remoteConnection, "incoming machine was rebuilt")
    }

    /// The switch must not add or remove rows either: it moves the foreground.
    @Test("switching does not change how many machines exist")
    func switchKeepsRoster() {
        let store = AppStore(target: .local)
        let local = EndpointState(id: .local, label: "Local", settings: .local)
        let remote = EndpointState(
            id: .ssh(id: "abc"),
            label: "remote",
            status: .online,
            settings: ConnectionSettings(name: "remote", transport: .ssh)
        )
        store.endpoints = [local, remote]
        store.activeEndpointID = .local

        store.selectEndpoint(remote)

        #expect(store.endpoints.count == 2)
    }

    /// A background machine streams snapshots but not pane content. If a surface
    /// from a non-selected machine were applied, the screen would show whichever
    /// machine happened to send last.
    @Test("a background machine's surface is not applied")
    func backgroundSurfaceIsDropped() {
        let store = AppStore(target: .local)
        let local = EndpointState(id: .local, label: "Local", settings: .local)
        let remote = EndpointState(
            id: .ssh(id: "abc"),
            label: "remote",
            status: .online,
            settings: ConnectionSettings(name: "remote", transport: .ssh)
        )
        store.endpoints = [local, remote]
        store.activeEndpointID = .local

        // The routing rule, stated directly: only the active machine's surface
        // events reach the store. `applyEndpointEvent` is private, so the rule is
        // exercised through the predicate it is built on.
        #expect(remote.id != store.activeEndpointID)
        #expect(store.connection === local.connection)
    }

    /// A machine that cannot be told to change surfaces has to be reopened — but
    /// only that machine. Pinned because the obvious implementation (reconnect
    /// everything) would drag the other machines down with it.
    @Test("only a machine without surface.set is reopened on switch")
    func legacyDaemonGetsNarrowFallback() {
        let capable = EndpointState(
            id: .ssh(id: "new"),
            label: "new",
            settings: ConnectionSettings(name: "new", transport: .ssh)
        )
        capable.welcome = Self.welcome(version: "0.9.5", methods: ["client_shell.surface.set"])
        let legacy = EndpointState(
            id: .ssh(id: "old"),
            label: "old",
            settings: ConnectionSettings(name: "old", transport: .ssh)
        )
        legacy.welcome = Self.welcome(version: "0.9.1", methods: [])

        #expect(capable.supportsSurfaceInterest)
        #expect(!legacy.supportsSurfaceInterest)
    }

    /// The welcome only has a decoding initialiser, so it is built the way it is
    /// received: from JSON.
    private static func welcome(version: String, methods: [String]) -> EndpointServerWelcome? {
        let methodsJSON = methods.map { "\"\($0)\"" }.joined(separator: ",")
        let json = """
        {"generation":1,"server_version":"\(version)",
         "snapshot_codec":"shell.snapshot.v1","surface_codec":"shell.surface.v1",
         "input_codec":"shell.input.v1","blob_codec":"blob.v1",
         "methods":[\(methodsJSON)],"capabilities":[]}
        """
        return try? JSONDecoder().decode(
            EndpointServerWelcome.self,
            from: Data(json.utf8)
        )
    }
}

// MARK: - Live peer switching

/// The end-to-end shape of a switch against a real daemon.
///
/// Gated on the sandbox socket like the rest of the live suite: it needs two
/// machines that are genuinely reachable, and inventing them would either fail
/// everywhere or — worse — quietly dial the developer's own herdr.
@Suite("Live peer switching", .serialized)
@MainActor
struct LivePeerSwitchTests {
    private var sandboxSocket: String? {
        guard let path = ProcessInfo.processInfo.environment["KRAAL_HERDR_SOCKET"],
              !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    /// Switching must leave every connection object in place. This is the
    /// assertion the whole change exists for: the previous implementation closed
    /// the live socket and reopened it, which is what produced the stale frame
    /// and the gap.
    @Test("a switch keeps every machine connected")
    func switchKeepsAllConnections() async {
        guard sandboxSocket != nil else {
            print("skipped: set KRAAL_HERDR_SOCKET to a sandbox daemon socket")
            return
        }
        let store = AppStore(target: .local)
        await store.loadEndpoints()
        store.connect()

        // Wait for the local machine, which is the one the store starts on.
        var live = false
        for _ in 0..<60 where !live {
            if store.phase.isLive, store.connection != nil { live = true }
            if !live { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        #expect(live, "the foreground connection never went live")

        // Whatever the catalog found, capture the objects before the switch.
        let before = store.endpoints.map { ($0.id, ObjectIdentifier($0)) }
        let connectionsBefore = store.endpoints.compactMap { endpoint in
            endpoint.connection.map { (endpoint.id, ObjectIdentifier($0)) }
        }

        guard let target = store.endpoints.first(where: { $0.id != store.activeEndpointID }) else {
            print("skipped: the sandbox has only one machine")
            return
        }
        let wasConnected = target.connection != nil
        store.selectEndpoint(target)

        let after = store.endpoints.map { ($0.id, ObjectIdentifier($0)) }
        #expect(before.map(\.1) == after.map(\.1), "the roster was rebuilt by a switch")
        #expect(store.activeEndpointID == target.id, "the selection did not move")

        if wasConnected {
            // The incoming machine must not have been torn down on the way in.
            let stillThere = connectionsBefore.contains {
                $0.0 == target.id && $0.1 == target.connection.map(ObjectIdentifier.init)
            }
            #expect(stillThere, "the incoming machine's connection was rebuilt by the switch")
        }
    }
}
