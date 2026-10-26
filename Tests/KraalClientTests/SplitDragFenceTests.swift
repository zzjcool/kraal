// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// A divider drag names a divider by its `path`, and a path is a *position in a
// tree* rather than an identity. Close one pane, or split another, and every
// path below it can come to name a different border — at which point
// `layout.set_split_ratio` still succeeds, still answers `ok`, and moves a
// divider the user never touched.
//
// Nothing on either side reports this. The daemon cannot: the path is valid. The
// store cannot detect it from the answer: there is no error in it. So the guard
// has to be a comparison made *before* each send, and these tests are what keep
// it there.
//
// Ported from `herdr-gpui/crates/herdr-gpui/src/terminal/splits.rs`
// (`topology`) and the guards in `window/mouse.rs` (`flush_split`). Two
// behaviours from upstream are asserted deliberately:
//
//   * movement is *not* a structural change — a divider that moves must not end
//     its own drag, so `position`, `area` and `hitRect` stay out of the fence;
//   * the drag ends *silently* — no status error, because the user did nothing
//     wrong and has nothing to act on.

import CoreGraphics
import Foundation
import Testing

@testable import KraalProtocol
@testable import KraalUI

@Suite("Divider drag fencing")
@MainActor
struct SplitDragFenceTests {
    // MARK: - Fixtures

    private func rect(_ column: Int, _ row: Int, _ width: Int, _ height: Int) -> SurfaceRect {
        SurfaceRect(originX: UInt16(column), originY: UInt16(row),
                    width: UInt16(width), height: UInt16(height))
    }

    private func pane(_ id: String, _ box: SurfaceRect) -> PaneSurfacePane {
        PaneSurfacePane(
            paneId: id, contentRevision: 1, rect: box, innerRect: box,
            scrollbarRect: nil, scroll: nil, focused: false,
            mouseReporting: false, sgrPixelMouse: false, alternateScreenActive: false,
            pixelWidth: 100, pixelHeight: 100
        )
    }

    private func split(
        _ direction: PaneSurfaceSplitDirection,
        path: [Bool],
        position: UInt16 = 40,
        area: SurfaceRect = SurfaceRect(originX: 0, originY: 0, width: 80, height: 24)
    ) -> PaneSurfaceSplit {
        PaneSurfaceSplit(
            direction: direction, position: position, area: area,
            hitRect: area, path: path
        )
    }

    /// Two panes side by side, one horizontal divider at column 40.
    private func sideBySide(
        at position: UInt16 = 40,
        panes: [String] = ["w1:p1", "w1:p2"]
    ) -> PaneSurfaceFrame {
        frame(
            panes: panes,
            splits: [split(.horizontal, path: [false], position: position)]
        )
    }

    private func frame(panes: [String], splits: [PaneSurfaceSplit]) -> PaneSurfaceFrame {
        PaneSurfaceFrame(
            bootId: "boot", projectionRevision: 1, surfaceRevision: 1,
            frame: FrameData(
                cells: Array(repeating: .blank, count: 80 * 24), width: 80, height: 24,
                cursor: nil, hyperlinks: [], graphics: Data()
            ),
            panes: panes.enumerated().map { index, id in
                pane(id, rect(index * 40, 0, 40, 24))
            },
            splits: splits, popup: nil, graphics: SurfaceGraphicsScene()
        )
    }

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

    private func waitUntil(
        _ label: String,
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting for \(label)")
    }

    // MARK: - The fence itself

    /// Movement is not structure. This is the assertion that keeps the fence
    /// usable at all: a drag that succeeds changes `position` on every send, so a
    /// fence that noticed would end every drag at its own first request.
    @Test("a moved divider is the same structure")
    func movementIsNotAChange() {
        #expect(sideBySide(at: 40).splitFence == sideBySide(at: 30).splitFence)
        #expect(sideBySide(at: 40).splitFence == sideBySide(at: 55).splitFence)
    }

    /// A pane closing is a change: the surviving paths can shift by one.
    @Test("a pane closing changes the structure")
    func closingAPaneChangesTheFence() {
        let before = sideBySide()
        let after = frame(panes: ["w1:p1"], splits: [split(.horizontal, path: [false])])
        #expect(before.splitFence != after.splitFence)
    }

    /// So is a pane being split — including when the *appearance* is unchanged,
    /// which is the case a naive "same number of panes and dividers" check misses.
    @Test("an extra divider changes the structure")
    func anExtraDividerChangesTheFence() {
        let before = sideBySide()
        let after = frame(
            panes: ["w1:p1", "w1:p2", "w1:p3"],
            splits: [
                split(.horizontal, path: [false]),
                split(.vertical, path: [true], position: 12),
            ]
        )
        #expect(before.splitFence != after.splitFence)
    }

    /// Renaming a divider's path is a different divider, even with the same
    /// count, the same panes and the same direction. This is the exact shape of
    /// the bug the fence exists for.
    @Test("the same divider under another path is a different structure")
    func pathIdentityMatters() {
        let before = frame(
            panes: ["w1:p1", "w1:p2"],
            splits: [split(.horizontal, path: [false])]
        )
        let after = frame(
            panes: ["w1:p1", "w1:p2"],
            splits: [split(.horizontal, path: [true])]
        )
        #expect(before.splitFence != after.splitFence)
    }

    /// Direction is structure: the same path facing the other way moves the
    /// divider along the other axis.
    @Test("a divider facing another way is a different structure")
    func directionMatters() {
        let before = frame(
            panes: ["w1:p1", "w1:p2"],
            splits: [split(.horizontal, path: [false])]
        )
        let after = frame(
            panes: ["w1:p1", "w1:p2"],
            splits: [split(.vertical, path: [false])]
        )
        #expect(before.splitFence != after.splitFence)
    }

    /// A whitelisted pane is a different pane. Two layouts that differ only in
    /// which pane sits where must not compare equal, or a close-plus-open that
    /// keeps the count would slip through.
    @Test("a replaced pane changes the structure")
    func paneIdentityMatters() {
        #expect(sideBySide().splitFence != sideBySide(panes: ["w1:p1", "w1:p3"]).splitFence)
    }

    /// The daemon may reorder its arrays; that is not a change. Without sorting,
    /// every send in an unlucky layout would end its own drag.
    @Test("reordering the arrays does not read as a change")
    func reorderingIsNotAChange() {
        let forwards = frame(
            panes: ["w1:p1", "w1:p2"],
            splits: [
                split(.horizontal, path: [false]),
                split(.vertical, path: [true], position: 12),
            ]
        )
        let backwards = frame(
            panes: ["w1:p2", "w1:p1"],
            splits: [
                split(.vertical, path: [true], position: 12),
                split(.horizontal, path: [false]),
            ]
        )
        #expect(forwards.splitFence == backwards.splitFence)
    }

    /// A layout with nothing to drag has no fence. `nil` rather than an empty
    /// value, so two "nothing to drag" layouts cannot compare equal and let a
    /// drag start.
    @Test("a layout without dividers has no fence")
    func aLonePaneHasNoFence() {
        #expect(frame(panes: ["w1:p1"], splits: []).splitFence == nil)
    }

    // MARK: - The drag

    /// The point of the whole exercise: the request still goes out when nothing
    /// changed. A fence that refused everything would pass the tests above and
    /// break the product.
    @Test("an unchanged layout lets the drag through")
    func unchangedLayoutSends() async throws {
        let (store, recorder) = store()
        store.surface = sideBySide()

        store.dragSplitRatio(path: [false], ratio: 0.5, fence: sideBySide().splitFence)
        try await waitUntil("the ratio request") { !recorder.requests.isEmpty }

        #expect(recorder.methods == ["layout.set_split_ratio"])
        let params = recorder.lastParams(of: "layout.set_split_ratio")
        #expect(params?["ratio"] as? Double == 0.5)
        #expect(params?["path"] as? [Bool] == [false])
    }

    /// The bug, end to end: a pane closes between two changes of one gesture, and
    /// the second ratio must not be sent. It names a path the new layout still
    /// has, so only the fence can stop it.
    @Test("a pane closing mid-drag stops the rest of the drag")
    func closingAPaneStopsTheDrag() async throws {
        let (store, recorder) = store()
        store.surface = sideBySide()
        let grabbed = sideBySide().splitFence

        store.dragSplitRatio(path: [false], ratio: 0.4, fence: grabbed)
        try await waitUntil("the first ratio request") { !recorder.requests.isEmpty }

        // The drafter's own answer would have cleared the sender; wait for the
        // loop to be idle so the next call starts a fresh iteration.
        try await waitUntil("the sender to go idle") { !store.splitDrag.inFlight }

        store.surface = frame(panes: ["w1:p1"], splits: [split(.horizontal, path: [false])])
        store.dragSplitRatio(path: [false], ratio: 0.6, fence: grabbed)
        try await waitUntil("the sender to go idle again") { !store.splitDrag.inFlight }

        #expect(recorder.methods == ["layout.set_split_ratio"],
                "the ratio after the close was sent: \(recorder.methods)")
        #expect(recorder.lastParams(of: "layout.set_split_ratio")?["ratio"] as? Double == 0.4)
    }

    /// A drag that is already dead drops everything that arrives after it, not
    /// just the one value that noticed the change.
    @Test("a dead drag drops the values that follow")
    func aDeadDragDropsTheRest() async throws {
        let (store, recorder) = store()
        store.surface = sideBySide()
        let grabbed = sideBySide().splitFence

        store.dragSplitRatio(path: [false], ratio: 0.4, fence: grabbed)
        try await waitUntil("the first ratio request") { !recorder.requests.isEmpty }
        try await waitUntil("the sender to go idle") { !store.splitDrag.inFlight }

        store.surface = frame(panes: ["w1:p1", "w1:p2", "w1:p3"],
                              splits: [split(.horizontal, path: [false]),
                                       split(.vertical, path: [true], position: 12)])
        store.dragSplitRatio(path: [false], ratio: 0.6, fence: grabbed)
        try await waitUntil("the sender to go idle") { !store.splitDrag.inFlight }
        store.dragSplitRatio(path: [false], ratio: 0.7, fence: grabbed)
        try await waitUntil("the sender to go idle") { !store.splitDrag.inFlight }

        #expect(recorder.methods == ["layout.set_split_ratio"],
                "a dead drag kept sending: \(recorder.methods)")
    }

    /// Ending the drag is not an error the user has to read. There is nothing for
    /// them to do, and a banner would be the only visible sign of a problem they
    /// did not cause — this is the same "silent abstention" `herdr-gpui` asserts.
    @Test("stopping a drag raises no status error")
    func stoppingIsSilent() async throws {
        let (store, recorder) = store()
        store.surface = sideBySide()
        store.dragSplitRatio(path: [false], ratio: 0.4, fence: sideBySide().splitFence)
        try await waitUntil("the first ratio request") { !recorder.requests.isEmpty }
        try await waitUntil("the sender to go idle") { !store.splitDrag.inFlight }

        store.surface = frame(panes: ["w1:p1"], splits: [split(.horizontal, path: [false])])
        store.dragSplitRatio(path: [false], ratio: 0.6, fence: sideBySide().splitFence)
        try await waitUntil("the sender to go idle") { !store.splitDrag.inFlight }

        #expect(store.lastError == nil)
    }

    /// A drag captured without a fence — nothing to compare — must still work.
    /// The alternative is a client that silently stops resizing whenever the
    /// layout could not be read at press time.
    @Test("a drag with no fence still sends")
    func noFenceStillSends() async throws {
        let (store, recorder) = store()
        store.surface = sideBySide()

        store.dragSplitRatio(path: [false], ratio: 0.5, fence: nil)
        try await waitUntil("the ratio request") { !recorder.requests.isEmpty }

        #expect(recorder.methods == ["layout.set_split_ratio"])
    }

    /// The tab the drag started on is named on every request.
    ///
    /// Without it the daemon resolves the target to "the current tab of the
    /// current workspace", which is the tab this client is showing only for as
    /// long as it keeps showing it. A drag that lands just after a focus change
    /// then resizes a tab nobody is looking at, silently.
    ///
    /// The fixture **must** carry a snapshot. Written without one first, this test
    /// passed against an implementation that dropped `tab_id` entirely: with no
    /// snapshot the id is `nil`, so "names the tab" and "omits the key" produce
    /// the same dictionary. A test that cannot tell those apart is asserting
    /// nothing — the same failure mode as `ratioRequestShape` guarding a
    /// `setSplitRatio` that nothing calls.
    @Test("every drag request names the tab it started on")
    func everyRequestNamesItsTab() async throws {
        let (store, recorder) = store()
        store.snapshot = try Self.snapshot(focusedTabId: "w1:t2")
        store.surface = sideBySide()

        store.dragSplitRatio(path: [false], ratio: 0.5, fence: sideBySide().splitFence)
        try await waitUntil("the ratio request") { !recorder.requests.isEmpty }

        let params = recorder.lastParams(of: "layout.set_split_ratio")
        #expect(params?["tab_id"] as? String == "w1:t2",
                "params carried no tab_id: \(params ?? [:])")
        #expect(params?["pane_id"] == nil, "params carried a pane_id: \(params ?? [:])")
    }

    /// No snapshot yet means no tab to name, and the key must be **absent** rather
    /// than empty: an empty id is a tab that does not exist, while a missing key is
    /// the daemon's documented "current tab" fallback.
    @Test("a drag before the first snapshot omits the tab instead of blanking it")
    func aDragWithoutASnapshotOmitsTheTab() async throws {
        let (store, recorder) = store()
        store.surface = sideBySide()

        store.dragSplitRatio(path: [false], ratio: 0.5, fence: sideBySide().splitFence)
        try await waitUntil("the ratio request") { !recorder.requests.isEmpty }

        let params = recorder.lastParams(of: "layout.set_split_ratio")
        #expect(params?.keys.contains("tab_id") == false,
                "params carried a tab_id key: \(params ?? [:])")
    }

    /// A minimal snapshot carrying just enough to have a focused tab.
    ///
    /// Decoded rather than memberwise-initialised because that is how the
    /// connection produces one, so the keys here are the wire's spelling and a
    /// rename in the protocol shows up as a failure in this file.
    private static func snapshot(focusedTabId: String) throws -> ClientShellSnapshot {
        let json = """
        {"boot_id": "boot", "revision": 1, "focused_tab_id": "\(focusedTabId)",
         "workspaces": [{"workspace_id": "w1", "active_tab_id": "\(focusedTabId)",
                         "new_workspace_cwd": "/tmp", "number": 1, "label": "one",
                         "custom_label": false, "focused": true, "tokens": []}],
         "tabs": [{"tab_id": "\(focusedTabId)", "workspace_id": "w1", "number": 1,
                   "label": "1", "focused": true, "zoomed": false,
                   "agent_status": "idle"}],
         "panes": [{"pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "\(focusedTabId)",
                    "label": "p0", "cwd": "/tmp", "focused": true,
                    "right_click_passthrough": false}],
         "agents": [], "agent_order": [], "commands": []}
        """
        return try JSONDecoder().decode(ClientShellSnapshot.self, from: Data(json.utf8))
    }
}
