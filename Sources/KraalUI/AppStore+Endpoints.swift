// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The endpoint catalog: one row group per machine in the sidebar.
//
// Herdr's terminal client learns about other machines from the saved-profile
// list and keeps a connection to each one, but only the selected machine streams
// pane screens (`connecting-machines.mdx`: "Other connected machines keep
// updating their workspace information, agent states, and notifications without
// streaming their pane screens"). It does that by connecting with
// `surface_active: false`, which the daemon treats as "send this client
// snapshots, but do not make it the foreground client" (`server/headless.rs:2022`).
//
// Kraal follows the same split: the selected machine keeps the existing
// surface/input path untouched, and every other machine gets an observer
// connection that only ever collects snapshots.

import Foundation
import KraalClient
import KraalProtocol
import KraalSidebar
import KraalTransport
import Observation

/// Which machine a sidebar row group belongs to.
public enum EndpointID: Hashable, Sendable {
    case local
    case ssh(id: String)

    public var isLocal: Bool {
        if case .local = self { return true }
        return false
    }

    /// Stable key for collapse state and observation bookkeeping.
    public var storageKey: String {
        switch self {
        case .local: "local"
        case let .ssh(id): "ssh:\(id)"
        }
    }
}

public enum EndpointStatus: Equatable, Sendable {
    case connecting
    case online
    case reconnecting
    case attention(String)
    case disabled

    /// What the row draws on its right.
    ///
    /// The terminal client renders a coloured glyph for every remote state — the
    /// healthy one included (`endpoint_sidebar.rs:602-618`: an online endpoint
    /// leaves `state` empty, so the signal falls through to the bare glyph). Only
    /// the local endpoint gets nothing, because its own row is the machine you
    /// are looking at.
    public var badge: String? {
        switch self {
        case .online: "●"
        case .connecting: "●"
        case .reconnecting: "●"
        case let .attention(reason): reason
        case .disabled: nil
        }
    }

    /// Colour for `badge`. Green when healthy, amber while settling, red when the
    /// machine needs the user.
    public var badgeIsWarning: Bool {
        switch self {
        case .attention: true
        case .disabled: false
        default: false
        }
    }
}

/// One machine's sidebar state.
@MainActor
@Observable
public final class EndpointState {
    public let id: EndpointID
    public internal(set) var label: String
    public internal(set) var status: EndpointStatus
    /// The last snapshot this machine delivered. Kept when a connection drops:
    /// the rows stay on screen, marked by `status`, rather than vanishing.
    public internal(set) var snapshot: ClientShellSnapshot?

    /// Connection settings to use when this machine becomes the selected one.
    public internal(set) var settings: ConnectionSettings
    /// Saved profiles this machine answers to, so writing a profile back targets
    /// the right one.
    public internal(set) var profile: HerdrMachine?
    public internal(set) var enabled: Bool

    @ObservationIgnored var observerTask: Task<Void, Never>?
    @ObservationIgnored var observer: EndpointConnection?
    @ObservationIgnored var observerEpoch = 0
    @ObservationIgnored var reconnectAttempt = 0

    public init(
        id: EndpointID,
        label: String,
        status: EndpointStatus = .connecting,
        snapshot: ClientShellSnapshot? = nil,
        settings: ConnectionSettings,
        profile: HerdrMachine? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.label = label
        self.status = status
        self.snapshot = snapshot
        self.settings = settings
        self.profile = profile
        self.enabled = enabled
    }

    public var workspaces: [ClientShellWorkspace] { snapshot?.workspaces ?? [] }
    public var agents: [ClientShellAgent] { snapshot?.agents ?? [] }
    public var tabs: [ClientShellTab] { snapshot?.tabs ?? [] }
    public var panes: [ClientShellPane] { snapshot?.panes ?? [] }
}

// MARK: - Catalog

public extension AppStore {
    /// The local machine's row, always first.
    ///
    /// The terminal client seeds the catalog with `Local` before any saved
    /// profile (`endpoints.rs:47-56`) and keeps it there even when it is not the
    /// selected machine, so the list does not reorder as the selection moves.
    func rebuildEndpoints(roster: [MachineEntry]) {
        var next: [EndpointState] = []

        let localSettings = ConnectionSettings.local
        let existingLocal = endpoints.first { $0.id == .local }
        let local = existingLocal ?? EndpointState(
            id: .local,
            label: "Local",
            settings: localSettings
        )
        // The local row reflects the live connection when that connection *is*
        // the local one; otherwise it keeps whatever it last saw, so its
        // workspaces do not disappear while another machine is selected.
        local.settings = localSettings
        local.enabled = true
        next.append(local)

        for entry in roster {
            guard let machine = entry.machine else { continue }
            let id = EndpointID.ssh(id: machine.id)
            let settings = ConnectionSettings(
                name: machine.displayLabel,
                transport: .ssh,
                session: machine.session ?? HerdrDiscovery.defaultSession,
                sshHost: Self.hostPart(of: machine.target),
                sshUser: Self.userPart(of: machine.target),
                sshPort: Self.portPart(of: machine.target)
            )
            if let existing = endpoints.first(where: { $0.id == id }) {
                existing.label = machine.displayLabel
                existing.enabled = machine.enabled
                existing.profile = machine
                existing.settings = settings
                if !machine.enabled { existing.status = .disabled }
                next.append(existing)
            } else {
                next.append(EndpointState(
                    id: id,
                    label: machine.displayLabel,
                    status: machine.enabled ? .connecting : .disabled,
                    settings: settings,
                    profile: machine,
                    enabled: machine.enabled
                ))
            }
        }

        // Drop observers for machines that are no longer configured.
        let kept = Set(next.map(\.id))
        for stale in endpoints where !kept.contains(stale.id) {
            stopObserver(stale)
        }
        endpoints = next
        syncActiveEndpointSnapshot()
    }

    /// Marks which row is the machine the main connection is talking to.
    func syncActiveEndpointSnapshot() {
        let activeID = activeEndpointID ?? EndpointID.matching(
            settings: target,
            in: endpoints
        )
        activeEndpointID = activeID
        for endpoint in endpoints where endpoint.id == activeID {
            endpoint.status = phase.isLive ? .online : .connecting
            endpoint.snapshot = snapshot ?? endpoint.snapshot
        }
        // A machine that is selected must not also run an observer: two
        // connections to one daemon would double every snapshot.
        if let active = endpoints.first(where: { $0.id == activeID }) {
            stopObserver(active)
        }
    }

    /// Opens snapshot-only connections for every enabled machine that is not the
    /// selected one.
    func refreshObservers() {
        for endpoint in endpoints {
            guard endpoint.id != activeEndpointID else { continue }
            guard endpoint.enabled else {
                stopObserver(endpoint)
                continue
            }
            guard endpoint.observerTask == nil else { continue }
            startObserver(endpoint)
        }
    }

    func stopAllObservers() {
        for endpoint in endpoints {
            stopObserver(endpoint)
        }
    }

    // MARK: - Observer lifecycle

    private func startObserver(_ endpoint: EndpointState) {
        endpoint.observerEpoch &+= 1
        let epoch = endpoint.observerEpoch
        endpoint.status = .connecting
        let settings = endpoint.settings

        endpoint.observerTask = Task { [weak self] in
            guard let self else { return }
            let resolved: HerdrTarget
            do {
                resolved = try HerdrDiscovery.resolve(settings)
            } catch {
                endpoint.status = .attention("! error")
                endpoint.observerTask = nil
                return
            }
            // `surfaceActive: false`: this connection must never become the
            // daemon's foreground client, or it would take the pane screen away
            // from the machine the user is actually looking at.
            let connection = EndpointConnection(
                target: resolved,
                surfaceSize: ClientSurfaceSize(cols: 80, rows: 24),
                surfaceActive: false
            ) { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.applyObserverEvent(event, to: endpoint, epoch: epoch)
                }
            }
            endpoint.observer = connection
            do {
                try await connection.start()
            } catch {
                guard !Task.isCancelled, endpoint.observerEpoch == epoch else { return }
                kraalLog("endpoint \(endpoint.label): connect failed: \(error)")
                endpoint.status = .attention("! error")
                endpoint.observerTask = nil
                await connection.stop()
                scheduleObserverRetry(endpoint)
            }
        }
    }

    private func applyObserverEvent(
        _ event: ConnectionEvent,
        to endpoint: EndpointState,
        epoch: Int
    ) {
        // Same rule as the main connection: a superseded attempt still reports
        // its disconnect, and acting on it would schedule a second reconnect on
        // top of the one already running.
        guard endpoint.observerEpoch == epoch else { return }
        switch event {
        case let .connected(welcome):
            endpoint.status = .online
            endpoint.reconnectAttempt = 0
            kraalLog("endpoint \(endpoint.label): online (\(welcome.serverVersion))")
        case let .snapshot(snapshot):
            endpoint.snapshot = snapshot
            endpoint.status = .online
        case let .disconnected(reason):
            endpoint.status = .reconnecting
            kraalLog("endpoint \(endpoint.label): disconnected \(reason ?? "")")
            endpoint.observerTask = nil
            let connection = endpoint.observer
            endpoint.observer = nil
            Task { await connection?.stop() }
            scheduleObserverRetry(endpoint)
        case let .error(message):
            endpoint.status = .attention("! error")
            kraalLog("endpoint \(endpoint.label): error \(message)")
        case .serverShutdown:
            endpoint.status = .reconnecting
            endpoint.observerTask = nil
            scheduleObserverRetry(endpoint)
        default:
            // Surfaces and input belong to the selected machine only.
            break
        }
    }

    private func scheduleObserverRetry(_ endpoint: EndpointState) {
        guard endpoint.enabled, endpoint.id != activeEndpointID else { return }
        endpoint.reconnectAttempt += 1
        let delay = min(pow(2.0, Double(endpoint.reconnectAttempt - 1)), 30)
        let epoch = endpoint.observerEpoch
        endpoint.observerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self, endpoint.observerEpoch == epoch else { return }
            endpoint.observerTask = nil
            guard endpoint.enabled, endpoint.id != self.activeEndpointID else { return }
            self.startObserver(endpoint)
        }
    }

    func stopObserver(_ endpoint: EndpointState) {
        endpoint.observerEpoch &+= 1
        endpoint.observerTask?.cancel()
        endpoint.observerTask = nil
        let connection = endpoint.observer
        endpoint.observer = nil
        if connection != nil {
            Task { await connection?.stop() }
        }
    }

    // MARK: - Selecting a machine

    /// Switches the main connection to `endpoint`, demoting the previous one to
    /// an observer.
    ///
    /// Switching is a reconnect, not a focus: the daemon has no way to move a
    /// client between machines. The previous machine keeps a row and keeps
    /// refreshing through an observer, so its workspaces do not freeze the moment
    /// it stops being selected.
    func selectEndpoint(_ endpoint: EndpointState) {
        guard endpoint.id != activeEndpointID else { return }
        let previous = activeEndpointID
        target = endpoint.settings
        activeEndpointID = endpoint.id
        // The machine we just left has to start observing, and the one we moved
        // to has to stop — otherwise both ends hold a connection and the selected
        // machine receives its snapshot twice.
        if let previous, let old = endpoints.first(where: { $0.id == previous }) {
            old.snapshot = snapshot ?? old.snapshot
            startObserver(old)
        }
        stopObserver(endpoint)
        refreshObservers()
    }

    // MARK: - Profile target parsing

    /// `ssh://user@host:port` -> host. The terminal client stores the whole URI;
    /// Kraal needs the parts because `ConnectionSettings` is what actually opens
    /// the transport.
    static func hostPart(of target: String) -> String {
        guard let url = URL(string: target), let host = url.host else { return target }
        return host
    }

    static func userPart(of target: String) -> String? {
        guard let url = URL(string: target), let user = url.user, !user.isEmpty else {
            return nil
        }
        return user
    }

    static func portPart(of target: String) -> UInt16? {
        guard let url = URL(string: target), let port = url.port else { return nil }
        return UInt16(exactly: port)
    }
}

public extension EndpointID {
    /// Which row a set of connection settings belongs to.
    ///
    /// Matched on the settings the transport actually uses rather than on the
    /// display name: the user can rename either side, and a name is not what
    /// opens a socket. A local transport is always the `Local` row.
    @MainActor
    static func matching(
        settings: ConnectionSettings,
        in endpoints: [EndpointState]
    ) -> EndpointID {
        guard settings.transport != .local else { return .local }
        let match = endpoints.first { endpoint in
            guard !endpoint.id.isLocal else { return false }
            let candidate = endpoint.settings
            return candidate.sshHost == settings.sshHost
                && candidate.sshPort == settings.sshPort
                && candidate.session == settings.session
        }
        return match?.id ?? .ssh(id: settings.name)
    }
}
