// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  SnapshotFencingTests.swift
//  KraalClientTests
//
//  `AppStore.snapshotIsCurrent`: which incoming snapshot wins.
//
//  The function was written to be testable ("split out as a pure function so the rule
//  is testable without a daemon") but only its *caller* was ever exercised, through a
//  handshake test. The rule itself has three branches and one of them is the dangerous
//  one: a daemon restart resets `revision` to 1, so a revision-only comparison throws
//  away every snapshot after a restart and the window freezes on the last pre-restart
//  frame — with no error anywhere, because the fence is working as written.
//

import Foundation
import Testing

@testable import KraalUI

@Suite("Snapshot fencing")
struct SnapshotFencingTests {
    /// Nothing adopted yet, so anything is better than nothing.
    @Test("the first snapshot is always accepted")
    func firstSnapshotWins() {
        #expect(AppStore.snapshotIsCurrent(
            incomingRevision: 1,
            incomingBootId: "boot",
            currentRevision: nil,
            currentBootId: nil
        ))
    }

    /// A boot id without a revision (or the reverse) is not a complete identity, so the
    /// store cannot claim the incoming frame is old. Accepting is the safe answer:
    /// a redraw costs a frame, rejecting costs a frozen window.
    @Test("a half-known current identity accepts")
    func halfKnownIdentityAccepts() {
        #expect(AppStore.snapshotIsCurrent(
            incomingRevision: 1,
            incomingBootId: "new",
            currentRevision: 5,
            currentBootId: nil
        ))
        #expect(AppStore.snapshotIsCurrent(
            incomingRevision: 1,
            incomingBootId: "new",
            currentRevision: nil,
            currentBootId: "old"
        ))
    }

    /// A newer revision on the same boot is accepted, an equal one too (it is the same
    /// state, and rejecting it would drop a legitimate re-send).
    @Test("same boot accepts newer and equal revisions")
    func sameBootAccepts() {
        #expect(AppStore.snapshotIsCurrent(
            incomingRevision: 6,
            incomingBootId: "boot",
            currentRevision: 5,
            currentBootId: "boot"
        ))
        #expect(AppStore.snapshotIsCurrent(
            incomingRevision: 5,
            incomingBootId: "boot",
            currentRevision: 5,
            currentBootId: "boot"
        ))
    }

    /// Out-of-order delivery on the same boot is the case the fence exists for: a
    /// stale frame must not overwrite a newer one, or the UI goes backwards.
    @Test("same boot rejects an older revision")
    func sameBootRejectsOlder() {
        #expect(!AppStore.snapshotIsCurrent(
            incomingRevision: 4,
            incomingBootId: "boot",
            currentRevision: 5,
            currentBootId: "boot"
        ))
    }

    /// **The dangerous branch.** A restarted daemon reuses `bootId = "boot"` but starts
    /// `revision` at 1, so a revision-only fence discards everything after the restart.
    /// The comparison must be boot-first.
    @Test("a different boot id accepts even a lower revision")
    func differentBootAcceptsLowerRevision() {
        #expect(AppStore.snapshotIsCurrent(
            incomingRevision: 1,
            incomingBootId: "after-restart",
            currentRevision: 900,
            currentBootId: "before-restart"
        ))
    }

    /// The rule is stated in terms of `>=`, not `>`: an identical re-send is accepted.
    /// Worth pinning because flipping it to `>` looks harmless and would silently drop
    /// the re-sends the resync path depends on.
    @Test("an identical snapshot is not treated as stale")
    func identicalIsAccepted() {
        for revision in [UInt64(0), 1, 1_000_000] {
            #expect(AppStore.snapshotIsCurrent(
                incomingRevision: revision,
                incomingBootId: "boot",
                currentRevision: revision,
                currentBootId: "boot"
            ))
        }
    }
}
