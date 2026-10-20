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
    public var surfaceSize = ClientSurfaceSize(cols: 120, rows: 40) {
        didSet {
            if surfaceSize != oldValue { scheduleReconnect(resetBackoff: true) }
        }
    }

    @ObservationIgnored var connection: EndpointConnection?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var healthTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectAttempt = 0
    @ObservationIgnored private var inputDecoders: [String: TerminalInputDecoder] = [:]
    @ObservationIgnored var intentionalStop = false

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

    /// The panes of the focused tab, in surface order.
    public var visiblePanes: [ClientShellPane] {
        guard let tab = focusedTab else { return panes }
        return panes.filter { $0.tabId == tab.tabId }
    }

    public var agentsOrdered: [ClientShellAgent] {
        guard let snapshot else { return [] }
        let byPane = Dictionary(
            uniqueKeysWithValues: snapshot.agents.map { ($0.paneId, $0) }
        )
        if snapshot.agentOrder.isEmpty {
            return snapshot.agents
        }
        return snapshot.agentOrder.compactMap { byPane[$0] }
    }

    public func workspace(for tab: ClientShellTab) -> ClientShellWorkspace? {
        workspaces.first { $0.workspaceId == tab.workspaceId }
    }

    public func tab(for pane: ClientShellPane) -> ClientShellTab? {
        tabs.first { $0.tabId == pane.tabId }
    }

    public func agent(forPane paneId: String) -> ClientShellAgent? {
        snapshot?.agents.first { $0.paneId == paneId }
    }

    public func paneGeometry(for paneId: String) -> PaneSurfacePane? {
        surface?.panes.first { $0.paneId == paneId }
    }

    /// Splits that belong to the current surface, for divider dragging.
    public var splits: [PaneSurfaceSplit] { surface?.splits ?? [] }

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
            phase = .failed(reason ?? "The daemon shut down.")
        case let .disconnected(reason):
            surface = nil
            if intentionalStop { return }
            if case .failed = phase { return }
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

    public func splitPane(paneId: String) {
        Task { await call("pane.split", ["pane_id": paneId]) }
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

    /// Re-issues a request when the geometry changed, so the daemon re-renders
    /// at the new size.
    /// Records the renderer's measured cell size and re-negotiates if it changed
    /// enough to alter the grid.
    public func updateCellMetrics(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let changed = abs(size.width - terminalCellSize.width) > 0.5
            || abs(size.height - terminalCellSize.height) > 0.5
        guard changed else { return }
        kraalLog("cell metrics: \(terminalCellSize) -> \(size)")
        terminalCellSize = size
        needsGeometryReeval = true
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

    public func resizeSurface(cols: UInt16, rows: UInt16) {
        guard cols > 0, rows > 0 else { return }
        let clamped = ClientSurfaceSize(cols: cols, rows: rows)
        guard clamped != surfaceSize else { return }
        kraalLog("geometry: \(surfaceSize.cols)x\(surfaceSize.rows) -> \(cols)x\(rows)")
        surfaceSize = clamped
    }

    /// Sends keystrokes to a pane.
    ///
    /// Ghostty returns encoded bytes; they are translated into semantic events
    /// here so they can travel on the endpoint connection. The decoder holds
    /// partial escape sequences between calls, hence one per pane.
    public func sendInput(_ data: Data, to paneId: String?) {
        guard let paneId else { return }
        var decoder = inputDecoders[paneId] ?? TerminalInputDecoder()
        var events = decoder.decode(data)
        if events.isEmpty {
            // A lone Esc produces a single byte and no follow-up; flush it once
            // the chunk ends so the key is not swallowed.
            if let escape = decoder.flushEscape() {
                events.append(escape)
            }
        }
        inputDecoders[paneId] = decoder
        guard !events.isEmpty else { return }

        Task {
            do {
                try await connection?.sendPaneInput(paneId, events: events)
            } catch {
                lastError = "\(error)"
            }
        }
    }

    /// Whether the program inside a pane asked for mouse reporting.
    ///
    /// Ghostty cannot know this (it renders from the cell grid, which carries no
    /// mouse mode), so the daemon's per-pane flag is the authority. When it is
    /// false the click belongs to the app, not the program.
    public func mouseReportingEnabled(forPane paneId: String) -> Bool {
        paneGeometry(for: paneId)?.mouseReporting ?? false
    }

    public func mousePrecision(forPane paneId: String) -> Bool {
        paneGeometry(for: paneId)?.sgrPixelMouse ?? false
    }

    /// Sends one mouse event to a pane, when that pane accepts mouse input.
    public func sendMouse(
        _ kind: ClientMouseKind,
        at point: CGPoint,
        in viewSize: CGSize,
        paneId: String,
        modifiers: UInt8 = 0,
        lines: UInt16 = 0
    ) {
        guard let geometry = paneGeometry(for: paneId),
              geometry.mouseReporting
        else { return }

        let surface = self.surface?.frame
        let mapper = MouseCoordinateMapper(
            innerRect: geometry.innerRect,
            viewSize: viewSize,
            gridWidth: surface?.width ?? 0,
            gridHeight: surface?.height ?? 0
        )
        let position = PaneMouse.position(
            for: point,
            mapper: mapper,
            precision: geometry.sgrPixelMouse
        )
        let event = ClientPaneInputEvent.mouse(
            kind: kind,
            position: position,
            geometry: ClientMouseGeometry(
                cols: geometry.innerRect.width,
                rows: geometry.innerRect.height,
                widthPx: geometry.pixelWidth,
                heightPx: geometry.pixelHeight
            ),
            modifiers: modifiers,
            lines: lines
        )
        Task {
            do {
                try await connection?.sendPaneInput(paneId, events: [event])
            } catch {
                lastError = "\(error)"
            }
        }
    }

    public func send(text: String, to paneId: String?) {
        guard let paneId else { return }
        Task {
            do {
                try await connection?.sendPaneInput(paneId, events: [.textCommit(text)])
            } catch {
                lastError = "\(error)"
            }
        }
    }

    public func loadSidebarConfig(contents: String, source: String) {
        do {
            sidebarLayout = try SidebarConfigResolver.layout(fromTOML: contents)
            sidebarConfigSource = source
            lastError = nil
        } catch {
            lastError = "Sidebar config: \(error)"
        }
    }

    public func loadSidebarConfig(fileURL: URL) {
        do {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            loadSidebarConfig(contents: text, source: fileURL.lastPathComponent)
        } catch {
            lastError = "Could not read \(fileURL.lastPathComponent): \(error)"
        }
    }

    /// Loads `~/.config/herdr/config.toml` if it exists.
    public func loadDefaultSidebarConfig() {
        let path = (HerdrDiscovery.configDirectory() as NSString)
            .appendingPathComponent("config.toml")
        guard FileManager.default.fileExists(atPath: path) else { return }
        loadSidebarConfig(fileURL: URL(fileURLWithPath: path))
    }

    /// Asks the daemon to stream the focused tab's projection to us.
    ///
    /// `client_shell.surface.set` is an upstream API, not a protocol message:
    /// until it is called the daemon keeps projecting whichever tab held focus at
    /// handshake time, so switching tabs in another client would leave this
    /// window rendering a tab that is no longer visible.
}
