// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import Testing

@testable import KraalHC

@Suite("Terminal API", .serialized)
struct HcTerminalAPITests {
    private func readyClient(_ core: FakeCore) async throws -> HcClient {
        let client = HcClient(path: core.socketPath, initialBackoff: 0.01, maxBackoff: 0.02)
        client.start()
        for _ in 0 ..< 200 {
            if client.isConnected { return client }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TestTimeout()
    }

    private func record(_ address: String, labels: [String: String] = [:]) -> JSONValue {
        .object([
            "address": .string(address),
            "state": .string("live"),
            "name": .string("dev"),
            "labels": .object(labels.mapValues(JSONValue.string)),
        ])
    }

    @Test("run sends argv, cwd, env, labels, name, keep and machine")
    func runParams() async throws {
        try await withFakeCore { core in
            let seen = LockedBox<JSONValue?>(nil)
            core.onSession = { session in
                guard let frame = session.readFrame(),
                      let incoming = try? HcRPC.decode(frame.payload),
                      case let .request(id, "terminal.run", params) = incoming,
                      let id
                else { return }
                seen.set(params)
                session.writeMessage(.object([
                    "jsonrpc": .string("2.0"),
                    "id": .int(Int(id)),
                    "result": self.record("alpha/t7", labels: ["herdr.space": "sp1"]),
                ]))
            }
            let client = try await readyClient(core)
            defer { client.stop() }

            let terminal = try await client.runTerminal(
                argv: ["zsh", "-l"],
                cwd: "/src/api",
                env: ["TERM": "xterm-ghostty", "TERM_PROGRAM": "Kraal"],
                labels: ["herdr.space": "sp1", "herdr.tab": "tb1"],
                name: "fix-login",
                keep: true,
                on: "alpha"
            )
            #expect(terminal.address == "alpha/t7")
            let params = try #require(seen.value())
            #expect(params["argv"]?.arrayValue?.compactMap(\.stringValue) == ["zsh", "-l"])
            #expect(params["cwd"]?.stringValue == "/src/api")
            #expect(params["env"]?["TERM"]?.stringValue == "xterm-ghostty")
            #expect(params["labels"]?["herdr.space"]?.stringValue == "sp1")
            #expect(params["labels"]?["herdr.tab"]?.stringValue == "tb1")
            #expect(params["name"]?.stringValue == "fix-login")
            #expect(params["keep"]?.boolValue == true)
            #expect(params["on"]?.stringValue == "alpha")
        }
    }

    @Test("a line run omits argv")
    func lineRun() async throws {
        try await withFakeCore { core in
            let seen = LockedBox<JSONValue?>(nil)
            core.onSession = { session in
                guard let frame = session.readFrame(),
                      let incoming = try? HcRPC.decode(frame.payload),
                      case let .request(id, "terminal.run", params) = incoming,
                      let id
                else { return }
                seen.set(params)
                session.writeMessage(.object([
                    "jsonrpc": .string("2.0"),
                    "id": .int(Int(id)),
                    "result": self.record("t3"),
                ]))
            }
            let client = try await readyClient(core)
            defer { client.stop() }
            _ = try await client.runTerminal(line: "printf hello")
            let params = try #require(seen.value())
            #expect(params["line"]?.stringValue == "printf hello")
            #expect(params["argv"] == nil)
        }
    }

    @Test("get, kill, label, keep and rm address one terminal")
    func lifecycle() async throws {
        try await withFakeCore { core in
            let seen = LockedBox<[(String, JSONValue)]>([])
            core.onSession = { session in
                for _ in 0 ..< 5 {
                    guard let frame = session.readFrame(),
                          let incoming = try? HcRPC.decode(frame.payload),
                          case let .request(id, method, params) = incoming,
                          let id
                    else { return }
                    seen.mutate { $0.append((method, params)) }
                    session.writeMessage(.object([
                        "jsonrpc": .string("2.0"),
                        "id": .int(Int(id)),
                        "result": self.record("t3"),
                    ]))
                }
            }
            let client = try await readyClient(core)
            defer { client.stop() }

            _ = try await client.terminal("t3")
            _ = try await client.killTerminal("t3")
            _ = try await client.labelTerminal("t3", labels: ["herdr.space": "", "herdr.tab": ""])
            _ = try await client.keepTerminal("t3", keep: true)
            try await client.removeTerminal("t3")

            let calls = seen.value()
            #expect(calls.map(\.0) == [
                "terminal.get", "terminal.kill", "terminal.label", "terminal.keep", "terminal.rm",
            ])
            #expect(calls.allSatisfy { $0.1["terminal"]?.stringValue == "t3" })
            #expect(calls[2].1["labels"]?["herdr.space"]?.stringValue == "")
            #expect(calls[3].1["keep"]?.boolValue == true)
        }
    }

    @Test("names follow the core's alphabet and limit")
    func names() {
        #expect(HcTerminalName.isValid("a"))
        #expect(HcTerminalName.isValid("fix-login_2"))
        #expect(HcTerminalName.isValid(String(repeating: "a", count: 32)))
        #expect(!HcTerminalName.isValid(""))
        #expect(!HcTerminalName.isValid(String(repeating: "a", count: 33)))
        #expect(!HcTerminalName.isValid("Fix"))
        #expect(!HcTerminalName.isValid("a b"))
        #expect(!HcTerminalName.isValid("a/b"))
        #expect(HcTerminalName.suggested("My Project!!") == "my-project")
        #expect(HcTerminalName.suggested("--dev--") == "dev")
        #expect(HcTerminalName.suggested("  ") == "")
        #expect(HcTerminalName.suggested(String(repeating: "x", count: 40)).count == 32)
    }
}

/// A value written on the fake core's thread and read on the test's.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    func value() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: Value) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&stored)
        lock.unlock()
    }
}
