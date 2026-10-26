// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  DerivedQueryTests.swift
//  KraalClientTests
//
//  The pure queries in `AppStore+Derived.swift`: pane lookup, zoom label, tab shift.
//
//  Two of these were real bugs before they were queries:
//
//  * **`right_click_passthrough` was decoded and never read**, because the only pane
//    lookup the mouse path had was the *surface* one (`paneGeometry`), and that record
//    does not carry the field. Keeping `pane(_:)` (snapshot) and `paneGeometry(_:)`
//    (surface) as separate answers is what makes that mistake visible, so both are
//    pinned here.
//  * **`isZoomed` must not answer `false` for a pane whose tab is zoomed.** Herdr
//    renames the menu item between "Zoom Pane" and "Unzoom Pane" rather than leaving a
//    verb that lies half the time; a wrong answer here shows the user the wrong verb.
//
//  `shiftFocusedTab` is the one with a boundary: `tab.move` takes an absolute
//  `insert_index`, so asking to move past either end must be a no-op rather than a
//  request the daemon rejects.
//

import Foundation
import Testing

@testable import KraalProtocol
@testable import KraalUI

@Suite("Derived queries")
@MainActor
struct DerivedQueryTests {
    /// A snapshot with two workspaces' worth of tabs and panes to look up.
    private func snapshot(
        zoomed: Bool = false,
        rightClickPassthrough: Bool = false,
        focusedTabId: String = "w1:t2"
    ) throws -> ClientShellSnapshot {
        let json = """
        {"boot_id": "boot", "revision": 1,
         "focused_tab_id": "\(focusedTabId)",
         "workspaces": [{"workspace_id": "w1", "active_tab_id": "w1:t1",
                         "new_workspace_cwd": "/tmp", "number": 1, "label": "one",
                         "custom_label": false, "focused": true, "tokens": []}],
         "tabs": [
           {"tab_id": "w1:t1", "workspace_id": "w1", "number": 1, "label": "1",
            "focused": \(focusedTabId == "w1:t1"), "zoomed": false,
            "agent_status": "idle"},
           {"tab_id": "w1:t2", "workspace_id": "w1", "number": 2, "label": "2",
            "focused": \(focusedTabId == "w1:t2"), "zoomed": \(zoomed),
            "agent_status": "idle"}
         ],
         "panes": [
           {"pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1",
            "label": "first", "cwd": "/tmp", "focused": false,
            "right_click_passthrough": false},
           {"pane_id": "w1:p2", "workspace_id": "w1", "tab_id": "w1:t2",
            "label": "second", "cwd": "/tmp", "focused": true,
            "right_click_passthrough": \(rightClickPassthrough)}
         ],
         "agents": [], "agent_order": [], "commands": []}
        """
        return try JSONDecoder().decode(ClientShellSnapshot.self, from: Data(json.utf8))
    }

    private func store() -> AppStore {
        let store = AppStore(target: .local)
        store.endpoints = [EndpointState(id: .local, label: "Local", settings: .local)]
        store.activeEndpointID = .local
        return store
    }

    // MARK: - Pane lookup

    @Test("a pane's label comes from the snapshot")
    func paneLabel() throws {
        let store = store()
        store.snapshot = try snapshot()
        #expect(store.paneLabel("w1:p2") == "second")
        #expect(store.paneLabel("w9:p9") == nil)
    }

    /// The snapshot record and the surface record answer *different* questions, and
    /// conflating them is what hid `right_click_passthrough` for a while.
    @Test("the snapshot pane and the surface pane are different lookups")
    func paneLookupsAreDistinct() throws {
        let store = store()
        store.snapshot = try snapshot()
        store.surface = PaneSurfaceFrame(
            bootId: "boot", projectionRevision: 1, surfaceRevision: 1,
            frame: FrameData(
                cells: Array(repeating: .blank, count: 4), width: 2, height: 2,
                cursor: nil, hyperlinks: [], graphics: Data()
            ),
            panes: [PaneSurfacePane(
                paneId: "w1:p2", contentRevision: 1,
                rect: SurfaceRect(originX: 0, originY: 0, width: 2, height: 2),
                innerRect: SurfaceRect(originX: 0, originY: 0, width: 2, height: 2),
                scrollbarRect: nil, scroll: nil, focused: true,
                mouseReporting: false, sgrPixelMouse: false,
                alternateScreenActive: false, pixelWidth: 0, pixelHeight: 0
            )],
            splits: [], popup: nil, graphics: SurfaceGraphicsScene()
        )

        // Snapshot knows the label; the surface record does not.
        #expect(store.pane("w1:p2")?.label == "second")
        #expect(store.paneGeometry(for: "w1:p2") != nil)
        // A pane only the surface knows has no snapshot record.
        #expect(store.pane("w1:p9") == nil)
        #expect(store.paneGeometry(for: "w1:p9") == nil)
    }

    /// The field is on the snapshot record, so this is the lookup that must read it.
    @Test("right-click passthrough is read from the snapshot pane")
    func rightClickPassthrough() throws {
        let store = store()
        store.snapshot = try snapshot(rightClickPassthrough: true)
        #expect(store.rightClickPassthrough(paneId: "w1:p2"),
                "the field is decoded but this lookup did not read it")
        #expect(!store.rightClickPassthrough(paneId: "w1:p1"))
        // An unknown pane must default to opening the menu, not to passthrough.
        #expect(!store.rightClickPassthrough(paneId: "w9:p9"))
    }

    // MARK: - Zoom

    @Test("a zoomed tab reports its pane as zoomed")
    func zoomedPane() throws {
        let store = store()
        store.snapshot = try snapshot(zoomed: true)
        #expect(store.isZoomed(paneId: "w1:p2"))
    }

    @Test("an unzoomed tab reports its pane as not zoomed")
    func unzoomedPane() throws {
        let store = store()
        store.snapshot = try snapshot(zoomed: false)
        #expect(!store.isZoomed(paneId: "w1:p2"))
    }

    /// An unknown pane cannot be zoomed; answering `true` would show "Unzoom Pane" for
    /// something that is not zoomed.
    @Test("an unknown pane is not zoomed")
    func unknownPaneIsNotZoomed() throws {
        let store = store()
        store.snapshot = try snapshot(zoomed: true)
        #expect(!store.isZoomed(paneId: "w9:p9"))
    }

    /// Herdr's menu renames the item rather than leaving one verb that lies half the
    /// time, so the label must follow the same answer as `isZoomed`.
    @Test("the zoom label follows the zoom state")
    func zoomLabelFollowsState() throws {
        let zoomed = store()
        zoomed.snapshot = try snapshot(zoomed: true)
        #expect(zoomed.zoomLabel(forPane: "w1:p2") == "Unzoom Pane")

        let flat = store()
        flat.snapshot = try snapshot(zoomed: false)
        #expect(flat.zoomLabel(forPane: "w1:p2") == "Zoom Pane")
    }

    // MARK: - Tab shift

    /// Moving one slot right plans the neighbouring index for the focused tab.
    @Test("shifting right plans the next index")
    func shiftRightPlans() throws {
        let store = store()
        store.snapshot = try snapshot(focusedTabId: "w1:t1")
        let plan = try #require(store.shiftFocusedTabPlan(by: 1))
        #expect(plan.tabId == "w1:t1")
        #expect(plan.index == 1)
    }

    @Test("shifting left plans the previous index")
    func shiftLeftPlans() throws {
        let store = store()
        store.snapshot = try snapshot(focusedTabId: "w1:t2")
        let plan = try #require(store.shiftFocusedTabPlan(by: -1))
        #expect(plan.tabId == "w1:t2")
        #expect(plan.index == 0)
    }

    /// `tab.move` takes an absolute `insert_index`, so a target past either end is a
    /// request the daemon rejects. The plan must be nil, not a clamped index: clamping
    /// would silently move the tab to an end the user did not ask for.
    ///
    /// This replaces an earlier assertion that watched `visibleTabs` and passed with the
    /// bounds check **removed** — `move` only sends a request, so local order never
    /// changes either way. The decision, not the side effect, is what this pins.
    @Test("shifting past either end plans nothing")
    func shiftPastEndPlansNothing() throws {
        let store = store()
        store.snapshot = try snapshot(focusedTabId: "w1:t2")
        #expect(store.shiftFocusedTabPlan(by: 1) == nil,
                "an out-of-range shift planned a move the daemon would reject")
        #expect(store.shiftFocusedTabPlan(by: 100) == nil)

        store.snapshot = try snapshot(focusedTabId: "w1:t1")
        #expect(store.shiftFocusedTabPlan(by: -1) == nil)
        #expect(store.shiftFocusedTabPlan(by: -100) == nil)
    }

    /// No snapshot: no tabs, no action tab, nothing to plan.
    @Test("shifting with no snapshot plans nothing")
    func shiftWithNoSnapshotPlansNothing() {
        let store = store()
        #expect(store.actionTabId == nil)
        #expect(store.shiftFocusedTabPlan(by: 1) == nil)
    }

    /// A delta of zero is in range and plans the tab's own index, which `move` then
    /// sends as a no-op move. Pinned so the range check is not written as `target > current`.
    @Test("a zero shift plans the current index")
    func zeroShiftPlansCurrent() throws {
        let store = store()
        store.snapshot = try snapshot(focusedTabId: "w1:t1")
        let tabs = store.visibleTabs.map(\.tabId)
        let current = try #require(tabs.firstIndex(of: "w1:t1"))
        let plan = try #require(store.shiftFocusedTabPlan(by: 0))
        #expect(plan.index == current)
        #expect(plan.tabId == "w1:t1")
    }
}
