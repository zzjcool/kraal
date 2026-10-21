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
    // Spaces is the default: it is the unit you navigate by, and it stays
    // meaningful with plain shells. Agents only fills in once the daemon
    // detects a coding agent, so opening there shows a fallback pane list
    // instead — with one workspace, every row repeats the same name.
    @State private var selection: Selection = .workspaces
    @State private var prompt: CommandPrompt?

    enum Selection: Hashable {
        case workspaces
        case agents
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    switch selection {
                    case .workspaces: workspacesSection
                    case .agents: agentsSection
                    }
                }
                .padding(.horizontal, KraalTheme.Space.base)
                .padding(.vertical, KraalTheme.Space.snug)
            }
            Spacer(minLength: 0)
            Divider().opacity(0.4)
            footer
        }
        .frame(width: KraalTheme.sidebarWidth)
        // A real `NSVisualEffectView` sidebar, not SwiftUI's `.thinMaterial`: the
        // latter samples sibling views, so inside this opaque window it rendered a
        // flat grey (measured 0.125 before the change). This one reaches the
        // desktop and follows window-active state and Reduce Transparency.
        .glassChrome(.sidebar, rim: false)
        .renamePrompt($prompt)
    }

    // MARK: - Sections

    /// The machine every sidebar row belongs to.
    ///
    /// A connection talks to exactly one machine, so the name is a property of the
    /// view rather than of the rows. It comes from `store.target`, the settings the
    /// connection was opened with — not from `NSScreen`-style ambient state — so it
    /// cannot disagree with what the pane content is showing. Panel and sidebar
    /// therefore name the same machine: this Mac's row reads "This Mac", and an
    /// SSH target reads the label the user gave it.
    private var machineName: String {
        MachineRoster.sidebarMachineName(settings: store.target)
    }

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
        .padding(.horizontal, KraalTheme.Space.base)
        .padding(.vertical, KraalTheme.Space.snug)
    }

    /// The space list, grouped by machine when more than one is configured.
    ///
    /// The terminal client switches between two renderers on
    /// `endpoints.len() > 1` (`render.rs:271`): a flat list under a `spaces`
    /// heading for one machine, and a `machines` heading with one group per
    /// machine otherwise. The single-machine case is not a special case of the
    /// grouped one — it has no machine row at all — so both are drawn here rather
    /// than folding the group header into a list of one.
    @ViewBuilder
    private var workspacesSection: some View {
        let multi = store.endpoints.count > 1
        sectionHeading(multi ? "machines" : "spaces")
        if multi {
            ForEach(store.endpoints, id: \.id) { endpoint in
                machineRow(endpoint)
                if !store.collapsedEndpoints.contains(endpoint.id) {
                    spaceRows(for: endpoint)
                }
            }
        } else {
            // Identity is namespaced by machine: every group's entries start at
            // index 0, so a bare index would collide across groups and the lazy
            // stack would reuse a row for the wrong workspace — which showed up
            // as a group's rows replaced by blank space.
            ForEach(SidebarSpaceTree.entries(workspaces: store.workspaces),
                    id: \.index) { entry in
                workspaceRow(store.workspaces[entry.index], entry: entry,
                             machineName: machineName, endpointID: store.activeEndpointID)
            }
        }
    }

    /// The ` machines` / ` spaces` heading. Lowercase in the terminal client.
    private func sectionHeading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.top, 2)
    }

    /// A machine header with two hit areas, because a machine row means two
    /// different things depending on where you click.
    ///
    /// Clicking the name selects that machine — the same act as clicking one of
    /// its workspaces, which is how you get to a machine you are not on. Clicking
    /// the triangle only folds the list. Making the *whole* row fold was the
    /// earlier behaviour, and it left no way to select a machine whose workspaces
    /// were collapsed: the row was the only handle, and it did the wrong thing.
    ///
    /// The two areas are laid out as separate views rather than one row with a
    /// gesture that inspects the click position: `onTapGesture` carries no
    /// location, so splitting the row is what keeps each area's meaning explicit.
    /// Both keep the full-width frame and the same insets as a workspace row, so
    /// the list still reads as one block with one left edge.
    @ViewBuilder
    private func machineRow(_ endpoint: EndpointState) -> some View {
        let collapsed = store.collapsedEndpoints.contains(endpoint.id)
        let isActive = endpoint.id == store.activeEndpointID
        HStack(spacing: 4) {
            // Fold target. Padded out to a comfortable square so it is hittable
            // without stealing clicks from the label next to it.
            Text(collapsed ? "▸" : "▾")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 16)
                .contentShape(Rectangle())
                .onTapGesture {
                    store.collapsedEndpoints.formSymmetricDifference([endpoint.id])
                }
                .help(collapsed ? "Expand \(endpoint.label)" : "Collapse \(endpoint.label)")

            // Select target: the name and the empty space to its right, so the
            // row is clickable the way it looks.
            HStack(spacing: 4) {
                Text(endpoint.label)
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let badge = endpoint.status.badge, !endpoint.id.isLocal {
                    Text(badge)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(endpoint.status.badgeIsWarning
                            ? Color.red : Color.green)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                // Selecting an already-active machine just makes sure its list is
                // open — the click would otherwise do nothing at all.
                if isActive {
                    store.collapsedEndpoints.remove(endpoint.id)
                } else {
                    store.selectEndpoint(endpoint)
                }
            }
        }
        // The row looks like one 20pt band — it has a rounded highlight of that
        // height when active — so every part of that band has to respond. It
        // used to depend on `padding(.vertical, 2)` sitting *inside* a
        // `contentShape` that carried no gesture: the 2pt above and below the
        // 16pt hit areas were dead, and because the list spaces rows by 0 that
        // made a 4pt dead strip between every pair of machines. Clicking a row
        // near its edge silently did nothing, or landed on its neighbour.
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            // The band itself falls back to the label's action. The fold square
            // sits above this and keeps its own tap, so a click on the arrow
            // still only folds — `onTapGesture` does not report a location, which
            // is why the two targets are siblings rather than one hit-tested view.
            if isActive {
                store.collapsedEndpoints.remove(endpoint.id)
            } else {
                store.selectEndpoint(endpoint)
            }
        }
        .padding(.horizontal, 6)
        // The label's `Spacer` only stretches the label against its siblings;
        // the row itself still needs to claim the sidebar's full width or its
        // highlight would stop short of the right edge.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: KraalTheme.cornerRadius)
                .fill(isActive ? Color.accentColor.opacity(0.10) : .clear)
        }
    }

    /// One machine's workspaces, with its worktrees nested.
    @ViewBuilder
    private func spaceRows(for endpoint: EndpointState) -> some View {
        let collapsed = store.collapsedWorktreeGroups[endpoint.id] ?? []
        let entries = SidebarSpaceTree.entries(workspaces: endpoint.workspaces,
                                               collapsedGroups: collapsed)
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            workspaceRow(endpoint.workspaces[entry.index], entry: entry,
                         machineName: endpoint.label, endpointID: endpoint.id)
                .id("\(endpoint.id.storageKey):\(entry.index)")
        }
    }

    private func workspaceRow(
        _ workspace: ClientShellWorkspace,
        entry: SidebarSpaceEntry,
        machineName: String,
        endpointID: EndpointID?
    ) -> some View {
        WorkspaceRowView(
            workspace: workspace,
            layout: store.sidebarLayout,
            machineName: machineName,
            entry: entry,
            // Only the selected machine accepts focus: switching machines is a
            // reconnect, not a focus call, so a row on another machine selects
            // that machine instead.
            isActiveMachine: endpointID == nil || endpointID == store.activeEndpointID,
            multiMachine: store.endpoints.count > 1
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if let endpointID, endpointID != store.activeEndpointID,
               let endpoint = store.endpoints.first(where: { $0.id == endpointID }) {
                store.selectEndpoint(endpoint)
            } else {
                store.focus(workspaceId: workspace.workspaceId)
            }
        }
        .contextMenu {
            WorkspaceContextMenu(prompt: $prompt, workspace: workspace)
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
                        layout: store.sidebarLayout,
                        machineName: machineName,
                        multiMachine: store.endpoints.count > 1
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { store.focus(paneId: agent.paneId) }
                    .contextMenu {
                        PaneContextMenu(prompt: $prompt, paneId: agent.paneId)
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
                        layout: store.sidebarLayout,
                        machineName: machineName
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { store.focus(paneId: pane.paneId) }
                    .contextMenu {
                        PaneContextMenu(prompt: $prompt, paneId: pane.paneId)
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
        .padding(.horizontal, KraalTheme.Space.base)
        .padding(.vertical, KraalTheme.Space.tight)
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
    /// The machine this workspace lives on. Rows describe one connection, so the
    /// whole sidebar carries a single name; without it the `machine` token fell
    /// back to the literal "local" and never matched the roster.
    let machineName: String
    let entry: SidebarSpaceEntry
    let isActiveMachine: Bool
    /// Whether the catalog has more than one machine, which is what decides if a
    /// `machine` token renders at all.
    let multiMachine: Bool

    var body: some View {
        let context = SidebarRowContext(
            workspace: workspace,
            machineName: machineName,
            indented: entry.indented,
            showsMachineName: multiMachine
        )
        HStack(alignment: .top, spacing: 0) {
            // The tree glyph replaces the leading space a top-level row gets, so
            // a child's dot lines up under its parent's label rather than under
            // the parent's dot (`sidebar.rs:710-723`).
            if entry.indented {
                Text(entry.lastChild ? "   └─ " : "   ├─ ")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: CGFloat(layout.spacesRowGap)) {
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
            // The row is as wide as the sidebar, not as wide as its text.
            //
            // Without this the highlight wrapped the label and stopped, so a row
            // read as a chip floating in the list, and the empty space to its
            // right belonged to no row at all: clicking beside a workspace did
            // nothing, while clicking beside a machine row (which already had a
            // trailing `Spacer`) toggled it. Two rows in one list must not
            // disagree about where they end.
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Hit testing follows the drawn rect, so the whole row is clickable
        // rather than just the glyphs SwiftUI happened to layout.
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: KraalTheme.cornerRadius)
                .fill(workspace.focused && isActiveMachine
                    ? Color.accentColor.opacity(0.20) : .clear)
        }
        .opacity(isActiveMachine ? 1 : 0.75)
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
        case .gitStatus:
            // Ahead is green, behind is red, with a single space between them —
            // one token, two colours (`sidebar.rs:246-267`).
            HStack(spacing: 0) {
                ForEach(Array(token.segments.enumerated()), id: \.offset) { _, segment in
                    Text(segment.text)
                        .font(.system(size: 10))
                        .foregroundStyle(segment.tint == .ahead
                            ? sidebarColor("green")
                            : segment.tint == .behind ? Color.red : Color.secondary)
                }
            }
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
    let machineName: String
    let multiMachine: Bool

    var body: some View {
        let context = SidebarRowContext(
            workspace: workspace,
            agent: agent,
            tab: tab,
            machineName: machineName,
            tokens: Dictionary(
                uniqueKeysWithValues: agent.tokens.compactMap { pair in
                    pair.count == 2 ? (pair[0], pair[1]) : nil
                }
            ),
            showsMachineName: multiMachine
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
    let machineName: String

    var body: some View {
        let context = SidebarRowContext(
            workspace: workspace,
            tab: tab,
            pane: pane,
            machineName: machineName
        )
        VStack(alignment: .leading, spacing: CGFloat(layout.agentsRowGap)) {
            ForEach(Array(layout.paneRows.enumerated()), id: \.offset) { _, row in
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
