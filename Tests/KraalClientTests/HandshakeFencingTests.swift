// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Handshake and snapshot hardening, ported from the two upstream clients.
//
// Sources (all Apache-2.0, see NOTICE):
//   * `herdr-gpui/crates/herdr-client/src/tests/version_mismatch.rs`
//     (`legacy_welcome_means_the_daemon_predates_the_endpoint`,
//      `generation_says_which_side_is_older_even_in_a_rejection`)
//   * `herdr-gpui/crates/herdr-client/src/tests/session_state.rs`
//     (`session_deadlines_and_snapshot_revision_fence`)
//   * `rootshell/rootshellTests/HerdrProtocolTests.swift`
//     (`testVersionsBelowMinimumAreRefused`, `testSessionSnapshotRejectsDuplicateTopologyIDs`)
//   * `herdr-gpui/crates/herdr-client/src/tests/framing.rs`
//     (`geometry_and_frame_reader_limits`)
//
// The common thread: a daemon that is too old, a snapshot that went backwards,
// and a grid the daemon cannot render all currently look *fine* to this client.
// Each one produces a wrong screen rather than an error, which is why upstream
// tests them and we did not.

import Foundation
import Testing

import KraalClient
import KraalProtocol
@testable import KraalUI

@Suite("Handshake compatibility")
struct CompatibilityPortTests {
    private func welcome(_ json: String) throws -> EndpointServerWelcome {
        try JSONDecoder().decode(EndpointServerWelcome.self, from: Data(json.utf8))
    }

    private func compatibleJSON(
        generation: UInt32 = 1,
        version: String = "0.9.4",
        error: String = "null"
    ) -> String {
        """
        {
          "generation": \(generation),
          "server_version": "\(version)",
          "snapshot_codec": "shell.snapshot.v1",
          "surface_codec": "shell.surface.v1",
          "input_codec": "shell.input.semantic.v1",
          "blob_codec": "shell.blob.v1",
          "methods": ["client_shell.surface.set"],
          "capabilities": ["surface_interest", "health_check"],
          "error": \(error)
        }
        """
    }

    /// `version_mismatch.rs:40` `generation_says_which_side_is_older_even_in_a_rejection`.
    ///
    /// Upstream: the *generation* decides which side is outdated, even when the
    /// daemon also attached an error. A rejected handshake with a newer
    /// generation is an old client, and the user has to update Kraal — telling
    /// them to update Herdr sends them to the wrong machine.
    ///
    /// RED AS PORTED: `evaluate` checks `welcome.error` first, so this reports a
    /// generic rejection.
    @Test("generation, not the error code, says which side is older")
    func generationBeatsError() throws {
        let parsed = try welcome(compatibleJSON(
            generation: 2,
            error: #"{"code": "unsupported_generation", "message": "no"}"#
        ))
        let result = Compatibility.evaluate(parsed)
        #expect(result == .clientTooOld(serverVersion: "0.9.4", generation: 2), "got \(result)")
    }

    /// The other direction: an *older* daemon's generation must be reported as
    /// "update Herdr", and `serverVersion` has to survive into the message so the
    /// user can see what they are running.
    ///
    /// RED AS PORTED: the `.serverTooOld` case exists but `evaluate` never
    /// produces it — a lower generation currently falls into `clientTooOld`,
    /// which tells the user to update the wrong thing.
    @Test("an older daemon is reported as too old")
    func olderDaemon() throws {
        let parsed = try welcome(compatibleJSON(generation: 0, version: "0.8.2"))
        let result = Compatibility.evaluate(parsed)
        guard case let .serverTooOld(version) = result else {
            Issue.record("expected .serverTooOld, got \(result)")
            return
        }
        #expect(version == "0.8.2")
    }

    /// `rootshell testVersionsBelowMinimumAreRefused`: a daemon that speaks the
    /// right generation but is older than the client's minimum must be refused
    /// with advice, not accepted and then driven into a half-working state.
    ///
    /// RED AS PORTED: nothing parses `server_version`, so `0.4.0` is accepted.
    @Test("a version below the client minimum is refused")
    func versionFloor() throws {
        for version in ["0.4.0", "0.8.9", "not-a-version"] {
            let parsed = try welcome(compatibleJSON(version: version))
            #expect(!Compatibility.evaluate(parsed).isOK, "\(version) was accepted")
        }
        for version in ["0.9.0", "0.9.4", "1.0.0+build.7"] {
            let parsed = try welcome(compatibleJSON(version: version))
            #expect(Compatibility.evaluate(parsed).isOK, "\(version) was refused")
        }
    }

    /// `framing.rs:24` `geometry_and_frame_reader_limits`, client half: a grid the
    /// daemon cannot render must be refused locally. The daemon's own limit is
    /// 4096 per axis and 1 000 000 cells total.
    ///
    /// RED AS PORTED: `resizeSurface` only checks for zero.
    @Test("an unrenderable grid is refused by the store")
    @MainActor
    func gridLimit() {
        let store = AppStore()
        let before = store.surfaceSize
        // Per-axis limit.
        store.resizeSurface(cols: 4097, rows: 24)
        #expect(store.surfaceSize == before, "4097 columns was accepted")
        // Total-cell limit: 1001 x 1000 = 1 001 000.
        store.resizeSurface(cols: 1001, rows: 1000)
        #expect(store.surfaceSize == before, "1 001 000 cells was accepted")
    }
}

@Suite("Snapshot fencing")
struct SnapshotFencePortTests {
    private static func snapshotJSON(revision: UInt64, panes: String? = nil) -> Data {
        let paneList = panes ?? """
            [{"pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1", "focused": true}]
            """
        let json = """
        {
          "boot_id": "boot-v1",
          "revision": \(revision),
          "update_install_command": "",
          "worktree_directory": "",
          "tab_bar_right": [],
          "tab_bar_right_separator": " ",
          "agent_order": [],
          "workspaces": [{
            "workspace_id": "w1", "active_tab_id": "w1:t1", "new_workspace_cwd": "/",
            "number": 1, "label": "repo", "custom_label": false,
            "tokens": [], "focused": true, "agent_status": "working"
          }],
          "tabs": [{
            "tab_id": "w1:t1", "workspace_id": "w1", "number": 1, "label": "main",
            "custom_label": false, "zoomed": false, "focused": true, "agent_status": "working"
          }],
          "panes": \(paneList),
          "agents": [],
          "commands": []
        }
        """
        return Data(json.utf8)
    }

    private static func snapshot(revision: UInt64) throws -> ClientShellSnapshot {
        try JSONDecoder().decode(ClientShellSnapshot.self, from: snapshotJSON(revision: revision))
    }

    /// `session_state.rs:104` `session_deadlines_and_snapshot_revision_fence`.
    ///
    /// A snapshot whose revision went backwards belongs to a dead projection. The
    /// store must keep the newer one: every surface is fenced on
    /// `projectionRevision == snapshot.revision`, so adopting a regressed
    /// revision makes every live frame look stale at once.
    ///
    /// RED AS PORTED: `handleSnapshot` assigns unconditionally.
    @Test("a snapshot revision regression is not published")
    @MainActor
    func revisionRegression() throws {
        let store = AppStore()
        store.handleSnapshot(try Self.snapshot(revision: 7))
        store.handleSnapshot(try Self.snapshot(revision: 6))
        #expect(store.snapshot?.revision == 7, "revision regressed to \(store.snapshot?.revision ?? 0)")
    }

    /// The same revision arriving again is normal (a repaint of the sidebar) and
    /// must not be mistaken for a regression.
    @Test("an equal revision is accepted")
    @MainActor
    func equalRevision() throws {
        let store = AppStore()
        store.handleSnapshot(try Self.snapshot(revision: 7))
        store.handleSnapshot(try Self.snapshot(revision: 7))
        #expect(store.snapshot?.revision == 7)
    }

    /// `rootshell testSessionSnapshotRejectsDuplicateTopologyIDs`: duplicate
    /// identifiers in a snapshot make pane lookup ambiguous — every hit test and
    /// every surface slice would pick whichever entry happened to be first.
    ///
    /// RED AS PORTED: nothing validates uniqueness.
    @Test("duplicate pane ids are rejected at decode time")
    func duplicatePaneIDs() {
        let duplicated = Self.snapshotJSON(
            revision: 1,
            panes: """
                [
                  {"pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1", "focused": true},
                  {"pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1", "focused": false}
                ]
                """
        )
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(ClientShellSnapshot.self, from: duplicated)
        }
    }
}

@Suite("Connection limits")
struct ConnectionLimitTests {
    /// `herdr-gpui/crates/herdr-client/src/limits.rs` and
    /// `herdr/src/client/endpoint/health.rs` pin these numbers; the daemon
    /// assumes every client probes on the same schedule, so drifting here gets a
    /// healthy connection torn down (too short) or a dead one kept forever (too
    /// long).
    @Test("timing constants match the reference client")
    @MainActor
    func limits() {
        #expect(ConnectionLimits.quietPing == 5)
        #expect(ConnectionLimits.pingTimeout == 10)
        #expect(ConnectionLimits.handshakeTimeout == 10)
        #expect(ConnectionLimits.commandTimeout == 60)
        #expect(ConnectionLimits.maxResponseBytes == 8 * 1024 * 1024)
        #expect(FrameLimits.maxFrameSize == 2 * 1024 * 1024)
        #expect(FrameLimits.maxGraphicsFrameSize == 32 * 1024 * 1024)
    }

    /// `herdr/src/client/endpoint/supervisor.rs:1132` `retry_backoff_is_bounded`:
    /// the delay doubles but stops at a ceiling, so a daemon that stays down does
    /// not turn into a reconnect storm, and one that comes back is retried within
    /// half a minute.
    ///
    /// Asserted through `phase`, because `retryAt` is what the UI counts down.
    ///
    /// The backoff lives on the endpoint, not the store (every machine keeps its
    /// own connection), so the store needs one before it can schedule a retry.
    ///
    /// This was red until #9: the delay was computed twice from two reads of one
    /// counter — `scheduleReconnect` derived `attempt`/`retryAt` before
    /// `scheduleEndpointRetry` incremented it, so the countdown lagged the real
    /// sleep. `scheduleEndpointRetry` is now the single source of both.
    @Test("reconnect backoff doubles and is capped")
    @MainActor
    func backoffIsBounded() {
        let store = AppStore(target: .local)
        store.endpoints = [EndpointState(id: .local, label: "Local", settings: .local)]
        store.activeEndpointID = .local
        var delays: [Double] = []
        for _ in 0 ..< 6 {
            store.scheduleReconnect()
            guard case let .reconnecting(_, retryAt) = store.phase else {
                Issue.record("expected .reconnecting, got \(store.phase)")
                return
            }
            delays.append(retryAt.timeIntervalSinceNow)
        }
        // 1, 2, 4, 8, 16 then capped at 30.
        let expected: [Double] = [1, 2, 4, 8, 16, 30]
        for (index, expectedDelay) in expected.enumerated() {
            // The scheduled instant is a fraction of a second in the past by the
            // time it is read, so compare with a tolerance.
            #expect(
                abs(delays[index] - expectedDelay) < 0.2,
                "attempt \(index + 1) scheduled in \(delays[index])s, expected \(expectedDelay)s"
            )
        }
        store.intentionalStop = true
    }
}
