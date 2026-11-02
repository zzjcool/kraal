// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The first herdr-core window: a flat list of terminals and one attached pane.
//
// It is deliberately smaller than the Herdr 1 workspace. Spaces, tabs and splits
// arrive with the shared layout document (#227); events replace the manual
// refresh in #225. What it establishes is the part every later window depends on:
// a reconnecting link, `terminal.list` as the source of truth, and a pane whose
// bytes are the core's bytes.

import Foundation
import KraalHC

public struct HcTerminalSummary: Identifiable, Equatable, Sendable {
    public let address: String
    public let name: String
    public let agent: String
    public let cwd: String
    public let state: String
    public let turn: Int

    public var id: String { address }

    public var isLive: Bool { state == "live" }

    init?(json: JSONValue) {
        guard let address = json["address"]?.stringValue else { return nil }
        self.address = address
        name = json["name"]?.stringValue ?? address
        agent = json["agent"]?.stringValue ?? ""
        cwd = json["cwd"]?.stringValue ?? ""
        state = json["state"]?.stringValue ?? "unknown"
        turn = json["turn"]?.intValue ?? 0
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
    @Published public private(set) var terminals: [HcTerminalSummary] = []
    @Published public private(set) var selected: String?
    @Published public private(set) var session: HcTerminalSession?
    @Published public private(set) var openError: String?

    public let path: String
    /// Optional sink for one-line state changes; the app routes this to `kraalLog`
    /// so a GUI run can prove what the window did without a screenshot.
    public var log: ((String) -> Void)?

    private let client: HcClient
    private var eventsTask: Task<Void, Never>?
    private var started = false

    public init(path: String) {
        self.path = path
        client = HcClient(path: path)
    }

    deinit {
        eventsTask?.cancel()
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
    }

    public func stop() {
        eventsTask?.cancel()
        eventsTask = nil
        detach()
        client.stop()
    }

    /// Re-reads the terminal list. Called on connect and by the Refresh button.
    public func reload() async {
        do {
            let reply = try await client.call("terminal.list", params: .object(["all": .bool(true)]))
            terminals = (reply["terminals"]?.arrayValue ?? []).compactMap(HcTerminalSummary.init)
            log?("hc: \(terminals.count) terminals, \(terminals.filter(\.isLive).count) live")
            if selected == nil {
                selected = terminals.first(where: \.isLive)?.address
            }
            await attachSelected()
        } catch {
            openError = String(describing: error)
        }
    }

    public func select(_ address: String) async {
        guard selected != address || session == nil else { return }
        selected = address
        await attachSelected()
    }

    public func refresh() async {
        await reload()
    }

    private func handle(_ event: HcClientEvent) {
        switch event {
        case let .connecting(attempt):
            log?("hc: connecting (attempt \(attempt))")
            status = .connecting
            if attempt > 0 { detach() }
        case let .ready(hello):
            log?("hc: ready core=\(hello.coreName) version=\(hello.version) generation=\(hello.generation)")
            status = .ready(version: hello.version)
            openError = nil
            Task { await self.reload() }
        case let .incompatible(compatibility):
            log?("hc: incompatible \(compatibility)")
            status = .incompatible(String(describing: compatibility))
            detach()
        case .disconnected:
            log?("hc: disconnected")
            status = .connecting
            detach()
        case let .failed(error):
            log?("hc: failed \(error)")
            status = .failed(String(describing: error))
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
