// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import KraalHC
import KraalModel
import Testing

@testable import KraalHCTerminal

@MainActor
@Suite("Workspace model")
struct HcWorkspaceModelTests {
    private func modelWithOnePane() -> HcWorkspaceModel {
        let model = HcWorkspaceModel(
            path: "/tmp/does-not-exist",
            viewPath: URL(fileURLWithPath: "/tmp/kraal-view-test.json")
        )
        model.workspace.addSpace(
            id: "sp1",
            folder: "/tmp",
            tab: KraalTabSeed(id: "tb1", paneID: "p1", terminal: "t1")
        )
        return model
    }

    @Test("an empty terminal list before the snapshot does not delete the layout")
    func beforeSnapshot() {
        let model = modelWithOnePane()
        model.hasSnapshot = false
        model.reconcile()
        #expect(model.workspace.space("sp1")?.tabs.first?.terminals == ["t1"])
    }

    @Test("control listing mirrors spaces, tabs and placed panes")
    func controlListing() {
        let model = modelWithOnePane()
        let listing = model.controlListing()
        let space = listing["spaces"]?.arrayValue?.first
        #expect(space?["id"]?.stringValue == "sp1")
        #expect(space?["active"]?.boolValue == true)
        let tab = space?["tabs"]?.arrayValue?.first
        #expect(tab?["id"]?.stringValue == "tb1")
        #expect(tab?["active"]?.boolValue == true)
        let terminal = tab?["terminals"]?.arrayValue?.first
        #expect(terminal?["terminal"]?.stringValue == "t1")
        #expect(terminal?["pane"]?.stringValue == "p1")
        #expect(terminal?["status"]?.isNull == true)
    }

    @Test("control status reports the focused tab and open overlays")
    func controlStatus() {
        let model = modelWithOnePane()
        model.showHelp = true
        let status = model.controlStatus()
        #expect(status["space"]?.stringValue == "sp1")
        #expect(status["tab"]?.stringValue == "tb1")
        #expect(status["focused_pane"]?.stringValue == "p1")
        #expect(status["overlays"]?.arrayValue?.first?.stringValue == "help")
        #expect(status["status"]?.stringValue == "idle")
    }

    @Test("after a snapshot, a pane whose terminal is gone is dropped")
    func afterSnapshot() {
        let model = modelWithOnePane()
        model.hasSnapshot = true
        model.reconcile()
        #expect(model.workspace.space("sp1") == nil)
    }
}
