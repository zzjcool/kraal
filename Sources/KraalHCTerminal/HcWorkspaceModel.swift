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
    @Published public private(set) var selected: String?
    @Published public private(set) var session: HcTerminalSession?
    @Published public private(set) var openError: String?
    /// The core has not sent a heartbeat for twice its 15 s interval.
    @Published public private(set) var heartbeatStale = false

    public let path: String
    /// Optional sink for one-line state changes; the app routes this to `kraalLog`
    /// so a GUI run can prove what the window did without a screenshot.
    public var log: ((String) -> Void)?

    private let client: HcClient
    private let store = HcStateStore()
    private var eventsTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
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
            openError = nil
            Task { await self.subscribe() }
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
            detach()
        case let .failed(error):
            log?("hc: failed \(error)")
            status = .failed(String(describing: error))
            cancelSubscription()
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

            if selected == nil || !terminals.contains(where: { $0.address == selected && $0.isLive }) {
                selected = terminals.first(where: \.isLive)?.address
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

    private func publish() {
        terminals = store.view().terminals
        if let selected, !terminals.contains(where: { $0.address == selected }) {
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
