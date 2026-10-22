// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Split geometry and drag arithmetic, ported from the two upstream clients.
//
// Sources (Apache-2.0 / MIT, see NOTICE):
//   * `rootshell/rootshellTests/TmuxDividerResizeTests.swift:12,66`
//     (`cellDelta` uses the pane's own extent, and a non-finite metric yields no
//      command at all)
//   * `rootshell/rootshellTests/HerdrProtocolTests.swift:29`
//     (`testRatioRequestEncodesExplicitTabAndBooleanPath`: `layout.set_split_ratio`
//      carries `tab_id`, `path`, `ratio` and never `pane_id`)
//   * `rootshell/rootshellTests/HerdrProtocolTests.swift:23`
//     (`testThreeColumnsAndRowsTargetTheMiddlePane`: a drag resolves to the pane on
//      one side of the boundary, not to the boundary itself)
//   * `herdr-gpui/crates/herdr-protocol/tests/surface_prefix.rs:93`
//     (a `PaneSurface` only counts for the *current* projection)
//
// All three upstream tests exist because a divider drag is silent when it is
// wrong: the ratio just lands somewhere plausible and the panes settle a cell or
// two off. `splitRatio` is the whole of that arithmetic.

import CoreGraphics
import Foundation
import Testing

@testable import KraalProtocol
@testable import KraalUI

@Suite("Split ratio arithmetic")
struct SplitRatioPortTests {
    private let area = SurfaceRect(originX: 0, originY: 0, width: 80, height: 20)

    /// `rootshell/rootshellTests/HerdrProtocolTests.swift:29`
    /// `testRatioRequestEncodesExplicitTabAndBooleanPath`: the daemon's params are
    /// `{tab_id, pane_id?, path, ratio}`, and a drag must name the tab it came
    /// from — never a `pane_id`.
    ///
    /// Why it matters: without `tab_id` the daemon resizes "the active tab of the
    /// active workspace" (`src/app/api/layouts.rs:704` `resolve_layout_export_target`,
    /// the `(None, None)` arm). That is the same tab only while this client is
    /// showing it, so a drag that lands just after a focus change resizes a tab
    /// the user is not looking at — silently, with no error on either side.
    ///
    /// RED AS PORTED: `splitRatioParams` sends only `path` and `ratio`.
    @Test("a ratio request names its tab and never a pane")
    @MainActor
    func ratioRequestShape() {
        let params = AppStore.splitRatioParams(path: [false, true], ratio: 0.5)
        #expect(params["tab_id"] != nil, "params carried no tab_id: \(params)")
        #expect(params["pane_id"] == nil, "params carried a pane_id: \(params)")
        #expect(params["path"] as? [Bool] == [false, true])
        #expect(params["ratio"] as? Double == 0.5)
    }

    /// The daemon's `layout.set_split_ratio` rejects a non-finite ratio
    /// (`src/app/api/layouts.rs:235`). A drag that produced `NaN` would come back
    /// as an error the user never sees, and the divider would not move at all.
    ///
    /// RED AS PORTED: `splitRatio` divides by `max(area.height, 1)` but never
    /// guards the *numerator*, so `translatedY` of `.nan` / `.infinity` propagates
    /// straight into the return value. `min`/`max` do not sanitise NaN.
    @Test("a non-finite drag cannot produce a ratio")
    func nonFiniteDrag() {
        for delta in [CGFloat.nan, .infinity, -.infinity] {
            let ratio = PaneLayoutView.splitRatio(
                direction: .vertical,
                position: 5,
                area: area,
                translatedX: 0,
                translatedY: delta
            )
            #expect(ratio.isFinite, "delta \(delta) produced \(ratio)")
        }
    }

    /// A degenerate split area (zero height on a vertical divider) must not
    /// divide by zero. `max(area.height, 1)` covers the divisor; this pins the
    /// resulting ratio to the band rather than something outside it.
    @Test("a zero-extent area still yields a usable ratio")
    func degenerateArea() {
        let flat = SurfaceRect(originX: 0, originY: 0, width: 80, height: 0)
        let ratio = PaneLayoutView.splitRatio(
            direction: .vertical,
            position: 0,
            area: flat,
            translatedX: 0,
            translatedY: 0
        )
        #expect(ratio >= 0.1 && ratio <= 0.9, "got \(ratio)")
        #expect(ratio.isFinite)
    }

    /// `rootshell TmuxDividerResizeTests:12`: the drag is measured against the
    /// pane's own extent, not the window's. A 20-row area dragged by 2 rows is
    /// exactly +0.1, no matter how tall the window is.
    @Test("a drag is measured against the split area, not the window")
    func dragUsesOwnExtent() {
        let moved = PaneLayoutView.splitRatio(
            direction: .vertical,
            position: 10,
            area: area,
            translatedX: 0,
            translatedY: 2
        )
        #expect(abs(moved - 0.6) < 1e-9, "got \(moved)")
    }

    /// `rootshell TmuxDividerResizeTests:12` second half: no movement, no change.
    /// A rounding error here makes a click on a divider nudge the layout.
    @Test("an unmoved drag keeps the divider where it is")
    func unmovedDrag() {
        let ratio = PaneLayoutView.splitRatio(
            direction: .vertical,
            position: 10,
            area: area,
            translatedX: 0,
            translatedY: 0
        )
        #expect(abs(ratio - 0.5) < 1e-9, "got \(ratio)")
    }

    /// The `position` field is already relative to the split area's origin; a
    /// nested split's origin must be subtracted once and only once. Doing it twice
    /// (or not at all) puts the divider in the wrong place only for nested
    /// splits — the hardest case to notice by hand.
    @Test("a nested split subtracts its area origin exactly once")
    func nestedOrigin() {
        let nested = SurfaceRect(originX: 0, originY: 30, width: 80, height: 20)
        let ratio = PaneLayoutView.splitRatio(
            direction: .vertical,
            position: 40, // 10 rows into the area
            area: nested,
            translatedX: 0,
            translatedY: 0
        )
        #expect(abs(ratio - 0.5) < 1e-9, "got \(ratio)")
    }

    /// Both axes clamp to 0.1…0.9 so a pane can never be dragged to nothing;
    /// without it a fast drag hands the daemon `0` and the pane disappears.
    @Test("both axes clamp to the same band")
    func clamps() {
        let vertical = PaneLayoutView.splitRatio(
            direction: .vertical,
            position: 0,
            area: area,
            translatedX: 0,
            translatedY: -1000
        )
        let horizontal = PaneLayoutView.splitRatio(
            direction: .horizontal,
            position: 0,
            area: area,
            translatedX: 1000,
            translatedY: 0
        )
        #expect(vertical == 0.1)
        #expect(horizontal == 0.9)
    }
}

@Suite("Surface projection fencing")
struct SurfaceProjectionFencePortTests {
    /// `surface_prefix.rs:93` `current_identity_and_patch_baseline_are_required`:
    /// a surface belongs to the projection the snapshot names. A frame for another
    /// projection is authoritative for *that* tab and must not be drawn.
    ///
    /// This one is already correct; it is here as the regression guard for the
    /// behaviour the upstream test is about.
    @Test("a frame from another projection is not adopted")
    @MainActor
    func foreignProjection() throws {
        let store = AppStore()
        store.handleSnapshot(try Self.snapshot(revision: 7))
        store.handleSurface(Self.surface(projection: 6, revision: 1))
        #expect(store.surface == nil, "a frame for projection 6 was adopted at revision 7")

        store.handleSurface(Self.surface(projection: 7, revision: 1))
        #expect(store.surface != nil)
    }

    /// `surface_prefix.rs:93` second half: within one projection, the surface
    /// revision never goes backwards. A stale frame arriving late (a patch and a
    /// full surface racing on two threads) must not overwrite newer cells.
    @Test("a stale surface revision is dropped inside one projection")
    @MainActor
    func staleRevision() throws {
        let store = AppStore()
        store.handleSnapshot(try Self.snapshot(revision: 7))
        store.handleSurface(Self.surface(projection: 7, revision: 5))
        store.handleSurface(Self.surface(projection: 7, revision: 4))
        #expect(store.surface?.surfaceRevision == 5)
    }

    /// A *new* boot id restarts every counter, so a lower revision is expected and
    /// must be adopted: the daemon was restarted and the old high-water mark does
    /// not apply.
    @Test("a new boot id resets the revision comparison")
    @MainActor
    func newBoot() throws {
        let store = AppStore()
        store.handleSnapshot(try Self.snapshot(revision: 7))
        store.handleSurface(Self.surface(projection: 7, revision: 9, boot: "boot-1"))
        store.handleSurface(Self.surface(projection: 7, revision: 1, boot: "boot-2"))
        #expect(store.surface?.surfaceRevision == 1)
        #expect(store.surface?.bootId == "boot-2")
    }

    private static func snapshot(revision: UInt64) throws -> ClientShellSnapshot {
        let json = """
        {
          "boot_id": "boot-1", "revision": \(revision),
          "update_install_command": "", "worktree_directory": "",
          "tab_bar_right": [], "tab_bar_right_separator": " ", "agent_order": [],
          "workspaces": [{"workspace_id": "w1", "active_tab_id": "w1:t1",
            "new_workspace_cwd": "/", "number": 1, "label": "repo",
            "custom_label": false, "tokens": [], "focused": true,
            "agent_status": "working"}],
          "tabs": [{"tab_id": "w1:t1", "workspace_id": "w1", "number": 1,
            "label": "main", "custom_label": false, "zoomed": false,
            "focused": true, "agent_status": "working"}],
          "panes": [{"pane_id": "w1:p1", "workspace_id": "w1",
            "tab_id": "w1:t1", "focused": true}],
          "agents": [], "commands": []
        }
        """
        return try JSONDecoder().decode(ClientShellSnapshot.self, from: Data(json.utf8))
    }

    private static func surface(
        projection: UInt64,
        revision: UInt64,
        boot: String = "boot-1"
    ) -> PaneSurfaceFrame {
        PaneSurfaceFrame(
            bootId: boot,
            projectionRevision: projection,
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
}
