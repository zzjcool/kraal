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

    public var target: ConnectionSettings {
        didSet { if target != oldValue { scheduleReconnect(resetBackoff: true) } }
    }

    /// The measured size of one terminal cell in device pixels, reported by the
    /// renderer once a surface exists. Geometry negotiation divides the pane
    /// area by this to pick a grid size.
    public var terminalCellSize = SurfaceGeometry.fallbackCellSize

    /// The geometry the daemon renders for us, in cells.
    ///
    /// A change here is a *resize*, not a new session: it is pushed onto the live
    /// connection with `client_shell_resize` (see `resizeSurface`). Reconnecting
    /// instead — which is what this used to do — made every step of a window drag
    /// a fresh handshake, so the pane sat on a stale surface for the length of a
    /// TCP/handshake round-trip and the chrome never followed the window.
    public var surfaceSize = ClientSurfaceSize(cols: 120, rows: 40)

    @ObservationIgnored var connection: EndpointConnection?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
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
        // second handshake would deliver a duplicate snapshot and surface.
        if connectTask != nil, !intentionalStop, phase.isLive || phase == .connecting {
            return
        }
        intentionalStop = false
        reconnectAttempt = 0
        startConnection()
    }

    public func disconnect() {
        intentionalStop = true
        connectTask?.cancel()
        connectTask = nil
        healthTask?.cancel()
        healthTask = nil
        let connection = self.connection
        self.connection = nil
        Task { await connection?.stop() }
        phase = .idle
        surface = nil
    }

    private func startConnection() {
        kraalLog("connect: target=\(target.name) transport=\(target.transport.rawValue) "
            + "session=\(target.session) surface=\(surfaceSize.cols)x\(surfaceSize.rows)")
        connectTask?.cancel()
        let resolvedTarget: HerdrTarget
        do {
            resolvedTarget = try HerdrDiscovery.resolve(target)
        } catch {
            phase = .failed("\(error)")
            return
        }

        phase = .connecting
        lastError = nil

        connectTask = Task { [weak self] in
            guard let self else { return }
            let connection = EndpointConnection(
                target: resolvedTarget,
                surfaceSize: surfaceSize
            ) { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.apply(event)
                }
            }
            self.connection = connection
            do {
                try await connection.start()
                self.phase = .live
                self.reconnectedAt = Date()
                self.reconnectAttempt = 0
                kraalLog("connected: daemon=\(self.welcome?.serverVersion ?? "?")")
                // The hello carried the grid measured when this attempt began.
                // A resize during the handshake would otherwise leave the daemon
                // rendering a size the window has already left, with no later
                // event to correct it.
                self.pushSurfaceSize()
            } catch {
                kraalLog("connect failed: \(error)")
                await connection.stop()
                guard !Task.isCancelled else { return }
                self.phase = .failed("\(error)")
                self.lastError = "\(error)"
                self.scheduleReconnect()
            }
        }
    }

    /// Exponential backoff capped at 30 s, as the design calls for: the daemon
    /// has no transparent resume, so a reconnect is always a fresh handshake.
    func scheduleReconnect(resetBackoff: Bool = false) {
        guard !intentionalStop else { return }
        if resetBackoff {
            reconnectAttempt = 0
            let established = connection
            connection = nil
            Task { await established?.stop() }
        }
        reconnectAttempt += 1
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)), 30)
        let retryAt = Date().addingTimeInterval(delay)
        phase = .reconnecting(attempt: reconnectAttempt, retryAt: retryAt)

        connectTask?.cancel()
        connectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self, !self.intentionalStop else { return }
            self.startConnection()
        }
    }

    // MARK: - Events

    private func apply(_ event: ConnectionEvent) {
        switch event {
        case let .connected(welcome):
            handleWelcome(welcome)
        case let .snapshot(snapshot):
            handleSnapshot(snapshot)
        case let .surface(surface):
            handleSurface(surface)
        case let .surfacePatch(patch):
            handleSurfacePatch(patch)
        case let .error(message):
            lastError = message
        case let .serverShutdown(reason):
            self.surface = nil
            surfaceIsStale = false
            phase = .failed(reason ?? "The daemon shut down.")
        case let .disconnected(reason):
            // Keep the last frame up while the reconnect runs. A dropped
            // connection does not invalidate what was on screen a moment ago, and
            // replacing a working picture with an empty background turns a blip
            // into what looks like a crash. The frame is marked stale so the view
            // can dim it rather than pass it off as current.
            surfaceIsStale = surface != nil
            if intentionalStop {
                surface = nil
                surfaceIsStale = false
                return
            }
            if case .failed = phase { return }
            if surfaceIsStale {
                kraalLog("disconnected: holding last frame (stale)")
            } else {
                surface = nil
            }
            lastError = reason
            scheduleReconnect()
        default:
            break
        }
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
        Task { await call("pane.split", ["pane_id": paneId, "direction": orientation.rawValue]) }
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

    public func splitPane(paneId: String, orientation: SplitOrientation = .right) {
        Task {
            await call("pane.split", [
                "pane_id": paneId,
                "direction": orientation.rawValue,
            ])
        }
    }

    public func toggleZoom(paneId: String) {
        Task { await call("pane.zoom", ["pane_id": paneId]) }
    }

    public func setSplitRatio(path: [Bool], ratio: Double) {
        Task {
            await call("layout.set_split_ratio", [
                "path": path,
                "ratio": ratio,
            ])
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
