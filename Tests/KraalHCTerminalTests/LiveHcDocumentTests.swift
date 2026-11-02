// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import KraalHC
import Testing

/// Real core: CAS on this machine, a document on a `via` machine, and the doc
/// event the core forwards for it. Opt-in because it starts two cores.
///
///     KRAAL_LIVE_HC_TESTS=1 swift test --filter KraalHCTerminalTests
@Suite(
    "Live hc documents",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["KRAAL_LIVE_HC_TESTS"] == "1")
)
struct LiveHcDocumentTests {
    private struct Core {
        let binary: String
        let root: String
        var variables: [String: String]
    }

    private func binary() -> String? {
        let env = ProcessInfo.processInfo.environment
        return [env["KRAAL_HC_BINARY"], NSHomeDirectory() + "/.local/bin/hc",
                "/opt/homebrew/bin/hc", "/usr/local/bin/hc"]
            .compactMap { $0 }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func env(_ root: String, _ session: String) -> [String: String] {
        var variables = ProcessInfo.processInfo.environment
        variables["HC_SESSION"] = session
        variables["XDG_STATE_HOME"] = root + "/state"
        variables["XDG_CONFIG_HOME"] = root + "/config"
        variables.removeValue(forKey: "HC_SOCKET")
        variables.removeValue(forKey: "XDG_RUNTIME_DIR")
        return variables
    }

    private func run(_ binary: String, _ arguments: [String], _ variables: [String: String]) throws -> String {
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

    private func waitFor(_ what: String, seconds: Double = 20, _ body: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if try await body() { return }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw DocTimeout(what: what)
    }

    private struct DocTimeout: Error, CustomStringConvertible {
        let what: String
        var description: String { "timed out waiting for \(what)" }
    }

    @Test("version CAS, latest-wins on conflict, and a document on a via machine")
    func documents() async throws {
        guard let binary = binary() else {
            Issue.record("hc binary not found; set KRAAL_HC_BINARY")
            return
        }
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        let root = "/tmp/dm-\(suffix)"
        try FileManager.default.createDirectory(atPath: root + "/a", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/b", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let local = Core(binary: binary, root: root + "/a", variables: env(root + "/a", "dm-\(suffix)"))
        let remote = Core(binary: binary, root: root + "/b", variables: env(root + "/b", "dn-\(suffix)"))
        defer {
            _ = try? run(binary, ["server", "stop"], local.variables)
            _ = try? run(binary, ["server", "stop"], remote.variables)
        }

        _ = try run(binary, ["ls", "--json"], local.variables)
        let paths = try HcPaths.resolve(environment: local.variables)
        let client = HcClient(path: paths.socket, initialBackoff: 0.01, maxBackoff: 0.05)
        client.start()
        defer { client.stop() }
        try await waitFor("the core") { client.isConnected }

        let sync = HcDocumentSync(client: client, name: "herdr-app")
        #expect(try await sync.load().isUnwritten)

        let mine = JSONValue.object(["spaces": .array([.object(["id": .string("mine")])])])
        let first = try await sync.save(mine)
        #expect(first.version >= 1)

        // Another writer, then this one still on the old version.
        let theirs = JSONValue.object(["spaces": .array([.object(["id": .string("theirs")])])])
        let second = try await client.setDocument("herdr-app", value: theirs, version: first.version)
        #expect(second.version == first.version + 1)
        do {
            _ = try await sync.save(mine)
            Issue.record("expected a conflict")
        } catch let HcDocumentError.conflict(latest) {
            #expect(latest.version == second.version)
            #expect(latest.value == theirs)
        }
        #expect(sync.current()?.value == theirs)

        // A machine's document is addressed with `on` and its events carry `machine`.
        let via = root + "/via"
        try """
        #!/bin/sh
        HC_SESSION=dn-\(suffix) XDG_STATE_HOME=\(root)/b/state XDG_CONFIG_HOME=\(root)/b/config exec sh -c "$1"
        """.write(toFile: via, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: via)
        _ = try await client.addMachine(via: via, name: "alpha")
        try await waitFor("alpha") {
            try await client.machines().first { $0.name == "alpha" }?.state == .connected
        }
        let events = DocEventProbe()
        let subscription = try await client.subscribeEvents(handlers: HcEventHandlers(
            onEvent: { events.append($0) }, onMissed: { _ in },
            onHeartbeat: { _ in }, onClosed: { _ in }
        ))
        defer { subscription.close() }

        let remoteSync = HcDocumentSync(client: client, name: "herdr-app", machine: "alpha")
        #expect(try await remoteSync.load().isUnwritten)
        let written = try await remoteSync.save(theirs)
        #expect(written.version == 1)
        let reread = try await client.document("herdr-app", on: "alpha")
        #expect(reread.value == theirs)
        #expect(reread.version == 1)
        // The core forwards the remote write as a doc event; its data is only
        // name+version, so the value must be read again.
        try await waitFor("alpha's doc event") { events.hasDoc(machine: "alpha", version: 1) }
    }
}

private final class DocEventProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [HcEvent] = []

    func append(_ event: HcEvent) {
        lock.lock()
        seen.append(event)
        lock.unlock()
    }

    func hasDoc(machine: String, version: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return seen.contains {
            $0.type == "doc" && $0.machine == machine
                && $0.data["name"]?.stringValue == "herdr-app"
                && $0.data["version"]?.uint64Value == version
        }
    }
}
