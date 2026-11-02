// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import Testing

@testable import KraalHC

@Suite("Documents")
struct HcDocumentTests {
    private func readyClient(_ core: FakeCore) async throws -> HcClient {
        let client = HcClient(path: core.socketPath, initialBackoff: 0.01, maxBackoff: 0.02)
        client.start()
        try await withTimeout(5) {
            var iterator = client.events.makeAsyncIterator()
            while let event = await iterator.next() {
                if case .ready = event { return }
                if case .failed = event { throw TestTimeout() }
            }
            throw TestTimeout()
        }
        return client
    }

    @Test("reads a document, writes it back with the version it read")
    func loadAndSave() async throws {
        let log = DocRequestLog()
        try await withFakeCore { core in
            core.onSession = { session in
                for index in 0 ..< 2 {
                    guard let request = DocRequestLog.read(session) else { return }
                    log.append(request.method, request.params)
                    let result: JSONValue = if index == 0 {
                        .object(["value": .object(["spaces": .array([])]), "version": .int(3)])
                    } else {
                        .object(["version": .int(4)])
                    }
                    session.writeMessage(.object([
                        "jsonrpc": .string("2.0"),
                        "id": .int(Int(request.id)),
                        "result": result,
                    ]))
                }
            }

            let client = try await readyClient(core)
            defer { client.stop() }
            let sync = HcDocumentSync(client: client, name: "herdr-app")
            let loaded = try await sync.load()
            #expect(loaded.version == 3)
            #expect(loaded.value == .object(["spaces": .array([])]))

            let written = try await sync.save(.object(["spaces": .array([.object(["id": .string("sp1")])])]))
            #expect(written.version == 4)

            #expect(log.methods == ["doc.get", "doc.set"])
            #expect(log.params(at: 0) == .object(["name": .string("herdr-app")]))
            #expect(log.params(at: 1)?["name"]?.stringValue == "herdr-app")
            #expect(log.params(at: 1)?["version"]?.intValue == 3)
            #expect(log.params(at: 1)?["value"]?["spaces"]?.arrayValue?.count == 1)
        }
    }

    @Test("a conflict reloads and reports the other writer's document")
    func conflict() async throws {
        let log = DocRequestLog()
        try await withFakeCore { core in
            core.onSession = { session in
                for index in 0 ..< 3 {
                    guard let request = DocRequestLog.read(session) else { return }
                    log.append(request.method, request.params)
                    let value: JSONValue = index == 2
                        ? .object(["spaces": .array([.object(["id": .string("theirs")])])])
                        : .object(["spaces": .array([.object(["id": .string("mine")])])])
                    let message: JSONValue
                    if index == 1 {
                        message = .object([
                            "jsonrpc": .string("2.0"),
                            "id": .int(Int(request.id)),
                            "error": .object([
                                "code": .number(-32_000),
                                "message": .string("version is not current"),
                                "data": .object(["kind": .string("conflict")]),
                            ]),
                        ])
                    } else {
                        message = .object([
                            "jsonrpc": .string("2.0"),
                            "id": .int(Int(request.id)),
                            "result": .object([
                                "value": value,
                                "version": .int(index == 0 ? 3 : 4),
                            ]),
                        ])
                    }
                    session.writeMessage(message)
                }
            }

            let client = try await readyClient(core)
            defer { client.stop() }
            let sync = HcDocumentSync(client: client, name: "herdr-app")
            _ = try await sync.load()
            do {
                _ = try await sync.save(.object(["spaces": .array([.object(["id": .string("mine")])])]))
                Issue.record("expected a conflict")
            } catch let HcDocumentError.conflict(latest) {
                #expect(latest.version == 4)
                #expect(latest.value?["spaces"]?[0]?["id"]?.stringValue == "theirs")
            }
            #expect(sync.current()?.version == 4)
            #expect(log.methods == ["doc.get", "doc.set", "doc.get"])
        }
    }

    @Test("the local size guard stops a document the core would reject")
    func tooLarge() async throws {
        let log = DocRequestLog()
        try await withFakeCore { core in
            core.onSession = { session in
                guard let request = DocRequestLog.read(session) else { return }
                log.append(request.method, request.params)
                session.writeMessage(.object([
                    "jsonrpc": .string("2.0"),
                    "id": .int(Int(request.id)),
                    "result": .object(["value": .null, "version": .int(0)]),
                ]))
            }

            let client = try await readyClient(core)
            defer { client.stop() }
            let sync = HcDocumentSync(client: client, name: "herdr-app")
            _ = try await sync.load()
            let huge = JSONValue.string(String(repeating: "a", count: HcDocumentSync.limit + 1))
            do {
                _ = try await sync.save(huge)
                Issue.record("expected tooLarge")
            } catch let HcDocumentError.tooLarge(bytes) {
                #expect(bytes > HcDocumentSync.limit)
            }
            #expect(log.methods == ["doc.get"])
        }
    }

    @Test("a remote doc event matches only its own name and machine")
    func events() async throws {
        try await withFakeCore { core in
            core.onSession = { session in
                guard let request = DocRequestLog.read(session) else { return }
                session.writeMessage(.object([
                    "jsonrpc": .string("2.0"),
                    "id": .int(Int(request.id)),
                    "result": .object(["value": .null, "version": .int(9)]),
                ]))
            }
            let client = try await readyClient(core)
            defer { client.stop() }
            let sync = HcDocumentSync(client: client, name: "herdr-app", machine: "rohan")
            _ = try await sync.load()
            let event = HcEvent(
                seq: 9, type: "doc", terminal: nil, machine: "rohan",
                data: .object(["name": .string("herdr-app"), "version": .int(10)])
            )
            #expect(sync.noteRemoteChange(event))
            #expect(!sync.noteRemoteChange(HcEvent(
                seq: 9, type: "doc", terminal: nil, machine: nil,
                data: .object(["name": .string("herdr-app"), "version": .int(4)])
            )))
            #expect(!sync.noteRemoteChange(HcEvent(
                seq: 9, type: "doc", terminal: nil, machine: "rohan",
                data: .object(["name": .string("other"), "version": .int(4)])
            )))
            #expect(!sync.noteRemoteChange(HcEvent(
                seq: 4, type: "terminal.title", terminal: "t1", data: .object([:])
            )))
            // Older than what the sync already has: not news.
            let older = HcEvent(
                seq: 4, type: "doc", terminal: nil, machine: "rohan",
                data: .object(["name": .string("herdr-app"), "version": .int(4)])
            )
            #expect(!sync.noteRemoteChange(older))
        }
    }

    @Test("an unwritten document is null at version zero")
    func unwritten() async throws {
        try await withFakeCore { core in
            core.onSession = { session in
                guard let request = DocRequestLog.read(session) else { return }
                session.writeMessage(.object([
                    "jsonrpc": .string("2.0"),
                    "id": .int(Int(request.id)),
                    "result": .object(["value": .null, "version": .int(0)]),
                ]))
            }
            let client = try await readyClient(core)
            defer { client.stop() }
            let document = try await HcDocumentSync(client: client, name: "herdr-app").load()
            #expect(document.isUnwritten)
            #expect(document.version == 0)
        }
    }
}

private final class DocRequestLog: @unchecked Sendable {
    struct Request {
        let id: Int64
        let method: String
        let params: JSONValue
    }

    private let lock = NSLock()
    private var entries: [Request] = []

    static func read(_ session: FakeCoreSession) -> Request? {
        guard let frame = session.readFrame(),
              let incoming = try? HcRPC.decode(frame.payload),
              case let .request(id, method, params) = incoming,
              let id
        else { return nil }
        return Request(id: id, method: method, params: params)
    }

    func append(_ method: String, _ params: JSONValue) {
        lock.lock()
        entries.append(Request(id: 0, method: method, params: params))
        lock.unlock()
    }

    var methods: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries.map(\.method)
    }

    func params(at index: Int) -> JSONValue? {
        lock.lock()
        defer { lock.unlock() }
        guard entries.indices.contains(index) else { return nil }
        return entries[index].params
    }
}
