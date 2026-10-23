// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Live reachability for the saved machines — issue #73.
//
// Its own type rather than a few properties on `MachinesStore`, because it answers
// a different question on a different clock. The store owns the *roster*: what
// `herdr machine list` says is saved, re-read after every write and whenever
// another herdr process edits the file, all local and cheap. This owns the
// *probe*: one `herdr machine status` run, which opens SSH to every saved machine
// and waits for each one to answer.
//
// **When it runs is the whole design**, and it is why this is not hung off the
// store's `reload()`:
//
//  - `reload()` fires on every mutation (add / rename / enable / disable / remove)
//    and on every roster-file change from another terminal. A rename says nothing
//    about reachability; paying one SSH round trip per machine for it would make
//    renaming slow and buy nothing.
//  - so the probe runs at the two moments a user has asked to see the list right
//    now: the panel's first appearance, and each press of Refresh.
//
// Measured on loopback SSH (this Mac, herdr 0.9.5): ~0.5s per reachable machine;
// a dead one takes as long as its SSH attempt does, and the issue's own report
// describes the whole command taking seconds.

import KraalTransport
import Observation

@MainActor
@Observable
public final class MachineReachability {
    /// Live reachability per profile id. Empty until a probe lands; a machine
    /// missing from it is **not probed**, never "broken".
    public private(set) var statuses = MachineStatusIndex()
    /// True while a probe is in flight.
    public private(set) var isProbing = false
    /// Set when the probe itself failed (CLI missing, output not the promised
    /// JSON).
    ///
    /// Kept apart from a machine reporting `error`: that is a *successful* probe
    /// which found the machine down, and reporting it as "the check is broken"
    /// would be exactly the confusion this issue is about. Whatever `statuses`
    /// held before survives a failure, marked by this flag.
    public private(set) var probeError: String?
    /// Whether a probe has ever been started, so an appearance-triggered probe
    /// happens once rather than on every SwiftUI re-render.
    public private(set) var hasProbed = false

    private let client: HerdrMachineClient?

    public init(client: HerdrMachineClient?) {
        self.client = client
    }

    /// Asks the CLI whether each saved machine is reachable right now.
    ///
    /// Replaces the whole index rather than merging: the answer is a snapshot, so
    /// merging would keep a machine marked reachable after the CLI stopped
    /// reporting it at all.
    public func probe() {
        guard let client else { return }
        // One at a time. Refresh is pressable while the probe launched by the
        // first appearance is still in flight, and two overlapping runs would let
        // the older answer land last — an SSH check that takes seconds is exactly
        // where that happens.
        guard !isProbing else { return }
        hasProbed = true
        isProbing = true
        probeError = nil
        Task {
            do {
                let rows = try await Task.detached(priority: .userInitiated) {
                    try client.status()
                }.value
                self.statuses = MachineStatusIndex(rows)
                self.isProbing = false
                self.probeError = nil
                // One line per probe, in the CLI's own vocabulary. This is what
                // proves the panel holds a real probe result rather than a
                // defaulted "looks fine".
                kraalLog("machines: status \(rows.count) row(s) -> "
                    + (rows.isEmpty ? "none" : rows.map { "\($0.label)[\($0.id.prefix(8))]=\($0.status)" }
                        .joined(separator: ", ")))
            } catch {
                // A failed *check* is not a broken machine. Keep the last snapshot;
                // this only says it is not fresh.
                self.probeError = String(describing: error)
                self.isProbing = false
                kraalLog("machines: status failed \(error)")
            }
        }
    }

    /// Reachability for one row, or nil when that row has not been probed.
    ///
    /// This Mac is never in the CLI's answer (it is not a saved profile), and a
    /// profile added since the last probe has no row either. Both are "unknown",
    /// and the panel draws nothing for unknown rather than inventing a state.
    public func status(for entry: MachineEntry) -> MachineStatus? {
        guard !entry.isLocal else { return nil }
        return statuses.status(for: entry.id)
    }
}
