// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import KraalHC
import Testing

@testable import KraalHCTerminal

/// A second core reached the way a machine is: the core runs a command, the
/// command runs `hc connect` there. No ssh needed, and nothing outside /tmp is
/// touched. Opt-in because it starts two cores and a PTY.
///
///     KRAAL_LIVE_HC_TESTS=1 swift test --filter KraalHCTerminalTests
@Suite("Live hc machines", .serialized, .enabled(if: ProcessInfo.processInfo.environment["KRAAL_LIVE_HC_TESTS"] == "1"))
struct LiveHcMachinesTests {
    private struct Core {
        let name: String
        let directory: String
        let variables: [String: String]
    }

    private func hcBinary() -> String? {
        let env = ProcessInfo.processInfo.environment
        let candidates = [
            env["KRAAL_HC_BINARY"],
            NSHomeDirectory() + "/.local/bin/hc",
            "/opt/homebrew/bin/hc",
            "/usr/local/bin/hc",
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Short on purpose: `sun_path` is 103 bytes, and the core's path repeats
    /// the session name under `state/herdr-core`.
    private func makeRoot(_ suffix: String, _ side: String) throws -> String {
        let root = "/tmp/km-\(suffix)/\(side)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }

    private func env(_ root: String, session: String) -> [String: String] {
        var variables = ProcessInfo.processInfo.environment
        variables["HC_SESSION"] = session
        variables["XDG_STATE_HOME"] = root + "/state"
        variables["XDG_CONFIG_HOME"] = root + "/config"
        variables.removeValue(forKey: "HC_SOCKET")
        variables.removeValue(forKey: "XDG_RUNTIME_DIR")
        return variables
    }

    private func run(_ binary: String, _ arguments: [String], in variables: [String: String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = variables
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    private func waitFor(
        _ description: String,
        seconds: Double = 20,
        until body: () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if try await body() { return }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw LiveMachineTimeout(message: description)
    }

    private struct LiveMachineTimeout: Error, CustomStringConvertible {
        let message: String
        var description: String { "timed out waiting for \(message)" }
    }

    @Test("a via machine's terminal appears, takes input, and survives a rename")
    func viaMachine() async throws {
        guard let binary = hcBinary() else {
            Issue.record("hc binary not found; set KRAAL_HC_BINARY")
            return
        }
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        let localRoot = try makeRoot(suffix, "a")
        let remoteRoot = try makeRoot(suffix, "b")
        defer { try? FileManager.default.removeItem(atPath: "/tmp/km-" + suffix) }

        let local = Core(name: "ma-\(suffix)", directory: localRoot,
                         variables: env(localRoot, session: "ma-\(suffix)"))
        let remote = Core(name: "mb-\(suffix)", directory: remoteRoot,
                          variables: env(remoteRoot, session: "mb-\(suffix)"))
        defer {
            _ = try? run(binary, ["server", "stop"], in: local.variables)
            _ = try? run(binary, ["server", "stop"], in: remote.variables)
        }

        // The core runs `<via> "$1"`; this makes that shell line run in the
        // second core's isolation, exactly as ssh would on another host.
        let via = localRoot + "/via"
        let script = """
        #!/bin/sh
        HC_SESSION=\(remote.name) XDG_STATE_HOME=\(remoteRoot)/state XDG_CONFIG_HOME=\(remoteRoot)/config \\
        exec sh -c "$1"
        """
        try script.write(toFile: via, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: via)

        // The client connects to a core; the CLI is what starts one.
        _ = try run(binary, ["ls", "--json"], in: local.variables)

        let paths = try HcPaths.resolve(environment: local.variables)
        let client = HcClient(path: paths.socket, initialBackoff: 0.05, maxBackoff: 0.2)
        client.start()
        defer { client.stop() }

        try await waitFor("the local core") { client.isConnected }

        let added = try await client.addMachine(via: via, name: "alpha")
        #expect(added.name == "alpha")

        try await waitFor("alpha connected") {
            try await client.machines().first { $0.name == "alpha" }?.state == .connected
        }

        // A program on the machine, addressed `alpha/tN` in the same list.
        _ = try await client.call("terminal.run", params: .object([
            "on": .string("alpha"),
            "argv": .array([.string("sh"), .string("-c"),
                            .string("printf 'FROM-ALPHA\\n'; while read line; do echo \"GOT:$line\"; done")]),
            "name": .string("alpha-shell"),
        ]))
        var address = ""
        try await waitFor("a terminal on alpha") {
            let reply = try await client.call("terminal.list")
            let found = reply["terminals"]?.arrayValue?.first {
                $0["address"]?.stringValue?.hasPrefix("alpha/") == true
                    && $0["state"]?.stringValue == "live"
            }
            address = found?["address"]?.stringValue ?? ""
            return !address.isEmpty
        }
        #expect(address.hasPrefix("alpha/"))

        try await expectEcho(client: client, socket: paths.socket, address: address)
        try await expectRenameAndRemove(client: client)
    }

    private func expectEcho(client: HcClient, socket: String, address: String) async throws {
        let probe = ByteProbe()
        let connection = try await openTestConnection(path: socket)
        defer { connection.close() }
        let stream = try await HcAttachStream.attach(
            connection,
            terminal: address,
            handlers: HcAttachHandlers(
                onData: { probe.append($0) },
                onEnd: { end in probe.setEnd(end) },
                onLost: { probe.setLost() }
            )
        )
        defer { stream.close() }

        try await waitFor("alpha's replay") { probe.contains("FROM-ALPHA") }
        stream.send(Data("hi\n".utf8))
        try await waitFor("input echoed back") { probe.contains("GOT:hi") }
    }

    private func expectRenameAndRemove(client: HcClient) async throws {
        // Renaming changes the prefix; old machine names no longer resolve.
        _ = try await client.renameMachine("alpha", to: "beta")
        try await waitFor("alpha's terminals under beta/") {
            let reply = try await client.call("terminal.list")
            return reply["terminals"]?.arrayValue?.contains {
                $0["address"]?.stringValue?.hasPrefix("beta/") == true
            } == true
        }
        do {
            _ = try await client.connectMachine("alpha")
            Issue.record("the old machine name still resolves after rename")
        } catch let error as HcRPCError {
            #expect(error.kind == "machine_unknown")
        }

        try await client.removeMachine("beta")
        try await waitFor("the machine to disappear") {
            try await client.machines().isEmpty
        }
    }
}

private final class ByteProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var end: HcTerminalEnd?
    private var lost = false

    func append(_ data: Data) {
        lock.lock()
        bytes.append(data)
        lock.unlock()
    }

    func contains(_ text: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return String(bytes: bytes, encoding: .utf8)?.contains(text) ?? false
    }

    func setEnd(_ end: HcTerminalEnd) {
        lock.lock()
        self.end = end
        lock.unlock()
    }

    func setLost() {
        lock.lock()
        lost = true
        lock.unlock()
    }
}
