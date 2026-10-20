// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Actions the menu bar and context menus invoke.
//
// Split out of `AppStore.swift` for length, not for architecture: these are the
// same kind of request-per-intent wrappers as the focus/close methods that stayed
// behind. Every one of them is a single endpoint call, which is why they can live
// in one file and stay readable.
//
// The daemon validates these requests itself — `pane.swap` needs a neighbour,
// `tab.move` needs a real index — so the client-side guards here only exist to
// stop an obviously-doomed click from reaching the wire.

import Foundation
import KraalProtocol

extension AppStore {
    // MARK: - Directional moves

    /// Directional focus. The daemon resolves what "right" means from the
    /// split tree, which is why this is a request and not a client-side walk.
    public func focusDirection(_ direction: PaneDirection) {
        Task { await call("pane.focus_direction", ["direction": direction.rawValue]) }
    }

    /// Swaps the focused pane with its neighbour in `direction`.
    public func swapPane(_ direction: PaneDirection) {
        Task { await call("pane.swap", ["direction": direction.rawValue]) }
    }

    public func resizePane(_ direction: PaneDirection) {
        Task { await call("pane.resize", ["direction": direction.rawValue]) }
    }

    // MARK: - Reordering

    /// `insert_index` is absolute within the workspace, not a delta, so the
    /// caller has to know the tab's current position. Moving a tab onto itself
    /// is rejected by the daemon, hence the guard.
    public func move(tabId: String, toIndex index: Int) {
        guard index >= 0 else { return }
        Task { await call("tab.move", ["tab_id": tabId, "insert_index": index]) }
    }

    public func move(workspaceId: String, toIndex index: Int) {
        guard index >= 0 else { return }
        Task { await call("workspace.move", ["workspace_id": workspaceId, "insert_index": index]) }
    }

    // MARK: - Naming

    public func rename(tabId: String, to label: String) {
        Task { await call("tab.rename", ["tab_id": tabId, "label": label]) }
    }

    public func rename(workspaceId: String, to label: String) {
        Task { await call("workspace.rename", ["workspace_id": workspaceId, "label": label]) }
    }

    public func rename(paneId: String, to label: String) {
        Task { await call("pane.rename", ["pane_id": paneId, "label": label]) }
    }

    // MARK: - Pane content

    public func clearPane(paneId: String) {
        Task { await call("pane.clear", ["pane_id": paneId]) }
    }

    public func scrollPane(paneId: String, delta: Int) {
        Task { await call("pane.scroll", ["pane_id": paneId, "delta": delta]) }
    }

    /// Re-reads config.toml on the daemon side (theme, keybindings, sidebar).
    public func reloadServerConfig() {
        Task { await call("server.reload_config", [:]) }
    }

}
