// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// `shell.snapshot.v1` — the sidebar/tab-bar data payload. Arrives as JSON in an
// `EndpointControl` frame, so these types are `Decodable`, not bincode.
//
// Field names match the daemon's snake_case JSON exactly; `CodingKeys` keep the
// Swift side camelCase. Unknown keys are ignored by `Decodable`, which is what
// lets a newer daemon add fields without breaking this client.

import Foundation

/// Binary enum order is significant upstream (see `wire.rs`); over JSON the
/// daemon sends the snake_case spelling.
public enum AgentStatus: String, Decodable, Sendable, CaseIterable {
    case idle
    case working
    case blocked
    case done
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentStatus(rawValue: raw) ?? .unknown
    }
}

public struct ClientShellSnapshot: Decodable, Equatable, Sendable {
    public var bootId: String
    public var revision: UInt64
    public var configDiagnostic: String?
    public var productAnnouncement: ClientShellProductAnnouncement?
    public var updateAvailable: String?
    public var updateInstallCommand: String
    public var serverKeybindingsToml: String?
    public var latestReleaseNotesAvailable: Bool
    public var integrationUpdatesAvailable: Bool
    public var worktreeDirectory: String
    public var releaseNotes: ClientShellReleaseNotes?
    public var focusedWorkspaceId: String?
    public var focusedTabId: String?
    public var focusedPaneId: String?
    public var tabBarRight: [ClientShellTabStatusSegment]
    public var tabBarRightSeparator: String
    public var agentViewLabel: String?
    public var agentOrder: [String]
    public var workspaces: [ClientShellWorkspace]
    public var tabs: [ClientShellTab]
    public var panes: [ClientShellPane]
    public var agents: [ClientShellAgent]
    public var commands: [ClientShellCommand]

    enum CodingKeys: String, CodingKey {
        case bootId = "boot_id"
        case revision
        case configDiagnostic = "config_diagnostic"
        case productAnnouncement = "product_announcement"
        case updateAvailable = "update_available"
        case updateInstallCommand = "update_install_command"
        case serverKeybindingsToml = "server_keybindings_toml"
        case latestReleaseNotesAvailable = "latest_release_notes_available"
        case integrationUpdatesAvailable = "integration_updates_available"
        case worktreeDirectory = "worktree_directory"
        case releaseNotes = "release_notes"
        case focusedWorkspaceId = "focused_workspace_id"
        case focusedTabId = "focused_tab_id"
        case focusedPaneId = "focused_pane_id"
        case tabBarRight = "tab_bar_right"
        case tabBarRightSeparator = "tab_bar_right_separator"
        case agentViewLabel = "agent_view_label"
        case agentOrder = "agent_order"
        case workspaces
        case tabs
        case panes
        case agents
        case commands
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bootId = try container.decode(String.self, forKey: .bootId)
        revision = try container.decode(UInt64.self, forKey: .revision)
        configDiagnostic = try container.decodeIfPresent(String.self, forKey: .configDiagnostic)
        productAnnouncement = try container.decodeIfPresent(
            ClientShellProductAnnouncement.self,
            forKey: .productAnnouncement
        )
        updateAvailable = try container.decodeIfPresent(String.self, forKey: .updateAvailable)
        updateInstallCommand = try container.decodeIfPresent(
            String.self,
            forKey: .updateInstallCommand
        ) ?? ""
        serverKeybindingsToml = try container.decodeIfPresent(String.self, forKey: .serverKeybindingsToml)
        latestReleaseNotesAvailable = try container.decodeIfPresent(
            Bool.self,
            forKey: .latestReleaseNotesAvailable
        ) ?? false
        integrationUpdatesAvailable = try container.decodeIfPresent(
            Bool.self,
            forKey: .integrationUpdatesAvailable
        ) ?? false
        worktreeDirectory = try container.decodeIfPresent(String.self, forKey: .worktreeDirectory) ?? ""
        releaseNotes = try container.decodeIfPresent(ClientShellReleaseNotes.self, forKey: .releaseNotes)
        focusedWorkspaceId = try container.decodeIfPresent(String.self, forKey: .focusedWorkspaceId)
        focusedTabId = try container.decodeIfPresent(String.self, forKey: .focusedTabId)
        focusedPaneId = try container.decodeIfPresent(String.self, forKey: .focusedPaneId)
        tabBarRight = try container.decodeIfPresent(
            [ClientShellTabStatusSegment].self,
            forKey: .tabBarRight
        ) ?? []
        tabBarRightSeparator = try container.decodeIfPresent(
            String.self,
            forKey: .tabBarRightSeparator
        ) ?? " "
        agentViewLabel = try container.decodeIfPresent(String.self, forKey: .agentViewLabel)
        agentOrder = try container.decodeIfPresent([String].self, forKey: .agentOrder) ?? []
        workspaces = try container.decodeIfPresent([ClientShellWorkspace].self, forKey: .workspaces) ?? []
        tabs = try container.decodeIfPresent([ClientShellTab].self, forKey: .tabs) ?? []
        panes = try container.decodeIfPresent([ClientShellPane].self, forKey: .panes) ?? []
        agents = try container.decodeIfPresent([ClientShellAgent].self, forKey: .agents) ?? []
        commands = try container.decodeIfPresent([ClientShellCommand].self, forKey: .commands) ?? []

        // Duplicate topology ids make a lookup ambiguous: every hit test and
        // every surface slice would silently take whichever entry came first,
        // so clicks land on the wrong pane and no layer reports a problem.
        //
        // Ported from `rootshellTests/HerdrProtocolTests.swift:468`
        // `testSessionSnapshotRejectsDuplicateTopologyIDs`, which checks all
        // three layers. `agents` is keyed by `paneId` too — one agent per pane —
        // so it gets the same check; duplicate *workspace* and *tab* ids would
        // break the sidebar the same way.
        try Self.rejectDuplicateIDs(workspaces.map(\.workspaceId), layer: "workspaces")
        try Self.rejectDuplicateIDs(tabs.map(\.tabId), layer: "tabs")
        try Self.rejectDuplicateIDs(panes.map(\.paneId), layer: "panes")
        try Self.rejectDuplicateIDs(agents.map(\.paneId), layer: "agents")
    }

    private static func rejectDuplicateIDs(_ ids: [String], layer: String) throws {
        guard Set(ids).count == ids.count else {
            let duplicates = ids.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
                .filter { $0.value > 1 }
                .keys
                .sorted()
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: [],
                    debugDescription: "snapshot has duplicate \(layer) ids: "
                        + duplicates.joined(separator: ", ")
                )
            )
        }
    }
}

public struct ClientShellProductAnnouncement: Decodable, Equatable, Sendable {
    public var version: String
    public var id: String
    public var title: String
    public var body: String
    public var preview: Bool
}

public struct ClientShellReleaseNotes: Decodable, Equatable, Sendable {
    public var version: String
    public var body: String
    public var preview: Bool
}

public enum ClientShellCommandAction: String, Decodable, Sendable {
    case shell
    case pane
    case popup
    case pluginAction
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "Shell": self = .shell
        case "Pane": self = .pane
        case "Popup": self = .popup
        case "PluginAction": self = .pluginAction
        default: self = .unknown
        }
    }
}

public struct ClientShellCommand: Decodable, Equatable, Sendable, Identifiable {
    public var commandId: String
    public var bindingLabel: String
    public var bindingLabels: [String]
    public var action: ClientShellCommandAction
    public var description: String?

    public var id: String { commandId }

    enum CodingKeys: String, CodingKey {
        case commandId = "command_id"
        case bindingLabel = "binding_label"
        case bindingLabels = "binding_labels"
        case action
        case description
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        commandId = try container.decode(String.self, forKey: .commandId)
        bindingLabel = try container.decodeIfPresent(String.self, forKey: .bindingLabel) ?? ""
        bindingLabels = try container.decodeIfPresent([String].self, forKey: .bindingLabels) ?? []
        action = try container.decodeIfPresent(ClientShellCommandAction.self, forKey: .action) ?? .unknown
        description = try container.decodeIfPresent(String.self, forKey: .description)
    }
}

public struct ClientShellTabStatusSegment: Decodable, Equatable, Sendable {
    public var text: String
    public var accent: Bool
}

public struct ClientShellWorkspace: Decodable, Equatable, Sendable, Identifiable {
    public var workspaceId: String
    public var activeTabId: String
    public var newWorkspaceCwd: String
    public var number: Int
    public var label: String
    public var customLabel: Bool
    public var branch: String?
    public var gitAheadBehind: [Int]?
    public var tokens: [[String]]
    public var worktree: ClientShellWorktree?
    public var focused: Bool
    public var agentStatus: AgentStatus

    public var id: String { workspaceId }

    enum CodingKeys: String, CodingKey {
        case workspaceId = "workspace_id"
        case activeTabId = "active_tab_id"
        case newWorkspaceCwd = "new_workspace_cwd"
        case number
        case label
        case customLabel = "custom_label"
        case branch
        case gitAheadBehind = "git_ahead_behind"
        case tokens
        case worktree
        case focused
        case agentStatus = "agent_status"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaceId = try container.decode(String.self, forKey: .workspaceId)
        activeTabId = try container.decodeIfPresent(String.self, forKey: .activeTabId) ?? ""
        newWorkspaceCwd = try container.decodeIfPresent(String.self, forKey: .newWorkspaceCwd) ?? ""
        number = try container.decodeIfPresent(Int.self, forKey: .number) ?? 0
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        customLabel = try container.decodeIfPresent(Bool.self, forKey: .customLabel) ?? false
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        gitAheadBehind = try container.decodeIfPresent([Int].self, forKey: .gitAheadBehind)
        tokens = try container.decodeIfPresent([[String]].self, forKey: .tokens) ?? []
        worktree = try container.decodeIfPresent(ClientShellWorktree.self, forKey: .worktree)
        focused = try container.decodeIfPresent(Bool.self, forKey: .focused) ?? false
        agentStatus = try container.decodeIfPresent(AgentStatus.self, forKey: .agentStatus) ?? .unknown
    }

    /// `(ahead, behind)`, when the daemon reported git divergence.
    public var aheadBehind: (ahead: Int, behind: Int)? {
        guard let gitAheadBehind, gitAheadBehind.count == 2 else { return nil }
        return (gitAheadBehind[0], gitAheadBehind[1])
    }

    /// `tokens` arrives as an array of `[key, value]` pairs.
    public var tokenPairs: [(key: String, value: String)] {
        tokens.compactMap { pair in
            guard pair.count == 2 else { return nil }
            return (pair[0], pair[1])
        }
    }
}

public struct ClientShellWorktree: Decodable, Equatable, Sendable {
    public var key: String
    public var label: String
    public var isLinkedWorktree: Bool

    enum CodingKeys: String, CodingKey {
        case key
        case label
        case isLinkedWorktree = "is_linked_worktree"
    }
}

public struct ClientShellTab: Decodable, Equatable, Sendable, Identifiable {
    public var tabId: String
    public var workspaceId: String
    public var number: Int
    public var label: String
    public var customLabel: Bool
    public var zoomed: Bool
    public var focused: Bool
    public var agentStatus: AgentStatus

    public var id: String { tabId }

    enum CodingKeys: String, CodingKey {
        case tabId = "tab_id"
        case workspaceId = "workspace_id"
        case number
        case label
        case customLabel = "custom_label"
        case zoomed
        case focused
        case agentStatus = "agent_status"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tabId = try container.decode(String.self, forKey: .tabId)
        workspaceId = try container.decodeIfPresent(String.self, forKey: .workspaceId) ?? ""
        number = try container.decodeIfPresent(Int.self, forKey: .number) ?? 0
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        customLabel = try container.decodeIfPresent(Bool.self, forKey: .customLabel) ?? false
        zoomed = try container.decodeIfPresent(Bool.self, forKey: .zoomed) ?? false
        focused = try container.decodeIfPresent(Bool.self, forKey: .focused) ?? false
        agentStatus = try container.decodeIfPresent(AgentStatus.self, forKey: .agentStatus) ?? .unknown
    }
}

public struct ClientShellPane: Decodable, Equatable, Sendable, Identifiable {
    public var paneId: String
    public var workspaceId: String
    public var tabId: String
    public var label: String?
    public var cwd: String?
    public var foregroundCwd: String?
    public var focused: Bool
    public var rightClickPassthrough: Bool

    public var id: String { paneId }

    enum CodingKeys: String, CodingKey {
        case paneId = "pane_id"
        case workspaceId = "workspace_id"
        case tabId = "tab_id"
        case label
        case cwd
        case foregroundCwd = "foreground_cwd"
        case focused
        case rightClickPassthrough = "right_click_passthrough"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paneId = try container.decode(String.self, forKey: .paneId)
        workspaceId = try container.decodeIfPresent(String.self, forKey: .workspaceId) ?? ""
        tabId = try container.decodeIfPresent(String.self, forKey: .tabId) ?? ""
        label = try container.decodeIfPresent(String.self, forKey: .label)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        foregroundCwd = try container.decodeIfPresent(String.self, forKey: .foregroundCwd)
        focused = try container.decodeIfPresent(Bool.self, forKey: .focused) ?? false
        rightClickPassthrough = try container.decodeIfPresent(
            Bool.self,
            forKey: .rightClickPassthrough
        ) ?? false
    }
}

public struct ClientShellAgent: Decodable, Equatable, Sendable, Identifiable {
    public var paneId: String
    public var workspaceId: String
    public var tabId: String
    public var name: String?
    public var displayAgent: String?
    public var agent: String?
    public var title: String?
    public var terminalTitle: String?
    public var terminalTitleStripped: String?
    public var agentStatus: AgentStatus
    public var stateChangeSeq: UInt64
    public var stateLabels: [[String]]
    public var tokens: [[String]]
    public var focused: Bool

    public var id: String { paneId }

    enum CodingKeys: String, CodingKey {
        case paneId = "pane_id"
        case workspaceId = "workspace_id"
        case tabId = "tab_id"
        case name
        case displayAgent = "display_agent"
        case agent
        case title
        case terminalTitle = "terminal_title"
        case terminalTitleStripped = "terminal_title_stripped"
        case agentStatus = "agent_status"
        case stateChangeSeq = "state_change_seq"
        case stateLabels = "state_labels"
        case tokens
        case focused
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paneId = try container.decode(String.self, forKey: .paneId)
        workspaceId = try container.decodeIfPresent(String.self, forKey: .workspaceId) ?? ""
        tabId = try container.decodeIfPresent(String.self, forKey: .tabId) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name)
        displayAgent = try container.decodeIfPresent(String.self, forKey: .displayAgent)
        agent = try container.decodeIfPresent(String.self, forKey: .agent)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        terminalTitle = try container.decodeIfPresent(String.self, forKey: .terminalTitle)
        terminalTitleStripped = try container.decodeIfPresent(
            String.self,
            forKey: .terminalTitleStripped
        )
        agentStatus = try container.decodeIfPresent(AgentStatus.self, forKey: .agentStatus) ?? .unknown
        stateChangeSeq = try container.decodeIfPresent(UInt64.self, forKey: .stateChangeSeq) ?? 0
        stateLabels = try container.decodeIfPresent([[String]].self, forKey: .stateLabels) ?? []
        tokens = try container.decodeIfPresent([[String]].self, forKey: .tokens) ?? []
        focused = try container.decodeIfPresent(Bool.self, forKey: .focused) ?? false
    }

    public var bestTitle: String {
        terminalTitleStripped ?? terminalTitle ?? title ?? ""
    }

    public var label: String {
        displayAgent ?? agent ?? name ?? "agent"
    }
}
