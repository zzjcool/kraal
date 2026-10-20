// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Context menus, one per kind of row.
//
// Herdr's pane menu is long: split in either direction, zoom, directional
// focus/swap/resize, rename, close. Rather than repeat that list at each call
// site — the sidebar lists panes twice (agents, and the pane fallback) — it lives
// here once and is attached wherever a pane is shown.
//
// The destructive items always come last. A context menu opens under the pointer,
// so the top entries are the ones a mis-click is most likely to hit.

import KraalProtocol
import SwiftUI

// MARK: - Pane

struct PaneContextMenu: View {
    @Environment(AppStore.self) private var store
    @Binding var prompt: CommandPrompt?

    let paneId: String

    var body: some View {
        Button("Focus Pane") { store.focus(paneId: paneId) }
        Divider()

        Button("Split Right") { store.splitPane(paneId: paneId, orientation: .right) }
        Button("Split Down") { store.splitPane(paneId: paneId, orientation: .down) }
        Button(store.zoomLabel(forPane: paneId)) { store.toggleZoom(paneId: paneId) }
        Divider()

        Menu("Focus Pane Direction") {
            ForEach(PaneDirection.allCases, id: \.rawValue) { direction in
                Button(direction.title) { store.focusDirection(direction) }
            }
        }
        Menu("Swap Pane") {
            ForEach(PaneDirection.allCases, id: \.rawValue) { direction in
                Button("Swap \(direction.title)") { store.swapPane(direction) }
                    .disabled(store.visiblePanes.count < 2)
            }
        }
        Menu("Resize Pane") {
            ForEach(PaneDirection.allCases, id: \.rawValue) { direction in
                Button("Resize \(direction.title)") { store.resizePane(direction) }
            }
        }
        Divider()

        Button("Clear Pane") { store.clearPane(paneId: paneId) }
        Button("Rename Pane…") {
            prompt = .renamePane(paneId: paneId, current: store.paneLabel(paneId) ?? "")
        }
        Divider()
        Button("Close Pane", role: .destructive) { store.close(paneId: paneId) }
    }
}

// MARK: - Tab

struct TabContextMenu: View {
    @Environment(AppStore.self) private var store
    @Binding var prompt: CommandPrompt?

    let tab: ClientShellTab

    var body: some View {
        Button("Focus Tab") { store.focus(tabId: tab.tabId) }
        Divider()

        Button("Split Right") { store.splitPane(paneId: firstPaneId, orientation: .right) }
            .disabled(firstPaneId.isEmpty)
        Button("Split Down") { store.splitPane(paneId: firstPaneId, orientation: .down) }
            .disabled(firstPaneId.isEmpty)
        Divider()

        Button("Rename Tab…") {
            prompt = .renameTab(tabId: tab.tabId, current: tab.label)
        }
        Button("Move Tab Left") { store.move(tabId: tab.tabId, toIndex: index - 1) }
            .disabled(index <= 0)
        Button("Move Tab Right") { store.move(tabId: tab.tabId, toIndex: index + 1) }
            .disabled(index >= store.visibleTabs.count - 1)
        Divider()

        Button("New Tab") { store.createTab() }
        Divider()
        Button("Close Tab", role: .destructive) { store.close(tabId: tab.tabId) }
    }

    private var firstPaneId: String {
        store.panes.first { $0.tabId == tab.tabId }?.paneId ?? ""
    }

    private var index: Int {
        store.visibleTabs.firstIndex { $0.tabId == tab.tabId } ?? 0
    }
}

// MARK: - Workspace

struct WorkspaceContextMenu: View {
    @Environment(AppStore.self) private var store
    @Binding var prompt: CommandPrompt?

    let workspace: ClientShellWorkspace

    var body: some View {
        Button("Focus Workspace") { store.focus(workspaceId: workspace.workspaceId) }
        Divider()

        Button("New Tab") { store.createTab() }
        Button("New Workspace") { store.createWorkspace() }
        Divider()

        Button("Rename Workspace…") {
            prompt = .renameWorkspace(
                workspaceId: workspace.workspaceId,
                current: workspace.label
            )
        }
        Button("Move Workspace Up") { store.move(workspaceId: workspace.workspaceId, toIndex: index - 1) }
            .disabled(index <= 0)
        Button("Move Workspace Down") { store.move(workspaceId: workspace.workspaceId, toIndex: index + 1) }
            .disabled(index >= store.workspaces.count - 1)
        Divider()
        Button("Close Workspace", role: .destructive) {
            store.close(workspaceId: workspace.workspaceId)
        }
    }

    private var index: Int {
        store.workspaces.firstIndex { $0.workspaceId == workspace.workspaceId } ?? 0
    }
}
