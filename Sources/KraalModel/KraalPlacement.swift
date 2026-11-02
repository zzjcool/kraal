// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Putting a terminal into the layout. This is the client half of the label
// contract: `herdr.space`/`herdr.tab` on the core's record say where a terminal
// belongs; the client makes that place exist when it does not, without
// changing what the person is looking at.

import Foundation
import KraalHC

extension KraalModel {
    /// The pane holding a terminal address, anywhere in the model.
    public func paneID(ofTerminal address: String) -> String? {
        for space in spaces {
            for tab in space.tabs {
                if let pane = tab.root.panes.first(where: { $0.terminal == address }) {
                    return pane.id
                }
            }
        }
        return nil
    }

    public func terminal(ofPane pane: String) -> String? {
        tab(ofPane: pane)?.root.find(pane)?.terminal
    }

    /// The tabs each terminal is placed in; a terminal belongs to one pane.
    public var placedTerminals: [String: String] {
        var result: [String: String] = [:]
        for space in spaces {
            for tab in space.tabs {
                for pane in tab.root.panes {
                    if let terminal = pane.terminal {
                        result[terminal] = pane.id
                    }
                }
            }
        }
        return result
    }

    /// Places `address` where its labels say, creating a space/tab it does not
    /// know yet. A space or tab created this way is unnamed, as if the core had
    /// been the one to open it.
    ///
    /// - Parameters:
    ///   - spaceID: qualified space id from `herdr.space`.
    ///   - tabID: qualified tab id from `herdr.tab`, when the label has one.
    ///   - folder: the terminal's live folder, used for a new space's title.
    /// - Returns: the pane id, or nil when the layout already has this terminal
    ///   or the insertion failed.
    @discardableResult
    public mutating func adopt(
        terminal address: String,
        space spaceID: String,
        tab tabID: String? = nil,
        folder: String = "",
        machine: String? = nil
    ) -> String? {
        if let existing = paneID(ofTerminal: address) {
            return existing
        }
        let machine = machine ?? machineOf(id: spaceID)
        guard spaceIndex(spaceID) != nil else {
            let paneID = freshPaneID(machine: machine)
            let seed = KraalTabSeed(
                id: tabID ?? freshTabID(machine: machine),
                paneID: paneID,
                terminal: address
            )
            let active = view.activeSpace
            guard addSpace(id: spaceID, name: "", folder: folder, machine: machine, tab: seed) else {
                return nil
            }
            // Found by its label, not opened by the person: it must not take
            // over the space that is being looked at.
            view.activeSpace = active
            return paneID
        }

        let paneID = freshPaneID(machine: machine)
        if let tabID, let target = tab(tabID),
           space(of: tabID)?.id == spaceID,
           let last = target.panes.last {
            let previous = view.tabs[tabID] ?? KraalTabView()
            guard splitWith(
                pane: last.id,
                axis: .row,
                node: HcLayoutDocument.terminalNode(id: paneID, terminal: address),
                focus: false
            ) else { return nil }
            view.tabs[tabID] = previous
            return paneID
        }

        let activeTab = view.activeTabs[spaceID]
        // A label naming a tab of another space must not move it: use a fresh
        // id in the space the terminal actually claims.
        let seedTabID = tabID.flatMap { tab($0) == nil ? $0 : nil } ?? freshTabID(machine: machine)
        let seed = KraalTabSeed(id: seedTabID, paneID: paneID, terminal: address)
        guard addTab(space: spaceID, tab: seed) else { return nil }
        view.activeTabs[spaceID] = activeTab
        return paneID
    }

    /// The space a tab belongs to.
    public func space(of tabID: String) -> KraalSpace? {
        spaces.first { $0.tabs.contains { $0.id == tabID } }
    }
}
