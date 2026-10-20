// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Read-only projections of the snapshot.
//
// These answer "what is focused / what is visible / which pane would an action
// hit". They are separated from `AppStore` for length only; nothing here mutates
// state, which is what makes the file safe to read as a unit.

import KraalProtocol

extension AppStore {
    /// The panes of the focused tab, in surface order.
    public var visiblePanes: [ClientShellPane] {
        guard let tab = focusedTab else { return panes }
        return panes.filter { $0.tabId == tab.tabId }
    }

    /// The label shown for a pane in a rename prompt.
    public func paneLabel(_ paneId: String) -> String? {
        panes.first { $0.paneId == paneId }?.label
    }

    /// Whether the pane is the zoomed one. Herdr's menu renames the item between
    /// "Zoom" and "Unzoom" rather than leaving a single verb that lies half the
    /// time, so the same distinction is made here.
    public func isZoomed(paneId: String) -> Bool {
        if let tab = tabs.first(where: { $0.tabId == tab(forPane: paneId)?.tabId }) {
            return tab.zoomed
        }
        return false
    }

    public func zoomLabel(forPane paneId: String) -> String {
        isZoomed(paneId: paneId) ? "Unzoom Pane" : "Zoom Pane"
    }

    private func tab(forPane paneId: String) -> ClientShellTab? {
        guard let pane = panes.first(where: { $0.paneId == paneId }) else { return nil }
        return tabs.first { $0.tabId == pane.tabId }
    }

    /// Moves the focused tab one slot along the tab bar. `tab.move` takes an
    /// absolute `insert_index`, so the target is computed from the tab's
    /// current position and clamped; asking to move past either end is a no-op
    /// rather than a request the daemon will reject.
    public func shiftFocusedTab(by delta: Int) {
        let tabs = visibleTabs
        guard let current = tabs.firstIndex(where: { $0.focused })
            ?? tabs.firstIndex(where: { $0.tabId == actionTabId })
        else { return }
        let target = current + delta
        guard tabs.indices.contains(target) else { return }
        move(tabId: tabs[current].tabId, toIndex: target)
    }

    public var agentsOrdered: [ClientShellAgent] {
        guard let snapshot else { return [] }
        let byPane = Dictionary(
            uniqueKeysWithValues: snapshot.agents.map { ($0.paneId, $0) }
        )
        if snapshot.agentOrder.isEmpty {
            return snapshot.agents
        }
        return snapshot.agentOrder.compactMap { byPane[$0] }
    }

    public func workspace(for tab: ClientShellTab) -> ClientShellWorkspace? {
        workspaces.first { $0.workspaceId == tab.workspaceId }
    }

    public func tab(for pane: ClientShellPane) -> ClientShellTab? {
        tabs.first { $0.tabId == pane.tabId }
    }

    public func agent(forPane paneId: String) -> ClientShellAgent? {
        snapshot?.agents.first { $0.paneId == paneId }
    }

    public func paneGeometry(for paneId: String) -> PaneSurfacePane? {
        surface?.panes.first { $0.paneId == paneId }
    }

    /// Splits that belong to the current surface, for divider dragging.
    public var splits: [PaneSurfaceSplit] { surface?.splits ?? [] }

}
