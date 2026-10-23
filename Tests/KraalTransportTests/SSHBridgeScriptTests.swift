// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Issue #74, part (a): nothing tested `bridgeScript`. That script decides *which*
// remote `herdr` binary the client ends up talking to, and every way it can go
// wrong looks the same from the outside — "connect failed" — so the nine-entry
// candidate list, the `mise` shim exclusion and the `accept` / `accept-idle`
// choice had no guard at all.
//
// The script is plain text, so it is tested as text: each test plants a fake
// `$HOME` and a fake `$PATH`, writes the script to a scratch file, runs it with
// `/bin/sh` exactly like the remote side would, and asserts on which stub spoke.
// No real `herdr`, no real `~/.local/bin`, no remote host, no `ssh`.
//
// One thing a fake `$HOME` cannot hide is the six *absolute* candidates the
// script also probes (`/opt/homebrew/bin/herdr`, `/usr/local/bin/herdr`, …).
// Tests that need "and nowhere else" are gated on `foreignAbsoluteCandidate()`
// returning nil, so on a machine with Homebrew `herdr` they report as skipped
// instead of failing for a reason that has nothing to do with the code.

import Foundation
import Testing

import KraalTransport

/// An executable `herdr` at one of the script's hardcoded absolute candidates.
///
/// `$USER` is unset in the tests' environment, so the per-user profile candidate
/// really is `/etc/profiles/per-user//bin/herdr`; the login name is checked too
/// in case that ever changes.
private func foreignAbsoluteCandidate() -> String? {
    let candidates = [
        "/opt/homebrew/bin/herdr",
        "/usr/local/bin/herdr",
        "/home/linuxbrew/.linuxbrew/bin/herdr",
        "/etc/profiles/per-user//bin/herdr",
        "/etc/profiles/per-user/\(NSUserName())/bin/herdr",
        "/nix/var/nix/profiles/default/bin/herdr",
        "/run/current-system/sw/bin/herdr",
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

@Suite("SSH bridge script")
struct SSHBridgeScriptTests {
    /// A scratch root with a fake `$HOME` and a marker directory.
    private struct Fixture {
        let root: URL

        var home: String { root.appendingPathComponent("home", isDirectory: true).path }
        var markers: String { root.appendingPathComponent("markers", isDirectory: true).path }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "kraal-bridge-script-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: home),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: markers),
                withIntermediateDirectories: true
            )
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// What the fake `herdr` does when it is asked `status client --json`.
    private enum StatusBehaviour {
        case works
        case fails(code: Int32, stderr: String)
    }

    private struct ScriptRun {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Writes a fake `herdr` and returns its absolute path.
    ///
    /// Two behaviours, told apart by the first argument the script passes:
    /// `status …` takes the status branch; anything else is the bridge branch,
    /// which prints `BRIDGE-<tag>` so the test can see which candidate was
    /// exec'd. `trace` makes every invocation of this stub leave a file behind,
    /// which is how "was never even tried" is proven rather than inferred.
    private func installHerdr(
        in fixture: Fixture,
        at relativePath: String,
        tag: String,
        status: StatusBehaviour = .works,
        trace: Bool = false
    ) throws {
        let executable = fixture.root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var lines = ["#!/bin/sh"]
        if trace {
            lines.append("printf x > \(singleQuoted(fixture.markers + "/\(tag)-ran"))")
        }
        lines.append("if [ \"$1\" = status ]; then")
        switch status {
        case .works:
            lines.append("    printf '%s\\n' '{\"version\":\"0.9.5\",\"stub\":\"\(tag)\"}'")
            lines.append("    exit 0")
        case let .fails(code, stderr):
            lines.append("    printf '%s\\n' \(singleQuoted(stderr)) >&2")
            lines.append("    exit \(code)")
        }
        lines.append("fi")
        lines.append("printf 'BRIDGE-\(tag) session=%s args=%s\\n' \"$2\" \"$*\"")
        lines.append("")

        try lines.joined(separator: "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
    }

    /// Runs the bridge script the way the remote side does (`/bin/sh -c`), with
    /// `stdin` as the client's answer to the banner, and returns what came out.
    private func runScript(
        _ script: String,
        home: String,
        path: [String],
        stdin: String
    ) throws -> ScriptRun {
        let runner = Process()
        runner.executableURL = URL(fileURLWithPath: "/bin/sh")
        runner.arguments = ["-c", script]
        // Minimal and explicit: nothing from the developer's own `$PATH` may leak
        // in, or `command -v herdr` would find the real binary.
        runner.environment = [
            "HOME": home,
            "PATH": path.joined(separator: ":"),
            "LC_ALL": "C",
        ]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        runner.standardInput = stdinPipe
        runner.standardOutput = stdoutPipe
        runner.standardError = stderrPipe

        try runner.run()
        try? stdinPipe.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
        // Closing is what tells the script the client has nothing more to say;
        // with no bytes written first it is a plain EOF.
        try? stdinPipe.fileHandleForWriting.close()

        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        runner.waitUntilExit()

        return ScriptRun(
            status: runner.terminationStatus,
            stdout: String(bytes: stdout, encoding: .utf8) ?? "",
            stderr: String(bytes: stderr, encoding: .utf8) ?? ""
        )
    }

    /// `'` + value with every `'` turned into `'\''` — written out here instead of
    /// calling the transport's `shellQuote`, so the assertion stays independent of
    /// the code it guards.
    private func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The `$PATH` that finds nothing — no real `herdr` anywhere on it.
    private let emptyPath = ["/usr/bin", "/bin"]

    // MARK: - 1. the common install location

    @Test("herdr in ~/.local/bin is found and used")
    func localBinIsFound() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try installHerdr(in: fixture, at: "home/.local/bin/herdr", tag: "local")

        let ran = try runScript(
            SSHProcessTransport.bridgeScript(session: "default"),
            home: fixture.home,
            path: emptyPath,
            stdin: "accept\n"
        )
        print("local-bin run: status=\(ran.status) stdout=\(ran.stdout) stderr=\(ran.stderr)")

        #expect(ran.status == 0, "the script exited \(ran.status): \(ran.stderr)")
        #expect(ran.stdout.contains(#"{"version":"0.9.5","stub":"local"}"#),
                "the status JSON never reached stdout: \(ran.stdout)")
        #expect(ran.stdout.contains("herdr-remote-output-ready:1"),
                "the ready banner never reached stdout: \(ran.stdout)")
        #expect(ran.stdout.contains("BRIDGE-local"),
                "the ~/.local/bin candidate was not the one exec'd: \(ran.stdout)")
    }

    // MARK: - 2. nothing anywhere

    @Test(
        "no herdr anywhere exits 127 without ever offering a banner",
        .enabled(if: foreignAbsoluteCandidate() == nil,
                 "a herdr exists at one of the script's absolute candidates on this machine")
    )
    func missingEverywhereExits127() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        let ran = try runScript(
            SSHProcessTransport.bridgeScript(session: "default"),
            home: fixture.home,
            path: emptyPath,
            stdin: "accept\n"
        )
        print("missing run: status=\(ran.status) stdout=\(ran.stdout) stderr=\(ran.stderr)")

        #expect(ran.status == 127, "expected the script's own 127, got \(ran.status)")
        #expect(!ran.stdout.contains("herdr-remote-output-ready:1"),
                "a host without herdr must not offer a banner: \(ran.stdout)")
        #expect(!ran.stdout.contains("BRIDGE"), "no bridge may be exec'd: \(ran.stdout)")
    }

    // MARK: - 3. present, but its `status` fails

    @Test("a candidate whose status fails is skipped for the next candidate")
    func failingStatusIsSkipped() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        // The broken one sits on PATH (so it is tried first, and provably tried),
        // the working one in ~/.local/bin (second candidate). Neither position
        // depends on any absolute path this machine might already have.
        try installHerdr(
            in: fixture,
            at: "shim/herdr",
            tag: "broken",
            status: .fails(code: 3, stderr: "boom: cannot read config"),
            trace: true
        )
        try installHerdr(in: fixture, at: "home/.local/bin/herdr", tag: "local")

        let ran = try runScript(
            SSHProcessTransport.bridgeScript(session: "default"),
            home: fixture.home,
            path: [fixture.root.appendingPathComponent("shim").path] + emptyPath,
            stdin: "accept\n"
        )
        print("failing-status run: status=\(ran.status) stdout=\(ran.stdout) stderr=\(ran.stderr)")

        #expect(FileManager.default.fileExists(atPath: fixture.markers + "/broken-ran"),
                "the broken candidate was never tried, so this test proves nothing")
        #expect(ran.status == 0, "the script exited \(ran.status)")
        #expect(ran.stdout.contains("BRIDGE-local"),
                "the next candidate was not used after the first failed: \(ran.stdout)")
        #expect(!ran.stdout.contains("BRIDGE-broken"),
                "a candidate whose status failed was exec'd anyway: \(ran.stdout)")
        #expect(ran.stderr.contains("boom: cannot read config"),
                "the failing candidate's stderr must surface (issue #74): \(ran.stderr)")
    }

    @Test(
        "every candidate failing its status exits 127",
        .enabled(if: foreignAbsoluteCandidate() == nil,
                 "a herdr exists at one of the script's absolute candidates on this machine")
    )
    func allStatusesFailExits127() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        for (relativePath, tag) in [("home/.local/bin/herdr", "one"), ("home/.nix-profile/bin/herdr", "two")] {
            try installHerdr(
                in: fixture,
                at: relativePath,
                tag: tag,
                status: .fails(code: 3, stderr: "boom: \(tag)")
            )
        }

        let ran = try runScript(
            SSHProcessTransport.bridgeScript(session: "default"),
            home: fixture.home,
            path: emptyPath,
            stdin: "accept\n"
        )
        print("all-failing run: status=\(ran.status) stdout=\(ran.stdout) stderr=\(ran.stderr)")

        #expect(ran.status == 127, "expected 127 once every candidate failed, got \(ran.status)")
        #expect(!ran.stdout.contains("herdr-remote-output-ready:1"), "no banner may be offered")
        #expect(ran.stderr.contains("boom: one") && ran.stderr.contains("boom: two"),
                "both failures must reach stderr: \(ran.stderr)")
    }

    // MARK: - 4. the mise shim exclusion

    @Test("a mise shim found on PATH is not even tried")
    func miseShimIsIgnored() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try installHerdr(in: fixture, at: "mise/shims/herdr", tag: "mise", trace: true)
        try installHerdr(in: fixture, at: "home/.local/bin/herdr", tag: "local")

        let ran = try runScript(
            SSHProcessTransport.bridgeScript(session: "default"),
            home: fixture.home,
            // First on PATH, so `command -v herdr` returns the shim: the script
            // must drop it and keep looking.
            path: [fixture.root.appendingPathComponent("mise/shims").path] + emptyPath,
            stdin: "accept\n"
        )
        print("mise run: status=\(ran.status) stdout=\(ran.stdout) stderr=\(ran.stderr)")

        #expect(ran.status == 0, "the script exited \(ran.status)")
        #expect(ran.stdout.contains("BRIDGE-local"),
                "the mise shim displaced the real candidate: \(ran.stdout)")
        #expect(!ran.stdout.contains("BRIDGE-mise"), "the mise shim was exec'd: \(ran.stdout)")
        #expect(!FileManager.default.fileExists(atPath: fixture.markers + "/mise-ran"),
                "the mise shim was executed; it must not even be tried")
    }

    @Test("a herdr found on PATH is preferred over ~/.local/bin")
    func pathCandidateComesFirst() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try installHerdr(in: fixture, at: "opt/bin/herdr", tag: "path")
        try installHerdr(in: fixture, at: "home/.local/bin/herdr", tag: "local")

        let ran = try runScript(
            SSHProcessTransport.bridgeScript(session: "default"),
            home: fixture.home,
            path: [fixture.root.appendingPathComponent("opt/bin").path] + emptyPath,
            stdin: "accept\n"
        )
        print("path-first run: status=\(ran.status) stdout=\(ran.stdout)")

        #expect(ran.stdout.contains("BRIDGE-path"),
                "the PATH candidate is first in the list and must win: \(ran.stdout)")
    }

    // MARK: - 5. no answer from the client

    @Test("stdin closing before accept ends the script without a bridge")
    func eofBeforeAcceptExits() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try installHerdr(in: fixture, at: "home/.local/bin/herdr", tag: "local")

        let ran = try runScript(
            SSHProcessTransport.bridgeScript(session: "default"),
            home: fixture.home,
            path: emptyPath,
            stdin: ""
        )
        print("eof run: status=\(ran.status) stdout=\(ran.stdout)")

        // The banner is printed *before* the read, so it is expected here; what
        // must not happen is the exec.
        #expect(ran.stdout.contains("herdr-remote-output-ready:1"),
                "the banner must already have been offered: \(ran.stdout)")
        #expect(!ran.stdout.contains("BRIDGE"), "no bridge may start without an answer: \(ran.stdout)")
        #expect(ran.status != 0, "the script must fail, not fall through to success")
    }

    // MARK: - 6. accept vs accept-idle

    @Test("accept and accept-idle pass different flags to the bridge")
    func acceptVersusAcceptIdle() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try installHerdr(in: fixture, at: "home/.local/bin/herdr", tag: "local")
        let script = SSHProcessTransport.bridgeScript(session: "default")

        let accepted = try runScript(
            script, home: fixture.home, path: emptyPath, stdin: "accept\n"
        )
        let idle = try runScript(
            script, home: fixture.home, path: emptyPath, stdin: "accept-idle\n"
        )
        print("accept run: \(accepted.stdout)")
        print("accept-idle run: \(idle.stdout)")

        #expect(accepted.stdout.contains("remote-client-bridge"),
                "the bridge was not started on accept: \(accepted.stdout)")
        #expect(!accepted.stdout.contains("--idle-timeout-v1"),
                "accept must not opt into the idle-timeout protocol: \(accepted.stdout)")
        #expect(idle.stdout.contains("--idle-timeout-v1"),
                "accept-idle must opt into the idle-timeout protocol: \(idle.stdout)")
    }

    // MARK: - 7. quoting of the session name

    @Test("a session name with quotes and substitutions reaches the bridge verbatim")
    func sessionNameIsQuoted() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try installHerdr(in: fixture, at: "home/.local/bin/herdr", tag: "local")

        // `shellQuote` is the last line of defence for the session name: a name
        // that escaped it would be evaluated as shell code on the remote host.
        //
        // The payload's marker is only spelled `PWNED` *after* evaluation — as
        // written it is `PWN;printf ED` — so a failing run leaves the marker in
        // the output while a passing one provably cannot. That is what makes the
        // negative assertion mean "was executed" rather than "contains a string".
        let hostile = "a'b $(printf %s PWN;printf ED) `printf %s PWN;printf ED` ; :"
        let script = SSHProcessTransport.bridgeScript(session: hostile)
        #expect(script.contains(#"'a'\''b $(printf %s PWN;printf ED) `printf %s PWN;printf ED` ; :'"#),
                "the session name is not shell-quoted: \(script)")

        let ran = try runScript(script, home: fixture.home, path: emptyPath, stdin: "accept\n")
        print("quoting run: \(ran.stdout)")

        // The stub prints `$2` — the session exactly as the bridge would receive
        // it. Byte-for-byte identity proves the quoting is transparent, and the
        // absent marker proves nothing was evaluated.
        #expect(ran.stdout.contains("session=\(hostile) "),
                "the session name did not arrive verbatim: \(ran.stdout)")
        #expect(!ran.stdout.contains("PWNED"),
                "the session name was evaluated as shell code: \(ran.stdout)")
        #expect(ran.stdout.contains("remote-client-bridge"), "the bridge was not started")
    }
}
