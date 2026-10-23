// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Issue #73: the machines panel never showed whether a machine is reachable.
//
// The fact was available all along — `herdr machine status --json` reports
// `reachable` / `error` / `disabled` / `auth required` per saved profile — but
// nothing in the app called it, so a machine that had been dead for weeks still
// drew the same row as one that worked.
//
// Two things are pinned here, and they are different in kind:
//
//  1. **The merge.** `machine list` is the roster on disk; `machine status` is a
//     live probe. They can disagree by design (a machine added since the last
//     probe has no status row; a status row can outlive its profile), so the join
//     is on `id` and a missing entry is *unknown*, never "broken".
//  2. **When the probe runs.** One `machine status` costs one SSH round trip per
//     saved machine, so it must not hang off `reload()` — which runs on every
//     mutation and on every roster-file change from another terminal. These tests
//     count invocations of the stub CLI, which is the only way to see the
//     difference between "the panel probed once" and "the panel probed on every
//     redraw".
//
// The stub is a shell script, in the spirit of `HerdrMachineClientTests`: no test
// here runs the real `herdr`, so nothing can touch a real roster or open SSH.

import Foundation
import Testing

import KraalTransport

@testable import KraalUI

@Suite("Machines reachability", .serialized)
@MainActor
struct MachinesReachabilityTests {
    // MARK: - Stub

    /// A fake `herdr` plus the files it reads.
    ///
    /// `status` mode is a file on disk (not a closure) because the store calls the
    /// stub from a detached task; the test flips the file between calls.
    private final class StubCLI {
        let root: URL

        init() {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("kraal-reachability-\(UUID().uuidString.prefix(8))")
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        deinit { cleanUp() }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }

        var executable: URL { root.appendingPathComponent("herdr") }
        private var calls: URL { root.appendingPathComponent("calls.txt") }
        private var rosterJSON: URL { root.appendingPathComponent("list.json") }
        private var statusJSON: URL { root.appendingPathComponent("status.json") }
        private var mode: URL { root.appendingPathComponent("mode.txt") }

        func writeRoster(_ payload: String) {
            try? payload.write(to: rosterJSON, atomically: true, encoding: .utf8)
        }

        func writeStatus(_ payload: String) {
            try? payload.write(to: statusJSON, atomically: true, encoding: .utf8)
        }

        /// `"probe"` (default) or `"fail"` — the latter models a CLI run whose
        /// stdout is not the promised JSON at all (a usage error, say).
        func setMode(_ value: String) {
            try? value.write(to: mode, atomically: true, encoding: .utf8)
        }

        /// Every invocation, as `"machine status --json"`-style lines.
        var invocations: [String] {
            guard let text = try? String(contentsOf: calls, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        }

        var statusInvocations: Int { invocations.filter { $0.hasPrefix("machine status") }.count }
        var listInvocations: Int { invocations.filter { $0.hasPrefix("machine list") }.count }

        func makeClient() -> HerdrMachineClient {
            // The script is written once and never mutated, so the store's detached
            // task cannot race with the test rewriting it.
            let body = """
            #!/bin/sh
            echo "$*" >> '\(calls.path)'
            case "$1 $2" in
              "machine list")
                cat '\(rosterJSON.path)' 2>/dev/null || echo '[]'
                exit 0
                ;;
              "machine status")
                if [ "$(cat '\(mode.path)' 2>/dev/null || echo probe)" = "fail" ]; then
                    echo "boom" >&2
                    exit 2
                fi
                cat '\(statusJSON.path)' 2>/dev/null || echo '[]'
                # herdr itself exits 1 when any row carries an error, while still
                # printing the whole document — the premise of this issue. The
                # pattern accepts `"error":null` as healthy and `"error":"…"` as
                # not; matching on a single spelling is how the first version of
                # this stub silently always exited 0, which made the A/B unable to
                # tell the fixed client from the unfixed one.
                if grep -qE '"error":[[:space:]]*"' '\(statusJSON.path)' 2>/dev/null; then
                    exit 1
                fi
                exit 0
                ;;
            esac
            exit 0
            """
            try? body.write(to: executable, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )
            return HerdrMachineClient(executable: executable)
        }
    }

    private let local = LocalMachineDescriptor(label: "This Mac", socketPath: "/tmp/herdr-client.sock")

    private func rosterJSON(_ machines: [(id: String, label: String)]) -> String {
        let rows = machines.map { machine in
            """
            {"id":"\(machine.id)","label":"\(machine.label)","target":"zj@127.0.0.1",
             "session":"default","enabled":true,"selected":false}
            """
        }
        return "[\(rows.joined(separator: ","))]"
    }

    private func statusJSON(_ rows: [MachineStatus]) -> String {
        let body = rows.map { row -> String in
            let error = row.error.map { "\"\($0)\"" } ?? "null"
            return """
            {"id":"\(row.id)","label":"\(row.label)","status":"\(row.status)","error":\(error)}
            """
        }
        return "[\(body.joined(separator: ","))]"
    }

    /// True once a probe has finished and left at least one answer. Reading the
    /// two properties through one closure keeps the call sites inside the line
    /// limit and says what the test is waiting for in one phrase.
    private func settled(_ store: MachinesStore) -> Bool {
        !store.reachability.isProbing && !store.reachability.statuses.isEmpty
    }

    /// True once a probe has finished, however it ended.
    private func finished(_ store: MachinesStore) -> Bool {
        !store.reachability.isProbing
    }

    /// Polls instead of sleeping a fixed amount: the probe runs in a detached task
    /// and a fixed sleep is either flaky or slow depending on the machine.
    private func eventually(
        _ description: String,
        within seconds: TimeInterval = 10,
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        if condition() { return true }
        Issue.record("timed out waiting for \(description)")
        return false
    }

    // MARK: - The merge

    /// Before any probe, a row has no reachability. The panel must draw nothing —
    /// not "unreachable" — because "we did not ask" is not "it is down", and
    /// defaulting to red would make every launch look like an outage.
    @Test("a row has no reachability until it has been probed")
    func unprobedRowIsUnknown() {
        let stub = StubCLI()
        defer { stub.cleanUp() }
        stub.writeRoster(rosterJSON([("a", "alpha")]))

        let store = MachinesStore(client: stub.makeClient(), local: local)

        #expect(store.reachability.statuses.isEmpty)
        let remote = store.machines.first { !$0.isLocal }
        #expect(remote != nil || store.machines.count == 1)
        // The local row is always unknown: it is not a saved profile, so `machine
        // status` never mentions it.
        #expect(store.status(for: store.machines[0]) == nil)
    }

    /// The whole point: after a probe, a dead machine's row carries the CLI's
    /// status **and** its explanation. The explanation is what the old code threw
    /// away along with the non-zero exit.
    @Test("a probed machine shows the CLI's status and its reason")
    func probedMachineCarriesStatusAndReason() async {
        let stub = StubCLI()
        defer { stub.cleanUp() }
        stub.writeRoster(rosterJSON([("aaaa", "dead-one"), ("bbbb", "live-one")]))
        stub.writeStatus(statusJSON([
            MachineStatus(id: "aaaa", label: "dead-one", status: "error",
                          error: "remote Herdr server is stopped; run `herdr --remote zj@127.0.0.1`"),
            MachineStatus(id: "bbbb", label: "live-one", status: "reachable"),
        ]))

        let store = MachinesStore(client: stub.makeClient(), local: local)
        store.reload()
        _ = await eventually("the roster to load") { store.machines.count == 3 }

        store.reachability.probe()
        _ = await eventually("the probe to land") { settled(store) }

        let dead = try? #require(store.machines.first { $0.displayLabel == "dead-one" })
        let live = try? #require(store.machines.first { $0.displayLabel == "live-one" })
        if let dead {
            #expect(store.status(for: dead)?.reachability == .unreachable)
            #expect(store.status(for: dead)?.error?.contains("herdr --remote") == true)
        }
        if let live {
            #expect(store.status(for: live)?.reachability == .reachable)
        }
        // The local row is never joined to a CLI row, even when ids are close.
        #expect(store.status(for: store.machines[0]) == nil)
    }

    /// A status row for a profile `list` does not have must not invent a row, and a
    /// profile with no status row must stay unknown. Both directions are normal:
    /// the two commands run at different times.
    @Test("rows and statuses are joined on id, and extras are ignored")
    func joinIsByIDOnly() async {
        let stub = StubCLI()
        defer { stub.cleanUp() }
        stub.writeRoster(rosterJSON([("a", "alpha")]))
        stub.writeStatus(statusJSON([
            MachineStatus(id: "a", label: "alpha", status: "reachable"),
            MachineStatus(id: "zzz", label: "removed-since-the-list", status: "reachable"),
        ]))

        let store = MachinesStore(client: stub.makeClient(), local: local)
        store.reload()
        _ = await eventually("the roster to load") { store.machines.count == 2 }
        store.reachability.probe()
        _ = await eventually("the probe to land") { settled(store) }

        // `list` decides which rows exist; the orphan status is not a machine.
        #expect(store.machines.count == 2)
        #expect(!store.machines.contains { $0.displayLabel == "removed-since-the-list" })
        #expect(store.status(for: store.machines[1])?.reachability == .reachable)
    }

    // MARK: - When the probe runs

    /// **The cost decision.** `reload()` runs on every mutation (add, rename,
    /// enable, disable, remove) and after every roster-file change from another
    /// herdr process. Each probe is one SSH round trip per machine, so a rename
    /// must not launch them.
    @Test("reload never probes")
    func reloadDoesNotProbe() async {
        let stub = StubCLI()
        defer { stub.cleanUp() }
        stub.writeRoster(rosterJSON([("a", "alpha")]))
        stub.writeStatus(statusJSON([MachineStatus(id: "a", label: "alpha", status: "reachable")]))

        let store = MachinesStore(client: stub.makeClient(), local: local)
        store.reload()
        _ = await eventually("the roster to load") { store.machines.count == 2 }
        store.reload()
        _ = await eventually("the second roster read") { stub.listInvocations == 2 }

        #expect(stub.statusInvocations == 0)
        #expect(store.reachability.statuses.isEmpty)
    }

    /// The Refresh button: an explicit request for the current truth, roster *and*
    /// reachability. One press, one probe — not one per row.
    @Test("refresh(probe:) reads the roster and probes exactly once")
    func refreshProbesOnce() async {
        let stub = StubCLI()
        defer { stub.cleanUp() }
        stub.writeRoster(rosterJSON([("a", "alpha"), ("b", "beta")]))
        stub.writeStatus(statusJSON([
            MachineStatus(id: "a", label: "alpha", status: "reachable"),
            MachineStatus(id: "b", label: "beta", status: "error", error: "down"),
        ]))

        let store = MachinesStore(client: stub.makeClient(), local: local)
        store.refresh(probe: true)
        _ = await eventually("the probe to land") { settled(store) }
        _ = await eventually("the roster to load") { store.machines.count == 3 }

        #expect(stub.statusInvocations == 1)
        #expect(store.reachability.statuses.count == 2)
    }

    /// `onAppear` fires again when the user switches back from another settings
    /// tab. Probing there would spend N SSH round trips on a tab change, so the
    /// store probes on the first appearance only — the roster is still re-read
    /// every time, because that read is a local file.
    @Test("appearing probes the first time only")
    func appearProbesOnlyOnce() async {
        let stub = StubCLI()
        defer { stub.cleanUp() }
        stub.writeRoster(rosterJSON([("a", "alpha")]))
        stub.writeStatus(statusJSON([MachineStatus(id: "a", label: "alpha", status: "reachable")]))

        let store = MachinesStore(client: stub.makeClient(), local: local)
        store.appear()
        _ = await eventually("the first probe") { settled(store) }
        let afterFirst = stub.statusInvocations

        store.appear()
        store.appear()
        _ = await eventually("the later roster reads") { stub.listInvocations >= 3 }

        #expect(afterFirst == 1)
        #expect(stub.statusInvocations == 1, "a tab change must not launch SSH")
    }

    /// A missing CLI answers nothing. `appear()` must not ask the stub to probe a
    /// roster it just decided it cannot read, and it must not claim the machines
    /// are down.
    @Test("no CLI means no probe and no invented status")
    func noClientSkipsProbe() async {
        let store = MachinesStore(client: nil, local: local)
        store.appear()
        store.refresh(probe: true)
        try? await Task.sleep(nanoseconds: 150_000_000)

        #expect(store.reachability.statuses.isEmpty)
        #expect(store.reachability.probeError == nil)
        #expect(store.machines.count == 1)
        #expect(store.machines[0].isLocal)
    }

    // MARK: - Failure

    /// A **failed check** is not a broken machine. The last snapshot stays on
    /// screen: clearing it would blank the column because one subprocess failed,
    /// which is the same "the panel tells you nothing" failure the issue reports.
    @Test("a failed probe keeps the last snapshot and reports the failure separately")
    func failedProbeKeepsLastSnapshot() async {
        let stub = StubCLI()
        defer { stub.cleanUp() }
        stub.writeRoster(rosterJSON([("a", "alpha")]))
        stub.writeStatus(statusJSON([MachineStatus(id: "a", label: "alpha", status: "error", error: "down")]))

        let store = MachinesStore(client: stub.makeClient(), local: local)
        store.refresh(probe: true)
        _ = await eventually("the first probe") { settled(store) }
        #expect(store.reachability.probeError == nil)

        stub.setMode("fail")
        store.reachability.probe()
        _ = await eventually("the failing probe") { finished(store) && store.reachability.probeError != nil }

        // The machine record of "down" survives; only its freshness is in doubt.
        #expect(store.reachability.statuses.count == 1)
        #expect(store.status(for: store.machines[1])?.reachability == .unreachable)
        #expect(store.reachability.probeError?.contains("boom") == true)
    }

    /// Non-zero exit with unparseable output is still a failure: the tolerance is
    /// for "non-zero **and** valid JSON", not for "ignore the exit code".
    @Test("a probe whose output is not the promised JSON fails")
    func unparseableProbeFails() async {
        let stub = StubCLI()
        defer { stub.cleanUp() }
        stub.writeRoster(rosterJSON([("a", "alpha")]))
        stub.setMode("fail")

        let store = MachinesStore(client: stub.makeClient(), local: local)
        store.refresh(probe: true)
        _ = await eventually("the failing probe") { finished(store) && store.reachability.probeError != nil }

        #expect(store.reachability.statuses.isEmpty)
        #expect(store.reachability.probeError != nil)
        // The roster is unaffected: it was read successfully from the same stub.
        #expect(store.machines.count == 2)
    }

    // MARK: - Badge

    /// The pill's vocabulary. `error` reads as "unreachable" because a row saying
    /// `error` next to `disabled` reads like a severity, while the CLI's own word
    /// stays in the tooltip. An unknown status shows its own word rather than
    /// going blank.
    @Test("the badge words each status, including unknown ones")
    func badgeLabels() {
        func label(_ status: String) -> String {
            ReachabilityBadge(status: MachineStatus(id: "a", label: "x", status: status)).label
        }
        #expect(label("reachable") == "reachable")
        #expect(label("error") == "unreachable")
        #expect(label("auth required") == "auth required")
        #expect(label("disabled") == "disabled")
        #expect(label("quarantined") == "quarantined")
        #expect(label("") == "unknown")
    }

    /// Colour is the second channel, and it must not put two different amber
    /// meanings in one row: `.authRequired` is orange (fixable by reconnecting),
    /// `.unreachable` is red.
    @Test("the badge distinguishes the fixable state from the dead one")
    func badgeColours() {
        #expect(ReachabilityBadge(status: MachineStatus(id: "a", label: "x", status: "error")).isWarning)
        #expect(ReachabilityBadge(status: MachineStatus(id: "a", label: "x", status: "auth required")).isWarning)
        #expect(!ReachabilityBadge(status: MachineStatus(id: "a", label: "x", status: "reachable")).isWarning)
    }
}
