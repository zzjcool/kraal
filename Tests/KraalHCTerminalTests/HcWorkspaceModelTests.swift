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
        #expect(status["scrollback"]?.arrayValue?.isEmpty == true)
    }

    @Test("after a snapshot, a pane whose terminal is gone is dropped")
    func afterSnapshot() {
        let model = modelWithOnePane()
        model.hasSnapshot = true
        model.reconcile()
        #expect(model.workspace.space("sp1") == nil)
    }

    @Test("control listing carries the focused pane and the tab tree")
    func controlListingTree() {
        let model = modelWithOnePane()
        let tab = model.controlListing()["spaces"]?.arrayValue?.first?["tabs"]?.arrayValue?.first
        #expect(tab?["focused"]?.stringValue == "p1")
        // `tree` is the node tree verbatim, so a gate reads exactly what the
        // shared document holds: a row over the block that owns t1.
        let tree = tab?["tree"]
        let stored = model.workspace.space("sp1")?.tabs.first
        #expect(tree == stored?.root.raw)
        #expect(tree?["type"]?.stringValue == "row")
        let block = tree?["children"]?.arrayValue?.first
        #expect(block?["type"]?.stringValue == "block")
        #expect(block?["id"]?.stringValue == "p1")
        #expect(block?["content"]?["terminal"]?.stringValue == "t1")
        // The fields the listing already had keep their shape.
        #expect(tab?["id"]?.stringValue == "tb1")
        #expect(tab?["terminals"]?.arrayValue?.first?["terminal"]?.stringValue == "t1")
        #expect(tab?["terminals"]?.arrayValue?.first?["pane"]?.stringValue == "p1")
    }

    @Test("control status carries app activation, the seen-write guard")
    func controlStatusActive() {
        let model = modelWithOnePane()
        #expect(!model.appActive)
        let inactive: JSONValue? = model.controlStatus()["active"]
        #expect(inactive == JSONValue.bool(false))
        model.appActive = true
        let active: JSONValue? = model.controlStatus()["active"]
        #expect(active == JSONValue.bool(true))
        // The very flag `shareSeen` gates `herdr.seen` writes on.
        #expect(model.appActive)
    }
}
