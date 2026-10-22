// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// `workspace.close` / `pane.close` / `tab.close` request bodies, and the daemon
// codes that mean "this would take a worktree group with it".
//
// Why these tests exist: issue #21 was a close that *looked* like a no-op. The
// daemon refused it with `workspace_group_close_required` — in band, in a body
// that decoded fine — and the only trace was a tooltip in the status bar. None
// of these facts were pinned by a test, which is why it went unnoticed; the
// upstream daemon's own rule (`sidebar.rs:573-601`) is not the same as the
// sidebar's display grouping, so the client has to act on the refusal rather
// than predict it.

import Foundation
import Testing

@testable import KraalUI

@Suite("Close request bodies")
struct CloseRequestTests {
    /// The bug itself: without `close_group` the daemon cannot tell "close this
    /// workspace" from "close the group", so it refuses both.
    @Test("workspace.close states whether the group goes too")
    func workspaceCloseCarriesGroupFlag() {
        let alone = AppStore.closeWorkspaceParams(workspaceId: "w2", closeGroup: false)
        #expect(alone["workspace_id"] as? String == "w2")
        #expect(alone["close_group"] as? Bool == false)

        let group = AppStore.closeWorkspaceParams(workspaceId: "w2", closeGroup: true)
        #expect(group["close_group"] as? Bool == true)
    }

    /// The flag must be a real Bool, not the string "false": a non-empty string
    /// is truthy to some decoders, which would silently close the whole group.
    @Test("close_group is a JSON boolean, not a string")
    func groupFlagIsBoolean() {
        let params = AppStore.closeWorkspaceParams(workspaceId: "w2", closeGroup: false)
        #expect(params["close_group"] is Bool)
        #expect(!(params["close_group"] is String))
    }

    /// `pane.close` and `tab.close` take no group parameter — the daemon answers
    /// with `confirmation_required` instead. Sending one anyway would be ignored
    /// at best.
    @Test("pane.close and tab.close carry only their id")
    func paneAndTabTakeNoGroupFlag() {
        let pane = AppStore.closePaneParams(paneId: "w1:p1")
        #expect(pane["pane_id"] as? String == "w1:p1")
        #expect(pane["close_group"] == nil)
        #expect(pane.count == 1)

        let tab = AppStore.closeTabParams(tabId: "w1:t1")
        #expect(tab["tab_id"] as? String == "w1:t1")
        #expect(tab["close_group"] == nil)
        #expect(tab.count == 1)
    }
}

@Suite("Group close refusals")
struct GroupCloseRefusalTests {
    /// Two codes, one meaning: "confirm, then send it again". `workspace.close`
    /// uses the first, `pane.close` / `tab.close` the second
    /// (`workspaces.rs:328-336`, `panes.rs:1976-1987`, `tabs.rs:242-247`).
    @Test("both daemon codes count as a group-close refusal")
    func bothCodesAreRecognised() {
        #expect(AppStore.isGroupCloseRefusal("workspace_group_close_required"))
        #expect(AppStore.isGroupCloseRefusal("confirmation_required"))
    }

    /// Everything else stays an error. Prompting on, say, `pane_not_found` would
    /// train the user to click through the dialog without reading it.
    @Test("other refusals are not treated as a confirmation")
    func otherCodesAreErrors() {
        for code in [
            "pane_not_found",
            "workspace_not_found",
            "endpoint_busy",
            "worktree_operation_in_progress",
            "unknown",
            "",
        ] {
            #expect(!AppStore.isGroupCloseRefusal(code), "\(code) was treated as a confirmation")
        }
    }

    /// The strings are the wire contract — a typo here fails closed (the user
    /// sees an error instead of a dialog), which is the safe direction, but it
    /// would still be a bug.
    @Test("the codes match the daemon's own strings")
    func codesMatchTheDaemon() {
        #expect(AppStore.groupCloseRequired == "workspace_group_close_required")
        #expect(AppStore.confirmationRequired == "confirmation_required")
    }
}
