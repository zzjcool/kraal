// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Keeps the app's sidebar catalog in step with the saved-machine list.
//
// The machines dialog has its own store, because it also performs writes. The
// sidebar needs the same list for reading, and reading it from the dialog's store
// would mean the sidebar is empty until someone opens the dialog. So this runs
// the list command on the app's behalf and hands the result to
// `rebuildEndpoints(roster:)`.
//
// Refreshes are cheap: `herdr machine list` reads a JSON file and does not touch
// the network, but it is still a subprocess, so it runs off the main actor.
//
// **When** to refresh is the other half (issue #69). The roster file is shared by
// every herdr process on the account, so it is changed from outside this app all
// the time — another terminal, a second Kraal window, `herdr update`. Reloading
// only at launch and after the machines dialog writes meant every one of those
// changes was invisible until the app restarted. `RosterFileWatcher` watches the
// file (and the directory it lives in) and reports; the reload happens here.
//
// A third half is *coalescing*. Two callers arriving while one read is running
// used to have the second one return the pre-read value and skip its own refresh
// entirely, so a change could be seen once and then be silently overwritten by a
// caller that came in a moment later. `reload()` now guarantees that whatever a
// caller receives was read at or after the moment it asked.

import Foundation
import KraalTransport
import Observation

/// Where the catalog reads its saved-machine list from, and which file to watch.
///
/// Two fields because they are two facts about one thing: the CLI is the only
/// supported way to *read* the list, and the file it reads is the only way to
/// learn that the list *changed*. Tests replace both with a file, which keeps them
/// free of a subprocess and of any dependence on the developer's own roster.
public struct MachineRosterSource: Sendable {
    /// The roster file the CLI reads, or nil when it cannot be derived (no
    /// `$HOME`): the list still works, but there is nothing to watch.
    public var path: String?
    /// Runs `herdr machine list`. Called off the main actor.
    public var read: @Sendable () throws -> [HerdrMachine]

    public init(path: String?, read: @escaping @Sendable () throws -> [HerdrMachine]) {
        self.path = path
        self.read = read
    }

    /// The real thing: the CLI, plus the file that CLI reads.
    public static func live(
        client: HerdrMachineClient,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MachineRosterSource {
        MachineRosterSource(path: client.rosterPath(environment: environment)) {
            try client.list()
        }
    }
}

@MainActor
@Observable
public final class EndpointCatalogLoader {
    public private(set) var machines: [MachineEntry] = []
    public private(set) var error: String?
    /// False when the `herdr` CLI could not be found, which is not an error worth
    /// showing: a single-machine setup is the common case.
    public private(set) var available = true

    /// Called after a reload that was triggered by the roster file changing on
    /// disk, with the roster that reload produced.
    ///
    /// The reload itself happens here, not in the callback: the loader's own
    /// `machines` must be fresh whether or not anyone is listening. What the store
    /// needs to do with the result is fold it into `endpoints` — that is the only
    /// thing the loader cannot do, because the catalog belongs to the store.
    @ObservationIgnored public var onRosterChanged: (([MachineEntry]) -> Void)?

    @ObservationIgnored private let local: LocalMachineDescriptor
    /// Resolved on the first reload, then kept: discovery walks `$PATH` and the
    /// usual install locations, and the answer does not change while the app runs.
    @ObservationIgnored private var source: MachineRosterSource?
    @ObservationIgnored private var watcher: RosterFileWatcher?

    /// Coalescing state, both parts of one mechanism.
    ///
    /// `requests` numbers the calls: every `reload()` takes a ticket, and a read
    /// that starts after a call carries a ticket at least as high as that call's.
    /// `inFlight` is the read currently running. "Is there a read that started
    /// after I asked?" is then a comparison, which is what makes the guarantee
    /// checkable instead of hopeful.
    @ObservationIgnored private var requests = 0
    @ObservationIgnored private var inFlight: (ticket: Int, task: Task<[MachineEntry], Never>)?

    /// `source` is injectable so a test can read a temporary roster file instead of
    /// running a subprocess; production leaves it nil and discovery happens on the
    /// first reload.
    public init(local: LocalMachineDescriptor, source: MachineRosterSource? = nil) {
        self.local = local
        self.source = source
        machines = MachineRoster.compose(local: local, remote: [])
    }

    /// Whether the roster file is being watched right now. False before the first
    /// reload, and false when the path could not be derived.
    var isWatchingRoster: Bool { watcher != nil }

    /// The path being watched, for the same reason: "it did not work" and "it was
    /// watching the wrong file" look identical from the outside.
    var watchedRosterPath: String? { watcher == nil ? nil : source?.path }

    /// Stops watching the roster file. Called when the owning store goes away; also
    /// what a test asserts against, because a watcher left running holds a file
    /// descriptor and would report changes into a scene that no longer exists.
    public func stopWatchingRoster() {
        watcher?.stop()
        watcher = nil
    }

    /// Reads the saved profiles and returns them. Never throws: a missing CLI or a
    /// failed list leaves the previous roster in place, because losing every remote
    /// machine because one subprocess failed would empty the sidebar.
    ///
    /// Concurrent callers are serialised *and* made fresh. See `requests` for the
    /// ticket rule; the effect a caller can rely on is:
    ///
    ///  - the returned roster was read from disk at or after this call started, so
    ///    it cannot be older than the caller's own view of the world;
    ///  - a burst of callers does not cause one read each — a caller joins any read
    ///    that started after it asked, and only the first caller of a burst pays.
    public func reload() async -> [MachineEntry] {
        requests += 1
        let mine = requests
        while true {
            if let pass = inFlight {
                // Started after this call: its read of the disk happened at or
                // after the moment this caller asked, so joining it is both
                // cheaper and correct.
                if pass.ticket >= mine {
                    return await pass.task.value
                }
                // Started before this call: wait for it to land, then look again.
                // Whoever arrived meanwhile has already bumped `requests`, so the
                // read this loop starts next is marked with the highest ticket
                // outstanding and every one of them can join it. A burst of N
                // callers therefore costs two reads, not N.
                _ = await pass.task.value
                // Clear it here as well as in the owner's return path: if the
                // owner has not resumed yet, looping back on the same entry would
                // spin on a finished task instead of starting a fresh read.
                if inFlight?.ticket == pass.ticket { inFlight = nil }
                continue
            }
            // Nothing running: start the read. Its ticket is the newest request
            // number, so every caller that has arrived so far can join it.
            let ticket = requests
            let task = Task { @MainActor [self] in await readRoster() }
            inFlight = (ticket, task)
            let result = await task.value
            if inFlight?.ticket == ticket { inFlight = nil }
            return result
        }
    }

    // MARK: - Reading

    /// One read of the saved profiles, applied to `machines`.
    ///
    /// Separate from `reload()` because the coalescing above is about *when* this
    /// runs, not what it does; keeping the two apart is what stops the guarantee
    /// from turning into a comment.
    private func readRoster() async -> [MachineEntry] {
        // Discovery happens once, on the first read. Doing it in `init` would run a
        // `$PATH` scan for every store a test constructs.
        let source = self.source ?? HerdrMachineClient.discover().map { MachineRosterSource.live(client: $0) }
        guard let source else {
            available = false
            machines = MachineRoster.compose(local: local, remote: [])
            return machines
        }
        if self.source == nil {
            self.source = source
        }
        // Idempotent, and outside the discovery branch so an injected source (a
        // test's temporary file) is watched too. Without this the injected path
        // would be read correctly and never watched, which would make the
        // watch-related tests pass while watching nothing.
        ensureWatchingRoster()
        available = true

        do {
            let remote = try await Task.detached { try source.read() }.value
            let sorted = remote.sorted { lhs, rhs in
                if lhs.selected != rhs.selected { return lhs.selected == true }
                return lhs.displayLabel.localizedStandardCompare(rhs.displayLabel) == .orderedAscending
            }
            machines = MachineRoster.compose(local: local, remote: sorted)
            error = nil
            kraalLog("endpoints: \(sorted.count) saved machine(s) -> "
                + sorted.map(\.displayLabel).joined(separator: ", "))
        } catch {
            self.error = "\(error)"
            machines = MachineRoster.compose(local: local, remote: [])
            kraalLog("endpoints: machine list failed: \(error)")
        }
        return machines
    }

    // MARK: - Watching

    /// Starts the file watch, if there is a file to watch. Idempotent.
    private func ensureWatchingRoster() {
        guard watcher == nil, let path = source?.path, !path.isEmpty else { return }
        let watcher = RosterFileWatcher(path: path) { [weak self] in
            Task { @MainActor in self?.rosterFileChanged() }
        }
        self.watcher = watcher
        watcher.start()
        kraalLog("endpoints: watching \(path)")
    }

    /// Handles one debounced file change: re-read, then let the store fold the
    /// result into `endpoints`.
    private func rosterFileChanged() {
        kraalLog("endpoints: roster changed on disk, re-reading")
        Task { [weak self] in
            guard let self else { return }
            let roster = await self.reload()
            // `machines` is already updated by `reload`; this only exists so the
            // store can rebuild rows and connect machines it has not seen before.
            self.onRosterChanged?(roster)
        }
    }
}
