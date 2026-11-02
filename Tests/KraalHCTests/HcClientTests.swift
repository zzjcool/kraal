// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import Testing

@testable import KraalHC

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

@Suite("Reconnecting client")
struct HcClientTests {
    @Test("reconnects after the core restarts and calls work again")
    func reconnect() async throws {
        try await withFakeCore { core in
            let sessions = Counter()
            core.onSession = { session in
                let index = sessions.next()
                if index == 1 {
                    return // drop the first connection right after hello
                }
                guard let frame = session.readFrame(),
                      let incoming = try? HcRPC.decode(frame.payload),
                      case let .request(id, _, _) = incoming,
                      let id
                else { return }
                session.writeMessage(.object([
                    "jsonrpc": .string("2.0"),
                    "id": .int(Int(id)),
                    "result": .object(["ok": .bool(true), "session": .int(index)]),
                ]))
            }

            let client = HcClient(
                path: core.socketPath,
                initialBackoff: 0.01,
                maxBackoff: 0.02
            )
            client.start()
            defer { client.stop() }

            var readyCount = 0
            try await withTimeout(5) {
                var iterator = client.events.makeAsyncIterator()
                while readyCount < 2 {
                    guard let event = await iterator.next() else {
                        throw TestTimeout()
                    }
                    if case .ready = event { readyCount += 1 }
                }
            }
            #expect(core.acceptedConnections >= 2)

            let result = try await client.call("terminal.list")
            #expect(result["ok"]?.boolValue == true)
            #expect(result["session"]?.intValue == 2)
        }
    }

    @Test("stops on an incompatible core instead of retrying forever")
    func incompatible() async throws {
        let hello = try FakeCore.defaultHello(generation: 2, version: "9.0.0")
        try await withFakeCore(hello: hello) { core in
            core.onSession = { _ in }
            let client = HcClient(
                path: core.socketPath,
                initialBackoff: 0.01,
                maxBackoff: 0.02
            )
            client.start()
            defer { client.stop() }

            let event: HcClientEvent? = try await withTimeout(3) { () -> HcClientEvent? in
                var iterator = client.events.makeAsyncIterator()
                while let value = await iterator.next() {
                    if case .incompatible = value { return value }
                }
                return nil
            }
            guard case let .incompatible(compatibility)? = event else {
                Issue.record("expected an incompatible event, got \(String(describing: event))")
                return
            }
            #expect(compatibility == .unsupportedGeneration(have: 2, expected: 1))
        }
    }

    @Test("calls fail fast before the link is up")
    func callsWhileDown() async throws {
        let client = HcClient(path: "/tmp/kraal-hc-never-\(UUID().uuidString).sock")
        do {
            _ = try await client.call("terminal.list")
            Issue.record("expected notConnected")
        } catch let error as HcConnectionError {
            #expect(error.description == HcConnectionError.notConnected.description)
        }
    }
}
