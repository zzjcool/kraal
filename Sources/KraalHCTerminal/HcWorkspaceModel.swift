// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The herdr-core window: spaces, tabs and panes from the shared document, one
// attached stream per visible terminal, and the machines that own them.
//
// Terminal state comes from one place: the `events.subscribe` snapshot and the
// events after it. The 15 s heartbeat is what distinguishes "the core has
// nothing to say" from "the link is stuck"; a missing one is surfaced, not
// hidden behind a spinner. Reconnects replace the store with a fresh snapshot.
//
// Arrangement and streams live in `HcWorkspaceModel+Layout`; chrome, the
// command surface and the agents sidebar are #230/#231.

import AppKit
import Foundation
import KraalHC
import KraalModel
import KraalSocket

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
    @Published public internal(set) var machines: [HcMachine] = []
    /// The sidebar's sections: this core, then one per machine.
    @Published public private(set) var groups: [HcMachineGroup] = []
    /// Agents from OSC 7501, flattened for the sidebar (parents before
    /// children, pinned and most urgent first).
    @Published public internal(set) var agents: [HcAgent] = []
    @Published public internal(set) var agentGroups: [HcAgentGroup] = []
    @Published public var agentViewMode: HcAgentViewMode = .priority
    @Published public var settings: HcTerminalSettings = .load() {
        didSet {
            settings.save()
            applySettings()
        }
    }
    @Published public var sidebarVisible = true
    @Published public var showPalette = false
    @Published public var showHelp = false
    @Published public var showSettings = false
    /// A blocked/done event shown in the window; the system notification is
    /// delivered next to it.
    @Published public var agentToast: HcAgentToast?
    /// A sub-agent peeked from the sidebar; not the focused pane.
    @Published public internal(set) var peekSession: HcTerminalSession?
    /// NSMenuItem targets are not retained; this keeps the current menu's
    /// actions alive until the menu closes.
    var contextMenuTargets: [HcMenuAction] = []
    @Published public internal(set) var peekAddress: String?
    @Published public internal(set) var selected: String?
    @Published public private(set) var session: HcTerminalSession?
    @Published public private(set) var openError: String?
    /// The core has not sent a heartbeat for twice its 15 s interval.
    @Published public private(set) var heartbeatStale = false
    /// Spaces, tabs and panes from every machine's shared `herdr-app` document.
    /// A terminal with `herdr.space` is placed here; an unlabeled worker stays
    /// out of the layout and in the sidebar.
    @Published public internal(set) var workspace = KraalModel()
    /// One attached stream per visible pane, keyed by pane id. Hidden tabs and
    /// settled tabs cost nothing: they are attached when shown.
    @Published public internal(set) var paneSessions: [String: HcTerminalSession] = [:]
    /// A layout document that cannot be read. Terminals keep working; commands
    /// that would change the arrangement say why they cannot.
    @Published public internal(set) var layoutError: String?
    /// A close that needs confirmation because it would end several terminals.
    @Published public var closeRequest: HcCloseRequest?
    @Published public var renameRequest: HcRenameRequest?

    /// A sheet or overlay owns the keyboard while it is open. The terminal
    /// keeps its AppKit first responder until the overlay asks for it, so
    /// binding focus to this flag cannot steal the palette's search field.
    var terminalFocusAllowed: Bool {
        !showPalette && !showSettings && !showHelp
            && renameRequest == nil && closeRequest == nil
    }
    /// A failed machine action, shown until dismissed. Add/rename keep their
    /// sheet open instead, so the typed values are not lost.
    @Published public var machineError: String?
    @Published public var machineSheet: HcMachineSheet?
    @Published public var removingMachine: HcMachine?

    public let path: String
    /// Set by the app after the window exists; `kraal status`/`shot` use it.
    public var windowNumber: Int?
    public var controlSocketPath: String?
    private let viewURL: URL
    /// Optional sink for one-line state changes; the app routes this to `kraalLog`
    /// so a GUI run can prove what the window did without a screenshot.
    public var log: ((String) -> Void)?

    let client: HcClient
    private let store = HcStateStore()
    private var eventsTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var machinePollTask: Task<Void, Never>?
    var localName = "This core"
    /// One sync per machine, keyed by `""` for this core.
    var layoutSyncs: [String: HcDocumentSync] = [:]
    /// One save at a time per machine. Adoption and the action that started the
    /// terminal both write the same document; without this they CAS the same
    /// version and the second one reports a fake conflict.
    var layoutSaveChains: [String: Task<Void, Never>] = [:]
    var layoutSaveGeneration: [String: Int] = [:]
    /// A load that started before a newer doc event must not overwrite the
    /// newer read when it happens to finish last.
    var layoutGenerations: [String: Int] = [:]
    var layoutLoaded: Set<String> = []
    var layoutVersions: [String: UInt64] = [:]
    var adoptedKeep: Set<String> = []
    var attachingPanes: Set<String> = []
    /// Terminals whose pane was just closed. Their labels still name the space
    /// until the kill lands; adoption must not put them back in between.
    var closingTerminals: Set<String> = []
    /// Whether the terminal set from the current connection has arrived. Before
    /// it, an empty `terminals` means "not read yet", not "every pane died".
    var hasSnapshot = false
    var appActive = false
    var agentTracker = HcAgentTracker()
    var seenOverrides: [String: Int] = [:]
    var writtenSeen: [String: Int] = [:]
    var unreadAgents: Set<String> = []
    /// The first snapshot is not news; only later blocked/quiet transitions alert.
    var listedAgents = false
    private var activeObservers: [NSObjectProtocol] = []
    var toastTask: Task<Void, Never>?
    private var viewSaveTask: Task<Void, Never>?
    private var writtenView: Data?
    private var subscription: HcEventSubscription?
    private var resubscribeTask: Task<Void, Never>?
    /// Events that raced the snapshot installation (handlers run on the read
    /// thread and hop to the main actor, so they can land before `subscribe`
    /// resumes). Applied once the snapshot is in the store.
    private var pendingEvents: [HcEvent] = []
    private var acceptingEvents = false
    private var started = false

    /// A window over an injected transport (SSH today). The label is only for
    /// status/logs; the factory is called again for every reconnect.
    public init(
        linkFactory: @escaping HcLinkFactory,
        label: String,
        viewPath: URL? = nil
    ) {
        path = label
        viewURL = viewPath ?? Self.defaultViewPath
        client = HcClient(linkFactory: linkFactory, label: label)
    }

    deinit {
        viewSaveTask?.cancel()
        eventsTask?.cancel()
        heartbeatTask?.cancel()
        machinePollTask?.cancel()
        resubscribeTask?.cancel()
    }

    public func stop() {
        for observer in activeObservers { NotificationCenter.default.removeObserver(observer) }
        activeObservers = []
        toastTask?.cancel()
        closePeek()
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
        detachPanes()
        saveViewFile()
        client.stop()
    }

    /// Re-reads state. With events there is nothing to poll: resubscribing is
    /// the refresh, and it also repairs a missed sequence.
    public func refresh() async {
        await subscribe()
    }

    public func select(_ address: String) async {
        if let pane = workspace.paneID(ofTerminal: address) {
            focusPane(pane)
            return
        }
        guard selected != address || session == nil else { return }
        selected = address
        await attachSelected()
    }

    private func handle(_ event: HcClientEvent) {
        switch event {
        case let .connecting(attempt):
            log?("hc: connecting (attempt \(attempt))")
            status = .connecting
            hasSnapshot = false
            cancelSubscription()
            if attempt > 0 { detach() }
            detachPanes()
            closePeek()
        case let .ready(hello):
            log?("hc: ready core=\(hello.coreName) version=\(hello.version) generation=\(hello.generation)")
            status = .ready(version: hello.version)
            localName = hello.coreName.isEmpty ? "This core" : hello.coreName
            openError = nil
            Task { await self.subscribe() }
            Task { await self.loadLayout(machine: nil) }
            startMachinePolling()
        case let .incompatible(compatibility):
            log?("hc: incompatible \(compatibility)")
            status = .incompatible(String(describing: compatibility))
            hasSnapshot = false
            cancelSubscription()
            detach()
            detachPanes()
        case .disconnected:
            log?("hc: disconnected")
            status = .connecting
            hasSnapshot = false
            heartbeatStale = false
            cancelSubscription()
            stopMachinePolling()
            detach()
            detachPanes()
            closePeek()
        case let .failed(error):
            log?("hc: failed \(error)")
            status = .failed(String(describing: error))
            hasSnapshot = false
            cancelSubscription()
            stopMachinePolling()
            detach()
            detachPanes()
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
            hasSnapshot = true
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
        if event.type == "doc" {
            for (key, sync) in layoutSyncs where sync.noteRemoteChange(event) {
                let machine = key.isEmpty ? nil : key
                Task { await self.loadLayout(machine: machine) }
            }
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
        hasSnapshot = true
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

    func publish() {
        terminals = store.view().terminals
        if workspace.activeTab != nil { detach() }
        // The sidebar lists what the layout holds. An unlabeled worker is not
        // in any pane, so it stays out of the window (and is still in `hc ls`).
        let placed = Set(workspace.placedTerminals.keys)
        groups = HcMachineGrouping.groups(
            machines: machines,
            terminals: terminals.filter { placed.contains($0.address) },
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
        reconcile()
        refreshPaneSessions()
        updateAgents()
        scheduleViewSave()
    }

    /// `~/.config/kraal/view.json` (or `XDG_CONFIG_HOME`), overridable with
    /// `KRAAL_HC_VIEW`. This is the screen's private state, not the shared
    /// layout document.
    private static var defaultViewPath: URL {
        let env = ProcessInfo.processInfo.environment
        if let path = env["KRAAL_HC_VIEW"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        let base = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() + "/.config")
        return URL(fileURLWithPath: base).appendingPathComponent("kraal/view.json")
    }

    private func loadViewFile() {
        guard let data = try? Data(contentsOf: viewURL) else { return }
        do {
            try workspace.loadView(data)
            writtenView = data
            log?("hc: view loaded \(data.count) bytes")
        } catch {
            log?("hc: view unavailable: \(error)")
        }
    }

    /// Writes are debounced: focus changes arrive in bursts, and a view from a
    /// closed window is not worth a write per keystroke.
    func scheduleViewSave() {
        guard hasSnapshot, !layoutLoaded.isEmpty, let data = try? workspace.encodedView() else { return }
        guard data != writtenView else { return }
        viewSaveTask?.cancel()
        viewSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.writeView(data)
        }
    }

    private func saveViewFile() {
        guard let data = try? workspace.encodedView() else { return }
        writeView(data)
    }

    private func writeView(_ data: Data) {
        guard data != writtenView else { return }
        let url = viewURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            writtenView = data
            log?("hc: view saved \(data.count) bytes")
        } catch {
            log?("hc: view save failed: \(error)")
        }
    }

    private func attachSelected() async {
        // With a layout on screen, the visible panes own the streams; attaching
        // the flat selection too would resize a terminal nobody is looking at.
        guard workspace.activeTab == nil else {
            detach()
            return
        }
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

    private func observeActivation() {
        guard NSApp != nil, activeObservers.isEmpty else {
            appActive = NSApp?.isActive ?? false
            return
        }
        appActive = NSApp?.isActive ?? false
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.appActive = NSApp?.isActive ?? false
                    self.publish()
                }
            }
            activeObservers.append(observer)
        }
    }

    private func detachPanes() {
        for session in paneSessions.values { session.close() }
        paneSessions = [:]
        attachingPanes = []
    }
}

extension HcWorkspaceModel {
    public func start() {
        guard !started else { return }
        started = true
        loadViewFile()
        applySettings()
        observeActivation()
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
}

public extension HcWorkspaceModel {
    /// The normal local-core window: a fresh unix socket per reconnect.
    convenience init(path: String, viewPath: URL? = nil) {
        self.init(
            linkFactory: {
                let socket = try UnixSocket.connect(path: path, timeoutSeconds: 10)
                return socket
            },
            label: path,
            viewPath: viewPath
        )
    }
}
