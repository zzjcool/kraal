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

    /// Moves a whole block of workspaces so it sits before `beforeWorkspaceId`.
    ///
    /// This is what a sidebar drag reorders: `workspace.move` takes one id and an
    /// index, which cannot express "take these three linked worktrees and drop
    /// them together" — the linked group is a block, and moving it one id at a
    /// time would have the daemon re-derive the group between calls. Upstream has
    /// the same split (`workspace.move_block`, `api/workspaces.rs:171-230`).
    ///
    /// `beforeWorkspaceId == nil` means "to the end", which is how the daemon
    /// reads a missing `before_workspace_id`.
    ///
    /// The request is not sent when the daemon would reject it — empty block, or
    /// a `before` that is itself in the block — because the daemon's answer to
    /// both is an error the user cannot act on, and a drag that does nothing is
    /// less confusing than a red banner for a gesture that was already a no-op.
    public func moveWorkspaceBlock(_ workspaceIds: [String], before beforeWorkspaceId: String?) {
        guard Self.isValidWorkspaceBlock(
            workspaceIds,
            before: beforeWorkspaceId
        ) else { return }
        Task {
            await call(
                "workspace.move_block",
                Self.workspaceBlockParams(workspaceIds, before: beforeWorkspaceId)
            )
        }
    }

    /// The wire body of `workspace.move_block`, so the shape is testable without
    /// a daemon. `before_workspace_id` is omitted rather than sent as `null`:
    /// the daemon's field is `Option` with `skip_serializing_if`, and a literal
    /// `null` would have to be decoded as `Some(None)`-shaped noise.
    public nonisolated static func workspaceBlockParams(
        _ workspaceIds: [String],
        before beforeWorkspaceId: String?
    ) -> [String: Any] {
        var params: [String: Any] = ["workspace_ids": workspaceIds]
        if let beforeWorkspaceId {
            params["before_workspace_id"] = beforeWorkspaceId
        }
        return params
    }

    /// Whether the daemon would accept this block move.
    ///
    /// Mirrors the two rejections in `api/workspaces.rs:176-217`: an empty block,
    /// and a `before` that is part of the block. Duplicate ids are also rejected
    /// there; they cannot come from a sidebar drag, but checking is free and keeps
    /// the guard honest if a caller ever builds the list differently.
    public nonisolated static func isValidWorkspaceBlock(
        _ workspaceIds: [String],
        before beforeWorkspaceId: String?
    ) -> Bool {
        guard !workspaceIds.isEmpty else { return false }
        guard Set(workspaceIds).count == workspaceIds.count else { return false }
        if let beforeWorkspaceId, workspaceIds.contains(beforeWorkspaceId) { return false }
        return true
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

    /// Scrolls a pane's own history to an absolute position.
    ///
    /// The daemon's `pane.scroll` takes `offset_from_bottom`, not a delta: it sets
    /// where the viewport should sit rather than moving it by some amount. Sending
    /// a delta would be read literally as "jump to line N", which jumps to the top
    /// of history on any upward scroll.
    ///
    /// Absent an absolute target, a wheel gesture is a *rate*, not a list of
    /// destinations — so the wheel path goes through `scrollPaneBy` instead, which
    /// coalesces. This entry point stays for the callers that genuinely have a
    /// destination: the scrollbar thumb, copy mode, and the pane menu.
    public func scrollPane(paneId: String, toOffsetFromBottom offset: UInt64) {
        Task { await call("pane.scroll", ["pane_id": paneId, "offset_from_bottom": offset]) }
    }

    /// Builds the focus tracker, kept out of `AppStore.swift` for the same reason
    /// as the queue below: that file is at SwiftLint's type-length limit.
    ///
    /// Captures `store` weakly — the tracker must not keep its store alive.
    @MainActor
    static func makeFocusConfirmation(_ store: AppStore) -> FocusConfirmation {
        FocusConfirmation { [weak store] paneId in
            await store?.sendPaneFocus(paneId) ?? false
        }
    }

    /// Builds the coalescing queue, kept out of `AppStore.swift` so that file stays
    /// under SwiftLint's type-length limit.
    ///
    /// `@MainActor` because `PaneScrollQueue` is, and `self` is captured weakly: the
    /// queue must not keep its store alive.
    @MainActor
    static func makePaneScrollQueue(_ store: AppStore) -> PaneScrollQueue {
        PaneScrollQueue { [weak store] paneId, offset in
            await store?.call("pane.scroll", ["pane_id": paneId, "offset_from_bottom": offset])
        }
    }

    /// Moves a pane's history by a gesture instead of to a destination.
    ///
    /// This is what a wheel event calls. It exists because a trackpad emits one
    /// event per frame and sending each as its own `pane.scroll` both flooded the
    /// one-command-at-a-time connection and carried targets computed from a stale
    /// snapshot — measured 281 refusals against 791 successes, and an offset that
    /// visibly jumped backwards mid-gesture (issue #94). See `PaneScrollQueue`.
    ///
    /// `current` is only used the first time a pane is scrolled, to seed the queue;
    /// after that the queue tracks its own target, because the snapshot always lags
    /// the gesture.
    public func scrollPaneBy(
        paneId: String, lines: Int, current: UInt64, maxOffset: UInt64
    ) {
        paneScrollQueue.scroll(
            paneId: paneId, lines: lines, current: current, maxOffset: maxOffset
        )
    }

    /// Re-reads config.toml on the daemon side (theme, keybindings, sidebar).
    public func reloadServerConfig() {
        Task { await call("server.reload_config", [:]) }
    }

}
