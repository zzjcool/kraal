// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Issue #66, SSH half: `performReadyHandshake` checked its deadline in a
// `while` loop and then blocked in `handle.availableData`, which has no upper
// bound. Measured: a remote whose `herdr status client` hangs produced
//
//     STILL RUNNING after 50s  ->  30 s bridge deadline NOT enforced
//
// The stub below stands in for `ssh`: it is a shell script that prints nothing
// and sleeps, which is the same shape as that remote (the connection is up, the
// bytes never come). No network, no remote host, no `herdr`.

import Foundation
import Testing

import KraalTransport

@Suite("SSH bridge handshake deadline")
struct SSHBridgeDeadlineTests {
    /// Writes an `ssh` stand-in and returns its path.
    ///
    /// `body` runs with the stub's stdout as a pipe, so "silent" is literally a
    /// process that holds the pipe open and writes nothing — the case that used
    /// to park `availableData` forever.
    private func stub(_ script: String) throws -> String {
        let directory = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("kraal-ssh-stub-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("ssh")
        try "#!/bin/sh\n\(script)\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return executable.path
    }

    /// The decisive SSH test: a bridge that says nothing must be abandoned at the
    /// deadline, with an error that names the deadline.
    ///
    /// `sleep 30` rather than an infinite sleep so a broken run leaves no stray
    /// process behind after the test reports.
    @Test("a silent bridge is abandoned at the deadline")
    func silentBridgeTimesOut() throws {
        let executable = try stub("sleep 30")
        let budget: TimeInterval = 0.5
        let startedAt = Date()
        do {
            _ = try SSHProcessTransport.connect(
                user: nil,
                host: "example.invalid",
                port: nil,
                session: "default",
                timeout: budget,
                executable: executable
            )
            Issue.record("the handshake succeeded against a bridge that said nothing")
        } catch let error as SSHTransportError {
            let elapsed = Date().timeIntervalSince(startedAt)
            print(String(format: "silent bridge: threw after %.2fs: %@", elapsed, "\(error)"))
            guard case let .handshakeTimedOut(seconds, _) = error else {
                Issue.record("expected .handshakeTimedOut, got \(error)")
                return
            }
            #expect(seconds == budget, "the error must name the budget it applied")
            #expect("\(error)".contains("0.5s"), "the message must carry the seconds: \(error)")
            // Comfortably inside the window the issue measured (50 s), and not
            // instant: the bridge got its whole budget first.
            #expect(elapsed < budget + 3.0, "gave up after \(elapsed)s; the budget was \(budget)s")
            #expect(elapsed >= budget * 0.8, "gave up after \(elapsed)s, before the \(budget)s budget")
        } catch {
            Issue.record("expected SSHTransportError, got \(error)")
        }
    }

    /// "Silent" and "closed" must stay distinguishable: a bridge that exits
    /// without a banner is reported as a missing banner, not as a timeout.
    @Test("a bridge that exits without a banner is not a timeout")
    func closedBridgeIsNotATimeout() throws {
        let executable = try stub("exit 0")
        do {
            _ = try SSHProcessTransport.connect(
                user: nil,
                host: "example.invalid",
                port: nil,
                session: "default",
                timeout: 5,
                executable: executable
            )
            Issue.record("the handshake succeeded against a bridge that exited")
        } catch let error as SSHTransportError {
            #expect(!isTimeout(error), "a closed bridge was reported as a timeout: \(error)")
        } catch {
            Issue.record("expected SSHTransportError, got \(error)")
        }
    }

    /// The success path still works: a bridge that prints a status line and the
    /// ready banner completes the handshake, and the transport is handed back
    /// with the version line recorded.
    @Test("a bridge that sends the ready banner completes the handshake")
    func readyBannerCompletes() throws {
        let executable = try stub("""
        printf '%s\\n' '{"version":"0.9.5"}'
        printf '\\n%s\\n' 'herdr-remote-output-ready:1'
        sleep 0.4
        """)
        let transport = try SSHProcessTransport.connect(
            user: nil,
            host: "example.invalid",
            port: nil,
            session: "default",
            timeout: 5,
            executable: executable
        )
        defer { transport.close() }
        #expect(
            transport.remoteVersionLine == #"{"version":"0.9.5"}"#,
            "version line was not captured: \(transport.remoteVersionLine)"
        )
    }

    private func isTimeout(_ error: SSHTransportError) -> Bool {
        if case .handshakeTimedOut = error { return true }
        return false
    }
}
