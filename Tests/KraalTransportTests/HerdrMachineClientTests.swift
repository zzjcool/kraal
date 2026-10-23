// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Tests for the machine CLI client.
//
// These never invoke the real `herdr`. A machine profile lives in the user's own
// CLI config; a test that ran `herdr machine remove` would edit it. Instead every
// test points the client at a stub script that prints canned output, so the
// argument construction, JSON decoding and error paths are covered without
// touching anything outside the test's temporary directory.

import Foundation
import XCTest

@testable import KraalTransport

final class HerdrMachineClientTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kraal-machine-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Writes a stub `herdr` that echoes fixed stdout/stderr and exits with
    /// `status`, then records the arguments it was called with.
    private func stub(
        stdout: String = "",
        stderr: String = "",
        status: Int32 = 0
    ) throws -> (client: HerdrMachineClient, argumentsFile: URL) {
        let script = directory.appendingPathComponent("herdr")
        let argumentsFile = directory.appendingPathComponent("args.txt")
        let body = """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(argumentsFile.path)'
        printf '%s' '\(stdout.replacingOccurrences(of: "'", with: #"\'"#))'
        printf '%s' '\(stderr.replacingOccurrences(of: "'", with: #"\'"#))' >&2
        exit \(status)
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: script.path
        )
        return (HerdrMachineClient(executable: script), argumentsFile)
    }

    private func recordedArguments(_ file: URL) throws -> [String] {
        let text = try String(contentsOf: file, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    // MARK: - Discovery

    func testDiscoverPrefersEnvironmentOverride() throws {
        let executable = directory.appendingPathComponent("custom-herdr")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let client = HerdrMachineClient.discover(environment: ["KRAAL_HERDR_BIN": executable.path])
        XCTAssertEqual(client?.executable.path, executable.path)
    }

    func testDiscoverReturnsNilWhenNothingFound() {
        // A directory with no herdr and no PATH entry pointing at one.
        let client = HerdrMachineClient.discover(
            environment: ["PATH": directory.path, "HOME": directory.path]
        )
        XCTAssertNil(client)
    }

    func testDiscoverIgnoresNonExecutableOverride() {
        let path = directory.appendingPathComponent("not-executable")
        try? "nope".write(to: path, atomically: true, encoding: .utf8)
        let client = HerdrMachineClient.discover(
            environment: ["KRAAL_HERDR_BIN": path.path, "PATH": directory.path, "HOME": directory.path]
        )
        XCTAssertNil(client)
    }

    // MARK: - Isolation

    func testDiscoverPassesIsolatedHomeWhenRequested() throws {
        let (stubClient, _) = try stub()
        let client = HerdrMachineClient.discover(
            environment: [
                "KRAAL_HERDR_BIN": stubClient.executable.path,
                "KRAAL_HERDR_HOME": "/tmp/kraal-scratch-home",
            ]
        )
        XCTAssertEqual(client?.home, "/tmp/kraal-scratch-home")
    }

    func testDiscoverLeavesHomeNilByDefault() throws {
        let (stubClient, _) = try stub()
        let client = HerdrMachineClient.discover(
            environment: ["KRAAL_HERDR_BIN": stubClient.executable.path]
        )
        // Inheriting `$HOME` is the normal path: a packaged app must see the same
        // roster the user's terminal sees.
        XCTAssertNil(client?.home)
    }

    func testDiscoverTreatsEmptyHomeAsUnset() throws {
        let (stubClient, _) = try stub()
        let client = HerdrMachineClient.discover(
            environment: [
                "KRAAL_HERDR_BIN": stubClient.executable.path,
                "KRAAL_HERDR_HOME": "",
            ]
        )
        // An empty value would make "$HOME/.local/..." resolve against the
        // filesystem root; inheriting is strictly better than that.
        XCTAssertNil(client?.home)
    }

    func testIsolatedHomeReachesTheChildProcess() throws {
        let script = directory.appendingPathComponent("herdr")
        let out = directory.appendingPathComponent("home.txt")
        let body = """
        #!/bin/sh
        printf '%s' "$HOME" > '\(out.path)'
        exit 0
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let client = HerdrMachineClient(executable: script, home: "/tmp/kraal-scratch-home")
        _ = try client.list()

        // The child must actually see it; storing the value on the struct alone
        // would leave the real roster exposed.
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "/tmp/kraal-scratch-home")
    }

    // MARK: - Listing

    func testListDecodesJSON() throws {
        let json = """
        [{"id":"abc123","label":"alpha","target":"ssh://z@alpha:31415",
          "session":"default","enabled":true,"selected":false},
         {"id":"def456","label":"beta","target":"ssh://root@beta:2222",
          "session":"work","enabled":false,"selected":true}]
        """
        let (client, argumentsFile) = try stub(stdout: json)

        let machines = try client.list()

        XCTAssertEqual(machines.count, 2)
        XCTAssertEqual(machines[0].id, "abc123")
        XCTAssertEqual(machines[0].label, "alpha")
        XCTAssertEqual(machines[0].target, "ssh://z@alpha:31415")
        XCTAssertTrue(machines[0].enabled)
        XCTAssertEqual(machines[1].session, "work")
        XCTAssertFalse(machines[1].enabled)
        XCTAssertEqual(machines[1].selected, true)

        XCTAssertEqual(try recordedArguments(argumentsFile), ["machine", "list", "--json"])
    }

    /// `session` and `selected` are different fields. The text output puts the
    /// session name in its fourth column, so a reader could mistake "default"
    /// for a default-machine marker; this pins the JSON meaning down.
    func testListKeepsSessionDistinctFromSelected() throws {
        let json = """
        [{"id":"a","label":"one","target":"t","session":"default","enabled":true,"selected":false}]
        """
        let (client, _) = try stub(stdout: json)
        let machines = try client.list()
        XCTAssertEqual(machines[0].session, "default")
        XCTAssertEqual(machines[0].selected, false)
    }

    func testListTreatsBlankOutputAsEmpty() throws {
        let (client, _) = try stub(stdout: "\n  \n")
        XCTAssertTrue(try client.list().isEmpty)
    }

    func testListReportsUndecodableOutput() throws {
        let (client, _) = try stub(stdout: "not json at all")
        XCTAssertThrowsError(try client.list()) { error in
            guard case HerdrMachineError.undecodable = error else {
                return XCTFail("expected undecodable, got \(error)")
            }
        }
    }

    func testMissingEnabledDefaultsToTrue() throws {
        // Defensive: an older CLI that omits `enabled` should not render every
        // machine as disabled.
        let (client, _) = try stub(stdout: #"[{"id":"a","label":"x","target":"t"}]"#)
        XCTAssertTrue(try client.list()[0].enabled)
    }

    // MARK: - Arguments

    func testAddPassesLabelAndSession() throws {
        let (client, argumentsFile) = try stub()
        _ = try client.add(target: "ssh://root@host:22", label: "box", remoteSession: "work")
        XCTAssertEqual(
            try recordedArguments(argumentsFile),
            ["machine", "add", "ssh://root@host:22", "--label", "box", "--remote-session", "work"]
        )
    }

    func testAddOmitsEmptyOptionals() throws {
        let (client, argumentsFile) = try stub()
        _ = try client.add(target: "host", label: "", remoteSession: nil)
        XCTAssertEqual(try recordedArguments(argumentsFile), ["machine", "add", "host"])
    }

    func testRenamePutsIDBeforeFlag() throws {
        let (client, argumentsFile) = try stub()
        try client.rename(id: "abc123", label: "new name")
        // The id comes first: `herdr machine rename <profile-id> --label <label>`.
        // Its own `--help` claims the opposite order and is wrong — verified
        // against herdr 0.9.5, which rejects `--label x <id>` with a usage line.
        XCTAssertEqual(
            try recordedArguments(argumentsFile),
            ["machine", "rename", "abc123", "--label", "new name"]
        )
    }

    func testEnableAndDisable() throws {
        let (enabled, enabledArgs) = try stub()
        try enabled.setEnabled(id: "abc", enabled: true)
        XCTAssertEqual(try recordedArguments(enabledArgs), ["machine", "enable", "abc"])

        let (disabled, disabledArgs) = try stub()
        try disabled.setEnabled(id: "abc", enabled: false)
        XCTAssertEqual(try recordedArguments(disabledArgs), ["machine", "disable", "abc"])
    }

    func testRemove() throws {
        let (client, argumentsFile) = try stub()
        try client.remove(id: "abc")
        XCTAssertEqual(try recordedArguments(argumentsFile), ["machine", "remove", "abc"])
    }

    // MARK: - Failures

    func testNonZeroExitSurfacesStderr() throws {
        let (client, _) = try stub(
            stderr: "error: remote platform detection failed; machine was not saved",
            status: 1
        )
        XCTAssertThrowsError(try client.remove(id: "abc")) { error in
            guard case HerdrMachineError.failed(let status, let message) = error else {
                return XCTFail("expected failed, got \(error)")
            }
            XCTAssertEqual(status, 1)
            XCTAssertTrue(message.contains("machine was not saved"))
        }
    }

    func testNonZeroExitWithoutStderrStillExplains() throws {
        let (client, _) = try stub(status: 3)
        XCTAssertThrowsError(try client.rename(id: "a", label: "b")) { error in
            XCTAssertTrue(String(describing: error).contains("status 3"))
        }
    }

    func testMissingExecutableIsReported() {
        let client = HerdrMachineClient(executable: directory.appendingPathComponent("nope"))
        XCTAssertThrowsError(try client.list()) { error in
            guard case HerdrMachineError.launchFailed = error else {
                return XCTFail("expected launchFailed, got \(error)")
            }
        }
    }

    // MARK: - status

    /// The shape `herdr machine status --json` prints, measured on herdr 0.9.5.
    private static let reachableJSON = """
    [
      {
        "id": "bbbb2222cccc3333dddd4444eeee5555",
        "label": "live-one",
        "status": "reachable",
        "error": null
      }
    ]
    """

    // Wrapped the way the real CLI wraps it: `println!` of a pretty-printed
    // document, so the long reason sits on one line inside the JSON. The Swift
    // literal is split only to stay inside the line-length lint.
    private static let errorReason =
        "remote Herdr server is stopped or incompatible; "
        + "run `herdr --remote zheng@127.0.0.1 --session no-such-73`"

    private static var errorJSON: String {
        """
        [
          {
            "id": "aaaa1111bbbb2222cccc3333dddd4444",
            "label": "dead-one",
            "status": "error",
            "error": "\(errorReason)"
          }
        ]
        """
    }

    /// **The bug in issue #73.** Measured on herdr 0.9.5: when any machine is
    /// down, `machine status --json` exits **1** while still printing the complete,
    /// valid JSON — the exit code is only a summary
    /// (`src/cli/machine.rs:184`: `i32::from(rows.iter().any(|row| row.error.is_some()))`).
    ///
    /// A client that treats a non-zero exit as failure throws away the `error`
    /// field, which is the only place that says what to run to fix the machine.
    /// Measured three times in a row on the real binary: exit 1, 451 bytes, same
    /// md5 every time — so the output is not truncated or partial under a non-zero
    /// exit, it is the whole document.
    func testStatusUsesStdoutWhenExitIsNonZero() throws {
        let (client, argumentsFile) = try stub(stdout: Self.errorJSON, status: 1)

        let rows = try client.status()

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, "aaaa1111bbbb2222cccc3333dddd4444")
        XCTAssertEqual(rows[0].label, "dead-one")
        XCTAssertEqual(rows[0].status, "error")
        XCTAssertEqual(rows[0].reachability, .unreachable)
        // The actionable half — the command in the message — must survive.
        XCTAssertEqual(
            rows[0].error,
            "remote Herdr server is stopped or incompatible; "
                + "run `herdr --remote zheng@127.0.0.1 --session no-such-73`"
        )
        XCTAssertEqual(try recordedArguments(argumentsFile), ["machine", "status", "--json"])
    }

    func testStatusDecodesReachableWithNullError() throws {
        let (client, _) = try stub(stdout: Self.reachableJSON)
        let rows = try client.status()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].reachability, .reachable)
        XCTAssertNil(rows[0].error)
    }

    /// A missing `error` key and an explicit `null` mean the same thing. The
    /// measured shape uses `null`, but `decodeIfPresent` is what makes an absent
    /// key harmless too.
    func testStatusToleratesAbsentErrorKey() throws {
        let (client, _) = try stub(stdout: #"[{"id":"a","label":"one","status":"reachable"}]"#)
        XCTAssertNil(try client.status()[0].error)
    }

    /// Upstream's `status` is a plain `&'static str` with no declared enum, so a
    /// future herdr can add a state. That must render as itself, not fail: a
    /// `JSONDecoder` failure on one element fails the **whole array**, which would
    /// blank the reachability column at the exact moment it becomes interesting.
    func testStatusKeepsUnknownStatusValues() throws {
        let json = #"[{"id":"a","label":"one","status":"quarantined","error":null}]"#
        let (client, _) = try stub(stdout: json)
        let rows = try client.status()
        XCTAssertEqual(rows.count, 1, "an unknown status must not drop the row")
        XCTAssertEqual(rows[0].status, "quarantined")
        XCTAssertEqual(rows[0].reachability, .other("quarantined"))
    }

    /// The other two statuses upstream can emit (`machine.rs:136-150`), which the
    /// issue's report did not happen to produce. Both are pinned so a later change
    /// cannot quietly fold them into `error`.
    func testStatusKnowsDisabledAndAuthRequired() throws {
        let json = """
        [{"id":"a","label":"off","status":"disabled","error":null},
         {"id":"b","label":"locked","status":"auth required","error":"Permission denied (publickey)"}]
        """
        let (client, _) = try stub(stdout: json)
        let rows = try client.status()
        XCTAssertEqual(rows[0].reachability, .disabled)
        XCTAssertEqual(rows[1].reachability, .authRequired)
        // A disabled profile is not an error: upstream sets `error` to None.
        XCTAssertNil(rows[0].error)
    }

    func testStatusDecodesEmptyArray() throws {
        let (client, _) = try stub(stdout: "[]")
        XCTAssertTrue(try client.status().isEmpty)
    }

    /// Extra fields must be ignored, not fatal. `machine list` gaining a field is
    /// the normal case for a CLI that ships independently of this app.
    func testStatusIgnoresUnknownFields() throws {
        let json = #"[{"id":"a","label":"one","status":"reachable","error":null,"latencyMs":12}]"#
        let (client, _) = try stub(stdout: json)
        XCTAssertEqual(try client.status().count, 1)
    }

    /// The tolerance is for "non-zero exit **and** parseable output" only. A usage
    /// error (exit 2, empty stdout) still has to surface the CLI's own message:
    /// measured, `herdr machine status --json nope` prints
    /// `unknown machine 'nope'; use `herdr machine list`` on stderr and exits 2.
    func testStatusStillFailsOnNonZeroExitWithoutJSON() throws {
        let (client, _) = try stub(stdout: "", stderr: "unknown machine nope", status: 2)
        XCTAssertThrowsError(try client.status("nope")) { error in
            guard case HerdrMachineError.failed(let status, let message) = error else {
                return XCTFail("expected failed, got \(error)")
            }
            XCTAssertEqual(status, 2)
            XCTAssertTrue(message.contains("unknown machine"), message)
        }
    }

    /// Exit 0 with garbage stays "undecodable": the CLI claims success, so the
    /// problem is the output, and saying "exited with status 0" would be useless.
    func testStatusReportsUndecodableOutputOnSuccess() throws {
        let (client, _) = try stub(stdout: "not json at all")
        XCTAssertThrowsError(try client.status()) { error in
            guard case HerdrMachineError.undecodable = error else {
                return XCTFail("expected undecodable, got \(error)")
            }
        }
    }

    /// A single-machine probe passes the selector, and still gets the non-zero
    /// tolerance: measured, `machine status --json <id>` on a dead machine exits 1
    /// with the same complete one-element JSON.
    func testStatusSingleSelectorKeepsNonZeroTolerance() throws {
        let (client, argumentsFile) = try stub(stdout: Self.errorJSON, status: 1)
        let rows = try client.status("dead-one")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(try recordedArguments(argumentsFile), ["machine", "status", "--json", "dead-one"])
    }

    /// The write commands must NOT get the tolerance: their non-zero exit is a real
    /// failure and their stdout is human text, not JSON. This is why the change went
    /// into a private `invoke` + one relaxed caller instead of into `run`.
    func testWritesStillThrowOnNonZeroExitWithStdout() throws {
        let (client, _) = try stub(stdout: "looks successful", stderr: "error: ssh failed", status: 1)
        XCTAssertThrowsError(try client.add(target: "h", label: nil, remoteSession: nil)) { error in
            guard case HerdrMachineError.failed(let status, let message) = error else {
                return XCTFail("expected failed, got \(error)")
            }
            XCTAssertEqual(status, 1)
            XCTAssertEqual(message, "error: ssh failed")
        }
    }

    // MARK: - Status index

    /// Merging is by `id`, because the two commands answer different questions:
    /// `list` is the roster on disk, `status` is a live probe.
    func testStatusIndexJoinsOnID() {
        let index = MachineStatusIndex([
            MachineStatus(id: "a", label: "one", status: "reachable"),
            MachineStatus(id: "b", label: "two", status: "error", error: "boom"),
        ])
        XCTAssertEqual(index.reachability(for: "a"), .reachable)
        XCTAssertEqual(index.reachability(for: "b"), .unreachable)
        XCTAssertEqual(index.status(for: "b")?.error, "boom")
    }

    /// A machine in the roster with no probe result is *unknown*, never broken.
    /// Both directions happen in practice: a profile added since the last probe has
    /// no row yet, and a status row can outlive its profile when one is removed
    /// between the two commands.
    func testStatusIndexTreatsMissingEntriesAsUnknown() {
        let index = MachineStatusIndex(
            [MachineStatus(id: "gone", label: "removed", status: "reachable")]
        )
        XCTAssertNil(index.reachability(for: "just-added"))
        XCTAssertNil(index.status(for: "just-added"))
        // The status row for a profile `list` no longer has is kept, not invented
        // into a roster entry — `list` decides which rows exist.
        XCTAssertNotNil(index.status(for: "gone"))
    }

    func testStatusIndexIsEmptyByDefault() {
        XCTAssertTrue(MachineStatusIndex().isEmpty)
        XCTAssertNil(MachineStatusIndex().reachability(for: "a"))
    }

    /// A later row for the same id wins, so a probe that reports a machine twice
    /// (it does not today) cannot make the panel show a stale answer.
    func testStatusIndexLastRowWins() {
        let index = MachineStatusIndex([
            MachineStatus(id: "a", label: "one", status: "error", error: "x"),
            MachineStatus(id: "a", label: "one", status: "reachable"),
        ])
        XCTAssertEqual(index.count, 1)
        XCTAssertEqual(index.reachability(for: "a"), .reachable)
    }

    // MARK: - roster path

    /// The path the app watches has to be the file `herdr machine list` reads,
    /// or the watch reports a change nobody reads (issue #69).
    ///
    /// Upstream builds it as `state_dir()/client/endpoints.json`, and `state_dir()`
    /// is `$HOME/.local/state/herdr` on every non-Windows platform. Verified
    /// against herdr 0.9.5 by hand: a fake `HOME` holding
    /// `.local/state/herdr/client/endpoints.json` was the one `machine list`
    /// reported.
    func testRosterPathFollowsHome() {
        let client = HerdrMachineClient(
            executable: URL(fileURLWithPath: "/bin/true"),
            home: "/tmp/kraal-probe-home"
        )
        XCTAssertEqual(
            client.rosterPath(environment: ["HOME": "/tmp/other"]),
            "/tmp/kraal-probe-home/.local/state/herdr/client/endpoints.json"
        )
    }

    /// `KRAAL_HERDR_HOME` is what isolates a dev session's roster, so the watch must
    /// follow it rather than the app's own `$HOME` — otherwise a sandboxed session
    /// would react to the user's real machines being edited.
    func testRosterPathPrefersTheInjectedHome() {
        let client = HerdrMachineClient(
            executable: URL(fileURLWithPath: "/bin/true"),
            home: nil
        )
        XCTAssertEqual(
            client.rosterPath(environment: ["HOME": "/tmp/plain-home"]),
            "/tmp/plain-home/.local/state/herdr/client/endpoints.json"
        )
    }

    /// `XDG_STATE_HOME` wins over `$HOME` in herdr's `state_dir()` — measured:
    /// with both set, `machine list` read the XDG file. A watch on the `$HOME` path
    /// would then be watching a file herdr never reads.
    func testRosterPathHonoursXDGStateHome() {
        let client = HerdrMachineClient(
            executable: URL(fileURLWithPath: "/bin/true"),
            home: "/tmp/ignored-home"
        )
        XCTAssertEqual(
            client.rosterPath(environment: [
                "HOME": "/tmp/ignored-home",
                "XDG_STATE_HOME": "/tmp/xdg-state",
            ]),
            "/tmp/xdg-state/herdr/client/endpoints.json"
        )
    }

    /// A debug build of herdr keeps its state under `herdr-dev`, so watching
    /// `herdr` there would watch the wrong tree.
    func testRosterPathKnowsTheDevelopmentName() {
        let client = HerdrMachineClient(
            executable: URL(fileURLWithPath: "/bin/true"),
            home: "/tmp/kraal-probe-home"
        )
        XCTAssertEqual(
            client.rosterPath(development: true, environment: ["HOME": "/tmp/kraal-probe-home"]),
            "/tmp/kraal-probe-home/.local/state/herdr-dev/client/endpoints.json"
        )
    }
}
