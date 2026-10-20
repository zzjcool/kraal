// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Live smoke test: drives the real `herdr machine` CLI end to end.
//
// Skipped unless KRAAL_LIVE_MACHINE_TESTS=1. It mutates machine profiles, so it
// must only run against an isolated HOME (the harness sets one), never the
// developer's own config.

import Foundation
import XCTest

@testable import KraalTransport

final class LiveMachineSmokeTests: XCTestCase {
    func testFullLifecycleAgainstRealCLI() throws {
        guard ProcessInfo.processInfo.environment["KRAAL_LIVE_MACHINE_TESTS"] == "1" else {
            throw XCTSkip("set KRAAL_LIVE_MACHINE_TESTS=1 and an isolated HOME to run")
        }
        guard let client = HerdrMachineClient.discover() else {
            throw XCTSkip("herdr not found")
        }

        // This test must never touch machines it did not create. It records what
        // existed first, and only ever removes the one temporary profile it adds.
        // A blanket "clear the list" would delete real saved hosts — an isolated
        // HOME makes that harmless, but the code must be correct regardless of
        // where it runs.
        let preexisting = Set(try client.list().map(\.id))
        let labelPrefix = "kraal-task2-temp"

        let created = try Self.addTemporary(client: client, labelPrefix: labelPrefix, preexisting: preexisting)
        defer {
            // Best effort: if an assertion throws, still try to remove our own
            // profile so repeated runs do not accumulate junk.
            try? client.remove(id: created)
        }

        var machines = try client.list()
        let added = try XCTUnwrap(machines.first { $0.id == created })
        XCTAssertEqual(added.label, labelPrefix)
        XCTAssertTrue(added.enabled)
        // The pre-existing machines are all still there.
        XCTAssertTrue(preexisting.isSubset(of: Set(machines.map(\.id))))

        try client.rename(id: created, label: labelPrefix + "-renamed")
        machines = try client.list()
        XCTAssertEqual(machines.first { $0.id == created }?.label, labelPrefix + "-renamed")

        try client.setEnabled(id: created, enabled: false)
        XCTAssertEqual(try client.list().first { $0.id == created }?.enabled, false)

        try client.setEnabled(id: created, enabled: true)
        XCTAssertEqual(try client.list().first { $0.id == created }?.enabled, true)

        try client.remove(id: created)
        let remaining = Set(try client.list().map(\.id))
        XCTAssertFalse(remaining.contains(created))
        // Nothing else disappeared.
        XCTAssertTrue(preexisting.isSubset(of: remaining))
    }

    /// Adds one temporary machine and returns its id, refusing to proceed if the
    /// CLI saved something we did not ask for.
    private static func addTemporary(
        client: HerdrMachineClient,
        labelPrefix: String,
        preexisting: Set<String>
    ) throws -> String {
        // The SSH target is supplied by the caller rather than hard-coded: this
        // file is published, and a real hostname here would both leak where the
        // author's machines live and make the test unusable for anyone else.
        let target = try XCTUnwrap(
            ProcessInfo.processInfo.environment["KRAAL_LIVE_MACHINE_TARGET"],
            "set KRAAL_LIVE_MACHINE_TARGET to an SSH target you own"
        )
        _ = try client.add(
            target: target,
            label: labelPrefix,
            remoteSession: nil
        )
        let added = try client.list().filter { !preexisting.contains($0.id) }
        XCTAssertEqual(added.count, 1, "expected exactly one new profile")
        return try XCTUnwrap(added.first).id
    }
}
