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
// Refreshes are cheap and infrequent: `herdr machine list` reads a JSON file and
// does not touch the network, but it is still a subprocess, so it runs off the
// main actor and only when something asks for it.

import Foundation
import KraalTransport
import Observation

@MainActor
@Observable
public final class EndpointCatalogLoader {
    public private(set) var machines: [MachineEntry] = []
    public private(set) var error: String?
    /// False when the `herdr` CLI could not be found, which is not an error worth
    /// showing: a single-machine setup is the common case.
    public private(set) var available = true

    @ObservationIgnored private var client: HerdrMachineClient?
    @ObservationIgnored private var loading = false
    @ObservationIgnored private let local: LocalMachineDescriptor

    public init(local: LocalMachineDescriptor) {
        self.local = local
        machines = MachineRoster.compose(local: local, remote: [])
    }

    /// Reads the saved profiles and returns them. Never throws: a missing CLI or a
    /// failed list leaves the previous roster in place, because losing every remote
    /// machine because one subprocess failed would empty the sidebar.
    public func reload() async -> [MachineEntry] {
        guard !loading else { return machines }
        loading = true
        defer { loading = false }

        guard let client = client ?? HerdrMachineClient.discover() else {
            available = false
            machines = MachineRoster.compose(local: local, remote: [])
            return machines
        }
        self.client = client
        available = true

        do {
            let remote = try await Task.detached { try client.list() }.value
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
}
