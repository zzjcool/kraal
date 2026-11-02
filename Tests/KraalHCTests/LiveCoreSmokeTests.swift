// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Live smoke test against a real `hc`, in an isolated session.
//
// Skipped unless KRAAL_LIVE_HC_TESTS=1. It starts a core with its own
// HC_SESSION, state and config directories, then stops it. It never touches the
// developer's own core or terminals.

import Foundation
import Testing

@testable import KraalHC

@Suite("Live hc")
struct LiveCoreSmokeTests {
    @Test("hello and concurrent calls against a scratch core")
    func scratchCore() async throws {
        guard ProcessInfo.processInfo.environment["KRAAL_LIVE_HC_TESTS"] == "1" else {
            return // skipped: opt in with KRAAL_LIVE_HC_TESTS=1
        }
        guard let binary = Self.hcBinary() else {
            Issue.record("KRAAL_LIVE_HC_TESTS=1 but no hc binary was found")
            return
        }

        try await withTempDirectory { directory in
            var environment = ProcessInfo.processInfo.environment
            environment["HC_SESSION"] = "kraal-smoke-\(UUID().uuidString.prefix(8))"
            environment["XDG_STATE_HOME"] = directory + "/state"
            environment["XDG_CONFIG_HOME"] = directory + "/config"
            environment["HOME"] = directory + "/home"
            try FileManager.default.createDirectory(
                atPath: directory + "/home",
                withIntermediateDirectories: true
            )

            // `hc ls` starts a core if the session has none.
            let started = try Self.run(binary, ["ls", "--json"], environment: environment)
            #expect(started.status == 0, "hc ls failed: \(started.stderr)")

            defer {
                _ = try? Self.run(
                    binary,
                    ["server", "stop"],
                    environment: environment,
                    timeout: 10
                )
            }

            let paths = try HcPaths.resolve(environment: environment)
            try Self.waitForSocket(paths.socket)

            let connection = try await openTestConnection(path: paths.socket)
            defer { connection.close() }

            #expect(connection.hello.generation == HcProtocol.generation)
            #expect(!connection.hello.version.isEmpty)
            #expect(HcProtocol.check(connection.hello) == .compatible)
            #expect(connection.hello.methods.contains("terminal.list"))
            #expect(connection.hello.methods.contains("doc.get"))

            async let first = connection.call("terminal.list", params: .object(["all": .bool(true)]))
            async let second = connection.call("terminal.list", params: .object(["all": .bool(false)]))
            async let third = connection.call(
                "doc.get",
                params: .object(["name": .string("kraal-smoke")])
            )
            let (all, live, document) = try await (first, second, third)
            #expect(all["terminals"]?.arrayValue != nil)
            #expect(live["terminals"]?.arrayValue != nil)
            #expect(document["value"]?.isNull == true)
            #expect(document["version"]?.intValue == 0)
        }
    }

    private static func hcBinary() -> String? {
        if let override = ProcessInfo.processInfo.environment["KRAAL_HC_BIN"], !override.isEmpty {
            return override
        }
        let candidates = [
            NSHomeDirectory() + "/.local/bin/hc",
            "/opt/homebrew/bin/hc",
            "/usr/local/bin/hc",
            "/usr/bin/hc",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func waitForSocket(_ path: String) throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw TestTimeout()
    }

    private struct CommandResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String],
        timeout: TimeInterval? = nil
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning { process.terminate() }
        }
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            status: process.terminationStatus,
            stdout: String(bytes: outData, encoding: .utf8) ?? "",
            stderr: String(bytes: errData, encoding: .utf8) ?? ""
        )
    }
}
