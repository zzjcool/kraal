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

    /// Changing `target` must abandon the old connection; otherwise the button
    /// could set the target and still keep talking to the old host.
    @Test("changing target abandons the previous connection")
    func changingTargetAbandonsConnection() async {
        await withSandbox { _ in
            let store = AppStore(target: .local)
            store.connect()
            #expect(await waitForLive(store))
            #expect(store.connection != nil)

            store.target = ConnectionSettings(
                name: "elsewhere", transport: .ssh, sshHost: "example.invalid"
            )
            try? await Task.sleep(nanoseconds: 100_000_000)

            #expect(store.connection == nil, "the old connection was kept")
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

    /// Every new attempt bumps the epoch, so a switch produces a different stamp
    /// for the old and the new connection.
    @Test("starting a connection changes the stamp")
    func startingBumpsEpoch() async {
        await MainActor.run {
            let store = AppStore(target: .local)
            let before = store.connectionEpoch
            store.connect()
            let after = store.connectionEpoch
            #expect(after > before, "epoch did not move: \(before) -> \(after)")
        }
    }
}
