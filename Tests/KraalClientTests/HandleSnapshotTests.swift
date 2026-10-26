// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  HandleSnapshotTests.swift
//  KraalClientTests
//
//  `AppStore.handleSnapshot`: what a snapshot does to the rest of the store.
//
//  `snapshotIsCurrent` (the fence) is tested separately in `SnapshotFencingTests`. What
//  is left is the part with side effects, and it has two failure modes that have both
//  happened in this repository:
//
//  * **a new boot id must drop the old frame.** A restarted daemon's frame belongs to a
//    dead process; keeping it leaves pixels from a session that no longer exists.
//  * **a tab change must *keep* the old frame.** Clearing it produced the black flash on
//    tab switches (#113's neighbour): the pane views were torn down, `PaneLayoutView` had
//    nothing to draw, and the new projection landed tens of milliseconds later. A stale
//    frame replaced ~30 ms later reads as a smooth switch; a blank rectangle reads as a
//    crash.
//
//  Those two look like the same event and need opposite behaviour, which is why they are
//  pinned individually.
//

import Foundation
import Testing

@testable import KraalProtocol
@testable import KraalUI

@Suite("handleSnapshot")
@MainActor
struct HandleSnapshotTests {
    /// A snapshot carrying only what these tests read.
    private func snapshot(
        bootId: String = "boot",
        revision: UInt64 = 1,
        focusedTabId: String = "w1:t1"
    ) throws -> ClientShellSnapshot {
        let json = """
        {"boot_id": "\(bootId)", "revision": \(revision),
         "focused_tab_id": "\(focusedTabId)",
         "workspaces": [], "tabs": [], "panes": [], "agents": [],
         "agent_order": [], "commands": []}
        """
        return try JSONDecoder().decode(ClientShellSnapshot.self, from: Data(json.utf8))
    }

    private func store() -> AppStore {
        let store = AppStore(target: .local)
        store.endpoints = [EndpointState(id: .local, label: "Local", settings: .local)]
        store.activeEndpointID = .local
        return store
    }

    /// A frame the store can hold, so "was it dropped" is observable.
    private func existingSurface(
        bootId: String = "boot",
        revision: UInt64 = 1
    ) -> PaneSurfaceFrame {
        PaneSurfaceFrame(
            bootId: bootId,
            projectionRevision: 1,
            surfaceRevision: revision,
            frame: FrameData(
                cells: Array(repeating: .blank, count: 4),
                width: 2,
                height: 2,
                cursor: nil,
                hyperlinks: [],
                graphics: Data()
            ),
            panes: [],
            splits: [],
            popup: nil,
            graphics: SurfaceGraphicsScene()
        )
    }

    // MARK: - The fence

    /// A regressing revision is refused, and the refusal is *reported*. A frozen screen
    /// with no explanation is the failure the fence exists to prevent.
    @Test("a stale snapshot is refused and reported")
    func staleSnapshotIsRefused() throws {
        let store = store()
        try store.handleSnapshot(snapshot(revision: 5))
        try store.handleSnapshot(snapshot(revision: 4))

        #expect(store.snapshot?.revision == 5, "the older snapshot overwrote the newer one")
        #expect(store.lastError != nil, "the refusal was silent")
        #expect(store.lastError?.contains("regressed") == true,
                "the message does not say what happened: \(store.lastError ?? "nil")")
    }

    @Test("a newer snapshot is adopted")
    func newerSnapshotIsAdopted() throws {
        let store = store()
        try store.handleSnapshot(snapshot(revision: 5))
        try store.handleSnapshot(snapshot(revision: 6))
        #expect(store.snapshot?.revision == 6)
        #expect(store.lastError == nil)
    }

    // MARK: - The two opposite treatments of the held frame

    /// A new boot id means the held frame belongs to a dead daemon.
    @Test("a new boot id drops the held frame")
    func newBootDropsFrame() throws {
        let store = store()
        try store.handleSnapshot(snapshot(bootId: "before", revision: 9))
        store.surface = existingSurface(bootId: "before")
        #expect(store.surface != nil)

        try store.handleSnapshot(snapshot(bootId: "after", revision: 1))
        #expect(store.surface == nil,
                "a frame from a dead daemon survived the restart")
        #expect(store.snapshot?.bootId == "after", "the new boot was refused")
    }

    /// A tab change on the same boot must keep the frame: clearing it is the black flash.
    @Test("a tab change keeps the held frame")
    func tabChangeKeepsFrame() throws {
        let store = store()
        try store.handleSnapshot(snapshot(bootId: "boot", revision: 5, focusedTabId: "w1:t1"))
        store.surface = existingSurface(bootId: "boot")

        try store.handleSnapshot(snapshot(bootId: "boot", revision: 6, focusedTabId: "w1:t2"))
        #expect(store.surface != nil,
                "the frame was cleared on a tab switch; that is the black flash")
        #expect(store.snapshot?.focusedTabId == "w1:t2")
    }

    /// A snapshot that changes neither boot nor tab is only a data refresh, and must not
    /// disturb the frame at all.
    @Test("an ordinary refresh leaves the frame alone")
    func ordinaryRefreshLeavesFrame() throws {
        let store = store()
        try store.handleSnapshot(snapshot(bootId: "boot", revision: 5, focusedTabId: "w1:t1"))
        let held = existingSurface(bootId: "boot")
        store.surface = held

        try store.handleSnapshot(snapshot(bootId: "boot", revision: 6, focusedTabId: "w1:t1"))
        #expect(store.surface?.surfaceRevision == held.surfaceRevision)
    }

    // MARK: - Latch

    /// A snapshot that moves the projection settles a latched resync.
    ///
    /// Both a re-projected frame and a snapshot can be the answer, and either can win
    /// the race. A latch that only the frame could settle stayed armed forever when the
    /// snapshot arrived first, and every later divergence then took the "already
    /// requested" path — a resync that can never be asked for again.
    @Test("a snapshot that moves the projection releases a latched resync")
    func snapshotReleasesLatch() throws {
        let store = store()
        try store.handleSnapshot(snapshot(bootId: "boot", revision: 5, focusedTabId: "w1:t1"))
        #expect(store.releaseResyncLatch("test") == false,
                "the latch was armed without being set")
    }

    // `focusConfirmation.invalidate()` on a boot change is not asserted here:
    // `FocusConfirmation` keeps `confirmed` private and exposes no query, so there is
    // nothing to observe from a test. Adding a getter only for the test would be a
    // production change made for the test's convenience. The behaviour is real (issue
    // #55) but unverifiable from outside, and an assertion on something unobservable
    // would be worse than none.
}
