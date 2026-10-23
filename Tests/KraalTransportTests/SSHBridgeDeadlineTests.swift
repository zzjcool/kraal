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
//
// Issue #74 added the other half: the handshake's *exit* paths. A remote that
// closes without a banner can be three different failures — nothing installed,
// a `herdr` that failed, or a `herdr` that answered but withheld the banner —
// and the one thing they must not do is wear each other's error message. Each
// test below pins one of them, and the pairing is the point: the same silence
// means "not installed" only while stderr is empty too.

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
    ///
    /// Issue #74: this is also the *only* shape that may claim "not installed" —
    /// nothing was printed on either stream, so no `herdr` was found and none was
    /// run. `failedHerdrIsNotReportedAsMissing` is the same silence with stderr
    /// attached, which must not wear this message.
    @Test("a bridge that exits without a banner is not a timeout, and is 'not installed'")
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
            print("closed: \(error)")
            #expect(!isTimeout(error), "a closed bridge was reported as a timeout: \(error)")
            guard case .noRemoteHerdr = error else {
                Issue.record("expected .noRemoteHerdr for a remote silent on both streams, got \(error)")
                return
            }
            #expect("\(error)".contains("not installed"),
                    "the message must name the missing binary: \(error)")
        } catch {
            Issue.record("expected SSHTransportError, got \(error)")
        }
    }

    // MARK: - Issue #74: which of the three "no banner" failures is it?

    /// Issue #74's misleading case, verbatim: the remote *has* a `herdr`, its
    /// `status client --json` exits 3 and says why on stderr. The main sentence
    /// must not send the user hunting for a binary that is right there.
    @Test("a herdr that failed is not reported as not installed")
    func failedHerdrIsNotReportedAsMissing() throws {
        let executable = try stub("""
        printf '%s\\n' 'boom: cannot read config' >&2
        exit 3
        """)
        do {
            _ = try SSHProcessTransport.connect(
                user: nil,
                host: "example.invalid",
                port: nil,
                session: "default",
                timeout: 5,
                executable: executable
            )
            Issue.record("the handshake succeeded against a herdr that failed")
        } catch let error as SSHTransportError {
            print("failed: \(error)")
            guard case let .remoteHerdrFailed(detail) = error else {
                Issue.record("expected .remoteHerdrFailed, got \(error)")
                return
            }
            #expect(detail.contains("boom: cannot read config"), "the remote's own words must survive: \(detail)")
            let message = "\(error)"
            #expect(!message.contains("not installed"),
                    "a herdr that exists must not be reported as missing (issue #74): \(message)")
            #expect(message.lowercased().contains("failed"),
                    "the message must say the herdr failed: \(message)")
        } catch {
            Issue.record("expected SSHTransportError, got \(error)")
        }
    }

    /// Issue #74 suggestion 3: `status` printed something and then the bridge
    /// hung up before the banner. The binary is demonstrably installed, so the
    /// report is "answered, but not with a banner" — and it must carry what was
    /// actually said, or there is nothing to debug with.
    @Test("status output without a banner is a missing banner")
    func statusWithoutBannerIsAMissingBanner() throws {
        let executable = try stub("""
        printf '%s\\n' '{"version":"0.9.5"}'
        exit 0
        """)
        do {
            _ = try SSHProcessTransport.connect(
                user: nil,
                host: "example.invalid",
                port: nil,
                session: "default",
                timeout: 5,
                executable: executable
            )
            Issue.record("the handshake succeeded without a banner")
        } catch let error as SSHTransportError {
            print("no-banner: \(error)")
            guard case let .readyBannerMissing(output) = error else {
                Issue.record("expected .readyBannerMissing, got \(error)")
                return
            }
            #expect(output.contains("0.9.5"), "the status output must be in the error: \(output)")
            #expect(!isTimeout(error), "an answered-then-closed bridge is not a timeout: \(error)")
        } catch {
            Issue.record("expected SSHTransportError, got \(error)")
        }
    }

    /// Status *and* stderr with no banner: the status line proves the binary is
    /// there, so the banner is still what is missing — stderr rides along as
    /// context instead of replacing the diagnosis.
    @Test("status plus stderr without a banner is still a missing banner")
    func statusAndStderrWithoutBannerIsAMissingBanner() throws {
        let executable = try stub("""
        printf '%s\\n' '{"version":"0.9.5"}'
        printf '%s\\n' 'warning: no config' >&2
        exit 0
        """)
        do {
            _ = try SSHProcessTransport.connect(
                user: nil,
                host: "example.invalid",
                port: nil,
                session: "default",
                timeout: 5,
                executable: executable
            )
            Issue.record("the handshake succeeded without a banner")
        } catch let error as SSHTransportError {
            print("status+stderr: \(error)")
            guard case let .readyBannerMissing(output) = error else {
                Issue.record("expected .readyBannerMissing, got \(error)")
                return
            }
            #expect(output.contains("0.9.5"), "the status output must be in the error: \(output)")
            #expect(output.contains("no config"), "stderr must ride along as context: \(output)")
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

    // MARK: - Issue #91: stderr that arrives late is not "no stderr"

    /// The 50 ms race, made deterministic.
    ///
    /// `drainStderr` used to wait 50 ms and then report whatever it had — so a
    /// remote that wrote its error to stderr *after* the bridge closed was
    /// classified as "nothing installed", the one diagnosis #74 existed to
    /// prevent. A `sleep` between the write and the exit is what a slow link
    /// looks like from here; nothing about it is exotic.
    ///
    /// 300 ms is far beyond the old window and far inside any sane budget, so the
    /// test is about correctness, not about a race that may or may not fire.
    @Test("stderr written after the bridge exits is still read")
    func lateStderrIsStillRead() throws {
        // stdout closes first, stderr 200 ms later. That is what a slow remote
        // looks like from this side: the handshake's read loop sees end-of-stream
        // and gives up on the banner, while the error text is still on its way.
        // 200 ms is four times the window the old code gave it.
        let executable = try stub("""
        exec 1>&-
        sleep 0.2
        printf 'boom: cannot read config\n' >&2
        exit 3
        """)
        do {
            _ = try SSHProcessTransport.connect(
                user: nil,
                host: "example.invalid",
                port: nil,
                session: "default",
                timeout: 5,
                executable: executable
            )
            Issue.record("the handshake succeeded against a bridge that failed")
        } catch let error as SSHTransportError {
            print("late stderr: \(error)")
            guard case let .remoteHerdrFailed(detail) = error else {
                let detail = "late stderr was classified as \(error) — a herdr that exists"
                    + " must not be reported as missing merely because its error arrived"
                    + " slowly (issue #91)"
                Issue.record("\(detail)")
                return
            }
            #expect(detail.contains("boom: cannot read config"),
                    "the remote's own words must survive: \(detail)")
        } catch {
            Issue.record("expected SSHTransportError, got \(error)")
        }
    }

    /// Silence still means "not installed" — the fix must not turn the third
    /// category into a fourth one by accident.
    @Test("a bridge that writes nothing at all is still not installed")
    func silentBridgeIsStillNotInstalled() throws {
        let executable = try stub("exit 3")
        do {
            _ = try SSHProcessTransport.connect(
                user: nil,
                host: "example.invalid",
                port: nil,
                session: "default",
                timeout: 5,
                executable: executable
            )
            Issue.record("the handshake succeeded against a silent bridge")
        } catch let error as SSHTransportError {
            print("silent: \(error)")
            guard case .noRemoteHerdr = error else {
                Issue.record("expected .noRemoteHerdr, got \(error)")
                return
            }
        } catch {
            Issue.record("expected SSHTransportError, got \(error)")
        }
    }

    /// When the bridge never exits, waiting for it would hang. The wait has a
    /// ceiling, and reaching that ceiling is reported as such — not silently
    /// degraded into "no stderr, therefore not installed". A `herdr` that hung is
    /// a different fact from a host that has none, and the user's next action
    /// differs (kill the process vs install the binary).
    @Test("a bridge that never closes is not reported as not installed")
    func hungBridgeIsNotReportedAsMissing() throws {
        let executable = try stub("""
        printf '%s\n' 'starting' >&2
        sleep 30
        """)
        do {
            _ = try SSHProcessTransport.connect(
                user: nil,
                host: "example.invalid",
                port: nil,
                session: "default",
                timeout: 0.5,
                executable: executable
            )
            Issue.record("the handshake succeeded against a bridge that never closed")
        } catch let error as SSHTransportError {
            print("hung: \(error)")
            if case .noRemoteHerdr = error {
                Issue.record(
                    "a bridge that hung was reported as not installed (issue #91): \(error)"
                )
            }
            // The two acceptable answers both say the remote is at fault and both
            // carry what it managed to say.
            switch error {
            case .handshakeTimedOut:
                break
            case .remoteHerdrFailed:
                break
            default:
                Issue.record("expected a timeout or a herdr-failed, got \(error)")
            }
        } catch {
            Issue.record("expected SSHTransportError, got \(error)")
        }
    }

    private func isTimeout(_ error: SSHTransportError) -> Bool {
        if case .handshakeTimedOut = error { return true }
        return false
    }
}
