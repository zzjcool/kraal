// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Worktree grouping: which sidebar rows are parents, which are nested children,
// and in what order.
//
// Ported from the terminal client (`src/client/shell/sidebar.rs:458-556`,
// `workspace_entries`). The rule that matters — and the one that is easy to get
// wrong — is that a shared `worktree.key` alone does not make a group. A group
// exists only when that key is shared by *both* a linked worktree and its main
// checkout. A repository with three worktrees and no workspace of its own stays
// a flat list of three rows, which is what the daemon reports for a worktree
// created without opening the parent.

import KraalProtocol

/// One row in the sidebar's space list, after grouping.
public struct SidebarSpaceEntry: Equatable, Sendable {
    /// Index into the snapshot's workspace array.
    public var index: Int
    /// True for a linked worktree drawn under its parent.
    public var indented: Bool
    /// True for the last child of a group, which draws `└─` instead of `├─`.
    public var lastChild: Bool

    public init(index: Int, indented: Bool = false, lastChild: Bool = false) {
        self.index = index
        self.indented = indented
        self.lastChild = lastChild
    }
}

public enum SidebarSpaceTree {
    /// Orders workspaces into parent rows and nested worktree rows.
    ///
    /// `collapsedGroups` holds the `worktree.key` values the user folded shut. A
    /// collapsed group still shows one row — the focused child — so the selection
    /// never scrolls out of view while its group is collapsed.
    public static func entries(
        workspaces: [ClientShellWorkspace],
        collapsedGroups: Set<String> = []
    ) -> [SidebarSpaceEntry] {
        // Group members by repository key. Workspaces with no worktree never join.
        var members: [String: [Int]] = [:]
        for (index, workspace) in workspaces.enumerated() {
            guard let key = workspace.worktree?.key else { continue }
            members[key, default: []].append(index)
        }

        // A key is only a group when it has a main checkout *and* a linked one.
        var grouped: Set<String> = []
        for (key, indices) in members {
            let hasLinked = indices.contains { workspaces[$0].worktree?.isLinkedWorktree == true }
            let hasParent = indices.contains { workspaces[$0].worktree?.isLinkedWorktree == false }
            if hasLinked, hasParent { grouped.insert(key) }
        }

        var emitted: Set<String> = []
        var entries: [SidebarSpaceEntry] = []
        entries.reserveCapacity(workspaces.count)

        for (index, workspace) in workspaces.enumerated() {
            guard let key = workspace.worktree?.key, grouped.contains(key) else {
                entries.append(SidebarSpaceEntry(index: index))
                continue
            }
            // The group is emitted at its first member's position, once.
            guard emitted.insert(key).inserted else { continue }

            let groupMembers = members[key] ?? []
            for parent in groupMembers where workspaces[parent].worktree?.isLinkedWorktree == false {
                entries.append(SidebarSpaceEntry(index: parent))
            }

            if collapsedGroups.contains(key) {
                let focusedChild = groupMembers.first { member in
                    workspaces[member].worktree?.isLinkedWorktree == true
                        && workspaces[member].focused
                }
                if let focusedChild {
                    entries.append(SidebarSpaceEntry(index: focusedChild,
                                                     indented: true, lastChild: true))
                }
                continue
            }

            let children = groupMembers.filter { workspaces[$0].worktree?.isLinkedWorktree == true }
            for (childIndex, child) in children.enumerated() {
                entries.append(SidebarSpaceEntry(
                    index: child,
                    indented: true,
                    lastChild: childIndex + 1 == children.count
                ))
            }
        }
        return entries
    }

    /// The `worktree.key` of a parent row that has children to toggle.
    ///
    /// Returns nil for a child row and for a parent whose key is not shared, so a
    /// plain workspace never grows a disclosure arrow.
    public static func toggleKey(
        workspaces: [ClientShellWorkspace],
        index: Int
    ) -> String? {
        guard workspaces.indices.contains(index) else { return nil }
        guard let worktree = workspaces[index].worktree, !worktree.isLinkedWorktree else {
            return nil
        }
        let hasChild = workspaces.contains { candidate in
            candidate.worktree.map { $0.key == worktree.key && $0.isLinkedWorktree } ?? false
        }
        return hasChild ? worktree.key : nil
    }
}
