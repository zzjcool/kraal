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

    @Test("after a snapshot, a pane whose terminal is gone is dropped")
    func afterSnapshot() {
        let model = modelWithOnePane()
        model.hasSnapshot = true
        model.reconcile()
        #expect(model.workspace.space("sp1") == nil)
    }
}
