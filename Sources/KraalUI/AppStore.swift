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
    /// Whether the focused program asked for every key event, including bare
    /// modifiers and releases. Fed to `TerminalInputDecoder.reportsAllKeys` so the
    /// key events carry `tracksRelease`, which is what the setting means on the
    /// wire. Previously the daemon's message was dropped on the floor.
    public internal(set) var keyboardReportAll = false
    /// A close the daemon refused because it would take a worktree group with it,
    /// waiting for the user to say yes.
    ///
    /// Lives on the store rather than in a view because both close entry points
    /// are outside SwiftUI's view tree: the sidebar's context menu is SwiftUI but
    /// the File menu is AppKit (`MacMenuBar`), and a confirmation owned by one of
    /// them would be invisible to the other.
    public internal(set) var pendingGroupClose: PendingGroupClose?
    public private(set) var reconnectedAt: Date?

    /// Effects from the pane that the desktop still has to act on.
    ///
    /// Set by the event reduction (pure, testable) and consumed by the AppKit
    /// side, which owns `NSPasteboard` / `NSWindow` / `NSSound`. Keeping the two
    /// apart is what lets `swift test` assert that a clipboard event produces a
    /// clipboard write without a running app or a real pasteboard.
    public internal(set) var pendingEffects = TerminalEffects.none
    /// Called after `pendingEffects` changes, so the desktop side can drain it.
    ///
    /// The callback returns nothing and the store clears `pendingEffects` itself
    /// once it has been handed over. That keeps the mutable state owned by the
    /// store: `KraalMac` consumes effects, it does not write them back.
    @ObservationIgnored
    public var onEffectsChanged: ((TerminalEffects) -> Void)?
    /// True while `onEffectsChanged` is running, so a re-entrant event cannot
    /// overwrite the batch being handed over.
    @ObservationIgnored private var isDrainingEffects = false

    /// Hands the pending effects to the desktop and clears them.
    ///
    /// Clearing after the callback (rather than leaving it to the caller) makes
    /// the contract one-way, and a batch that is applied twice — which would put
    /// the same text on the pasteboard twice — impossible by construction.
    public func drainEffects() {
        guard !isDrainingEffects else { return }
        let pending = pendingEffects
        guard !pending.isEmpty else { return }
        isDrainingEffects = true
        pendingEffects = .none
        onEffectsChanged?(pending)
        isDrainingEffects = false
    }

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
    @ObservationIgnored var inputDecoders: [String: TerminalInputDecoder] = [:]
    @ObservationIgnored var intentionalStop = false
    /// In-flight `client_shell_resize` sender, so a drag coalesces.
    @ObservationIgnored var resizeTask: Task<Void, Never>?

    /// In-flight divider drag, so a mouse move coalesces into one request.
    /// See `dragSplitRatio(path:ratio:)` for why sending every change is wrong.
    @ObservationIgnored var splitDrag = SplitDragState()
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
        // `scheduleEndpointRetry` owns the counter and the delay. Deriving the
        // phase countdown here as well meant two reads of one counter — this one
        // before the increment, the sleep after it — so from the second retry on
        // the banner counted down one step short of the real wait.
        scheduleEndpointRetry(endpoint, report: true)
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

    /// Jumps to a navigator target, switching machines when it lives on another
    /// one.
    ///
    /// The order matters and is the reason this is one method rather than three
    /// calls at the call site: focusing a pane whose machine is not on screen
    /// sends `pane.focus` to the *wrong daemon*. Switching first means the
    /// subsequent focus reaches the machine that owns the pane.
    ///
    /// Workspace and tab are focused before the pane so the pane's tab is
    /// actually on screen when it becomes focused — the daemon will happily focus
    /// a pane in a background tab, which looks like nothing happened.
    public func goTo(_ target: NavigatorTarget) {
        if let endpoint = endpoints.first(where: { $0.id.storageKey == target.machineId }) {
            selectEndpoint(endpoint)
        }
        guard let paneId = target.paneId else {
            if target.kind == .workspace {
                focus(workspaceId: target.workspaceId)
            } else if !target.tabId.isEmpty {
                focus(tabId: target.tabId)
            }
            return
        }
        if !target.workspaceId.isEmpty {
            focus(workspaceId: target.workspaceId)
        }
        if !target.tabId.isEmpty {
            focus(tabId: target.tabId)
        }
        focus(paneId: paneId)
    }

    public func close(tabId: String) {
        closeAfterChecking(tabId: tabId)
    }

    public func close(workspaceId: String) {
        closeAfterChecking(workspaceId: workspaceId)
    }

    public func close(paneId: String) {
        closeAfterChecking(paneId: paneId)
    }

    // MARK: - Closing, with the worktree-group confirmation the daemon asks for

    /// `workspace.close` params.
    ///
    /// `close_group` is not optional in practice: the daemon refuses to close a
    /// member of a multi-workspace worktree group unless the caller says whether
    /// it means the whole group. Leaving it out is what made the menu item look
    /// like a no-op — the refusal arrived in band and only reached a status-bar
    /// tooltip.
    nonisolated static func closeWorkspaceParams(
        workspaceId: String,
        closeGroup: Bool
    ) -> [String: Any] {
        ["workspace_id": workspaceId, "close_group": closeGroup]
    }

    /// `pane.close` params. No group flag: the daemon signals a group-level
    /// consequence with `confirmation_required` instead of taking a parameter.
    nonisolated static func closePaneParams(paneId: String) -> [String: Any] {
        ["pane_id": paneId]
    }

    nonisolated static func closeTabParams(tabId: String) -> [String: Any] {
        ["tab_id": tabId]
    }

    /// The error code the daemon uses when closing a workspace would take a whole
    /// worktree group with it (`src/app/api/workspaces.rs:328-336`).
    nonisolated static let groupCloseRequired = "workspace_group_close_required"

    /// The error code `pane.close` / `tab.close` use for the same consequence
    /// (`src/app/api/panes.rs:1976-1987`, `tabs.rs:242-247`).
    nonisolated static let confirmationRequired = "confirmation_required"

    /// Whether a refusal is the daemon asking "do you really mean the whole
    /// group?" rather than a failure. Both codes mean the same thing to the user
    /// — confirm once and send it again — so they share a branch.
    nonisolated static func isGroupCloseRefusal(_ code: String) -> Bool {
        code == groupCloseRequired || code == confirmationRequired
    }

    /// Closes something, retrying with the group flag when the daemon says the
    /// target is part of a worktree group.
    ///
    /// The retry is *after* an explicit refusal rather than predicted from the
    /// snapshot: the daemon is the authority on what a group is, and its rule
    /// (parent + at least one linked child, `sidebar.rs:573-601`) differs from the
    /// sidebar's display grouping. Asking beats guessing — and the second request
    /// is only sent once the user has confirmed.
    private func closeAfterChecking(
        workspaceId: String? = nil,
        paneId: String? = nil,
        tabId: String? = nil
    ) {
        let method: String
        let params: [String: Any]
        if let workspaceId {
            method = "workspace.close"
            // First attempt never claims the group: the user clicked one row.
            params = Self.closeWorkspaceParams(workspaceId: workspaceId, closeGroup: false)
        } else if let paneId {
            method = "pane.close"
            params = Self.closePaneParams(paneId: paneId)
        } else if let tabId {
            method = "tab.close"
            params = Self.closeTabParams(tabId: tabId)
        } else {
            return
        }

        Task {
            let refusal = await callReturningErrorCode(method, params)
            guard let refusal else { return }
            guard Self.isGroupCloseRefusal(refusal) else {
                // Not something the user can act on by confirming again, or they
                // already did and the daemon refused anyway.
                lastError = "\(method): \(refusal)"
                return
            }
            // Ask before taking other workspaces down with it. Logged because a
            // refusal that only reaches a tooltip is how #21 stayed hidden: this
            // line is the difference between "the menu did nothing" and "the app
            // is waiting for the user".
            kraalLog("close: daemon refused \(method) alone (\(refusal)), asking")
            pendingGroupClose = PendingGroupClose(
                method: method,
                workspaceId: workspaceId,
                paneId: paneId,
                tabId: tabId
            )
        }
    }

    /// What the user is being asked to confirm.
    public struct PendingGroupClose: Equatable, Sendable {
        public var method: String
        public var workspaceId: String?
        public var paneId: String?
        public var tabId: String?
    }

    /// Confirms the pending group close.
    ///
    /// `workspace.close` takes `close_group: true`; `pane.close` / `tab.close`
    /// take no such parameter — the second request is identical, and the daemon
    /// accepts it once the client has shown the confirmation it asked for.
    public func confirmPendingGroupClose() {
        guard let pending = pendingGroupClose else { return }
        pendingGroupClose = nil
        if let workspaceId = pending.workspaceId {
            let params = Self.closeWorkspaceParams(workspaceId: workspaceId, closeGroup: true)
            Task { await call("workspace.close", params) }
            return
        }
        if let paneId = pending.paneId {
            let params = Self.closePaneParams(paneId: paneId)
            Task { await call("pane.close", params) }
            return
        }
        if let tabId = pending.tabId {
            let params = Self.closeTabParams(tabId: tabId)
            Task { await call("tab.close", params) }
        }
    }

    public func cancelPendingGroupClose() {
        pendingGroupClose = nil
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

    /// Sets whether right-clicks on this pane go to its program.
    ///
    /// `pane.input.set` is the daemon's per-pane input routing
    /// (`api/schema/panes.rs:44-47`). It is **not** a client-side preference:
    /// the daemon stores it, applies it to the pane, and reports it back as
    /// `right_click_passthrough` in the snapshot. So the menu item sends the
    /// request and lets the snapshot be the source of truth — toggling a local
    /// flag would show a checkmark the daemon never agreed to.
    public func setRightClickPassthrough(paneId: String, passthrough: Bool) {
        let params = Self.rightClickParams(paneId: paneId, passthrough: passthrough)
        Task { await call("pane.input.set", params) }
    }

    /// The wire body of `pane.input.set`, kept separate so a test can assert the
    /// field names without a live daemon (`splitParams` follows the same rule).
    public nonisolated static func rightClickParams(
        paneId: String,
        passthrough: Bool
    ) -> [String: Any] {
        [
            "pane_id": paneId,
            "right_click": PaneContextRouting.target(for: passthrough).rawValue,
        ]
    }

    public func setSplitRatio(path: [Bool], ratio: Double) {
        let params = Self.splitRatioParams(
            path: path,
            ratio: ratio,
            tabId: snapshot?.focusedTabId
        )
        Task { await call("layout.set_split_ratio", params) }
    }

    /// The `layout.set_split_ratio` params, as a pure function.
    ///
    /// Follows the same pattern as `splitParams`: the body of a request that
    /// silently targets the wrong thing is only testable as a value, and the
    /// daemon does not reject a wrong or missing key.
    ///
    /// `tab_id` is what keeps the resize pointed at the tab the user is looking
    /// at. Without it the daemon falls back to "the current tab of the current
    /// workspace" (`src/app/api/layouts.rs` `resolve_layout_export_target`, the
    /// `(None, None)` arm), which is only the same tab while this client happens
    /// to be showing it — so a drag that lands just after a focus change resizes
    /// a tab nobody is watching, with no error on either side.
    ///
    /// `pane_id` must never appear: `layout.set_split_ratio` names a divider by
    /// `path`, and a pane id here would be ignored at best.
    ///
    /// `tabId == nil` (no snapshot yet) omits the key rather than sending an
    /// empty string — an empty id is a tab that does not exist, while a missing
    /// key is the documented "current tab" fallback.
    static func splitRatioParams(
        path: [Bool],
        ratio: Double,
        tabId: String?
    ) -> [String: Any] {
        let namedTab = tabId.flatMap { $0.isEmpty ? nil : $0 }
        guard let namedTab else {
            return ["path": path, "ratio": ratio]
        }
        return ["path": path, "ratio": ratio, "tab_id": namedTab]
    }

    /// Moves a divider while it is being dragged.
    ///
    /// Sending one request per `onChanged` looks obvious and is wrong twice over:
    ///
    /// - A connection serves one command at a time. A drag emits changes far
    ///   faster than a round-trip, so most requests would be refused with
    ///   `endpoint_busy` and the divider would follow only whichever ones won the
    ///   race — stuttering, and lagging further behind the faster you move.
    /// - The ratios are positions, not increments, so coalescing is safe and
    ///   skipping the intermediate ones loses nothing. Only the latest matters.
    ///
    /// So: keep the newest ratio, and while a request is in flight, let it fall
    /// through to the next slot. The result is at most one request per round-trip,
    /// always carrying the most recent pointer position.
    ///
    /// Also used for the released position: the last `onChanged` can be coalesced
    /// away and the daemon has no idea where the pointer stopped, so the final
    /// ratio has to be sent through the same path rather than dropped.
    public func dragSplitRatio(path: [Bool], ratio: Double) {
        splitDrag.pending = SplitDragState.Target(path: path, ratio: ratio)
        guard !splitDrag.inFlight else { return }
        splitDrag.inFlight = true
        Task {
            // Loop rather than recurse: each iteration drains the newest value
            // that arrived while the previous request was on the wire.
            while let next = splitDrag.pending {
                splitDrag.pending = nil
                await call("layout.set_split_ratio", [
                    "path": next.path,
                    "ratio": next.ratio,
                ])
            }
            splitDrag.inFlight = false
        }
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

/// Coalescing state for a divider drag.
///
/// A `DragGesture` emits a change per mouse move — hundreds per second on a
/// trackpad — while a request round-trip is milliseconds and the connection
/// serves exactly one command at a time. Sending them all would spend the whole
/// drag being refused with `endpoint_busy`, and the divider would follow only the
/// few that happened to win.
///
/// `pending` holds the newest position the pointer reported; the looping sender in
/// `dragSplitRatio` keeps consuming it, so the requests that do go out always
/// carry where the pointer is *now*, never a stale position queued behind them.
/// Because ratios are absolute positions rather than increments, dropping the
/// intermediate ones loses nothing.
struct SplitDragState {
    struct Target {
        var path: [Bool]
        var ratio: Double
    }

    /// The newest position not yet sent.
    var pending: Target?
    /// Whether a sender loop is already draining `pending`.
    var inFlight = false
}
