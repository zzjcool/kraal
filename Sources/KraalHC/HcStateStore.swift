// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The terminal set, reduced from the event stream.
//
// `seq` is the guard: every event carries the core's sequence, a snapshot
// carries its current one, and anything at or below the applied sequence is
// stale (most often an event that raced a `missed` snapshot). A gap is not
// invented into place: the store flags it so its owner can resubscribe.

import Foundation

public struct HcStateView: Sendable, Equatable {
    public let seq: UInt64
    public let terminals: [HcTerminal]
    public let lastHeartbeatAt: Date?
    /// An event skipped a sequence: the owner should resubscribe (`missed`).
    public let needsResync: Bool
}

public final class HcStateStore: @unchecked Sendable {
    private let lock = NSLock()
    private let filter: HcEventFilter
    private var records: [String: HcTerminal] = [:]
    private var storedSeq: UInt64 = 0
    private var heartbeatAt: Date?
    private var resync = false

    public init(filter: HcEventFilter = HcEventFilter()) {
        self.filter = filter
    }

    /// Installs a snapshot, either the subscribe reply or a `missed` one.
    public func replace(with snapshot: HcSnapshot, at now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        var next: [String: HcTerminal] = [:]
        for terminal in snapshot.terminals where filter.isEmpty || filter.matches(terminal) {
            next[terminal.address] = terminal
        }
        records = next
        storedSeq = snapshot.seq
        resync = false
        if heartbeatAt == nil { heartbeatAt = now }
    }

    /// Applies one event. Returns false when it was stale or about something
    /// this store does not track (documents, unknown types).
    @discardableResult
    public func apply(_ event: HcEvent) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard event.seq > storedSeq else { return false }
        if storedSeq > 0, event.seq > storedSeq + 1 { resync = true }
        storedSeq = event.seq

        guard let address = event.terminal else {
            // `doc` and future non-terminal events belong to their own layer.
            return false
        }
        if event.type == "removed" {
            records.removeValue(forKey: address)
            return true
        }
        if event.type == "created" || event.type == "restarted" {
            let terminal = HcTerminal(json: event.data)
            guard !terminal.address.isEmpty else { return false }
            if filter.isEmpty || filter.matches(terminal) {
                records[terminal.address] = terminal
            } else {
                records.removeValue(forKey: terminal.address)
            }
            return true
        }

        guard var terminal = records[address] else {
            // A labels event may be the first thing a newly matching terminal
            // produces; its `record` is the whole thing.
            guard event.type == "labels", let record = event.data["record"] else { return false }
            let adopted = HcTerminal(json: record)
            guard !adopted.address.isEmpty, filter.isEmpty || filter.matches(adopted) else { return false }
            records[adopted.address] = adopted
            return true
        }

        terminal.apply(type: event.type, data: event.data)
        if event.type == "labels", let record = event.data["record"] {
            terminal.adopt(record: record)
        }
        if filter.isEmpty || filter.matches(terminal) {
            records[terminal.address] = terminal
        } else {
            records.removeValue(forKey: terminal.address)
        }
        return true
    }

    /// Heartbeats carry the core's sequence but are not events: they say the
    /// link is alive, not that a fact changed. They must not advance the guard,
    /// or unrelated events between two heartbeats would look like a gap.
    public func heartbeat(seq: UInt64, at now: Date = Date()) {
        lock.lock()
        heartbeatAt = max(heartbeatAt ?? .distantPast, now)
        lock.unlock()
    }

    public func noteSubscription(at now: Date = Date()) {
        lock.lock()
        heartbeatAt = now
        resync = false
        lock.unlock()
    }

    public func view() -> HcStateView {
        lock.lock()
        defer { lock.unlock() }
        return HcStateView(
            seq: storedSeq,
            terminals: records.values.sorted(by: HcTerminal.ordered),
            lastHeartbeatAt: heartbeatAt,
            needsResync: resync
        )
    }

    public func terminal(_ address: String) -> HcTerminal? {
        lock.lock()
        defer { lock.unlock() }
        return records[address]
    }

    /// No heartbeat for twice the core's 15 s interval means the link is stuck,
    /// even if the socket has not failed yet.
    public func heartbeatIsStale(now: Date = Date(), after: TimeInterval = 35) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let heartbeatAt else { return false }
        return now.timeIntervalSince(heartbeatAt) > after
    }

    public func clearResync() {
        lock.lock()
        resync = false
        lock.unlock()
    }
}
