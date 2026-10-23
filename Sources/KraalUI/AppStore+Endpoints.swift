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
    /// Whether the focused program asked for every key event
    /// (`ClientShellKeyboardReportAll`). Connection level, like the daemon's own.
    public internal(set) var keyboardReportAll = false

    /// This machine's own connection.
    ///
    /// Every endpoint holds exactly one, alive for as long as the machine is
    /// configured and reachable — not only while it is the selected one. That is
    /// what makes switching machines a change of *role* rather than a reconnect:
    /// the connection to the machine you switch to is already open, so there is
    /// no handshake to wait for and no stale frame in between.
    ///
    /// Upstream does the same thing (`/tmp/herdr-src/src/client/endpoint/supervisor.rs`
    /// keeps a `ReconnectState` per endpoint and connects them all at launch);
    /// what distinguishes the foreground machine there is the surface lease, not
    /// the existence of a connection.
    @ObservationIgnored var connection: EndpointConnection?
    @ObservationIgnored var connectionTask: Task<Void, Never>?
    /// Per-connection epoch. Replaces the single store-wide counter: with one
    /// connection per machine, an epoch has to identify *which* connection an
    /// event came from, or a late report from machine A can be applied to
    /// machine B.
    @ObservationIgnored var connectionEpoch = 0
    @ObservationIgnored var reconnectAttempt = 0

    /// The handshake this machine's connection completed, kept so a machine
    /// switch can adopt it without waiting for a fresh one.
    @ObservationIgnored var welcome: EndpointServerWelcome?

    /// Whether this machine's daemon can be told to change which surface it
    /// streams. Daemons before 0.9.2 cannot, and switching to one of those has to
    /// reopen its connection instead of flipping a lease.
    var supportsSurfaceInterest: Bool {
        welcome?.methods.contains("client_shell.surface.set") == true
    }

    /// Whether this machine has a live connection right now.
    public var isConnected: Bool { connection != nil }

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
            // A target Kraal cannot read still gets a row — the machine exists in
            // herdr's roster, and hiding it would look like the dialog and the
            // sidebar disagree. What it does not get is a dialable transport: the
            // row is left disabled, so every automatic path (`connectMissingEndpoints`,
            // `scheduleEndpointRetry`) skips it, and its status says what to fix.
            // The raw target is kept as the host only so the row still has an
            // identity to match on; see `ParsedSSHTarget.parse` for why a `nil` parse
            // beats a best guess.
            let parsed = ParsedSSHTarget.parse(machine.target)
            let settings = ConnectionSettings(
                name: machine.displayLabel,
                transport: .ssh,
                session: machine.session ?? HerdrDiscovery.defaultSession,
                sshHost: parsed?.host ?? machine.target,
                sshUser: parsed?.user,
                sshPort: parsed?.port
            )
            // A profile the user switched off stays off — that is their choice, and
            // a target problem behind a disabled row is not news until they turn it
            // back on.
            let status: EndpointStatus = if !machine.enabled {
                .disabled
            } else if parsed == nil {
                .attention(Self.invalidTargetBadge)
            } else {
                .connecting
            }
            if let existing = endpoints.first(where: { $0.id == id }) {
                existing.label = machine.displayLabel
                existing.enabled = machine.enabled && parsed != nil
                existing.profile = machine
                existing.settings = settings
                // A machine whose handshake failed keeps its own status: re-reading
                // the roster is not a reconnect, and overwriting a live error with
                // "connecting" would hide it until the next retry.
                if !machine.enabled || parsed == nil { existing.status = status }
                next.append(existing)
            } else {
                next.append(EndpointState(
                    id: id,
                    label: machine.displayLabel,
                    status: status,
                    settings: settings,
                    profile: machine,
                    enabled: machine.enabled && parsed != nil
                ))
            }
        }

        // Close connections for machines that are no longer configured. Only a
        // removed or disabled profile gets here — selecting another machine never
        // does, because that is a change of role, not of configuration.
        let kept = Set(next.map(\.id))
        for stale in endpoints where !kept.contains(stale.id) {
            disconnectEndpoint(stale)
        }
        for endpoint in next where !endpoint.enabled {
            disconnectEndpoint(endpoint)
        }
        endpoints = next
        // The selected machine may have been removed entirely; fall back to the
        // local one rather than pointing at a row that no longer exists.
        if let active = activeEndpointID, !kept.contains(active) {
            activeEndpointID = .local
            target = .local
        }
        syncActiveEndpointSnapshot()
    }

    /// Marks which row is the machine whose surface we are showing, and copies
    /// the store's snapshot into it.
    ///
    /// The status is *not* inferred from `phase` any more. Each machine has its
    /// own connection with its own state, so overwriting one from a store-level
    /// phase would mark a machine online because a different machine's handshake
    /// finished — and could just as easily blank a healthy row.
    func syncActiveEndpointSnapshot() {
        let activeID = activeEndpointID ?? EndpointID.matching(
            settings: target,
            in: endpoints
        )
        activeEndpointID = activeID
        if let active = endpoints.first(where: { $0.id == activeID }),
           let snapshot {
            active.snapshot = snapshot
        }
    }

    /// What the sidebar writes next to a machine whose saved `target` could not be
    /// read.
    ///
    /// Deliberately *not* the generic "! error": that badge is what a failed
    /// handshake shows, and the fix for a failed handshake is not "edit the profile
    /// in the machines dialog". A saved target is the one thing here the user can
    /// correct by hand, so the row says where to look.
    static let invalidTargetBadge = "! check target"

    /// The machine whose surface and input we are using.
    var activeEndpoint: EndpointState? {
        endpoints.first { $0.id == activeEndpointID }
    }

    /// Opens a connection for every enabled machine that does not have one.
    ///
    /// All of them, not just the unselected ones: this is what makes the model
    /// "N peers, one foreground" instead of "one live connection plus observers".
    /// A machine that is already connected is left alone, so this is safe to call
    /// after every catalog reload.
    ///
    /// "Already connected" needs **both** checks, and used to test only the first:
    /// `connectEndpoint` clears `connectionTask` when the handshake lands and keeps
    /// `connection`, so a healthy machine has `connectionTask == nil` *and*
    /// `connection != nil`. Guarding on the task alone re-dialled every healthy
    /// machine. That went unnoticed while this ran only at launch (nothing
    /// connected yet) and after the machines dialog wrote a profile (rare); issue
    /// #69 makes it run on every external roster change, so it would show up as the
    /// pane blanking whenever anybody runs `herdr machine add`. Measured with the
    /// old guard, local row dialling a peer that answers: `connection` replaced,
    /// `connectionEpoch 1 -> 2`.
    func connectMissingEndpoints() {
        for endpoint in endpoints {
            guard endpoint.enabled else {
                disconnectEndpoint(endpoint)
                continue
            }
            guard endpoint.connectionTask == nil, endpoint.connection == nil else { continue }
            connectEndpoint(endpoint)
        }
    }

    func disconnectAllEndpoints() {
        for endpoint in endpoints {
            disconnectEndpoint(endpoint)
        }
    }

    /// Reconnects **every** enabled machine, dropping whatever each one is doing
    /// first.
    ///
    /// This is what the toolbar's Refresh button and the `.reconnect` command
    /// mean (issue #67). They used to call `connect()`, whose contract is
    /// different on both counts:
    ///
    ///  - it only looks at the *active* machine, so a background machine that
    ///    had given up was not touched at all — pressing Refresh looked like it
    ///    did nothing, and it had, for the one machine that was broken;
    ///  - it returns early when `connectionTask != nil`, which is exactly the
    ///    state a stuck machine is in — so the one case the button exists for
    ///    was the one case it refused to handle.
    ///
    /// `connect()` is not changed: it means "connect the target the user just
    /// named in the connection panel", and the three call sites in
    /// `ConnectionViews` rely on that narrower reading.
    ///
    /// The disconnect-then-connect order is what makes this work on a stuck
    /// machine. `disconnectEndpoint` bumps `connectionEpoch`, which invalidates
    /// the in-flight task's `epoch` guard, cancels it, and stops the connection;
    /// the follow-up `connectEndpoint` then starts a fresh attempt with a new
    /// epoch regardless of what the old task is doing.
    ///
    /// Disabled machines and machines whose saved target will not parse are
    /// skipped rather than dialled: `rebuildEndpoints` sets `enabled` to false
    /// for both, and trying anyway would only replace a `! check target` badge
    /// with a generic `! error`.
    func reconnectAllEndpoints() {
        intentionalStop = false
        for endpoint in endpoints {
            guard endpoint.enabled else { continue }
            disconnectEndpoint(endpoint)
            connectEndpoint(endpoint)
        }
    }

    // MARK: - Per-machine connection

    /// Opens this machine's connection.
    ///
    /// Every connection is established the same way: at launch, in the
    /// background, before anyone clicks anything. Upstream does the same
    /// (`supervisor.rs` seeds a `ReconnectState` per enabled profile with
    /// `next_attempt: Some(now)`), and it is what makes the sidebar's status
    /// badges meaningful — a machine that is only connected once selected has no
    /// status to show until it is too late to matter.
    func connectEndpoint(_ endpoint: EndpointState) {
        endpoint.connectionEpoch &+= 1
        let epoch = endpoint.connectionEpoch
        if endpoint.status == .disabled { endpoint.status = .connecting }
        let settings = endpoint.settings

        endpoint.connectionTask = Task { [weak self] in
            guard let self else { return }
            let resolved: HerdrTarget
            do {
                resolved = try HerdrDiscovery.resolve(
                    settings,
                    environment: self.discoveryEnvironment
                )
            } catch {
                endpoint.status = .attention("! error")
                endpoint.connectionTask = nil
                return
            }
            // Every connection is opened as a non-surface client except when this
            // machine is already the selected one. A background machine must never
            // become the daemon's foreground client, or it would take the pane
            // screen away from the machine the user is actually looking at.
            let isSelected = endpoint.id == self.activeEndpointID
            let connection = EndpointConnection(
                target: resolved,
                surfaceSize: self.surfaceSize,
                surfaceActive: isSelected
            ) { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.applyEndpointEvent(event, from: endpoint, epoch: epoch)
                }
            }
            endpoint.connection = connection
            do {
                try await self.startHandshake(connection)
                guard !Task.isCancelled, endpoint.connectionEpoch == epoch else { return }
                endpoint.reconnectAttempt = 0
                // The task is done once the handshake lands. Leaving it set would
                // make `connect()` think a connection was still being opened and
                // turn every later reconnect into a no-op.
                endpoint.connectionTask = nil
                // The new connection has its own idea of which surface is
                // current. Make it match this store's role for the machine
                // instead of waiting for a snapshot to correct it.
                if endpoint.id == self.activeEndpointID {
                    await self.setSurfaceActive(true, on: endpoint)
                }
            } catch {
                guard !Task.isCancelled, endpoint.connectionEpoch == epoch else { return }
                kraalLog("endpoint \(endpoint.label): connect failed: \(error)")
                endpoint.status = .attention("! error")
                endpoint.connectionTask = nil
                // `stop()` reports `.disconnected`, and that branch schedules the
                // retry. Scheduling one here as well counted every failure twice:
                // the backoff went 2, 4, 8, 16 instead of 1, 2, 4, 8, so the first
                // retry after a failed handshake already waited twice as long as
                // the one after a dropped connection. Measured before the fix:
                // `attempt 0 -> 2` on a single failed handshake.
                await connection.stop()
                endpoint.connection = nil
            }
        }
    }

    /// Applies an event from one machine's connection.
    ///
    /// The store-level state (`snapshot`, `surface`, `phase`) is written only when
    /// the event comes from the machine that currently holds the foreground.
    /// That is decided *here*, on arrival, not when the connection was created:
    /// after a switch, the machine that was background a moment ago is the
    /// foreground one, and its surface events must land.
    private func applyEndpointEvent(
        _ event: ConnectionEvent,
        from endpoint: EndpointState,
        epoch: Int
    ) {
        // A replaced attempt still reports its disconnect; acting on it would
        // schedule a second reconnect on top of the one already running.
        guard endpoint.connectionEpoch == epoch else { return }
        let isActive = endpoint.id == activeEndpointID

        switch event {
        case let .connected(welcome):
            endpoint.status = .online
            endpoint.reconnectAttempt = 0
            endpoint.welcome = welcome
            kraalLog("endpoint \(endpoint.label): online (\(welcome.serverVersion))")
            if isActive {
                handleWelcome(welcome)
            }
        case let .snapshot(snapshot):
            endpoint.snapshot = snapshot
            if endpoint.status != .disabled { endpoint.status = .online }
            if isActive {
                handleSnapshot(snapshot)
            }
        case let .surface(surface):
            if isActive { handleSurface(surface) }
        case let .surfacePatch(patch):
            if isActive { handleSurfacePatch(patch) }
        case let .disconnected(reason):
            endpoint.status = .reconnecting
            kraalLog("endpoint \(endpoint.label): disconnected \(reason ?? "")")
            endpoint.connectionTask = nil
            let connection = endpoint.connection
            endpoint.connection = nil
            Task { await connection?.stop() }
            if isActive {
                // The header of the following block was the store-level handler's
                // job: hold the last frame, mark it stale, and let the reconnect
                // put a fresh one up. `scheduleEndpointRetry` does the reconnect.
                surfaceIsStale = surface != nil
                if surfaceIsStale {
                    kraalLog("disconnected: holding last frame (stale)")
                } else {
                    surface = nil
                }
                lastError = reason
            }
            // Both `phase` and the sleep come from this one call; the attempt
            // number it reports is the one it is actually waiting on.
            scheduleEndpointRetry(endpoint, report: isActive)
        case let .error(message):
            endpoint.status = .attention("! error")
            kraalLog("endpoint \(endpoint.label): error \(message)")
            if isActive { lastError = message }
        case let .keyboardReportAll(enabled):
            applyKeyboardReportAll(enabled, from: endpoint, isActive: isActive)
        case .serverShutdown:
            endpoint.status = .reconnecting
            endpoint.connectionTask = nil
            scheduleEndpointRetry(endpoint, report: isActive)
        default:
            handleEffectEvent(event, isActive: isActive)
        }
    }

    /// Routes the events that only describe what the pane wants the desktop to
    /// do, ignoring them for a machine that is not on screen.
    ///
    /// Split out of `applyEndpointEvent` because four more branches pushed that
    /// switch past swiftlint's complexity limit. Keeping it separate also puts
    /// the "background machines are silent" rule in one readable place instead
    /// of in four `guard isActive else { return }` lines.
    private func handleEffectEvent(_ event: ConnectionEvent, isActive: Bool) {
        guard isActive else { return }
        switch event {
        case .clipboard, .windowTitle, .bell, .notification:
            applyEffects(event)
        default:
            break
        }
    }

    /// Records the daemon's `ClientShellKeyboardReportAll` for one machine.
    ///
    /// Connection level, matching the daemon: the message carries no pane id — it
    /// reports the mode of whichever program is focused now
    /// (`server/headless/render.rs:211-214`). Kept per machine so switching
    /// machines restores each side's answer instead of leaking one machine's
    /// keyboard mode into the other's panes.
    ///
    /// Split out of `applyEndpointEvent` rather than inlined: that switch is one
    /// branch per event and adding two pushed it past the complexity limit.
    private func applyKeyboardReportAll(
        _ enabled: Bool,
        from endpoint: EndpointState,
        isActive: Bool
    ) {
        endpoint.keyboardReportAll = enabled
        kraalLog("endpoint \(endpoint.label): keyboard report-all \(enabled)")
        if isActive { keyboardReportAll = enabled }
    }

    /// Folds one effect-carrying event into `pendingEffects` and lets the
    /// desktop act on the result.
    ///
    /// Only the foreground machine's events reach here. A background machine
    /// keeps its snapshot and status up to date, but its bells must not ring in
    /// this window and its clipboard must not overwrite yours: selection is what
    /// decides whose terminal you are looking at.
    private func applyEffects(_ event: ConnectionEvent) {
        pendingEffects = TerminalEffectsReducer.reduce(
            pendingEffects,
            event: event,
            fallbackTitle: activeEndpoint?.label ?? "Kraal",
            sessionSuffix: DevSession.windowTitleSuffix(name: DevSession.name)
        )
        drainEffects()
    }

    /// Retries one machine's connection, with the same backoff the store used for
    /// its single connection.
    ///
    /// The counter and the delay are computed in exactly one place — here. Callers
    /// that want to show a countdown pass `report: true` and this sets `phase`
    /// from the *same* numbers that the sleep uses. Computing the delay at the
    /// call site as well is what produced the off-by-one-step countdown: it read
    /// `reconnectAttempt` before this function incremented it.
    @discardableResult
    func scheduleEndpointRetry(_ endpoint: EndpointState, report: Bool = false) -> Double? {
        guard endpoint.enabled else { return nil }
        endpoint.reconnectAttempt += 1
        let attempt = endpoint.reconnectAttempt
        let delay = min(pow(2.0, Double(attempt - 1)), 30)
        if report, endpoint.id == activeEndpointID {
            phase = .reconnecting(
                attempt: attempt,
                retryAt: Date().addingTimeInterval(delay)
            )
        }
        let epoch = endpoint.connectionEpoch
        endpoint.connectionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self, endpoint.connectionEpoch == epoch else { return }
            endpoint.connectionTask = nil
            guard endpoint.enabled else { return }
            self.connectEndpoint(endpoint)
        }
        return delay
    }

    /// Closes one machine's connection. Used when its profile is removed or
    /// disabled — never when the selection moves.
    func disconnectEndpoint(_ endpoint: EndpointState) {
        endpoint.connectionEpoch &+= 1
        endpoint.connectionTask?.cancel()
        endpoint.connectionTask = nil
        let connection = endpoint.connection
        endpoint.connection = nil
        if connection != nil {
            // `abort()` first, and not only `stop()`. `stop()` is actor-isolated
            // and queues behind a handshake that is parked in a blocking read —
            // which is the exact state `disconnectEndpoint` is being called to get
            // out of (issue #67's Refresh). `abort()` closes the stream from
            // outside the actor, so the parked read returns immediately instead of
            // holding the socket until the deadline below notices.
            connection?.abort()
            Task { await connection?.stop() }
        }
    }

    /// Tells the daemon whether this machine's surface holds the foreground.
    ///
    /// This is the switch that a machine change actually flips. It is a request
    /// on the *existing* connection — `client_shell.surface.set` — which is why
    /// switching does not close anything. Daemons that predate the method
    /// (0.9.1) cannot be told, so for those the caller falls back to reopening
    /// the target's connection; see `selectEndpoint`.
    func setSurfaceActive(_ active: Bool, on endpoint: EndpointState) async {
        guard endpoint.supportsSurfaceInterest, let connection = endpoint.connection else {
            return
        }
        // A request before the first snapshot has no boot id to address, and the
        // connection rejects it. That is the handshake still opening, not a
        // failure — `connectEndpoint` retries the request once it goes live.
        do {
            try await connection.request("client_shell.surface.set", params: ["active": active])
        } catch {
            kraalLog("endpoint \(endpoint.label): surface.set(\(active)) failed: \(error)")
        }
    }

    // MARK: - Selecting a machine

    /// Moves the foreground to `endpoint`.
    ///
    /// This is the operation that used to reconnect, and it no longer does. Both
    /// machines already have a connection; what changes is which one is allowed
    /// to stream pane content and take input. Upstream calls that the surface
    /// lease and flips it with two `client_shell.surface.set` requests, leaving
    /// both transports alone (`/tmp/herdr-src/src/client/endpoint/activation.rs`).
    ///
    /// Doing it by reconnect — which is what this used to do — meant the machine
    /// being switched *to* was torn down first and rebuilt, so the user stared at
    /// a stale frame for the length of a backoff plus an SSH handshake. The
    /// machine being left was destroyed too, so its rows stopped updating.
    func selectEndpoint(_ endpoint: EndpointState) {
        guard endpoint.id != activeEndpointID else { return }
        let previous = activeEndpoint
        // Snapshot the outgoing machine before the switch: `snapshot` is about to
        // become the incoming machine's, and the row that stays behind must keep
        // drawing what it last saw.
        previous?.snapshot = snapshot ?? previous?.snapshot
        previous?.status = .online

        target = endpoint.settings
        activeEndpointID = endpoint.id

        // Adopt what the incoming machine already has. Its connection has been
        // receiving snapshots all along, so this is usually instant — the point
        // of the whole design.
        snapshot = endpoint.snapshot ?? snapshot
        surface = nil
        surfaceIsStale = false
        // Per-machine state, not store state: the latch tracks *this* connection's
        // outstanding resync. Carrying it across a switch would leave the new
        // machine unable to ask for its own first resync.
        surfaceResyncLatched = false
        phase = endpoint.status == .online ? .live : .connecting
        welcome = endpoint.welcome ?? welcome

        Task { [weak self] in
            guard let self else { return }
            await self.transferSurface(from: previous, to: endpoint)
        }
    }

    /// Hands the foreground from one machine's connection to another's.
    ///
    /// Order matters: the old machine releases first, so there is never a moment
    /// where two daemons both believe they own the screen. On a daemon that
    /// cannot be told (`supportsSurfaceInterest == false`) the only lever is to
    /// reopen that machine's connection with `surfaceActive: true` — a fallback
    /// that is confined to the one machine being switched to.
    private func transferSurface(from previous: EndpointState?, to endpoint: EndpointState) async {
        if let previous, previous.id != endpoint.id {
            await setSurfaceActive(false, on: previous)
        }
        guard let connection = endpoint.connection else {
            // Still connecting (or retrying). `connectEndpoint` sends the
            // active-lease request once the handshake lands, so there is nothing
            // more to do here.
            connectEndpoint(endpoint)
            pushSurfaceSize()
            return
        }
        // A handshake that has not landed yet advertises no methods, so
        // `supportsSurfaceInterest` is false for it *and* for a genuinely old
        // daemon. Reopening on that ambiguity would tear down a connection that
        // is about to become usable. `connectEndpoint` promotes the connection
        // itself once its own handshake completes (see its `.connected` path), so
        // the only case that needs the fallback here is a daemon that has already
        // told us it cannot do it.
        if endpoint.supportsSurfaceInterest || endpoint.welcome == nil {
            await setSurfaceActive(true, on: endpoint)
        } else {
            // Old daemon: no way to promote a live connection, so this one has to
            // be reopened as the surface client. The machine we just left keeps
            // its connection — it is a different daemon and still needs its rows
            // refreshed.
            kraalLog("endpoint \(endpoint.label): no surface.set, reopening as foreground")
            await connection.stop()
            endpoint.connection = nil
            connectEndpoint(endpoint)
        }
        // The new connection was opened at whatever grid the window had when *it*
        // connected, which may not be the current one.
        pushSurfaceSize()
    }
}

// MARK: - Saved-profile targets

/// The three parts of one saved machine's `target`.
///
/// A saved profile holds an *ssh destination*, not a URI. `herdr machine add`
/// stores back what it was given — `admin@127.0.0.1` for the default port — and a
/// non-default port forces the `ssh://` form, because `machine add` has no
/// `--port` (issue #68). A roster file can also be hand-edited, so all of these
/// reach this parser:
///
///     user@host          user@host:port        host
///     ssh://user@host    ssh://user@host:port  ssh://host:port
///     [::1]              [::1]:2222            user@[::1]
///
/// The previous code ran `URL(string:)` on the target and fell back to "the whole
/// string is the host". For the common shape that returns nothing at all,
/// measured on this Mac:
///
///     URL(string: "admin@127.0.0.1")        host=nil       user=nil   port=nil
///     URL(string: "ssh://admin@127.0.0.1")  host=127.0.0.1 user=admin port=nil
///
/// So two spellings of one machine produced two different `sshHost` values, and
/// `EndpointID.matching` — which compares `sshHost` — put that machine in the
/// sidebar twice, with its user shown as part of the host name.
public struct ParsedSSHTarget: Equatable, Sendable {
    public var host: String
    public var user: String?
    public var port: UInt16?

    public init(host: String, user: String? = nil, port: UInt16? = nil) {
        self.host = host
        self.user = user
        self.port = port
    }

    /// Reads one saved `target`, or `nil` when it is not a destination Kraal can
    /// dial.
    ///
    /// **Unreadable is `nil`, never a best guess.** The old fallback — "no host?
    /// then the whole string is the host" — turned a parse failure into a
    /// *plausible-looking* row: `admin@127.0.0.1` became a machine whose host name
    /// was the literal text `admin@127.0.0.1`. ssh happened to accept that
    /// (`SSHTransport` rejoins `user@host`, and with no user it passes the string
    /// through unchanged), so the mistake did not surface as an error — it
    /// surfaced later, as a duplicate row and a wrong sidebar label. Returning
    /// `nil` instead lets the catalog mark the profile as broken where the user
    /// can see it (`EndpointStatus.attention`), which is what the issue asks for.
    ///
    /// Rules, and why each is decided the way it is:
    ///
    /// - A scheme is accepted only when it is `ssh`. A `git://host` left in a
    ///   roster is a mistake; reading it as an ssh host would hide that.
    /// - The userinfo splits at the **last** `@`, which is what ssh itself does
    ///   (`ssh -G 'a@b@c'` reports user `a@b`, host `c`), and a host cannot
    ///   contain `@`.
    /// - An empty part is a typo, not an absence: `@host` and `user@` are
    ///   rejected rather than folded into "no user" / "no host", so they cannot
    ///   silently share a row with `host`.
    /// - Brackets are punctuation around an IPv6 literal, not part of the
    ///   address: `[::1]` -> host `::1`. ssh wants it unbracketed — `ssh
    ///   'admin@[::1]'` fails with "Could not resolve hostname [::1]" (measured)
    ///   — so keeping them would produce a destination that cannot connect.
    /// - An unbracketed literal carries no port: two or more colons cannot be
    ///   `host:port`, which has exactly one, so the text is read as an IPv6
    ///   address. `admin@::1:2222` is host `::1:2222`, which is also how ssh reads
    ///   it (measured: hostname `::0.1.34.34`); RFC 3986 requires the bracketed
    ///   form for a literal carrying a port anyway.
    /// - Port `0` and ports above 65535 are rejected: ssh refuses them on its own
    ///   (`Bad port '0'`, `Bad port '70000'`, measured), so reading them as
    ///   something else would only move the failure later.
    public static func parse(_ raw: String) -> ParsedSSHTarget? {
        // The roster is JSON, and a hand-edited file picks up stray whitespace far
        // more easily than a typed command line does.
        let target = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }

        var authority = target
        if let separator = target.range(of: "://") {
            guard target[target.startIndex..<separator.lowerBound].lowercased() == "ssh" else {
                return nil
            }
            authority = String(target[separator.upperBound...])
            // `ssh://user@host:2222/some/path`: a URI path is not part of the
            // destination. Nothing herdr writes includes one, but cutting here is
            // free and keeps the host free of `/`.
            if let end = authority.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
                authority = String(authority[authority.startIndex..<end])
            }
        }
        guard !authority.isEmpty else { return nil }

        var user: String?
        var hostPort = authority
        if let separator = authority.lastIndex(of: "@") {
            let name = String(authority[authority.startIndex..<separator])
            guard isValidUser(name) else { return nil }
            user = name
            hostPort = String(authority[authority.index(after: separator)...])
        }
        guard !hostPort.isEmpty, let split = splitHostPort(hostPort) else { return nil }
        return ParsedSSHTarget(host: split.host, user: user, port: split.port)
    }

    /// `host`, `host:port`, `[v6]` or `[v6]:port`.
    private static func splitHostPort(_ hostPort: String) -> (host: String, port: UInt16?)? {
        if hostPort.hasPrefix("[") {
            guard let close = hostPort.firstIndex(of: "]") else { return nil }
            let literal = String(hostPort[hostPort.index(after: hostPort.startIndex)..<close])
            guard isIPv6Literal(literal) else { return nil }
            let rest = String(hostPort[hostPort.index(after: close)...])
            if rest.isEmpty { return (literal, nil) }
            guard rest.hasPrefix(":"), let port = parsePort(String(rest.dropFirst())) else {
                return nil
            }
            return (literal, port)
        }
        switch hostPort.count(where: { $0 == ":" }) {
        case 0:
            guard isValidHost(hostPort) else { return nil }
            return (hostPort, nil)
        case 1:
            guard let colon = hostPort.firstIndex(of: ":") else { return nil }
            let host = String(hostPort[hostPort.startIndex..<colon])
            guard isValidHost(host), let port = parsePort(String(hostPort[hostPort.index(after: colon)...]))
            else { return nil }
            return (host, port)
        default:
            guard isIPv6Literal(hostPort) else { return nil }
            return (hostPort, nil)
        }
    }

    private static func parsePort(_ text: String) -> UInt16? {
        guard let port = UInt16(text), port > 0 else { return nil }
        return port
    }

    private static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty else { return false }
        return !host.contains { character in
            character.isWhitespace || character == "/" || character == "@" || character == "["
        }
    }

    /// A user name becomes part of an ssh argument (`user@host`), so it cannot
    /// contain whitespace or the characters that would re-split the destination.
    private static func isValidUser(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return !name.contains { character in
            character.isWhitespace || character == "/" || character == "[" || character == "]"
        }
    }

    private static func isIPv6Literal(_ host: String) -> Bool {
        var address = in6_addr()
        return host.withCString { inet_pton(AF_INET6, $0, &address) } == 1
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
