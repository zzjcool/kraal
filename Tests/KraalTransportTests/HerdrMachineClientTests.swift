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
}
