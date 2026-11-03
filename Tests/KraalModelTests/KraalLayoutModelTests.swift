// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import KraalHC
import Testing

@testable import KraalModel

@Suite("Model layout")
struct KraalLayoutModelTests {
    private func threePanes() -> KraalModel {
        var model = modelWithOne()
        model.split(pane: "p1", axis: .row, newPane: "p2", terminal: "t2")
        model.split(pane: "p2", axis: .column, newPane: "p3", terminal: "t3")
        return model
    }

    @Test("moving a pane to an edge keeps terminals and focus")
    func moveEdges() throws {
        for edge in KraalEdge.allCases {
            var model = threePanes()
            let didMove = model.movePane("p1", to: "p3", edge: edge)
            #expect(didMove)
            #expect(model.focusedPane == "p1")
            let tab = try #require(model.tab("tb1"))
            #expect(tab.root.panes.count == 3)
            #expect(tab.root.terminals.sorted() == ["t1", "t2", "t3"])
            let container = try #require(parent(of: "p1", in: tab.root))
            #expect(container.type == edge.axis.rawValue)
            let ids = container.children.map(\.id)
            let source = try #require(ids.firstIndex(of: "p1"))
            let target = try #require(ids.firstIndex(of: "p3"))
            #expect((source < target) == edge.beforeTarget)
            #expect(abs(source - target) == 1)
        }
    }

    @Test("moving without an edge swaps the places")
    func swapPlaces() throws {
        var model = threePanes()
        let didMove = model.movePane("p1", to: "p3")
        #expect(didMove)
        #expect(model.focusedPane == "p1")
        let tab = try #require(model.tab("tb1"))
        let root = tab.root
        let firstPane = try #require(root.find("p1"))
        let lastPane = try #require(root.find("p3"))
        #expect(firstPane.terminal == "t1")
        #expect(lastPane.terminal == "t3")
        #expect(root.panes.map(\.id) == ["p3", "p2", "p1"])
    }

    @Test("moving a tab uses 1-based positions and clamps at both ends")
    func moveTabs() throws {
        var model = modelWithOne()
        for index in 2 ... 3 {
            model.addTab(
                space: "sp1",
                tab: KraalTabSeed(
                    id: "tb\(index)", name: "tab \(index)", paneID: "p\(index)", terminal: "t\(index)"
                )
            )
        }
        let first = model.moveTab("tb3", to: 1)
        #expect(first)
        #expect(model.space("sp1")?.tabs.map(\.id) == ["tb3", "tb1", "tb2"])
        let pastEnd = model.moveTab("tb3", to: 99)
        #expect(pastEnd)
        #expect(model.space("sp1")?.tabs.map(\.id) == ["tb1", "tb2", "tb3"])
        let beforeStart = model.moveTab("tb2", to: -4)
        #expect(beforeStart)
        #expect(model.space("sp1")?.tabs.map(\.id) == ["tb2", "tb1", "tb3"])
        let missing = model.moveTab("missing", to: 1)
        #expect(!missing)
    }

    @Test("cross-axis moves start the new split equal, not with the old slot")
    func crossAxisSizes() throws {
        var model = modelWithOne()
        model.split(pane: "p1", axis: .row, newPane: "p2", terminal: "t2")
        let didMove = model.movePane("p2", to: "p1", edge: .bottom)
        #expect(didMove)
        let root = try #require(model.tab("tb1")?.root)
        let container = try #require(parent(of: "p2", in: root))
        #expect(container.children.count == 2)
        #expect(container.children.allSatisfy { $0.raw["size"] == nil })
    }

    @Test("invalid moves leave the model alone")
    func invalidMoves() throws {
        var model = modelWithOne()
        model.addTab(space: "sp1", tab: KraalTabSeed(id: "tb2", paneID: "p2", terminal: "t2"))
        let before = model
        let selfMove = model.movePane("p1", to: "p1")
        let missingTarget = model.movePane("p1", to: "missing")
        let missingSource = model.movePane("missing", to: "p1")
        let containerTarget = model.movePane("p1", to: "tb2")
        #expect(!selfMove)
        #expect(!missingTarget)
        #expect(!missingSource)
        #expect(!containerTarget)
        #expect(model == before)
    }

    @Test("swap keeps sizes with the places")
    func swapSizes() throws {
        var model = modelWithOne()
        model.split(pane: "p1", axis: .row, newPane: "p2", terminal: "t2")
        let didSwap = model.swapPanes("p1", "p2")
        #expect(didSwap)
        let root = try #require(model.tab("tb1")?.root)
        #expect(root.children.map(\.id) == ["p2", "p1"])
        #expect(root.children[0].terminal == "t2")
        #expect(root.children[1].terminal == "t1")
        #expect(root.children[0].raw["size"]?["weight"]?.doubleValue == 0.5)
    }

    @Test("any split/move/close sequence keeps the tree valid")
    func invariants() throws {
        var model = modelWithOne()
        var counter = 2
        for step in 0 ..< 40 {
            let panes = try #require(model.tab("tb1")?.root.panes)
            let target = panes[step % panes.count]
            switch step % 4 {
            case 0, 1:
                model.split(
                    pane: target.id,
                    axis: step.isMultiple(of: 2) ? .row : .column,
                    newPane: "p\(counter)",
                    terminal: "t\(counter)"
                )
                counter += 1
            case 2 where panes.count > 1:
                let other = panes[(step * 3 + 1) % panes.count]
                model.movePane(target.id, to: other.id, edge: KraalEdge.allCases[step % 4])
            default:
                if panes.count > 2 {
                    model.removePane(target.id)
                }
            }
            for space in model.spaces {
                for tab in space.tabs {
                    #expect(tab.root.panes.count == tab.terminals.count)
                    #expect(Set(tab.root.panes.map(\.id)).count == tab.root.panes.count)
                    #expect(descendantContainerProblem(tab.root) == nil)
                }
            }
            // The tab may have closed in the last case; bring it back for the
            // next round so the invariant loop keeps running.
            if model.tab("tb1") == nil { break }
        }
        #expect(model.tab("tb1") != nil)
    }

    @Test("spaces order local first and move only within one machine")
    func spaceOrdering() throws {
        var model = modelWithOne()
        model.addSpace(
            id: "sp2", name: "web", folder: "/src/web",
            tab: KraalTabSeed(id: "tb2", paneID: "p2", terminal: "t2")
        )
        model.addSpace(
            id: "sp3", name: "remote", folder: "/src/remote", machine: "alpha",
            tab: KraalTabSeed(id: "tb3", paneID: "p3", terminal: "t3")
        )
        #expect(model.spaces.map(\.id) == ["sp1", "sp2", "alpha/sp3"])
        #expect(model.machines == [nil, "alpha"])

        // A local space cannot be moved into the machine's part.
        let didMove = model.moveSpace("sp1", to: 2)
        #expect(didMove)
        #expect(model.spaces.map(\.id) == ["sp2", "sp1", "alpha/sp3"])
        // A remote space stays after the local ones.
        let didMoveRemote = model.moveSpace("alpha/sp3", to: 0)
        #expect(didMoveRemote)
        #expect(model.spaces.map(\.id) == ["sp2", "sp1", "alpha/sp3"])
        // Within the local part the requested order is honored.
        let didMoveBack = model.moveSpace("sp1", to: 0)
        #expect(didMoveBack)
        #expect(model.spaces.map(\.id) == ["sp1", "sp2", "alpha/sp3"])
    }
}
