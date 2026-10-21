// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Worktree grouping in the sidebar space list.
//
// The upstream rule (`src/client/shell/sidebar.rs:458-495`) is narrower than it
// first looks: a shared repository key is not enough to nest. Both a main
// checkout and a linked worktree have to be open, otherwise the rows stay flat.
// Getting that wrong turns a repository with three worktrees and no parent
// workspace into three orphaned, indented rows.

import Foundation
import KraalProtocol
import KraalSidebar
import Testing

@Suite("Worktree grouping")
struct SidebarRowsTests {
    /// Decodes a workspace the way the daemon sends one.
    private func workspace(
        _ id: String,
        label: String,
        branch: String? = nil,
        worktreeKey: String? = nil,
        linked: Bool = false,
        focused: Bool = false
    ) throws -> ClientShellWorkspace {
        var json: [String: Any] = [
            "workspace_id": id,
            "label": label,
            "number": 1,
            "focused": focused,
        ]
        if let branch { json["branch"] = branch }
        if let worktreeKey {
            json["worktree"] = [
                "key": worktreeKey,
                "label": "repo",
                "is_linked_worktree": linked,
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(ClientShellWorkspace.self, from: data)
    }

    @Test("a workspace with no worktree stays flat")
    func noWorktreeStaysFlat() throws {
        let list = [
            try workspace("w1", label: "migrate"),
            try workspace("w2", label: "aiphone"),
        ]
        let entries = SidebarSpaceTree.entries(workspaces: list)
        #expect(entries.map(\.index) == [0, 1])
        #expect(entries.allSatisfy { !$0.indented })
    }

    @Test("worktrees without a parent workspace are not nested")
    func linkedWithoutParentStaysFlat() throws {
        // Three worktrees of one repository, none of which is the main checkout.
        // The daemon reports the same key for all three; nesting them under a
        // parent that is not on screen would invent a row.
        let list = [
            try workspace("w6", label: "worktree-green", branch: "worktree/green",
                          worktreeKey: "/repo/.git", linked: true),
            try workspace("w7", label: "worktree-silver", branch: "worktree/silver",
                          worktreeKey: "/repo/.git", linked: true),
        ]
        let entries = SidebarSpaceTree.entries(workspaces: list)
        #expect(entries.map(\.index) == [0, 1])
        #expect(entries.allSatisfy { !$0.indented })
    }

    @Test("parent plus linked worktrees nest in order with the last child marked")
    func parentWithChildrenNests() throws {
        let list = [
            try workspace("w5", label: "rocketmq-mqtt", branch: "develop",
                          worktreeKey: "/repo/.git", linked: false),
            try workspace("w6", label: "worktree-green", branch: "worktree/green",
                          worktreeKey: "/repo/.git", linked: true),
            try workspace("w7", label: "worktree-silver", branch: "worktree/silver",
                          worktreeKey: "/repo/.git", linked: true),
        ]
        let entries = SidebarSpaceTree.entries(workspaces: list)
        #expect(entries.map(\.index) == [0, 1, 2])
        #expect(entries[0].indented == false)
        #expect(entries[1].indented)
        #expect(entries[1].lastChild == false)
        #expect(entries[2].indented)
        #expect(entries[2].lastChild)
    }

    @Test("the group is emitted where its first member appears")
    func groupEmitsAtFirstMember() throws {
        // The child comes back from the daemon before the parent. The parent has
        // to be drawn first, and the unrelated workspace keeps its own position.
        let list = [
            try workspace("w6", label: "worktree-green", branch: "worktree/green",
                          worktreeKey: "/repo/.git", linked: true),
            try workspace("w9", label: "unrelated"),
            try workspace("w5", label: "rocketmq-mqtt", branch: "develop",
                          worktreeKey: "/repo/.git", linked: false),
            try workspace("w7", label: "worktree-silver", branch: "worktree/silver",
                          worktreeKey: "/repo/.git", linked: true),
        ]
        let entries = SidebarSpaceTree.entries(workspaces: list)
        // Group emitted at index 0's position: parent first, then its children.
        #expect(entries.map(\.index) == [2, 0, 3, 1])
        #expect(entries[0].indented == false)
        #expect(entries[1].indented)
        #expect(entries[3].indented == false)
    }

    @Test("two repositories each group independently")
    func separateRepositories() throws {
        let list = [
            try workspace("a", label: "repoA", worktreeKey: "/a/.git", linked: false),
            try workspace("b", label: "repoB", worktreeKey: "/b/.git", linked: false),
            try workspace("a1", label: "wt-a", branch: "worktree/a1",
                          worktreeKey: "/a/.git", linked: true),
            try workspace("b1", label: "wt-b", branch: "worktree/b1",
                          worktreeKey: "/b/.git", linked: true),
        ]
        let entries = SidebarSpaceTree.entries(workspaces: list)
        #expect(entries.map(\.index) == [0, 2, 1, 3])
        #expect(entries.map(\.indented) == [false, true, false, true])
        #expect(entries.map(\.lastChild) == [false, true, false, true])
    }

    @Test("a collapsed group keeps only the focused child")
    func collapsedGroupShowsFocusedChild() throws {
        let list = [
            try workspace("w5", label: "repo", worktreeKey: "/repo/.git", linked: false),
            try workspace("w6", label: "worktree-green", worktreeKey: "/repo/.git", linked: true),
            try workspace("w7", label: "worktree-silver", worktreeKey: "/repo/.git",
                          linked: true, focused: true),
        ]
        let entries = SidebarSpaceTree.entries(
            workspaces: list,
            collapsedGroups: ["/repo/.git"]
        )
        // The parent stays visible, and exactly one child represents the group.
        #expect(entries.map(\.index) == [0, 2])
        #expect(entries[1].indented)
        #expect(entries[1].lastChild)
    }

    @Test("a collapsed group with no focused child shows only the parent")
    func collapsedGroupWithoutFocus() throws {
        let list = [
            try workspace("w5", label: "repo", worktreeKey: "/repo/.git", linked: false),
            try workspace("w6", label: "worktree-green", worktreeKey: "/repo/.git", linked: true),
        ]
        let entries = SidebarSpaceTree.entries(
            workspaces: list,
            collapsedGroups: ["/repo/.git"]
        )
        #expect(entries.map(\.index) == [0])
    }

    @Test("only a parent with linked children offers a toggle")
    func toggleOnlyForSharedParent() throws {
        let list = [
            try workspace("w5", label: "repo", worktreeKey: "/repo/.git", linked: false),
            try workspace("w6", label: "wt", worktreeKey: "/repo/.git", linked: true),
            try workspace("w9", label: "plain"),
        ]
        #expect(SidebarSpaceTree.toggleKey(workspaces: list, index: 0) == "/repo/.git")
        #expect(SidebarSpaceTree.toggleKey(workspaces: list, index: 1) == nil)
        #expect(SidebarSpaceTree.toggleKey(workspaces: list, index: 2) == nil)
        #expect(SidebarSpaceTree.toggleKey(workspaces: list, index: 99) == nil)
    }

    @Test("a lone parent with no worktree offers no toggle")
    func parentWithoutChildrenHasNoToggle() throws {
        let list = [try workspace("w5", label: "repo", worktreeKey: "/repo/.git", linked: false)]
        #expect(SidebarSpaceTree.toggleKey(workspaces: list, index: 0) == nil)
    }
}

// MARK: - Token resolution under nesting

@Suite("Nested row tokens")
struct SidebarNestedTokenTests {
    private func workspace(
        _ id: String,
        label: String,
        branch: String? = nil,
        ahead: Int? = nil,
        behind: Int? = nil,
        customLabel: Bool = false,
        worktreeKey: String? = nil,
        linked: Bool = false
    ) throws -> ClientShellWorkspace {
        var json: [String: Any] = [
            "workspace_id": id,
            "label": label,
            "number": 1,
            "custom_label": customLabel,
        ]
        if let branch { json["branch"] = branch }
        if let ahead, let behind { json["git_ahead_behind"] = [ahead, behind] }
        if let worktreeKey {
            json["worktree"] = [
                "key": worktreeKey, "label": "repo", "is_linked_worktree": linked,
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(ClientShellWorkspace.self, from: data)
    }

    /// Renders the default space layout the way the view does.
    private func render(_ workspace: ClientShellWorkspace, indented: Bool) -> [String] {
        let context = SidebarRowContext(workspace: workspace, indented: indented)
        return SidebarLayout().spacesRows.map { row in
            SidebarTokenResolver.resolve(row: row, context: context)
                .tokens.map(\.text).joined(separator: " ")
        }.filter { !$0.isEmpty }
    }

    @Test("a parent row shows its branch and divergence")
    func parentShowsBranchAndDivergence() throws {
        let parent = try workspace("w5", label: "rocketmq-mqtt", branch: "develop",
                                   ahead: 0, behind: 6)
        let rows = render(parent, indented: false)
        #expect(rows.count == 2)
        #expect(rows[0].contains("rocketmq-mqtt"))
        #expect(rows[1] == "develop ↓6")
    }

    @Test("a nested row is named by its branch without the worktree prefix")
    func nestedRowUsesStrippedBranch() throws {
        let child = try workspace("w6", label: "worktree-green-field-6b13",
                                  branch: "worktree/green-field-6b13",
                                  worktreeKey: "/repo/.git", linked: true)
        let rows = render(child, indented: true)
        // One row only: the branch line is suppressed because the branch is the
        // name, and repeating it underneath is noise (sidebar.rs:687).
        #expect(rows.count == 1)
        #expect(rows[0].contains("green-field-6b13"))
        #expect(!rows[0].contains("worktree/"))
    }

    @Test("a nested row keeps a user-chosen label")
    func nestedRowKeepsCustomLabel() throws {
        let child = try workspace("w6", label: "my-checkout", branch: "worktree/green",
                                  customLabel: true, worktreeKey: "/repo/.git", linked: true)
        let rows = render(child, indented: true)
        #expect(rows[0].contains("my-checkout"))
        #expect(!rows[0].contains("green"))
    }

    @Test("a nested row hides divergence even when the daemon reports it")
    func nestedRowHidesDivergence() throws {
        let child = try workspace("w6", label: "worktree-g", branch: "worktree/g",
                                  ahead: 2, behind: 3, worktreeKey: "/repo/.git", linked: true)
        let text = render(child, indented: true).joined(separator: " ")
        #expect(!text.contains("↑"))
        #expect(!text.contains("↓"))
    }

    @Test("git status splits into coloured segments")
    func gitStatusSegments() throws {
        let aheadOnly = try workspace("a", label: "a", ahead: 1, behind: 0)
        let both = try workspace("b", label: "b", ahead: 2, behind: 3)
        let contextA = SidebarRowContext(workspace: aheadOnly)
        let contextB = SidebarRowContext(workspace: both)
        let segsA = SidebarTokenResolver.segments(for: .gitStatus, context: contextA)
        let segsB = SidebarTokenResolver.segments(for: .gitStatus, context: contextB)
        #expect(segsA.map(\.text) == ["↑1"])
        #expect(segsB.map(\.text) == ["↑2", " ", "↓3"])
        #expect(segsB.map(\.tint) == [.ahead, .plain, .behind])
    }

    @Test("the machine token disappears with a single machine")
    func machineTokenHiddenForSingleMachine() throws {
        let single = try workspace("w1", label: "repo")
        let agent = try JSONDecoder().decode(ClientShellAgent.self, from: Data("""
        {"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","agent":"pi","label":"pi"}
        """.utf8))
        let singleCtx = SidebarRowContext(workspace: single, agent: agent,
                                       machineName: "Local", showsMachineName: false)
        let multiCtx = SidebarRowContext(workspace: single, agent: agent,
                                      machineName: "nj-mac", showsMachineName: true)
        let row = SidebarLayout.defaultAgentsRows[0]
        let singleText = SidebarTokenResolver.resolve(row: row, context: singleCtx)
            .tokens.map(\.text).joined(separator: " ")
        let multiText = SidebarTokenResolver.resolve(row: row, context: multiCtx)
            .tokens.map(\.text).joined(separator: " ")
        #expect(!singleText.contains("Local"))
        #expect(multiText.contains("nj-mac"))
    }
}
