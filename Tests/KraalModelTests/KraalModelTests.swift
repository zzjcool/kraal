// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import KraalHC
import Testing

@testable import KraalModel

@Suite("Model")
struct KraalModelTests {
    @Test("folder names match herdr on every path style")
    func folderNames() {
        #expect(KraalModel.folderName("/home/can", home: "/home/can") == "~")
        #expect(KraalModel.folderName("/home/can/", home: "/home/can") == "~")
        #expect(KraalModel.folderName("/Users/can/Projects/herdr", home: "/Users/can") == "herdr")
        #expect(KraalModel.folderName("/", home: "/home/can") == "/")
        #expect(KraalModel.folderName("", home: "/home/can") == "~")
        #expect(KraalModel.folderName(#"C:\Users\can\src\api"#, home: #"C:\Users\can"#) == "api")
        #expect(KraalModel.folderName(#"\\?\C:\Users\can\src\api\"#, home: #"C:\Users\can"#) == "api")
        #expect(KraalModel.folderName("C:/Users/can/src/web", home: #"C:\Users\can"#) == "web")
    }

    @Test("unnamed spaces follow their first terminal and tabs count")
    func naming() throws {
        var model = KraalModel(home: "/home/me")
        model.addSpace(
            id: "sp1", folder: "/home/me",
            tab: KraalTabSeed(id: "tb1", paneID: "p1", terminal: "t1")
        )
        model.addTab(space: "sp1", tab: KraalTabSeed(id: "tb2", name: "review", paneID: "p2", terminal: "t2"))
        model.addTab(space: "sp1", tab: KraalTabSeed(id: "tb3", paneID: "p3", terminal: "t3"))
        var space = try #require(model.space("sp1"))
        #expect(space.displayName == "~")
        model.paneFolders["p1"] = "/src/notes"
        space = try #require(model.space("sp1"))
        #expect(space.displayName == "notes")
        model.terminalFolders["t1"] = KraalFolderInfo(top: "/src/herdr", branch: "main")
        space = try #require(model.space("sp1"))
        #expect(space.displayName == "herdr")
        #expect(space.tabs.map(\.displayName) == ["1", "review", "3"])
        let didRename = model.renameSpace("sp1", to: "api")
        #expect(didRename)
        #expect(model.space("sp1")?.displayName == "api")
    }

    @Test("naming skips a mod pane and uses the first terminal")
    func namingSkipsMods() throws {
        var model = KraalModel(home: "/home/me")
        model.addSpace(
            id: "sp1", folder: "/home/me",
            tab: KraalTabSeed(id: "tb1", paneID: "p1", terminal: "t1")
        )
        let mod: JSONValue = .object([
            "id": .string("p0"),
            "type": .string("block"),
            "content": .object(["mod": .string("markdown")]),
        ])
        model.splitWith(pane: "p1", axis: .row, node: mod)
        model.focus(pane: "p0", select: false)
        model.terminalFolders["t1"] = KraalFolderInfo(top: "/src/herdr")
        let space = try #require(model.space("sp1"))
        #expect(space.displayName == "herdr")
    }

    @Test("new tabs go after the selected one")
    func tabOrder() throws {
        var model = modelWithOne()
        model.addTab(space: "sp1", tab: KraalTabSeed(id: "tb2", name: "b", paneID: "p2", terminal: "t2"))
        model.selectTab("tb1")
        model.addTab(space: "sp1", tab: KraalTabSeed(id: "tb3", name: "c", paneID: "p3", terminal: "t3"))
        let space = try #require(model.space("sp1"))
        #expect(space.tabs.map(\.id) == ["tb1", "tb3", "tb2"])
        #expect(space.activeTab == "tb3")
    }

    @Test("splits focus the new pane and closing it moves focus")
    func splitFocus() throws {
        var model = modelWithOne()
        let didSplit = model.split(pane: "p1", axis: .row, newPane: "p9", terminal: "t9")
        #expect(didSplit)
        #expect(model.focusedPane == "p9")
        let closed = model.removePane("p9")
        #expect(closed == (false, false))
        #expect(model.focusedPane == "p1")
        #expect(model.tab("tb1")?.root.id == "tb1")
    }

    @Test("closing the focused pane goes back to the one before")
    func focusHistory() throws {
        var model = modelWithOne()
        model.split(pane: "p1", axis: .row, newPane: "p2", terminal: "t2")
        model.split(pane: "p2", axis: .row, newPane: "p3", terminal: "t3")
        model.removePane("p3")
        #expect(model.focusedPane == "p2")

        model.split(pane: "p2", axis: .row, newPane: "p4", terminal: "t4")
        model.focus(pane: "p1", select: false)
        model.focus(pane: "p4", select: false)
        model.removePane("p4")
        #expect(model.focusedPane == "p1")

        model.split(pane: "p2", axis: .row, newPane: "p5", terminal: "t5")
        model.focus(pane: "p2", select: false)
        model.removePane("p5")
        model.removePane("p2")
        #expect(model.focusedPane == "p1")
    }

    @Test("focus history keeps the most recent 32")
    func focusHistoryCap() throws {
        var model = modelWithOne()
        for index in 2 ... 40 {
            model.split(pane: "p1", axis: .row, newPane: "p\(index)", terminal: "t\(index)")
        }
        for index in 1 ... 40 {
            model.focus(pane: "p\(index)", select: false)
        }
        let state = try #require(model.view.tabs["tb1"])
        #expect(state.before.count == 32)
        #expect(state.before.last == "p39")
        #expect(state.focused == "p40")
    }

    @Test("settling the shown tab hands over and showing it brings it back")
    func settle() throws {
        var model = modelWithOne()
        model.addTab(space: "sp1", tab: KraalTabSeed(id: "tb2", name: "docs", paneID: "p2", terminal: "t2"))
        model.selectTab("tb1")
        let didSettle = model.settle("tb1", at: 5)
        #expect(didSettle)
        #expect(model.space("sp1")?.activeTab == "tb2")
        #expect(model.view.tabs["tb1"]?.settled == 5)
        let didSettle2 = model.settle("tb2", at: 6)
        #expect(didSettle2)
        #expect(model.space("sp1")?.activeTab == "tb2")
        let didSelect = model.selectTab("tb1")
        #expect(didSelect)
        #expect(model.view.tabs["tb1"]?.settled == nil)
    }

    @Test("next and previous tab skip settled ones")
    func cycleTabs() throws {
        var model = modelWithOne()
        model.addTab(space: "sp1", tab: KraalTabSeed(id: "tb2", name: "b", paneID: "p2", terminal: "t2"))
        model.addTab(space: "sp1", tab: KraalTabSeed(id: "tb3", name: "c", paneID: "p3", terminal: "t3"))
        model.selectTab("tb1")
        model.settle("tb2", at: 5)
        let didSelect = model.selectTab("tb1")
        #expect(didSelect)
        let firstNext = model.nextTab()
        #expect(firstNext)
        #expect(model.space("sp1")?.activeTab == "tb3")
        let secondNext = model.nextTab()
        #expect(secondNext)
        #expect(model.space("sp1")?.activeTab == "tb1")
        let didPrevious = model.previousTab()
        #expect(didPrevious)
        #expect(model.space("sp1")?.activeTab == "tb3")
    }

    @Test("closing the last pane closes tab then space and remembers it")
    func closeCascade() throws {
        var model = modelWithOne()
        model.addTab(space: "sp1", tab: KraalTabSeed(id: "tb2", name: "docs", paneID: "p2", terminal: "t2"))
        model.addSpace(
            id: "sp2", name: "web", folder: "/src/web",
            tab: KraalTabSeed(id: "tb3", name: "deploy", paneID: "p3", terminal: "t3")
        )
        #expect(model.activeSpace?.id == "sp2")
        let closedSpace = model.removePane("p3")
        #expect(closedSpace == (true, true))
        #expect(model.activeSpace?.id == "sp1")
        #expect(model.recent == [KraalRecent(name: "web", folder: "/src/web")])
        let closedTab = model.removePane("p2")
        #expect(closedTab == (true, false))
        #expect(model.space("sp1")?.activeTab == "tb1")
        let reAdded = model.addSpace(
            id: "sp4", name: "web", folder: "/src/web",
            tab: KraalTabSeed(id: "tb4", name: "x", paneID: "p4", terminal: "t4")
        )
        #expect(reAdded)
        #expect(model.recent.isEmpty)
    }

    @Test("a mod is a pane beside terminals")
    func modPane() throws {
        var model = modelWithOne()
        let mod: JSONValue = .object([
            "id": .string("p2"),
            "type": .string("block"),
            "content": .object(["mod": .string("markdown"), "props": .object(["file": .string("README.md")])]),
        ])
        let didSplit = model.splitWith(pane: "p1", axis: .row, node: mod)
        #expect(didSplit)
        #expect(model.focusedPane == "p2")
        #expect(model.tab("tb1")?.root.panes.count == 2)
        let closedResult = model.removePane("p1")
        #expect(closedResult == (false, false))
        #expect(model.tab("tb1")?.root.panes.count == 1)
        let closedMod = model.removePane("p2")
        #expect(closedMod == (true, true))
    }

    @Test("zoom only applies to a pane in a split tab and clears on split")
    func zoom() throws {
        var model = modelWithOne()
        let didNot = model.zoom("p1")
        #expect(!didNot)
        model.split(pane: "p1", axis: .row, newPane: "p2", terminal: "t2")
        let didZoom = model.zoom("p1")
        #expect(didZoom)
        #expect(model.tab("tb1")?.zoomed == "p1")
        #expect(model.tab("tb1")?.shown.id == "p1")
        let didUnzoom = model.unzoom()
        #expect(didUnzoom)
        #expect(model.tab("tb1")?.zoomed == nil)
        let didToggle = model.toggleZoom("p1")
        #expect(didToggle)
        #expect(model.tab("tb1")?.zoomed == "p1")
        let didToggleOff = model.toggleZoom("p1")
        #expect(didToggleOff)
        #expect(model.tab("tb1")?.zoomed == nil)
        let didZoomAgain = model.zoom("p1")
        #expect(didZoomAgain)
        model.split(pane: "p2", axis: .row, newPane: "p3", terminal: "t3")
        #expect(model.tab("tb1")?.zoomed == nil)
    }

    @Test("recent spaces are unique, newest first, capped at 20")
    func recent() throws {
        var model = KraalModel(home: "/home/me")
        for index in 1 ... 25 {
            model.addSpace(
                id: "sp\(index)", name: "s\(index)", folder: "/src/\(index)",
                tab: KraalTabSeed(id: "tb\(index)", paneID: "p\(index)", terminal: "t\(index)")
            )
        }
        for index in 1 ... 25 {
            _ = model.removeSpace("sp\(index)")
        }
        #expect(model.recent.count == 20)
        #expect(model.recent.first?.name == "s25")
        #expect(model.recent.last?.name == "s6")
        #expect(Set(model.recent.map(\.name)).count == 20)
    }
}
