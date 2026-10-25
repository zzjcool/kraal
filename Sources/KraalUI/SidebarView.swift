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
    @Environment(WindowActions.self) private var windowActions
    @Environment(\.palette) private var palette
    @State private var prompt: CommandPrompt?

    /// Fraction of the list area given to the spaces pane.
    ///
    /// Starts from the stored value so the sidebar remembers how the user left it;
    /// a drag overwrites both this and the store (`SidebarPreferences`).
    @State private var sectionRatio = SidebarPreferences.initialSplit()

    /// The split the pane heights were drawn at, so a drag can be turned back into a
    /// ratio without re-measuring inside the gesture.
    @State private var lastMeasuredHeight: CGFloat = 0

    /// Whether the sidebar is a narrow strip.
    ///
    /// Persisted (`SidebarPreferences.collapsedKey`) so it survives a relaunch, which
    /// is what upstream does with `sidebar_collapsed`
    /// (`src/client/shell/state.rs:1002-1003`).
    @State private var isCollapsed = SidebarPreferences.initialCollapsed()

    var body: some View {
        // The chrome is applied *outside* the branch, so collapsing cannot lose it.
        // It used to live only on `expandedBody`, and the collapsed strip rendered as
        // a transparent column over the desktop — the rows were visible but the
        // sidebar was not, which read as a rendering bug rather than a narrow mode.
        Group {
            if isCollapsed {
                SidebarCollapsedView(
                    store: store,
                    attention: footerAttention,
                    toggle: { setCollapsed(false) }
                )
            } else {
                expandedBody
            }
        }
        .frame(width: isCollapsed ? SidebarCollapsed.width : KraalTheme.sidebarWidth)
        .glassChrome(.sidebar, rim: false)
        .renamePrompt($prompt)
    }

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            // Spaces above, agents below, both visible at once — upstream draws the
            // same thing (`src/ui/sidebar.rs:30-66`). They used to be two tabs of a
            // segmented control, which meant you could not answer "which space has
            // an agent" without leaving the list you were reading it from.
            //
            // The split is measured rather than given fixed heights: the sidebar's
            // available height depends on the window, and a heading plus no rows
            // reads as a bug.
            GeometryReader { proxy in
                let split = SidebarSections.heights(
                    totalHeight: proxy.size.height,
                    ratio: sectionRatio
                )
                VStack(alignment: .leading, spacing: 0) {
                    // The footer belongs to the *spaces* pane, not to the sidebar:
                    // upstream draws it at `workspace_area.bottom() - 1`
                    // (`src/client/shell/sidebar.rs:379-381`), which is the bottom of
                    // the top half. Putting it under both panes put `new` and `menu`
                    // somewhere upstream never has them, and made them look like
                    // sidebar-wide controls when they act on workspaces and the
                    // client's own menu.
                    VStack(alignment: .leading, spacing: 0) {
                        sectionScroll { workspacesSection }
                        Divider().opacity(0.4)
                        SidebarFooterView(
                            store: store,
                            attention: footerAttention,
                            layoutSource: store.sidebarConfigSource
                        )
                    }
                    .frame(height: split.spaces, alignment: .top)
                    sectionDivider(totalHeight: proxy.size.height)
                    sectionScroll { agentsSection }
                        .frame(height: split.agents, alignment: .top)
                }
                .onAppear { lastMeasuredHeight = proxy.size.height }
                .onChange(of: proxy.size.height) { _, height in
                    lastMeasuredHeight = height
                }
            }
        }
        // A real `NSVisualEffectView` sidebar, not SwiftUI's `.thinMaterial`: the
        // latter samples sibling views, so inside this opaque window it rendered a
        // flat grey (measured 0.125 before the change). This one reaches the
        // desktop and follows window-active state and Reduce Transparency.
        //
        // The frame and the chrome live in `body`, around both states.
    }

    /// One pane of the sidebar: a heading stays put, the rows scroll under it.
    ///
    /// Scrolling per pane, not for the whole sidebar, is what makes the two halves
    /// independent (#116): a long spaces list must not push the agents pane out of
    /// view, and the agents pane keeps its position while spaces scrolls.
    private func sectionScroll<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal, KraalTheme.Space.base)
            .padding(.vertical, KraalTheme.Space.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The draggable rule between the two panes.
    ///
    /// Upstream treats this line as a hit target and turns the pointer's row into a
    /// ratio (`src/client/shell/mouse.rs:1971-1974`), clamping through
    /// `SidebarSections.ratio`. The gesture here does the same in points: the drag
    /// offset is added to the height the spaces pane was drawn at, so the divider
    /// follows the pointer instead of jumping to it.
    ///
    /// The 8 pt band is invisible padding around a 1 pt rule: a 1 pt target is
    /// unhittable with a mouse, and drawing it thicker would read as a gap between
    /// the panes rather than a divider.
    private func sectionDivider(totalHeight: CGFloat) -> some View {
        let drag = DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard totalHeight > 0 else { return }
                let current = SidebarSections.heights(
                    totalHeight: totalHeight,
                    ratio: sectionRatio
                ).spaces
                let target = current + value.translation.height
                let ratio = SidebarSections.ratio(draggedTo: target, totalHeight: totalHeight)
                guard ratio != sectionRatio else { return }
                sectionRatio = ratio
                SidebarPreferences.storeSplit(ratio)
            }
        return ZStack {
            Divider().opacity(0.4)
            Color.clear
                .frame(height: 8)
                .contentShape(Rectangle())
                // Named so the GUI case can find the rule's real rectangle instead
                // of estimating it from the two headings. Estimating got the drag
                // ~90 pt off and the gesture landed inside the spaces pane, where it
                // selected text and changed nothing.
                .accessibilityIdentifier("sidebar.section.divider")
                .onHover { inside in
                    if inside {
                        NSCursor.resizeUpDown.push()
                    } else {
                        NSCursor.pop()
                    }
                }
        }
        .frame(height: 8)
        .gesture(drag)
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

    /// The sidebar's top bar: the machine name and the new-workspace button.
    ///
    /// The segmented control that used to live here is gone with the tabs it
    /// switched (#115). Both panes are on screen now, so there is nothing to switch.
    private var header: some View {
        HStack(spacing: 6) {
            Text(machineName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                store.createWorkspace()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New workspace")
            // The collapse control belongs in the header, next to the other
            // window-level control: the herdr UI puts it on the `WORKSPACES` title
            // row. At the bottom of the footer it competed with `new` and `menu`,
            // which act on the space list rather than on the sidebar itself.
            Button {
                setCollapsed(true)
            } label: {
                Image(systemName: "sidebar.leading")
            }
            .buttonStyle(.borderless)
            .help("Collapse the sidebar")
            .accessibilityIdentifier("sidebar.collapse.toggle")
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
        // Upstream picks the title by machine count, and the two cases are
        // different renderers, not one function with a conditional label
        // (`render.rs:271-310`):
        //
        //   1 machine  -> `sidebar.rs:render_sidebar`          -> " spaces"
        //   >1 machines -> `endpoint_sidebar.rs:render_expanded` -> " machines"
        //
        // A single machine has no machine row at all, so "machines" there would
        // title a list that does not group anything.
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
        VStack(alignment: .leading, spacing: 0) {
            // Upstream draws a rule and then the heading, and skips the heading
            // when there is no room for it (`agent_sidebar.rs:100-120`). The
            // spaces pane has the same heading without a rule, because its rule is
            // the divider above it.
            agentPanelHeader
            agentsBody
        }
    }

    /// The agents pane's header: a rule, the title, and the sort label on the right.
    ///
    /// Upstream draws exactly this (`src/client/shell/agent_sidebar.rs:100-145`):
    ///
    ///     ──────────────────────────
    ///      agents            grouped
    ///
    /// The label is not a menu — it is the *current* mode, printed, and clicking it
    /// toggles between the two (`mouse.rs:2025-2032`). A right-click menu hides the
    /// setting behind a gesture nobody would look for, and hides which mode is
    /// active until the menu is open, so the two orderings are indistinguishable
    /// from the rows themselves.
    private var agentPanelHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The rule above the title. `spaces` has none because its rule is the
            // divider between the panes.
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 1)
                .padding(.horizontal, 6)
            HStack(spacing: 0) {
                Text("agents")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button {
                    store.agentPanelSort = store.agentPanelSort.toggled
                } label: {
                    Text(store.agentPanelSort.shortTitle)
                        .font(.system(size: 9, weight: .semibold))
                        // A filtered view is what upstream tints with the accent
                        // colour (`agent_sidebar.rs:141-146`); it marks "this list is
                        // not the plain one".
                        .foregroundStyle(store.agentPanelSort == .priority
                            ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("Agents order: \(store.agentPanelSort.title) — click to switch")
                .accessibilityIdentifier("sidebar.agents.sort")
            }
            .padding(.horizontal, 6)
            .padding(.top, 2)
        }
    }

    private var agentsBody: some View {
        Group {
            if !store.aggregatedAgents.isEmpty {
                ForEach(store.aggregatedAgents) { row in
                    let agent = row.agent
                    AgentRowView(
                        agent: agent,
                        // From the row, i.e. from the agent's own machine. Looking
                        // these up in `store.workspaces` / `store.tabs` only ever found
                        // the *selected* machine's, so every other machine's rows lost
                        // their workspace and showed a bare machine name.
                        workspace: row.workspace,
                        tab: row.tab,
                        layout: store.sidebarLayout,
                        // Each row names its *own* machine, not the active one: the
                        // pane lists every machine, so `machineName` (which describes
                        // the connection) would label every row with whatever
                        // machine happens to be selected.
                        machineName: row.machineLabel,
                        multiMachine: store.endpoints.count > 1
                    )
                    .opacity(row.stale ? 0.5 : 1)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // A row on another machine has to switch first: `focus` acts
                        // on the selected machine's pane ids, and those are not
                        // unique across machines — the other daemon also has a
                        // `w1:p1`. Same two-step as a workspace row on another
                        // machine.
                        if let target = store.endpoints.first(where: {
                            $0.id.storageKey == row.endpointID
                        }), target.id != store.activeEndpointID {
                            store.selectEndpoint(target)
                        } else {
                            store.focus(paneId: agent.paneId)
                        }
                    }
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

    /// What the footer dot is about, or `nil` when nothing needs the user.
    ///
    /// The conditions live in `FooterAttention` so they can be tested without a
    /// window; this only forwards the current snapshot.
    private var footerAttention: String? {
        FooterAttention.reason(for: store.snapshot)
    }

    /// Collapse or expand, remembering the choice.
    private func setCollapsed(_ collapsed: Bool) {
        isCollapsed = collapsed
        SidebarPreferences.storeCollapsed(collapsed)
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

/// The text between two tokens in one row.
///
/// Upstream's rule (`tokens.rs:184-191`): a space follows the state icon, because it is
/// a glyph rather than a word, and every other pair gets ` · `. Rendering every token at
/// one `HStack` spacing made `machine workspace tab` read as three unrelated words while
/// the terminal client shows `machine · workspace`.
func sidebarTokenSeparator(before previous: ResolvedToken, current: ResolvedToken) -> String {
    if previous.kind == .stateIcon || current.kind == .gitStatus {
        return " "
    }
    return " · "
}

private struct WorkspaceRowView: View {
    @Environment(\.palette) private var palette
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
                        HStack(spacing: 0) {
                            ForEach(Array(resolved.tokens.enumerated()), id: \.offset) { index, token in
                                if index > 0 {
                                    Text(sidebarTokenSeparator(
                                        before: resolved.tokens[index - 1],
                                        current: token
                                    ))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                }
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
                            ? sidebarColor("green", palette: palette)
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

    @Environment(\.palette) private var palette

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
            // Always. Upstream passes `Some(&endpoint.label)` for every endpoint,
            // including Local (`endpoint_agents.rs:163-166`), because the agents pane
            // mixes machines and "which machine" is part of the row's identity. The
            // `multiMachine` flag is what the *spaces* pane uses, where rows belong to
            // one machine.
            showsMachineName: true
        )
        let rows = layout.rows(for: agent.agent)
        VStack(alignment: .leading, spacing: CGFloat(layout.agentsRowGap)) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                let resolved = SidebarTokenResolver.resolve(row: row, context: context)
                if !resolved.tokens.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(Array(resolved.tokens.enumerated()), id: \.offset) { index, token in
                            if index > 0 {
                                Text(sidebarTokenSeparator(
                                    before: resolved.tokens[index - 1],
                                    current: token
                                ))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            }
                            tokenView(token)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        // The row is as wide as the sidebar, not as wide as its text.
        //
        // Without this the background wrapped the label and stopped: a focused row
        // read as a chip floating in the list instead of a selected row, and the empty
        // space to its right belonged to no row at all, so clicking beside an agent did
        // nothing. `WorkspaceRowView` already had this for exactly the same reason and
        // the agents list was missed.
        .frame(maxWidth: .infinity, alignment: .leading)
        // Hit testing follows the drawn rect, so the whole row is clickable rather than
        // only the glyphs SwiftUI happened to lay out.
        .contentShape(Rectangle())
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
            // Upstream marks the agent name bold in both states, brightening it from
            // `subtext0` to `text` when the row is focused (`agent_sidebar.rs:333-341`).
            // A regular weight made the row's second line look like a caption.
            StyledText(text: token.text, style: token.style)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(agent.focused ? palette.textColor : palette.subtextColor)
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
        // Full width for the same reason as the agent row: a background that stops at
        // the text makes a focused row look like a chip, and leaves the space to its
        // right belonging to no row.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
