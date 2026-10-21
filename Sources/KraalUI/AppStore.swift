// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The app's single source of truth.
//
// One `@Observable` store owns the connection, the latest snapshot, and the
// per-pane terminal state. Views read it; only this file talks to the protocol
// layer. Keeping the boundary here is what lets the CLI and the UI share exactly
// one connection implementation.

import Foundation
import KraalProtocol
import KraalClient
import KraalSidebar
import KraalTransport
import Observation

@MainActor
@Observable
public final class AppStore {
    public enum Phase: Equatable {
        case idle
        case connecting
        case live
        case reconnecting(attempt: Int, retryAt: Date)
        case failed(String)

        public var isLive: Bool { self == .live }
    }

    public internal(set) var phase: Phase = .idle
    public internal(set) var welcome: EndpointServerWelcome?
    public internal(set) var snapshot: ClientShellSnapshot?
    public internal(set) var surface: PaneSurfaceFrame?
    /// True while the frame on screen belongs to a connection that has dropped.
    public internal(set) var surfaceIsStale = false
    public internal(set) var lastError: String?
    public private(set) var reconnectedAt: Date?

    /// Applied to every sidebar render; replaced when a config is imported.
    public var sidebarLayout = SidebarLayout()
    public var sidebarConfigSource: String?

    /// Every machine the sidebar can draw, local first.
    ///
    /// One entry per saved profile plus `Local`. Only the selected entry streams a
    /// pane surface and receives input; the others run snapshot-only observers (see
    /// `AppStore+Endpoints.swift`). The terminal client keeps the same catalog so a
    /// machine's workspace list stays visible, dimmed, while it reconnects.
    public internal(set) var endpoints: [EndpointState] = []
    /// The entry `target` currently points at.
    public internal(set) var activeEndpointID: EndpointID?
    /// `worktree.key` values whose child rows are folded shut, per endpoint.
    public var collapsedWorktreeGroups: [EndpointID: Set<String>] = [:]
    /// Machines whose row group is collapsed, hiding their workspaces.
    public var collapsedEndpoints: Set<EndpointID> = []

    /// Loads the saved-machine list that populates `endpoints`.
    @ObservationIgnored
    public let endpointCatalog: EndpointCatalogLoader

    /// Called whenever the set of live panes changes, so the renderer pool can
    /// release surfaces for panes that no longer exist.
    @ObservationIgnored
    public var onPaneSetChanged: ((Set<String>) -> Void)?

    /// Each pane view's rectangle in its window's content view, top-left origin.
    ///
    /// The pane views report themselves here so hit testing (mouse forwarding)
    /// uses real geometry instead of recomputing chrome heights.
    @ObservationIgnored
    public var paneViewFrames: [String: CGRect] = [:]

    /// Where the foreground connection points.
    ///
    /// Assigning it no longer reconnects. Changing machines goes through
    /// `selectEndpoint`, which flips the surface lease on two live connections
    /// instead of tearing one down — so a `didSet` reconnect here would undo that
    /// work and reintroduce the gap it was meant to remove. The setter is kept
    /// because the connection sheet writes it before calling `connect()`.
    public var target: ConnectionSettings

    /// The measured size of one terminal cell in device pixels, reported by the
    /// renderer once a surface exists. Geometry negotiation divides the pane
    /// area by this to pick a grid size.
    public var terminalCellSize = SurfaceGeometry.fallbackCellSize

    /// The geometry the daemon renders for us, in cells.
    ///
    /// A change here is a *resize*, not a new session: it is pushed onto the live
    /// connection with `client_shell_resize` (see `resizeSurface`). Reconnecting
    /// instead made every step of a window drag a fresh handshake, so the pane sat
    /// on a stale surface for the length of a round-trip and the chrome never
    /// followed the window.
    public var surfaceSize = ClientSurfaceSize(cols: 120, rows: 40)

    /// The connection belonging to the machine that currently owns the screen.
    ///
    /// Computed, not stored: every machine has its own connection now (see
    /// `EndpointState.connection`), and the store-level one is just the view onto
    /// whichever is foreground. Everything that talks to "the daemon" — input,
    /// requests, resize — reads this and therefore follows the selection without
    /// knowing that connections are per-machine.
    var connection: EndpointConnection? { activeEndpoint?.connection }
    @ObservationIgnored private var healthTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectAttempt = 0
    @ObservationIgnored var inputDecoders: [String: TerminalInputDecoder] = [:]
    @ObservationIgnored var intentionalStop = false
    /// In-flight `client_shell_resize` sender, so a drag coalesces.
    @ObservationIgnored var resizeTask: Task<Void, Never>?
    /// Set when a grid still has to be pushed, so a request that arrives while a
    /// send is in flight is not lost.
    @ObservationIgnored var resizePending = false

    public init(target: ConnectionSettings = .local) {
        self.target = target
        self.endpointCatalog = EndpointCatalogLoader(
            local: LocalMachineDescriptor.resolve(settings: target)
        )
    }

    /// Rebuilds the machine catalog from the saved-profile list.
    ///
    /// Called at launch and after the machines dialog writes a profile, so the
    /// sidebar's machine rows and the dialog never disagree about which machines
    /// exist.
    public func loadEndpoints() async {
        let roster = await endpointCatalog.reload()
        rebuildEndpoints(roster: roster)
        connectMissingEndpoints()
    }

    // MARK: - Derived state

    public var workspaces: [ClientShellWorkspace] { snapshot?.workspaces ?? [] }
    public var tabs: [ClientShellTab] { snapshot?.tabs ?? [] }
    public var panes: [ClientShellPane] { snapshot?.panes ?? [] }
    public var commands: [ClientShellCommand] { snapshot?.commands ?? [] }

    public var focusedWorkspace: ClientShellWorkspace? {
        guard let snapshot else { return nil }
        return snapshot.workspaces.first { $0.workspaceId == snapshot.focusedWorkspaceId }
            ?? snapshot.workspaces.first
    }

    public var focusedTab: ClientShellTab? {
        guard let snapshot else { return nil }
        return snapshot.tabs.first { $0.tabId == snapshot.focusedTabId } ?? snapshot.tabs.first
    }

    /// Tabs of the focused workspace, which is what the tab bar shows.
    public var visibleTabs: [ClientShellTab] {
        guard let workspace = focusedWorkspace else { return tabs }
        return tabs.filter { $0.workspaceId == workspace.workspaceId }
    }

    // MARK: - Lifecycle

    public func connect() {
        // Idempotent: `onAppear` and the app delegate both ask to connect, and a
        // second handshake would deliver a duplicate snapshot and surface. The
        // task check matters as much as the connection check — between the call
        // and the handshake landing there is no connection object yet, and that
        // window is exactly when the second caller arrives.
        if activeEndpoint?.connection != nil || activeEndpoint?.connectionTask != nil {
            return
        }
        intentionalStop = false
        reconnectAttempt = 0
        connectActiveEndpoint()
    }

    /// Opens the selected machine's connection, creating its endpoint row first if
    /// the catalog has not landed yet.
    ///
    /// At launch `connect()` runs before `loadEndpoints()`, so on the very first
    /// call there is no endpoint to attach to. The local row is the one the store
    /// starts on, so it is created here rather than making `connect()` wait for a
    /// subprocess to list machines.
    private func connectActiveEndpoint() {
        if endpoints.isEmpty {
            let local = EndpointState(id: .local, label: "Local", settings: .local)
            endpoints = [local]
            activeEndpointID = .local
        }
        guard let endpoint = activeEndpoint else { return }
        endpoint.settings = target
        kraalLog("connect: target=\(target.name) transport=\(target.transport.rawValue) "
            + "session=\(target.session) surface=\(surfaceSize.cols)x\(surfaceSize.rows)")
        phase = .connecting
        lastError = nil
        connectEndpoint(endpoint)
    }

    public func disconnect() {
        intentionalStop = true
        healthTask?.cancel()
        healthTask = nil
        // Every machine has a connection now, so leaving the store means closing
        // all of them — not just the foreground one.
        disconnectAllEndpoints()
        phase = .idle
        surface = nil
    }

    /// Reconnects the selected machine after its connection was lost.
    ///
    /// Kept as a store-level entry point because the reconnect controls and the
    /// phase machine call it, but the work belongs to the endpoint: one machine
    /// dropping out must not touch any other machine's connection.
    func scheduleReconnect(resetBackoff: Bool = false) {
        guard !intentionalStop, let endpoint = activeEndpoint else { return }
        if resetBackoff {
            endpoint.reconnectAttempt = 0
            disconnectEndpoint(endpoint)
        }
        let attempt = max(endpoint.reconnectAttempt, 1)
        let delay = min(pow(2.0, Double(attempt - 1)), 30)
        phase = .reconnecting(
            attempt: attempt,
            retryAt: Date().addingTimeInterval(delay)
        )
        scheduleEndpointRetry(endpoint)
    }

    // MARK: - Events

    /// Whether an event stamped with `epoch` still describes the connection the
    /// store is using.
    ///
    /// Split out as a pure function so the rule is testable without a daemon: the
    /// interesting case is a *superseded* connection reporting a disconnect after
    /// its replacement has already started.
    nonisolated static func eventIsCurrent(epoch: Int, currentEpoch: Int) -> Bool {
        epoch == currentEpoch
    }

    // MARK: - Actions

    public func focus(workspaceId: String) {
        Task {
            await call("workspace.focus", ["workspace_id": workspaceId])
            await reprojectSurface()
        }
    }

    /// Focuses a tab by its position in the visible tab list.
    public func focusTab(number index: Int) {
        guard visibleTabs.indices.contains(index) else { return }
        focus(tabId: visibleTabs[index].tabId)
    }

    /// Focuses a workspace by its position in the sidebar list.
    public func focusWorkspace(number index: Int) {
        guard workspaces.indices.contains(index) else { return }
        focus(workspaceId: workspaces[index].workspaceId)
    }

    /// Steps to the next/previous tab, wrapping at both ends — the behaviour a
    /// terminal multiplexer user expects from next/previous bindings.
    public func cycleTab(by delta: Int) {
        let tabs = visibleTabs
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex { $0.focused } ?? 0
        let next = ((current + delta) % tabs.count + tabs.count) % tabs.count
        focus(tabId: tabs[next].tabId)
    }

    public func cycleWorkspace(by delta: Int) {
        guard !workspaces.isEmpty else { return }
        let current = workspaces.firstIndex { $0.focused }
            ?? workspaces.firstIndex { $0.workspaceId == focusedWorkspace?.workspaceId }
            ?? 0
        let next = ((current + delta) % workspaces.count + workspaces.count) % workspaces.count
        focus(workspaceId: workspaces[next].workspaceId)
    }

    /// The pane that should receive a pane-scoped action. `focusedPaneId` is
    /// authoritative when the daemon fills it in; falling back to the first
    /// visible pane keeps the action usable on daemons that omit it.
    public var actionPaneId: String? {
        snapshot?.focusedPaneId ?? visiblePanes.first?.paneId
    }

    /// The tab that should receive a tab-scoped action.
    public var actionTabId: String? {
        snapshot?.focusedTabId ?? visibleTabs.first?.tabId
    }

    public func cyclePane(by delta: Int) {
        let panes = visiblePanes
        guard !panes.isEmpty else { return }
        let current = panes.firstIndex { $0.focused }
            ?? panes.firstIndex { $0.paneId == actionPaneId }
            ?? 0
        let next = ((current + delta) % panes.count + panes.count) % panes.count
        focus(paneId: panes[next].paneId)
    }

    /// Split the pane the user is actually in.
    public func splitActionPane(_ orientation: SplitOrientation = .right) {
        guard let paneId = actionPaneId else { return }
        splitPane(paneId: paneId, orientation: orientation)
    }

    public func toggleZoomActionPane() {
        guard let paneId = actionPaneId else { return }
        toggleZoom(paneId: paneId)
    }

    public func closeActionPane() {
        guard let paneId = actionPaneId else { return }
        close(paneId: paneId)
    }

    public func closeActionTab() {
        guard let tabId = actionTabId else { return }
        close(tabId: tabId)
    }

    public func closeActionWorkspace() {
        guard let workspace = focusedWorkspace else { return }
        close(workspaceId: workspace.workspaceId)
    }

    public func focus(tabId: String) {
        Task {
            await call("tab.focus", ["tab_id": tabId])
            // Daemons without surface interest never announce the new focus, so
            // ask for the projection explicitly instead of waiting for a snapshot
            // that will not come.
            await reprojectSurface()
        }
    }

    public func focus(paneId: String) {
        Task { await call("pane.focus", ["pane_id": paneId]) }
    }

    public func close(tabId: String) {
        Task { await call("tab.close", ["tab_id": tabId]) }
    }

    public func close(workspaceId: String) {
        Task { await call("workspace.close", ["workspace_id": workspaceId]) }
    }

    public func close(paneId: String) {
        Task { await call("pane.close", ["pane_id": paneId]) }
    }

    public func createTab(label: String? = nil) {
        var params: [String: Any] = [:]
        if let label { params["label"] = label }
        Task { await call("tab.create", params) }
    }

    public func createWorkspace() {
        Task { await call("workspace.create", [:]) }
    }

    /// Splits `paneId`, placing the new pane beside it.
    ///
    /// The parameter is `target_pane_id`, not `pane_id`. `PaneSplitParams` has
    /// no `pane_id` field at all — every other pane method takes one, so the
    /// mistake is invisible: the daemon drops the unknown key as it does any
    /// other, `direction` alone satisfies the request, and the split lands on
    /// whatever tab the daemon considers focused instead of the pane the user
    /// clicked. Measured against 0.9.5: `pane_id: wS:p1` from workspace `wS`
    /// created a pane in `wT:t1`; `target_pane_id: wS:p1` created it in `wS:t1`.
    ///
    /// Pass `AppStore.splitParams(..)` rather than building the dictionary here:
    /// the wire names have to stay testable without a live daemon.
    public func splitPane(paneId: String, orientation: SplitOrientation = .right) {
        let params = Self.splitParams(paneId: paneId, orientation: orientation)
        Task {
            await call("pane.split", params)
            // The daemon does not announce the new pane on its own: without an
            // explicit re-projection the split stayed invisible until the next
            // unrelated snapshot. Matches what `focus(tabId:)` already does.
            await reprojectSurface()
        }
    }

    /// The wire body of `pane.split`, kept separate so a test can assert the
    /// field name without opening a connection.
    public nonisolated static func splitParams(
        paneId: String,
        orientation: SplitOrientation = .right
    ) -> [String: Any] {
        [
            "target_pane_id": paneId,
            "direction": orientation.rawValue,
        ]
    }

    public func toggleZoom(paneId: String) {
        Task { await call("pane.zoom", ["pane_id": paneId]) }
    }

    public func setSplitRatio(path: [Bool], ratio: Double) {
        let params = Self.splitRatioParams(path: path, ratio: ratio)
        Task { await call("layout.set_split_ratio", params) }
    }

    /// The `layout.set_split_ratio` params, as a pure function.
    ///
    /// Follows the same pattern as `splitParams`: the body of a request that
    /// silently targets the wrong thing is only testable as a value, and the
    /// daemon does not reject a wrong or missing key.
    ///
    /// `SplitRatioPortTests` pins this against
    /// `rootshell/rootshellTests/HerdrProtocolTests.swift:29`, which asserts the
    /// exact param shape — including a `tab_id` this function does not send yet.
    static func splitRatioParams(path: [Bool], ratio: Double) -> [String: Any] {
        [
            "path": path,
            "ratio": ratio,
        ]
    }

    public func invoke(commandId: String) {
        Task { await call("command.invoke", ["command_id": commandId]) }
    }

    /// Set when measured metrics invalidate the current grid.
    public var needsGeometryReeval = false

    /// In-flight `client_shell.surface.set` request, coalesced by tab switches.
    var surfaceInterestTask: Task<Void, Never>?
    /// Set while a connection is being replaced to pick up a new focus, so the
    /// stale surface that is still arriving does not trigger another restart.
    @ObservationIgnored var resyncPending = false
    /// Guards `reprojectSurface` against overlapping toggles.
    @ObservationIgnored var reprojectInFlight = false
}
