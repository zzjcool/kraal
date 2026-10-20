// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The sidebar: workspaces on top, agents below, both drawn from the resolved
// `SidebarLayout` rather than from hard-coded rows.
//
// This is the piece that makes an imported `config.toml` visible: change
// `ui.sidebar.agents.rows` and these rows change shape.

import KraalProtocol
import KraalSidebar
import SwiftUI
import KraalTransport

struct SidebarView: View {
    @Environment(AppStore.self) private var store
    @State private var selection: Selection = .agents

    enum Selection: Hashable {
        case workspaces
        case agents
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    switch selection {
                    case .workspaces: workspacesSection
                    case .agents: agentsSection
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            Spacer(minLength: 0)
            Divider().opacity(0.4)
            footer
        }
        .frame(width: KraalTheme.sidebarWidth)
        .background(.thinMaterial)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 6) {
            Picker("", selection: $selection) {
                Text("Agents").tag(Selection.agents)
                Text("Spaces").tag(Selection.workspaces)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            Button {
                store.createWorkspace()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New workspace")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var workspacesSection: some View {
        ForEach(store.workspaces) { workspace in
            WorkspaceRowView(
                workspace: workspace,
                layout: store.sidebarLayout
            )
            .contentShape(Rectangle())
            .onTapGesture { store.focus(workspaceId: workspace.workspaceId) }
            .contextMenu {
                Button("Rename…") {}
                Button("Close Workspace", role: .destructive) {
                    store.close(workspaceId: workspace.workspaceId)
                }
            }
        }
    }

    private var agentsSection: some View {
        Group {
            if !store.agentsOrdered.isEmpty {
                ForEach(store.agentsOrdered) { agent in
                    AgentRowView(
                        agent: agent,
                        workspace: store.workspaces.first {
                            $0.workspaceId == agent.workspaceId
                        },
                        tab: store.tabs.first { $0.tabId == agent.tabId },
                        layout: store.sidebarLayout
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { store.focus(paneId: agent.paneId) }
                    .contextMenu {
                        Button("Focus Pane") { store.focus(paneId: agent.paneId) }
                        Button("Split Right") { store.splitPane(paneId: agent.paneId) }
                        Button("Zoom") { store.toggleZoom(paneId: agent.paneId) }
                        Divider()
                        Button("Close Pane", role: .destructive) {
                            store.close(paneId: agent.paneId)
                        }
                    }
                }
            } else if !store.panes.isEmpty {
                // The daemon only reports an agent once it detects a coding agent
                // inside a pane. With plain shells running there is nothing to
                // list, and an empty sidebar would look broken — so fall back to
                // the panes themselves, which are always present.
                ForEach(store.panes) { pane in
                    PaneRowView(
                        pane: pane,
                        workspace: store.workspaces.first {
                            $0.workspaceId == pane.workspaceId
                        },
                        tab: store.tabs.first { $0.tabId == pane.tabId },
                        layout: store.sidebarLayout
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { store.focus(paneId: pane.paneId) }
                    .contextMenu {
                        Button("Focus Pane") { store.focus(paneId: pane.paneId) }
                        Button("Split Right") { store.splitPane(paneId: pane.paneId) }
                        Button("Zoom") { store.toggleZoom(paneId: pane.paneId) }
                        Divider()
                        Button("Close Pane", role: .destructive) {
                            store.close(paneId: pane.paneId)
                        }
                    }
                }
            } else {
                Text("No panes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(store.phase.isLive ? sidebarColor("green") : sidebarColor("gray"))
                .frame(width: 6, height: 6)
            Text(statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if let config = store.sidebarConfigSource {
                Image(systemName: "slider.horizontal.3")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Layout from \(config)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private var statusText: String {
        switch store.phase {
        case .idle: "Not connected"
        case .connecting: "Connecting…"
        case .live:
            if let welcome = store.welcome {
                "\(welcome.serverVersion) · \(store.target.name)"
            } else {
                store.target.name
            }
        case let .reconnecting(attempt, _): "Reconnecting (\(attempt))…"
        case .failed: "Disconnected"
        }
    }
}

// MARK: - Rows

private struct WorkspaceRowView: View {
    let workspace: ClientShellWorkspace
    let layout: SidebarLayout

    var body: some View {
        let context = SidebarRowContext(workspace: workspace)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(layout.spacesRows.enumerated()), id: \.offset) { _, row in
                let resolved = SidebarTokenResolver.resolve(row: row, context: context)
                if !resolved.tokens.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(Array(resolved.tokens.enumerated()), id: \.offset) { _, token in
                            tokenView(token)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background {
            RoundedRectangle(cornerRadius: KraalTheme.cornerRadius)
                .fill(workspace.focused ? Color.accentColor.opacity(0.20) : .clear)
        }
    }

    @ViewBuilder
    private func tokenView(_ token: ResolvedToken) -> some View {
        switch token.kind {
        case .stateIcon:
            StatusDot(status: workspace.agentStatus, size: 7)
        case .workspace:
            StyledText(text: token.text, style: token.style)
                .font(.system(size: 12, weight: workspace.focused ? .semibold : .regular))
                .lineLimit(1)
        default:
            StyledText(text: token.text, style: token.style)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct AgentRowView: View {
    let agent: ClientShellAgent
    let workspace: ClientShellWorkspace?
    let tab: ClientShellTab?
    let layout: SidebarLayout

    var body: some View {
        let context = SidebarRowContext(
            workspace: workspace,
            agent: agent,
            tab: tab,
            tokens: Dictionary(
                uniqueKeysWithValues: agent.tokens.compactMap { pair in
                    pair.count == 2 ? (pair[0], pair[1]) : nil
                }
            )
        )
        let rows = layout.rows(for: agent.agent)
        VStack(alignment: .leading, spacing: CGFloat(layout.agentsRowGap)) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                let resolved = SidebarTokenResolver.resolve(row: row, context: context)
                if !resolved.tokens.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(Array(resolved.tokens.enumerated()), id: \.offset) { _, token in
                            tokenView(token)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background {
            RoundedRectangle(cornerRadius: KraalTheme.cornerRadius)
                .fill(agent.focused ? Color.accentColor.opacity(0.20) : .clear)
        }
    }

    @ViewBuilder
    private func tokenView(_ token: ResolvedToken) -> some View {
        switch token.kind {
        case .stateIcon:
            StatusDot(status: agent.agentStatus, size: 7)
        case .agent:
            StyledText(text: token.text, style: token.style)
                .font(.system(size: 12, weight: agent.focused ? .semibold : .regular))
                .lineLimit(1)
        default:
            StyledText(text: token.text, style: token.style)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// A pane with no detected agent. Same row treatment as an agent row so the list
/// does not jump when an agent appears.
private struct PaneRowView: View {
    let pane: ClientShellPane
    let workspace: ClientShellWorkspace?
    let tab: ClientShellTab?
    let layout: SidebarLayout

    var body: some View {
        let context = SidebarRowContext(
            workspace: workspace,
            tab: tab,
            pane: pane
        )
        VStack(alignment: .leading, spacing: CGFloat(layout.agentsRowGap)) {
            ForEach(Array(layout.agentsRows.enumerated()), id: \.offset) { _, row in
                let resolved = SidebarTokenResolver.resolve(row: row, context: context)
                if !resolved.tokens.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(Array(resolved.tokens.enumerated()), id: \.offset) { _, token in
                            tokenView(token)
                        }
                    }
                }
            }
            if let cwd = pane.foregroundCwd ?? pane.cwd {
                Text((cwd as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background {
            RoundedRectangle(cornerRadius: KraalTheme.cornerRadius)
                .fill(pane.focused ? Color.accentColor.opacity(0.20) : .clear)
        }
    }

    @ViewBuilder
    private func tokenView(_ token: ResolvedToken) -> some View {
        switch token.kind {
        case .stateIcon:
            StatusDot(status: workspace?.agentStatus ?? .unknown, size: 7)
        case .pane:
            StyledText(text: token.text, style: token.style)
                .font(.system(size: 11, weight: pane.focused ? .semibold : .regular))
                .lineLimit(1)
        default:
            StyledText(text: token.text, style: token.style)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
