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

    /// The snapshot record for a pane.
    ///
    /// `paneGeometry` answers questions about the *surface* (size, mouse mode);
    /// this answers questions about the pane itself (label, cwd, and the
    /// `right_click` setting). The two were easy to conflate, which is how
    /// `right_click_passthrough` ended up decoded and never read: the only pane
    /// lookup the mouse path had access to was the surface one.
    public func pane(_ paneId: String) -> ClientShellPane? {
        panes.first { $0.paneId == paneId }
    }

    /// Whether this pane sends right-clicks to its program instead of opening
    /// the pane menu.
    public func rightClickPassthrough(paneId: String) -> Bool {
        pane(paneId)?.rightClickPassthrough ?? false
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
        guard let plan = shiftFocusedTabPlan(by: delta) else { return }
        move(tabId: plan.tabId, toIndex: plan.index)
    }

    /// The target a shift would move to, or nil when there is nothing to do.
    ///
    /// Split out so the boundary is assertable. `move` only sends an asynchronous
    /// request and does not touch local order, so a test watching `visibleTabs` passed
    /// with the bounds check **removed** — it was asserting that a request sent into
    /// nothing changed nothing. The plan is the decision itself.
    public struct TabShift: Equatable, Sendable {
        public var tabId: String
        public var index: Int
    }

    public func shiftFocusedTabPlan(by delta: Int) -> TabShift? {
        let tabs = visibleTabs
        guard let current = tabs.firstIndex(where: { $0.focused })
            ?? tabs.firstIndex(where: { $0.tabId == actionTabId })
        else { return nil }
        let target = current + delta
        // `tab.move` takes an absolute `insert_index`; asking for one past either end
        // is a request the daemon rejects.
        guard tabs.indices.contains(target) else { return nil }
        return TabShift(tabId: tabs[current].tabId, index: target)
    }

    /// Every machine's agents, in the pane's display order.
    ///
    /// Upstream lists all endpoints here, not just the active one, and carries the
    /// machine label on each row (`src/client/shell/endpoint_agents.rs:132-174`).
    /// The rules live in `AgentAggregation` so they can be tested without a live
    /// connection.
    public var aggregatedAgents: [AggregatedAgent] {
        AgentAggregation.rows(
            endpoints.compactMap { endpoint in
                guard let snapshot = endpoint.snapshot else { return nil }
                return AgentAggregationSource(
                    endpointID: endpoint.id.storageKey,
                    label: endpoint.label,
                    isConnected: endpoint.isConnected,
                    snapshot: snapshot
                )
            },
            // `nil` when no machine is selected yet: then none of them is active, so
            // every row's `focused` is cleared, which is the truthful answer.
            activeEndpointID: activeEndpointID?.storageKey ?? "",
            sort: agentPanelSort,
            recency: agentRecency
        )
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
