// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Tests for issue #38's interaction layer.
//
// The four rules under test are the ones whose bugs are invisible from a
// screenshot:
//
// - `right_click = "pane"` had no effect at all before this change (the snapshot
//   field was decoded and never read), so a pane that should swallow the menu
//   still opened one — a user would call that "the setting is broken", and the
//   only way to catch it in CI is to assert the decision.
// - `ui.confirm_close` is the daemon's, not the client's, so what matters here is
//   that this client *asks* rather than checking a local preference.
// - the navigator's ordering has to be explained in one sentence and still be
//   right, which is exactly what a pure function is for.
// - `workspace.move_block` has two rejection modes the daemon enforces, and
//   sending a doomed request is how a drag turns into a red banner.
//

import Foundation
import Testing

@testable import KraalProtocol
@testable import KraalUI

@Suite("Right-click routing")
struct RightClickRoutingTests {
    /// The regression this whole change exists for: an explicit per-pane
    /// `right_click = "pane"` must beat the default, and it must do so even when
    /// the program does *not* report the mouse. The old implementation only looked
    /// at mouse reporting, so this exact case opened the menu.
    @Test("an explicit passthrough setting wins over the mouse-reporting default")
    func passthroughBeatsDefault() {
        #expect(!PaneContextRouting.shouldShowPaneMenu(
            programReportsMouse: false,
            rightClickPassthrough: true
        ))
        #expect(PaneContextRouting.ownsRightClick(
            programReportsMouse: false,
            rightClickPassthrough: true
        ))
    }

    /// Either signal is enough to hand the button to the program.
    @Test("mouse reporting and passthrough are independent reasons to skip the menu")
    func twoIndependentReasons() {
        #expect(!PaneContextRouting.shouldShowPaneMenu(programReportsMouse: true))
        #expect(!PaneContextRouting.shouldShowPaneMenu(
            programReportsMouse: false,
            rightClickPassthrough: true
        ))
        // Neither: the menu is the only thing that can happen, so it must open.
        #expect(PaneContextRouting.shouldShowPaneMenu(programReportsMouse: false))
    }

    /// The wire spelling is what the daemon parses. Getting it backwards would
    /// silently keep the menu (the daemon's default) and look like a dead toggle.
    @Test("the wire target names match the daemon's enum")
    func wireNames() {
        #expect(PaneContextRouting.target(for: true).rawValue == "pane")
        #expect(PaneContextRouting.target(for: false).rawValue == "herdr")
        #expect(PaneContextRouting.RightClickTarget.pane.rawValue == "pane")
        #expect(PaneContextRouting.RightClickTarget.herdr.rawValue == "herdr")
    }

    /// `pane.input.set` needs `pane_id` and `right_click`; the daemon drops
    /// unknown keys and defaults a missing `right_click` to `herdr`, so a wrong
    /// field name would look like "the toggle does nothing".
    @Test("the request carries the fields the daemon reads")
    func requestBody() {
        let enabled = AppStore.rightClickParams(paneId: "w1:p2", passthrough: true)
        #expect(enabled["pane_id"] as? String == "w1:p2")
        #expect(enabled["right_click"] as? String == "pane")

        let disabled = AppStore.rightClickParams(paneId: "w1:p2", passthrough: false)
        #expect(disabled["right_click"] as? String == "herdr")
    }

    /// A pane that reports the mouse already gets its own up event; claiming it
    /// for a menu that never opened would break the TUI this routing protects.
    @Test("only a menu this app raised claims the matching release")
    func rightUpOwnership() {
        #expect(PaneContextRouting.consumesRightUp(menuRaisedForPane: "w1:p1"))
        #expect(!PaneContextRouting.consumesRightUp(menuRaisedForPane: nil))
    }
}

@Suite("Close confirmation")
struct CloseConfirmationTests {
    /// The client must not decide this from a local preference. Both daemon
    /// codes mean "do you really mean the whole group?", and both have to be
    /// recognised or the retry never happens.
    @Test("both group-close codes are treated as a question, not a failure")
    func bothCodesAreQuestions() {
        #expect(AppStore.isGroupCloseRefusal(AppStore.confirmationRequired))
        #expect(AppStore.isGroupCloseRefusal(AppStore.groupCloseRequired))
        #expect(AppStore.confirmationRequired == "confirmation_required")
        #expect(AppStore.groupCloseRequired == "workspace_group_close_required")
    }

    /// An unrelated error must stay an error: retrying a `pane_not_found` with a
    /// group flag would turn one failure into two.
    @Test("an ordinary error is not a confirmation question")
    func ordinaryErrorIsNotAQuestion() {
        #expect(!AppStore.isGroupCloseRefusal("pane_not_found"))
        #expect(!AppStore.isGroupCloseRefusal("endpoint_busy"))
    }

    /// `pane.close` takes no group flag at all — the daemon answers with a code
    /// instead. Sending one would be ignored, and a client believing it had
    /// confirmed the group would then report success for a close that never
    /// happened.
    @Test("pane.close never claims the group up front")
    func paneCloseHasNoGroupFlag() {
        let params = AppStore.closePaneParams(paneId: "w1:p1")
        #expect(params["pane_id"] as? String == "w1:p1")
        #expect(params["close_group"] == nil)
    }
}

@Suite("Workspace block moves")
struct WorkspaceBlockMoveTests {
    /// The daemon rejects an empty block and a `before` inside the block. Neither
    /// can be acted on by the user, so the client refuses locally instead of
    /// turning a no-op drag into an error banner.
    @Test("a block the daemon would reject is not sent")
    func invalidBlocksRefused() {
        #expect(!AppStore.isValidWorkspaceBlock([], before: nil))
        #expect(!AppStore.isValidWorkspaceBlock(["w1", "w1"], before: nil))
        #expect(!AppStore.isValidWorkspaceBlock(["w1", "w2"], before: "w2"))
        #expect(AppStore.isValidWorkspaceBlock(["w1", "w2"], before: "w3"))
        #expect(AppStore.isValidWorkspaceBlock(["w1"], before: nil))
    }

    /// `before_workspace_id` is omitted (not `null`) when moving to the end: the
    /// daemon's field is `Option` with `skip_serializing_if`, so the absent key is
    /// the idiomatic "no anchor" and a literal null only adds a decoding edge.
    @Test("moving to the end omits the anchor")
    func endOfListHasNoAnchor() {
        let params = AppStore.workspaceBlockParams(["w1", "w2"], before: nil)
        #expect(params["workspace_ids"] as? [String] == ["w1", "w2"])
        #expect(params["before_workspace_id"] == nil)

        let anchored = AppStore.workspaceBlockParams(["w1"], before: "w9")
        #expect(anchored["before_workspace_id"] as? String == "w9")
    }

    /// Block order is the order given: the daemon places them contiguously in that
    /// sequence, so a caller that sorts them reorders the user's worktrees.
    @Test("the block keeps the caller's order")
    func blockOrderPreserved() {
        let params = AppStore.workspaceBlockParams(["w3", "w1", "w2"], before: "w9")
        #expect(params["workspace_ids"] as? [String] == ["w3", "w1", "w2"])
    }
}
