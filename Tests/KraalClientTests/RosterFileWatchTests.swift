// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Issue #69: the machine roster was only re-read at launch and after the machines
// dialog wrote a profile, so a change made by anything else — another terminal,
// a second Kraal window, `herdr update` rewriting the file — never showed up.
//
// The roster is `~/.local/state/herdr/client/endpoints.json`, shared by every
// herdr process on the account, so "somebody else changed it" is the normal case.
// These tests use a temporary file in that role, so none of them runs `herdr` and
// none of them can touch the developer's real roster.
//
// What is pinned, in the order the bug bites:
//
//  1. an **atomic** replacement (write a temp file, `rename(2)` it into place) is
//     seen — and seen again, because the first replacement leaves the open
//     descriptor pointing at an unlinked inode. Measured before the fix: the old
//     fd reported one event across four replacements and then went silent.
//  2. creating the file when it did not exist is seen, by watching the directory.
//  3. a reload that arrives while another is running is not swallowed: every
//     caller returns a roster read at or after the moment it asked.
//  4. the whole way through: a change on disk makes the *store* grow a row.

import Foundation
import Testing

import KraalTransport

@testable import KraalUI

@Suite("Roster file watch", .serialized)
struct RosterFileWatchTests {
    // MARK: - Fixtures

    /// A scratch tree holding one `endpoints.json`, standing in for
    /// `~/.local/state/herdr/client/`. Removed before and after each test.
    private final class ScratchRoster {
        let directory: URL

        init() {
            directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("kraal-roster-\(UUID().uuidString.prefix(8))")
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(
                at: directory.appendingPathComponent(".local/state/herdr/client"),
                withIntermediateDirectories: true
            )
        }

        /// The directory the loader watches — deep enough that "watch the parent"
        /// has to mean this one and not the scratch root.
        var clientDirectory: URL {
            directory.appendingPathComponent(".local/state/herdr/client")
        }

        var path: URL { clientDirectory.appendingPathComponent("endpoints.json") }
        var pathString: String { path.path }

        func write(_ machines: [HerdrMachine]) {
            writeData((try? JSONEncoder().encode(machines)) ?? Data())
        }

        /// What `herdr` does: write a sibling temp file, `rename(2)` it over the
        /// target (`src/client/endpoint/catalog.rs:349-370`).
        ///
        /// The raw call is deliberate. `FileManager.replaceItemAt` is *not* the
        /// same thing — it goes through `renamex_np`/`exchangedata`, which can
        /// leave the inode in place, and a test written with it would pass against
        /// a watcher that never re-opens the path.
        func atomicWrite(_ machines: [HerdrMachine]) {
            atomicWrite((try? JSONEncoder().encode(machines)) ?? Data())
        }

        func atomicWrite(_ payload: Data) {
            let temp = clientDirectory
                .appendingPathComponent(".endpoints-\(getpid())-\(Int.random(in: 0..<9999)).tmp")
            do {
                try payload.write(to: temp)
            } catch {
                Issue.record("could not stage the temp file: \(error)")
                return
            }
            guard rename(temp.path, path.path) == 0 else {
                Issue.record("rename(2) failed: \(String(cString: strerror(errno)))")
                try? FileManager.default.removeItem(at: temp)
                return
            }
        }

        func writeData(_ data: Data) {
            do {
                try data.write(to: path)
            } catch {
                Issue.record("could not write the roster: \(error)")
            }
        }

        func removeFile() {
            try? FileManager.default.removeItem(at: path)
        }

        func removeTree() {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(".local"))
        }

        /// Everything, including the directories: a leftover tree in the shared
        /// temp directory is how a later test would "start" with a roster it never
        /// wrote.
        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// A saved profile, in the shape `herdr machine list --json` reports.
    ///
    /// The target is deliberately one Kraal cannot dial (`ssh://` with no
    /// authority), so `rebuildEndpoints` marks the row disabled and
    /// `connectMissingEndpoints` never opens an ssh subprocess for it. What these
    /// tests watch is the row appearing, not a connection.
    private func profile(
        id: String = "191645f46cf4bc677a393cf0ca51d193",
        label: String = "nj-mac"
    ) -> HerdrMachine {
        HerdrMachine(id: id, label: label, target: "ssh://", session: "default",
                     enabled: true, selected: false)
    }

    private func id(_ character: Character) -> String {
        String(repeating: String(character), count: 32)
    }

    /// Polls until `condition` holds, so no test depends on a fixed sleep being
    /// long enough on a loaded machine.
    @MainActor
    @discardableResult
    private func eventually(
        _ description: String,
        within seconds: TimeInterval = 8,
        _ condition: @escaping @MainActor () -> Bool
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

    /// A loader reading from `scratch` instead of running `herdr`.
    @MainActor
    private func loader(
        reading path: String,
        read: @escaping @Sendable () throws -> [HerdrMachine]
    ) -> EndpointCatalogLoader {
        EndpointCatalogLoader(
            local: LocalMachineDescriptor(label: "This Mac", socketPath: "/tmp/herdr-client.sock"),
            source: MachineRosterSource(path: path, read: read)
        )
    }

    /// A store whose machines come from `path` and whose one dialable row (Local)
    /// points at a socket that does not exist. Without that override the local row
    /// would dial the developer's real daemon.
    @MainActor
    private func store(reading path: String) -> AppStore {
        let store = AppStore(
            target: .local,
            rosterSource: MachineRosterSource(path: path) { try readRosterFile(path) }
        )
        store.discoveryEnvironment = ["KRAAL_HERDR_SOCKET": "/tmp/kraal-nonexistent-\(UUID().uuidString).sock"]
        return store
    }

    // MARK: - 1. atomic replacement

    /// **Trap 1.** `herdr machine add` does not edit the file; it writes a temp
    /// file and `rename(2)`s it into place. The descriptor held from before the
    /// rename refers to an inode with no name left.
    ///
    /// The watch has two arms, and only this one discriminates: the directory arm
    /// also sees a rename (measured — it reports the entry change), so a test that
    /// only replaces the file passes even when the file arm is never re-opened.
    /// An **in-place** write is different: measured on this Mac, it reaches the
    /// file arm only (`FILE event raw=6`; the directory arm says nothing). So the
    /// assertion that pins the re-arm is: replace the file (killing the fd), then
    /// rewrite it in place. Without the re-open the second write is invisible
    /// forever.
    @Test("an in-place write is still noticed after the file was replaced")
    func inPlaceWriteSurvivesAReplacement() async throws {
        let scratch = ScratchRoster()
        defer { scratch.cleanUp() }
        scratch.write([profile(label: "m-one")])

        let counter = Counter()
        let watcher = RosterFileWatcher(path: scratch.pathString, debounce: 0.05) {
            counter.bump()
        }
        defer { watcher.stop() }
        watcher.start()
        #expect(watcher.isWatchingFile,
                "the file arm never mounted, so nothing below proves anything")

        // A rename into place: the inode the file arm is holding is unlinked here.
        scratch.atomicWrite([profile(label: "m-one"), profile(id: id("b"), label: "m-two")])
        let sawReplace = await eventually("the replacement to be reported") { counter.value >= 1 }
        #expect(sawReplace, "the replacement itself was not reported")
        try? await Task.sleep(nanoseconds: 200_000_000)
        let afterReplace = counter.value

        // An in-place rewrite of the same path. Only a file arm that re-opened the
        // path can see this; a stale one is pointing at the unlinked inode, and the
        // directory arm does not fire for it.
        scratch.write([profile(label: "m-one"), profile(id: id("b"), label: "m-three")])
        let sawInPlace = await eventually("the in-place write to be reported") {
            counter.value > afterReplace
        }
        print("in-place after replace: reports=\(counter.value) (at replace: \(afterReplace))")
        #expect(
            sawInPlace,
            "the watch went silent after the rename: the file arm never re-opened the path"
        )
    }

    /// The everyday case behind the issue: `herdr machine add` runs twice, so the
    /// file is replaced twice, and both have to land. Also the shape a user hits
    /// without touching anything by hand — every `machine add`/`remove`/`rename`
    /// rewrites the whole file this way.
    @Test("a roster replaced atomically is noticed again and again")
    func atomicReplacementIsSeenRepeatedly() async throws {
        let scratch = ScratchRoster()
        defer { scratch.cleanUp() }
        scratch.write([profile(label: "m-one")])

        let counter = Counter()
        let watcher = RosterFileWatcher(path: scratch.pathString, debounce: 0.05) {
            counter.bump()
        }
        defer { watcher.stop() }
        watcher.start()
        #expect(watcher.isWatchingFile,
                "the file arm never mounted, so nothing below proves anything")

        for round in 1...3 {
            scratch.atomicWrite([profile(label: "m-one"), profile(id: id("b"), label: "m-\(round)")])
            let seen = await eventually("replacement \(round) to be reported") {
                counter.value >= round
            }
            #expect(seen, "replacement \(round) was not reported (reports: \(counter.value))")
        }
        print("atomic replacement: 3 rename(2) writes -> \(counter.value) report(s)")
    }

    // MARK: - 2. the file does not exist yet

    /// **Trap 2.** A fresh account has no roster file at all, and a path that does
    /// not exist cannot be watched. The directory has to carry the watch until the
    /// file appears.
    @Test("creating the roster when there was none is noticed")
    func creationIsSeen() async throws {
        let scratch = ScratchRoster()
        defer { scratch.cleanUp() }
        scratch.removeFile()

        let counter = Counter()
        let watcher = RosterFileWatcher(path: scratch.pathString, debounce: 0.05) {
            counter.bump()
        }
        defer { watcher.stop() }
        watcher.start()
        #expect(!watcher.isWatchingFile, "a missing file must not mount a file arm")
        #expect(watcher.watchedDirectory == scratch.clientDirectory.path,
                "the directory arm is on \(watcher.watchedDirectory), not the roster's directory")

        // What `herdr machine add` does on a fresh install: the file appears.
        scratch.write([profile(label: "first-ever")])

        let seen = await eventually("the created roster to be reported") { counter.value >= 1 }
        #expect(seen, "creating the roster was not noticed")
        let mounted = await eventually("the file arm to mount") { watcher.isWatchingFile }
        #expect(mounted, "the watch never moved onto the file it can now open")
    }

    /// A deeper version of the same trap: nothing under `~/.local/state/herdr`
    /// exists, so the nearest watchable ancestor is the scratch root three levels
    /// above. The watch has to walk down as the tree is created.
    @Test("a roster appearing inside a tree that did not exist is noticed")
    func deepCreationIsSeen() async throws {
        let scratch = ScratchRoster()
        defer { scratch.cleanUp() }
        scratch.removeTree()

        let counter = Counter()
        let watcher = RosterFileWatcher(path: scratch.pathString, debounce: 0.05) {
            counter.bump()
        }
        defer { watcher.stop() }
        watcher.start()
        #expect(watcher.watchedDirectory == scratch.directory.path,
                "the fallback should be the nearest existing ancestor, got \(watcher.watchedDirectory)")

        try FileManager.default.createDirectory(
            at: scratch.clientDirectory,
            withIntermediateDirectories: true
        )
        scratch.write([profile(label: "planted")])

        let seen = await eventually("the roster planted three levels down to be reported") {
            counter.value >= 1
        }
        #expect(seen, "the watch never descended to the created directory")
    }

    // MARK: - 3. concurrent reloads

    /// The `guard !loading else { return machines }` this replaces handed the
    /// second caller the *pre-change* roster and skipped its refresh entirely.
    /// The contract now is: nobody returns a roster older than the disk was when
    /// they asked.
    ///
    /// The read is held inside a gate, so the second call is guaranteed to arrive
    /// while the first is genuinely in flight — not merely likely to.
    @Test("a reload arriving during another is not swallowed")
    @MainActor
    func concurrentReloadIsNotSwallowed() async throws {
        let scratch = ScratchRoster()
        defer { scratch.cleanUp() }
        scratch.write([profile(label: "m-one")])

        let gate = ReadGate()
        let path = scratch.pathString
        let loader = loader(reading: path) {
            // The gate sits *before* the file is read, so whatever the first read
            // returns reflects the disk as it is when the gate opens. That makes
            // "the second caller must see the change" a statement about ordering
            // rather than about which goroutine won.
            gate.enterAndWait()
            return try readRosterFile(path)
        }
        defer { loader.stopWatchingRoster() }

        let first = Task { @MainActor in await loader.reload() }
        // Wait until the first read is inside the source, so the second call
        // cannot slip in before it started.
        _ = await eventually("the first read to enter the source") { gate.entries >= 1 }

        // The external change, made while the first read is parked.
        scratch.atomicWrite([profile(label: "m-one"), profile(id: id("c"), label: "m-two")])

        let second = Task { @MainActor in await loader.reload() }
        // Coalescing: a waiting caller must not spawn a read of its own. Without
        // this the fix would "work" while running one subprocess per caller.
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(gate.entries == 1, "the second call started its own read instead of waiting")

        gate.release()
        let firstRoster = await first.value
        let secondRoster = await second.value

        print("concurrent reload: first=\(firstRoster.map(\.displayLabel)) "
            + "second=\(secondRoster.map(\.displayLabel)) "
            + "loader=\(loader.machines.map(\.displayLabel)) reads=\(gate.entries)")

        #expect(
            secondRoster.map(\.displayLabel) == ["This Mac", "m-one", "m-two"],
            "the second caller got \(secondRoster.map(\.displayLabel)), not the post-change roster"
        )
        #expect(
            loader.machines.map(\.displayLabel) == ["This Mac", "m-one", "m-two"],
            "the loader kept \(loader.machines.map(\.displayLabel)) after every call returned"
        )
    }

    /// The same defect stated as the guarantee a caller needs: after a burst, no
    /// caller holds a value from before its own call. Before the fix the second
    /// call returned without reading at all.
    @Test("a caller always gets a roster read at or after the moment it asked")
    @MainActor
    func callerNeverGetsStaleRoster() async throws {
        let scratch = ScratchRoster()
        defer { scratch.cleanUp() }
        scratch.write([profile(label: "before")])

        let gate = ReadGate()
        let path = scratch.pathString
        let loader = loader(reading: path) {
            gate.enterAndWait()
            return try readRosterFile(path)
        }
        defer { loader.stopWatchingRoster() }

        let first = Task { @MainActor in await loader.reload() }
        _ = await eventually("the first read to enter the source") { gate.entries >= 1 }

        scratch.write([profile(label: "after")])
        let second = Task { @MainActor in await loader.reload() }
        // Long enough that a second, independent read would have started and
        // finished by now — a second read is what the broken version does not
        // even bother with.
        try? await Task.sleep(nanoseconds: 150_000_000)
        gate.release()

        _ = await first.value
        let secondRoster = await second.value
        print("stale check: second saw \(secondRoster.map(\.displayLabel))")
        #expect(
            secondRoster.map(\.displayLabel) == ["This Mac", "after"],
            "the second caller was handed the pre-change roster: \(secondRoster.map(\.displayLabel))"
        )
    }

    // MARK: - 4. end to end: the store grows a row

    /// The assertion the issue is written about: the sidebar's machine list, not
    /// the file.
    @Test("a machine added on disk appears in the store's endpoints")
    @MainActor
    func diskChangeReachesTheStore() async throws {
        let scratch = ScratchRoster()
        defer { scratch.cleanUp() }
        scratch.write([profile(label: "m-one")])

        let store = store(reading: scratch.pathString)
        await store.loadEndpoints()
        defer { store.endpointCatalog.stopWatchingRoster() }

        #expect(store.endpoints.map(\.label) == ["Local", "m-one"],
                "the store did not load the roster at all: \(store.endpoints.map(\.label))")
        #expect(store.endpointCatalog.isWatchingRoster,
                "the store's loader is not watching the roster")

        // `herdr machine add` from another process on the same account.
        scratch.atomicWrite([profile(label: "m-one"), profile(id: id("d"), label: "m-two")])

        let appeared = await eventually("m-two to appear in the store") {
            store.endpoints.map(\.label) == ["Local", "m-one", "m-two"]
        }
        print("store wiring: endpoints=\(store.endpoints.map(\.label)) "
            + "watching=\(store.endpointCatalog.watchedRosterPath ?? "none")")
        #expect(appeared, "the disk change never reached the store: \(store.endpoints.map(\.label))")
    }

    /// The flip side — the "do not disconnect what is already connected" rule.
    ///
    /// A roster change must not re-dial a machine that is already up. This is the
    /// one assertion that makes wiring the watch safe: without it, every
    /// `herdr machine add` by anyone on the account would tear down every live
    /// connection in this window and handshake again, which a user sees as the
    /// pane going blank and the badge flashing `connecting`.
    ///
    /// Checked against a **real socket**, not by object identity: an `AppStore`
    /// whose local row dials a peer that answers the handshake, then a roster write
    /// from outside. The connection the store holds has to be the same object
    /// afterwards, and it has to still be live.
    @Test("a roster change does not re-dial a machine that is already connected")
    @MainActor
    func rosterChangeKeepsLiveConnections() async throws {
        let scratch = ScratchRoster()
        defer { scratch.cleanUp() }
        scratch.write([profile(label: "m-one")])

        let peer = try ScriptedSocketPeer(reply: try HandshakeDeadlineTests.welcomeFrame())
        peer.startAccepting()
        defer { peer.stop() }

        let store = AppStore(
            target: .local,
            rosterSource: MachineRosterSource(path: scratch.pathString) { try readRosterFile(scratch.pathString) }
        )
        store.discoveryEnvironment = ["KRAAL_HERDR_SOCKET": peer.path]
        await store.loadEndpoints()
        defer {
            store.endpointCatalog.stopWatchingRoster()
            store.disconnectAllEndpoints()
        }

        store.connect()
        let connected = await eventually("the local machine to handshake") { () -> Bool in
            guard let local = store.endpoints.first(where: { $0.id == .local }) else { return false }
            return local.connection != nil && local.connectionTask == nil
        }
        guard connected else {
            Issue.record("the local machine never connected, so nothing below means anything")
            return
        }

        guard let before = store.endpoints.first(where: { $0.id == .local })?.connection else {
            Issue.record("no local connection object")
            return
        }
        let epochBefore = store.endpoints.first(where: { $0.id == .local })?.connectionEpoch ?? -1

        // The external change, delivered through the file watch.
        scratch.atomicWrite([profile(label: "m-one"), profile(id: id("e"), label: "m-two")])
        let grew = await eventually("the new machine to be added") {
            store.endpoints.map(\.label) == ["Local", "m-one", "m-two"]
        }
        #expect(grew, "the roster change never arrived: \(store.endpoints.map(\.label))")

        let after = store.endpoints.first(where: { $0.id == .local })
        let epochAfter = after?.connectionEpoch ?? -2
        #expect(
            after?.connection === before,
            "the local machine was re-dialled: its connection object was replaced"
        )
        #expect(
            epochAfter == epochBefore,
            "the local connection's epoch moved \(epochBefore) -> \(epochAfter), so a new attempt was started"
        )
        #expect(after?.connectionTask == nil, "a fresh connect was started for a connected machine")
    }

    /// The flip side of the row-identity test below: rows that are still in the
    /// roster keep their objects.
    @Test("a roster change does not rebuild the rows it already has")
    @MainActor
    func rosterChangeKeepsExistingRows() async throws {
        let scratch = ScratchRoster()
        defer { scratch.cleanUp() }
        scratch.write([profile(label: "m-one")])

        let store = store(reading: scratch.pathString)
        await store.loadEndpoints()
        defer { store.endpointCatalog.stopWatchingRoster() }

        let before = store.endpoints.map { ($0.id, ObjectIdentifier($0)) }
        guard store.endpoints.count == 2 else {
            Issue.record("expected Local + m-one, got \(store.endpoints.map(\.label))")
            return
        }

        scratch.atomicWrite([
            profile(label: "m-one-renamed"),
            profile(id: id("d"), label: "m-two"),
        ])

        let renamed = await eventually("m-one to be renamed in place") {
            store.endpoints.contains { $0.label == "m-one-renamed" }
        }
        #expect(renamed, "the rename never landed: \(store.endpoints.map(\.label))")

        let after = store.endpoints.map { ($0.id, ObjectIdentifier($0)) }
        #expect(after.count == 3, "expected Local + two machines, got \(after.map(\.0))")
        #expect(
            after[0].1 == before[0].1,
            "the local row was replaced instead of updated, dropping its connection"
        )
        #expect(
            after[1].1 == before[1].1,
            "m-one's row was replaced instead of updated, dropping its connection"
        )
    }

    /// A stopped watch reports nothing, and stopping is idempotent (it is called
    /// from `deinit` as well as from the owner's teardown).
    @Test("a stopped watch stops reporting")
    func stopIsSilent() async throws {
        let scratch = ScratchRoster()
        defer { scratch.cleanUp() }
        scratch.write([profile(label: "m-one")])

        let counter = Counter()
        let watcher = RosterFileWatcher(path: scratch.pathString, debounce: 0.05) {
            counter.bump()
        }
        watcher.start()
        watcher.stop()
        watcher.stop()
        #expect(!watcher.isWatchingFile, "a stopped watcher still holds a file arm")

        scratch.atomicWrite([profile(label: "ignored")])
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(counter.value == 0, "a stopped watch reported \(counter.value) change(s)")
    }
}

// MARK: - Helpers

/// Reads the roster file the way `herdr machine list` would.
private func readRosterFile(_ path: String) throws -> [HerdrMachine] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return try JSONDecoder().decode([HerdrMachine].self, from: data)
}

/// A counter the watcher's background callback can bump.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func bump() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// Holds a source read open so a test can make a second call arrive while the
/// first is genuinely in flight.
///
/// `NSCondition` rather than a `DispatchSemaphore`: the read it blocks runs in a
/// detached task off the main actor (that is where production puts the herdr
/// subprocess), so the wait is on a background thread and never on the actor the
/// test is driving.
private final class ReadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entriesCount = 0
    private var open = false

    /// Blocks the calling thread until `release()`. Counts how many reads reached
    /// this point.
    func enterAndWait() {
        condition.lock()
        entriesCount += 1
        condition.broadcast()
        while !open {
            condition.wait()
        }
        condition.unlock()
    }

    /// How many source reads have started.
    var entries: Int {
        condition.lock()
        defer { condition.unlock() }
        return entriesCount
    }

    /// Lets every parked read through, and every later one too.
    func release() {
        condition.lock()
        open = true
        condition.broadcast()
        condition.unlock()
    }
}
