// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The first herdr-core window: a flat list of terminals and one attached pane.
//
// State comes from one place: the `events.subscribe` snapshot and the events
// after it. The 15 s heartbeat is what distinguishes "the core has nothing to
// say" from "the link is stuck"; a missing one is surfaced, not hidden behind a
// spinner. Reconnects replace the store with a fresh snapshot.
//
// Spaces, tabs and splits arrive with the shared layout document (#227); chrome
// and the action surface are #230/#231.

import Foundation
import KraalHC

public enum HcMachineSheet: Identifiable, Equatable {
    case add
    case rename(HcMachine)

    public var id: String {
        switch self {
        case .add: "add"
        case let .rename(machine): "rename-\(machine.name)"
        }
    }
}

@MainActor
public final class HcWorkspaceModel: ObservableObject {
    public enum Status: Equatable {
        case idle
        case connecting
        case ready(version: String)
        case incompatible(String)
        case failed(String)
    }

    @Published public private(set) var status: Status = .idle
    @Published public private(set) var terminals: [HcTerminal] = []
    @Published public private(set) var machines: [HcMachine] = []
    /// The sidebar's sections: this core, then one per machine.
    @Published public private(set) var groups: [HcMachineGroup] = []
    @Published public private(set) var selected: String?
    @Published public private(set) var session: HcTerminalSession?
    @Published public private(set) var openError: String?
    /// The core has not sent a heartbeat for twice its 15 s interval.
    @Published public private(set) var heartbeatStale = false
    /// A failed machine action, shown until dismissed. Add/rename keep their
    /// sheet open instead, so the typed values are not lost.
    @Published public var machineError: String?
    @Published public var machineSheet: HcMachineSheet?
    @Published public var removingMachine: HcMachine?

    public let path: String
    /// Optional sink for one-line state changes; the app routes this to `kraalLog`
    /// so a GUI run can prove what the window did without a screenshot.
    public var log: ((String) -> Void)?

    private let client: HcClient
    private let store = HcStateStore()
    private var eventsTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var machinePollTask: Task<Void, Never>?
    private var localName = "This core"
    private var subscription: HcEventSubscription?
    private var resubscribeTask: Task<Void, Never>?
    /// Events that raced the snapshot installation (handlers run on the read
    /// thread and hop to the main actor, so they can land before `subscribe`
    /// resumes). Applied once the snapshot is in the store.
    private var pendingEvents: [HcEvent] = []
    private var acceptingEvents = false
    private var started = false

    public init(path: String) {
        self.path = path
        client = HcClient(path: path)
    }

    deinit {
        eventsTask?.cancel()
        heartbeatTask?.cancel()
        machinePollTask?.cancel()
        resubscribeTask?.cancel()
    }

    public func start() {
        guard !started else { return }
        started = true
        status = .connecting
        client.start()
        eventsTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.client.events {
                await self.handle(event)
            }
        }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                if self.client.isConnected, self.store.heartbeatIsStale() {
                    self.heartbeatStale = true
                }
            }
        }
    }

    public func stop() {
        eventsTask?.cancel()
        eventsTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        machinePollTask?.cancel()
        machinePollTask = nil
        resubscribeTask?.cancel()
        resubscribeTask = nil
        cancelSubscription()
        detach()
        client.stop()
    }

    /// Re-reads state. With events there is nothing to poll: resubscribing is
    /// the refresh, and it also repairs a missed sequence.
    public func refresh() async {
        await subscribe()
    }

    public func select(_ address: String) async {
        guard selected != address || session == nil else { return }
        selected = address
        await attachSelected()
    }

    private func handle(_ event: HcClientEvent) {
        switch event {
        case let .connecting(attempt):
            log?("hc: connecting (attempt \(attempt))")
            status = .connecting
            cancelSubscription()
            if attempt > 0 { detach() }
        case let .ready(hello):
            log?("hc: ready core=\(hello.coreName) version=\(hello.version) generation=\(hello.generation)")
            status = .ready(version: hello.version)
            localName = hello.coreName.isEmpty ? "This core" : hello.coreName
            openError = nil
            Task { await self.subscribe() }
            startMachinePolling()
        case let .incompatible(compatibility):
            log?("hc: incompatible \(compatibility)")
            status = .incompatible(String(describing: compatibility))
            cancelSubscription()
            detach()
        case .disconnected:
            log?("hc: disconnected")
            status = .connecting
            heartbeatStale = false
            cancelSubscription()
            stopMachinePolling()
            detach()
        case let .failed(error):
            log?("hc: failed \(error)")
            status = .failed(String(describing: error))
            cancelSubscription()
            stopMachinePolling()
            detach()
        }
    }

    private func subscribe() async {
        cancelSubscription()
        acceptingEvents = false
        pendingEvents.removeAll()
        do {
            let handlers = HcEventHandlers(
                onEvent: { [weak self] event in
                    Task { @MainActor in self?.apply(event) }
                },
                onMissed: { [weak self] snapshot in
                    Task { @MainActor in self?.applyMissed(snapshot) }
                },
                onHeartbeat: { [weak self] seq in
                    Task { @MainActor in self?.beat(seq) }
                },
                onClosed: { [weak self] reason in
                    Task { @MainActor in self?.eventStreamClosed(reason) }
                }
            )
            let subscription = try await client.subscribeEvents(handlers: handlers)
            self.subscription = subscription
            store.replace(with: subscription.snapshot)
            acceptingEvents = true
            for event in pendingEvents { _ = store.apply(event) }
            pendingEvents.removeAll()
            heartbeatStale = false
            publish()
            log?("hc: events subscribed seq=\(subscription.snapshot.seq) terminals=\(terminals.count)")
            await refreshMachines()

            if selected == nil || !visibleTerminals.contains(where: { $0.address == selected && $0.isLive }) {
                // Opening the window must not attach (and resize) a terminal on
                // someone's remote machine; a remote pane waits for a click.
                selected = visibleTerminals.first { $0.isLive && $0.machine == nil }?.address
            }
            await attachSelected()
        } catch {
            openError = String(describing: error)
            log?("hc: subscribe failed: \(error)")
        }
    }

    private func apply(_ event: HcEvent) {
        guard acceptingEvents else {
            pendingEvents.append(event)
            return
        }
        guard store.apply(event) else { return }
        publish()
        if store.view().needsResync {
            scheduleResubscribe()
        }
    }

    private func applyMissed(_ snapshot: HcSnapshot) {
        guard acceptingEvents else { return }
        store.replace(with: snapshot)
        publish()
        log?("hc: missed resnapshot seq=\(snapshot.seq) terminals=\(terminals.count)")
    }

    private func beat(_ seq: UInt64) {
        store.heartbeat(seq: seq)
        if heartbeatStale {
            heartbeatStale = false
            log?("hc: heartbeat restored seq=\(seq)")
        }
        if store.view().needsResync { scheduleResubscribe() }
    }

    private func eventStreamClosed(_ reason: String?) {
        subscription = nil
        acceptingEvents = false
        log?("hc: event stream closed \(reason ?? "(no reason)")")
        // The connection events cover a lost socket. A channel that closes while
        // the link is still up (a core-side mistake) gets one fresh subscription.
        guard client.isConnected, started else { return }
        scheduleResubscribe()
    }

    private func scheduleResubscribe() {
        guard resubscribeTask == nil, started, client.isConnected else { return }
        resubscribeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.resubscribeTask = nil
            await self.subscribe()
        }
    }

    private func cancelSubscription() {
        acceptingEvents = false
        subscription?.close()
        subscription = nil
    }

    // MARK: Machines

    /// The core has no machine events, so this is polled. 2.5 s is the app's
    /// cadence too: fast enough for a login to show, slow enough to be free.
    public func refreshMachines() async {
        guard client.isConnected else { return }
        do {
            let listed = try await client.machines()
            if listed != machines {
                machines = listed
                let visible = listed.filter { !$0.temporary }.map { "\($0.name):\($0.state.rawValue)" }
                log?("hc: machines \(visible.joined(separator: " "))")
            }
            publish()
        } catch {
            log?("hc: machine.list failed: \(error)")
        }
    }

    private func startMachinePolling() {
        machinePollTask?.cancel()
        machinePollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshMachines()
                try? await Task.sleep(for: .seconds(2.5))
            }
        }
    }

    private func stopMachinePolling() {
        machinePollTask?.cancel()
        machinePollTask = nil
    }

    /// Adds through the RPC. Password/locale prompts need a person, so the
    /// caller offers a terminal fallback (`openAddTerminal`) when this throws.
    @discardableResult
    public func addMachine(
        target: String?,
        via: String?,
        name: String?,
        session: String?,
        temporary: Bool
    ) async throws -> HcMachine {
        let added = try await client.addMachine(
            target: target,
            via: via,
            name: name,
            session: session,
            temporary: temporary
        )
        log?("hc: machine added \(added.name) via \(added.target)")
        await refreshMachines()
        return added
    }

    public func reconnectMachine(_ machine: HcMachine) async {
        do {
            let view = try await client.connectMachine(machine.name)
            log?("hc: machine \(machine.name) \(view.state.rawValue)")
            await refreshMachines()
        } catch {
            machineError = HcWorkspaceModel.describe(error)
        }
    }

    public func renameMachine(_ machine: HcMachine, to newName: String) async throws {
        let renamed = try await client.renameMachine(machine.name, to: newName)
        log?("hc: machine \(machine.name) renamed to \(renamed.name)")
        await refreshMachines()
    }

    public func removeMachine(_ machine: HcMachine) async {
        do {
            try await client.removeMachine(machine.name)
            log?("hc: machine removed \(machine.name)")
            await refreshMachines()
        } catch {
            machineError = HcWorkspaceModel.describe(error)
        }
    }

    /// A login is interactive (password, code, host key); a real terminal is
    /// the only honest place for it. `hc machine login` also reconnects.
    public func openLoginTerminal(_ machine: HcMachine) async {
        await runTerminal(
            ["machine", "login", machine.name],
            name: "login-\(machine.name)"
        )
    }

    /// `machine.update` copies this `hc` to the other side; it has no RPC.
    public func openUpdateTerminal(_ machine: HcMachine) async {
        await runTerminal(
            ["machine", "update", machine.name],
            name: "update-\(machine.name)"
        )
    }

    /// The fallback for anything the RPC cannot show: the CLI can ask questions.
    public func openAddTerminal(
        target: String?,
        via: String?,
        name: String?,
        session: String?,
        temporary: Bool
    ) async {
        var arguments = ["machine", "add"]
        if let via, !via.isEmpty {
            arguments += ["--via", via]
        } else if let target, !target.isEmpty {
            arguments.append(target)
        }
        if let name, !name.isEmpty { arguments += ["--name", name] }
        if let session, !session.isEmpty { arguments += ["--session", session] }
        if temporary { arguments.append("--temp") }
        await runTerminal(arguments, name: "add-\(name ?? "machine")")
    }

    private func runTerminal(_ arguments: [String], name: String) async {
        do {
            let reply = try await client.call("terminal.run", params: .object([
                "argv": .array(([HcWorkspaceModel.hcBinary] + arguments).map { .string($0) }),
                "name": .string(HcWorkspaceModel.terminalName(name)),
            ]))
            if let address = reply["address"]?.stringValue {
                log?("hc: ran \(arguments.joined(separator: " ")) as \(address)")
                // The `created` event also arrives; selecting now makes the
                // terminal visible even if that event races this reply.
                await select(address)
            }
        } catch {
            machineError = "could not run hc: \(HcWorkspaceModel.describe(error))"
        }
    }

    /// `hc` next to the core, or on PATH. A GUI app does not inherit the shell's
    /// PATH, so the usual install locations are checked explicitly.
    public static var hcBinary: String {
        if let explicit = ProcessInfo.processInfo.environment["KRAAL_HC_BINARY"], !explicit.isEmpty {
            return explicit
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/hc",
            "/opt/homebrew/bin/hc",
            "/usr/local/bin/hc",
            "/usr/bin/hc",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "hc"
    }

    /// Terminal names are `1-32 of a-z 0-9 - _`.
    static func terminalName(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
        var name = raw.lowercased().map { allowed.contains($0) ? $0 : "-" }
        if name.isEmpty { name = Array("machine") }
        return String(name.prefix(32))
    }

    public static func describe(_ error: Error) -> String {
        if let rpc = error as? HcRPCError { return rpc.description }
        return String(describing: error)
    }

    /// Terminals the sidebar shows. A temporary machine's terminals exist but
    /// are hidden; selecting one would load a pane nobody can see in the list.
    public var visibleTerminals: [HcTerminal] {
        groups.flatMap(\.terminals)
    }

    private func publish() {
        terminals = store.view().terminals
        groups = HcMachineGrouping.groups(
            machines: machines,
            terminals: terminals,
            localName: localName
        )
        if let selected, !visibleTerminals.contains(where: { $0.address == selected }) {
            self.selected = nil
        }
        // Keep the pane in step with disappearance, not with `finished`: the
        // stream still has the program's last bytes and its own CLOSE, and
        // detaching on the event would race them away.
        if let address = session?.address,
           terminals.first(where: { $0.address == address }) == nil {
            detach()
        }
    }

    private func attachSelected() async {
        guard let address = selected,
              let terminal = terminals.first(where: { $0.address == address }),
              terminal.isLive
        else {
            detach()
            return
        }
        guard client.isConnected else { return }

        detach()
        do {
            session = try await HcTerminalSession.open(client: client, terminal: address)
            openError = nil
            log?("hc: attached \(address)")
        } catch {
            openError = String(describing: error)
            log?("hc: attach \(address) failed: \(error)")
        }
    }

    private func detach() {
        session?.close()
        session = nil
    }
}
