// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import AppKit
import Foundation
import KraalHC
import SwiftUI
import Testing

@testable import KraalHCTerminal

/// Drives a real `hc` core and a real Ghostty surface: the whole path this issue
/// changes, with no fake on either end. Opt-in because it starts a core and a PTY.
///
///     KRAAL_LIVE_HC_TESTS=1 swift test --filter KraalHCTerminalTests
private struct LiveTimeout: Error {}

@MainActor
@Suite("Live hc pane", .serialized, .enabled(if: ProcessInfo.processInfo.environment["KRAAL_LIVE_HC_TESTS"] == "1"))
struct LiveHcPaneTests {
    private struct Env {
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

    private func makeEnv() throws -> Env {
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        let directory = "/tmp/kraalhc-live-\(suffix)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var variables = ProcessInfo.processInfo.environment
        variables["HC_SESSION"] = "live-\(suffix)"
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

    private func waitForTerminal(_ binary: String, env: Env, address: inout String) async throws -> JSONValue {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            let text = try run(binary, ["ls", "--json"], env: env)
            if let data = text.data(using: .utf8),
               let json = try? JSONDecoder().decode(JSONValue.self, from: data),
               let terminal = json["terminals"]?.arrayValue?.first,
               terminal["state"]?.stringValue == "live" {
                address = terminal["address"]?.stringValue ?? ""
                return terminal
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw LiveTimeout()
    }

    private func pump(_ seconds: Double) async {
        let end = ContinuousClock.now + .seconds(seconds)
        repeat {
            for window in NSApp.windows {
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
            CATransaction.flush()
            try? await Task.sleep(for: .milliseconds(8))
        } while ContinuousClock.now < end
    }

    private func waitFor(_ needle: String, in session: HcTerminalSession, seconds: Double = 8) async -> String? {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if let text = session.viewportText, text.contains(needle) { return text }
            await pump(0.1)
        }
        return session.viewportText
    }

    @Test("a real core's replay and live output reach the engine")
    func replaysAndTypes() async throws {
        guard let binary = hcBinary() else {
            Issue.record("hc binary not found; set KRAAL_HC_BINARY")
            return
        }
        let env = try makeEnv()
        defer { try? FileManager.default.removeItem(atPath: env.directory) }
        _ = try run(binary, ["run", "--bg", "--name", "live", "--keep", "--", "sh", "-c",
                             "printf 'HELLO-FROM-HC\\n'; printf '\\033[31mRED\\033[0m 宽字 WO\\n'; "
                                 + "while read line; do echo \"GOT:$line\"; done"], env: env)
        defer { _ = try? run(binary, ["server", "stop"], env: env) }

        var address = ""
        _ = try await waitForTerminal(binary, env: env, address: &address)
        #expect(address.isEmpty == false)

        let paths = try HcPaths.resolve(environment: env.variables)
        let connection = try await openTestConnection(path: paths.socket)
        defer { connection.close() }

        let session = try await HcTerminalSession.open(
            connection: connection,
            terminal: address,
            columns: 80,
            rows: 24
        )

        _ = NSApplication.shared
        let host = NSHostingView(rootView: HcTerminalPaneView(session: session))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        let replay = await waitFor("HELLO-FROM-HC", in: session)
        #expect(replay?.contains("HELLO-FROM-HC") == true, "replay text: \(replay ?? "<nil>")")
        // SGR and wide characters are the engine's work, but a byte-level feed
        // that dropped or re-encoded them would show here.
        #expect(replay?.contains("RED 宽字 WO") == true, "colours/wide: \(replay ?? "<nil>")")

        session.send(Data("ping\n".utf8))
        let typed = await waitFor("GOT:ping", in: session)
        #expect(typed?.contains("GOT:ping") == true, "after typing: \(typed ?? "<nil>")")

        // The view's grid must reach the core, not stay a client-side idea.
        let grid = try #require(session.grid)
        let deadline = ContinuousClock.now + .seconds(5)
        var remote: JSONValue?
        while ContinuousClock.now < deadline {
            if let data = try? run(binary, ["get", address, "--json"], env: env).data(using: .utf8),
               let json = try? JSONDecoder().decode(JSONValue.self, from: data) {
                remote = json
                if json["cols"]?.intValue == Int(grid.columns), json["rows"]?.intValue == Int(grid.rows) {
                    break
                }
            }
            await pump(0.1)
        }
        #expect(remote?["cols"]?.intValue == Int(grid.columns),
                "core cols \(remote?["cols"]?.intValue ?? -1) vs engine \(grid.columns)")
        #expect(remote?["rows"]?.intValue == Int(grid.rows),
                "core rows \(remote?["rows"]?.intValue ?? -1) vs engine \(grid.rows)")

        session.close()
    }

    @Test("five megabytes of output arrive whole and the exit is reported")
    func largeOutput() async throws {
        guard let binary = hcBinary() else {
            Issue.record("hc binary not found; set KRAAL_HC_BINARY")
            return
        }
        let env = try makeEnv()
        defer { try? FileManager.default.removeItem(atPath: env.directory) }
        _ = try run(binary, ["run", "--bg", "--name", "burst", "--keep", "--", "sh", "-c",
                             "yes hello | head -c 5000000; printf 'END-OF-BURST\\n'"], env: env)
        defer { _ = try? run(binary, ["server", "stop"], env: env) }

        var address = ""
        _ = try await waitForTerminal(binary, env: env, address: &address)
        let paths = try HcPaths.resolve(environment: env.variables)
        let connection = try await openTestConnection(path: paths.socket)
        defer { connection.close() }
        let session = try await HcTerminalSession.open(connection: connection, terminal: address)
        defer { session.close() }

        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = NSHostingView(rootView: HcTerminalPaneView(session: session))
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        let text = await waitFor("END-OF-BURST", in: session, seconds: 30)
        #expect(text?.contains("END-OF-BURST") == true, "tail: \(text?.suffix(200) ?? "<nil>")")
        #expect(session.lost == false)

        let deadline = ContinuousClock.now + .seconds(10)
        while session.end == nil, ContinuousClock.now < deadline {
            await pump(0.1)
        }
        #expect(session.end?.reason == "exited", "end: \(String(describing: session.end))")
    }
}
