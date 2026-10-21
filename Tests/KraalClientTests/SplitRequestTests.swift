// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Regression tests for the `pane.split` request body.
//
// The bug: Split Right / Split Down appeared to do nothing. The request carried
// `pane_id`, and `PaneSplitParams` has no such field — it takes
// `target_pane_id`. Every other pane method (`pane.focus`, `pane.close`,
// `pane.zoom`, `pane.resize`, `pane.scroll`, `pane.rename`) does take `pane_id`,
// which is exactly why the wrong name was invisible on review.
//
// What made it look like a no-op rather than an obvious error is that the
// daemon does not reject unknown keys: `direction` is the only required field,
// so the request succeeded — and split whatever tab the daemon considered
// focused, not the pane the user right-clicked. Measured against a live 0.9.5
// daemon:
//
//   {"pane_id": "wS:p1",        "direction": "right"} -> created in wT:t1
//   {"target_pane_id": "wS:p1", "direction": "right"} -> created in wS:t1
//
// The daemon cannot catch this for us, so these tests are the only guard.

import Testing

import KraalProtocol
@testable import KraalUI

@Suite("pane.split request body")
struct SplitRequestTests {
    /// The bug itself: the field the daemon reads must be present.
    @Test("the target pane goes out as target_pane_id")
    func usesTargetPaneId() {
        let params = AppStore.splitParams(paneId: "wS:p1", orientation: .right)

        #expect(params["target_pane_id"] as? String == "wS:p1")
    }

    /// Naming both would leave two sources of truth for one value, and the day
    /// they disagree the daemon silently prefers one of them.
    @Test("pane_id is not also sent")
    func doesNotSendBarePaneId() {
        let params = AppStore.splitParams(paneId: "wS:p1", orientation: .right)

        #expect(params["pane_id"] == nil)
    }

    /// `direction` is the only required field. If it ever stops being sent the
    /// daemon rejects the request outright, which is the one failure mode that
    /// would have been loud — but it should still be pinned.
    @Test("direction carries the requested orientation", arguments: SplitOrientation.allCases)
    func sendsDirection(orientation: SplitOrientation) {
        let params = AppStore.splitParams(paneId: "wT:p1", orientation: orientation)

        #expect(params["direction"] as? String == orientation.rawValue)
    }

    /// Pins the two values the daemon accepts. `SplitDirection` is a closed enum
    /// on the wire; a third case invented here would be rejected.
    @Test("the orientations match the wire enum")
    func orientationsMatchSchema() {
        #expect(SplitOrientation.right.rawValue == "right")
        #expect(SplitOrientation.down.rawValue == "down")
    }

    /// Guards against a future refactor that sends a pane id from another
    /// workspace: quoting it verbatim is the whole contract.
    @Test("the pane id is passed through verbatim", arguments: ["wS:p1", "wT:p12", "wP:pJ"])
    func passesPaneIdThrough(paneId: String) {
        let params = AppStore.splitParams(paneId: paneId, orientation: .down)

        #expect(params["target_pane_id"] as? String == paneId)
    }
}
