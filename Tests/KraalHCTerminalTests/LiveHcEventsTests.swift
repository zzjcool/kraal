// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import KraalHC
import Testing

@testable import KraalHCTerminal

/// The event stream against a real core: an actual program, actual `hc` calls.
/// Opt-in for the same reason as the pane test: it starts a core and a PTY.
@MainActor
@Suite("Live hc events", .serialized, .enabled(if: ProcessInfo.processInfo.environment["KRAAL_LIVE_HC_TESTS"] == "1"))
struct LiveHcEventsTests {
    private struct Env {
        let directory: String
        let variables: [String: String]
    }

    private struct LiveTimeout: Error {}

    private func hcBinary() -> String? {
        let env = ProcessInfo.processInfo.environment
        return [env["KRAAL_HC_BINARY"], NSHomeDirectory() + "/.local/bin/hc",
                "/opt/homebrew/bin/hc", "/usr/local/bin/hc"]
            .compactMap { $0 }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func makeEnv() throws -> Env {
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        let directory = "/tmp/kraalhc-events-\(suffix)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var variables = ProcessInfo.processInfo.environment
        variables["HC_SESSION"] = "events-\(suffix)"
        variables["XDG_STATE_HOME"] = directory + "/state"
        variables["XDG_CONFIG_HOME"] = directory + "/config"
        variables.removeValue(forKey: "HC_SOCKET")
        variables.removeValue(forKey: "XDG_RUNTIME_DIR")
        return Env(directory: directory, variables: variables)
    }

    private func run(_ binary: String, _ arguments: [String], env: Env) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = env.variables
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    private func waitFor(_ condition: @escaping @Sendable () -> Bool, seconds: Double = 10) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [HcEvent] = []

        func handlers() -> HcEventHandlers {
            HcEventHandlers(
                onEvent: { [self] event in
                    lock.lock()
                    values.append(event)
                    lock.unlock()
                },
                onMissed: { _ in },
                onHeartbeat: { _ in },
                onClosed: { _ in }
            )
        }

        var events: [HcEvent] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    @Test("a real core's created/labels/finished/removed events reduce in order")
    func liveReduction() async throws {
        guard let binary = hcBinary() else {
            Issue.record("hc binary not found; set KRAAL_HC_BINARY")
            return
        }
        let env = try makeEnv()
        defer { try? FileManager.default.removeItem(atPath: env.directory) }
        _ = try run(binary, ["run", "--bg", "--name", "events", "--keep", "--", "sh"], env: env)
        defer { _ = try? run(binary, ["server", "stop"], env: env) }

        let paths = try HcPaths.resolve(environment: env.variables)
        let connection = try await openTestConnection(path: paths.socket)
        defer { connection.close() }

        let probe = Probe()
        let subscription = try await HcEventSubscription.subscribe(connection, handlers: probe.handlers())
        defer { subscription.close() }

        let store = HcStateStore()
        store.replace(with: subscription.snapshot)
        #expect(store.view().terminals.count == 1)
        #expect(store.view().terminals.first?.isLive == true)
        let address = try #require(store.view().terminals.first?.address)

        // Drain events into the store as they arrive.
        let pump = Task {
            var index = 0
            while !Task.isCancelled {
                let events = probe.events
                while index < events.count {
                    _ = store.apply(events[index])
                    index += 1
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        defer { pump.cancel() }

        _ = try run(binary, ["label", address, "role=agent"], env: env)
        let labelled = await waitFor { store.terminal(address)?.labels["role"] == "agent" }
        #expect(labelled)

        // OSC 7501: working, then done ends a turn.
        _ = try run(binary, ["send", address, #"printf '\033]7501;state=working\033\\'"#], env: env)
        let working = await waitFor { store.terminal(address)?.agentState == "working" }
        #expect(working)
        _ = try run(binary, ["send", address, #"printf '\033]7501;state=done\033\\'"#], env: env)
        let done = await waitFor { store.terminal(address)?.turn == 1 }
        #expect(done)
        #expect(store.terminal(address)?.agentState == "done")

        // A terminal created after subscribing arrives as an event, not a snapshot.
        _ = try run(binary, ["run", "--bg", "--name", "second", "--keep", "--", "sh"], env: env)
        let created = await waitFor { store.view().terminals.count == 2 }
        #expect(created)

        _ = try run(binary, ["kill", address], env: env)
        let finished = await waitFor { store.terminal(address)?.state == "finished" }
        #expect(finished)
        #expect(store.terminal(address)?.reason == "killed")

        _ = try run(binary, ["rm", address], env: env)
        let removed = await waitFor { store.terminal(address) == nil }
        #expect(removed)
        #expect(store.view().terminals.count == 1)

        // Sequence discipline: every applied event is ahead of the last.
        let seqs = probe.events.map(\.seq)
        #expect(seqs == seqs.sorted())
        #expect(Set(seqs).count == seqs.count)
        #expect(store.view().seq == seqs.last ?? subscription.snapshot.seq)
        let types = Set(probe.events.map(\.type))
        for expected in ["created", "labels", "status", "turn", "finished", "removed"] {
            #expect(types.contains(expected), "missing \(expected) in \(types)")
        }
    }
}
