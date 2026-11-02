// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import Testing

@testable import KraalHC

@Suite("Machines")
struct HcMachineTests {
    @Test("reads the profile, its state, and a state this client does not know")
    func decoding() throws {
        let machine = HcMachine(json: .object([
            "name": .string("rohan"),
            "target": .string("can@10.0.0.7"),
            "host": .string("rohan-mac"),
            "version": .string("0.1.16"),
            "session": .string("work"),
            "temporary": .bool(false),
            "via": .bool(false),
            "state": .string("needs_login"),
            "why": .string("Permission denied (publickey)"),
            "since_ms": .int(1_700_000_000_000),
        ]))
        #expect(machine.name == "rohan")
        #expect(machine.addressPrefix == "rohan")
        #expect(machine.state == .needsLogin)
        #expect(machine.why == "Permission denied (publickey)")
        #expect(machine.sinceMilliseconds == 1_700_000_000_000)
        #expect(machine.session == "work")
        #expect(!machine.temporary)

        let future = HcMachine(json: .object(["name": .string("x"), "state": .string("sleeping")]))
        #expect(future.state == .other("sleeping"))
        #expect(future.state.label == "sleeping")
        #expect(future.state.rawValue == "sleeping")
        #expect(future.why == nil)
    }

    @Test("add/list/connect/rename/rm send the core's parameter names")
    func calls() async throws {
        let seen = RequestLog()
        try await withFakeCore { core in
            core.onSession = { session in
                for _ in 0 ..< 5 {
                    guard let frame = session.readFrame(),
                          let incoming = try? HcRPC.decode(frame.payload),
                          case let .request(id, method, params) = incoming,
                          let id
                    else { return }
                    seen.append(method, params)
                    let result: JSONValue = switch method {
                    case "machine.list": .object(["machines": .array([
                        .object(["name": .string("rohan"), "target": .string("can@10.0.0.7"),
                                 "host": .string("rohan-mac"), "version": .string("0.1.16"),
                                 "state": .string("connected")]),
                    ])])
                    case "machine.rm": .object(["removed": .string("rohan")])
                    default: .object([
                        "name": .string("rohan"),
                        "target": .string("can@10.0.0.7"),
                        "host": .string("rohan-mac"),
                        "version": .string("0.1.16"),
                    ])
                    }
                    session.writeMessage(.object([
                        "jsonrpc": .string("2.0"),
                        "id": .int(Int(id)),
                        "result": result,
                    ]))
                }
            }

            let client = HcClient(path: core.socketPath, initialBackoff: 0.01, maxBackoff: 0.02)
            client.start()
            defer { client.stop() }
            try await waitUntilReady(client)

            let listed = try await client.machines()
            #expect(listed.map(\.name) == ["rohan"])
            #expect(listed.first?.state == .connected)

            let added = try await client.addMachine(
                via: "/tmp/via-rohan",
                name: "rohan",
                session: "work",
                temporary: true
            )
            #expect(added.name == "rohan")

            _ = try await client.connectMachine("rohan")
            _ = try await client.renameMachine("rohan", to: "rohan-2")
            try await client.removeMachine("rohan")

            #expect(seen.methods == [
                "machine.list", "machine.add", "machine.connect", "machine.rename", "machine.rm",
            ])
            #expect(seen.params(at: 1) == .object([
                "via": .string("/tmp/via-rohan"),
                "name": .string("rohan"),
                "session": .string("work"),
                "temporary": .bool(true),
            ]))
            #expect(seen.params(at: 2) == .object(["machine": .string("rohan")]))
            #expect(seen.params(at: 3) == .object([
                "machine": .string("rohan"), "new_name": .string("rohan-2"),
            ]))
            #expect(seen.params(at: 4) == .object(["machine": .string("rohan")]))
        }
    }

    @Test("ssh targets and via commands are exclusive in the request")
    func addByTarget() async throws {
        let seen = RequestLog()
        try await withFakeCore { core in
            core.onSession = { session in
                guard let frame = session.readFrame(),
                      let incoming = try? HcRPC.decode(frame.payload),
                      case let .request(id, _, params) = incoming,
                      let id
                else { return }
                seen.append("machine.add", params)
                session.writeMessage(.object([
                    "jsonrpc": .string("2.0"),
                    "id": .int(Int(id)),
                    "result": .object(["name": .string("rohan"), "target": .string("can@10.0.0.7")]),
                ]))
            }

            let client = HcClient(path: core.socketPath, initialBackoff: 0.01, maxBackoff: 0.02)
            client.start()
            defer { client.stop() }
            try await waitUntilReady(client)

            _ = try await client.addMachine(target: "can@10.0.0.7")
            #expect(seen.params(at: 0) == .object(["target": .string("can@10.0.0.7")]))
        }
    }

    @Test("a refused rename keeps the core's kind")
    func renameConflict() async throws {
        try await withFakeCore { core in
            core.onSession = { session in
                guard let frame = session.readFrame(),
                      let incoming = try? HcRPC.decode(frame.payload),
                      case let .request(id, _, _) = incoming,
                      let id
                else { return }
                session.writeMessage(.object([
                    "jsonrpc": .string("2.0"),
                    "id": .int(Int(id)),
                    "error": .object([
                        "code": .number(-32_000),
                        "message": .string("there is already a machine called rohan-2"),
                        "data": .object(["kind": .string("name_taken")]),
                    ]),
                ]))
            }

            let client = HcClient(path: core.socketPath, initialBackoff: 0.01, maxBackoff: 0.02)
            client.start()
            defer { client.stop() }
            try await waitUntilReady(client)
            do {
                _ = try await client.renameMachine("rohan", to: "rohan-2")
                Issue.record("expected name_taken")
            } catch let error as HcRPCError {
                #expect(error.kind == "name_taken")
            }
        }
    }
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(String, JSONValue)] = []

    func append(_ method: String, _ params: JSONValue) {
        lock.lock()
        entries.append((method, params))
        lock.unlock()
    }

    var methods: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries.map(\.0)
    }

    func params(at index: Int) -> JSONValue? {
        lock.lock()
        defer { lock.unlock() }
        guard entries.indices.contains(index) else { return nil }
        return entries[index].1
    }
}

private func waitUntilReady(_ client: HcClient) async throws {
    try await withTimeout(5) {
        var iterator = client.events.makeAsyncIterator()
        while let event = await iterator.next() {
            if case .ready = event { return }
            if case .failed = event { throw TestTimeout() }
        }
        throw TestTimeout()
    }
}
