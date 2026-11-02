// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The subscription itself: one event channel, line-delimited notifications.
//
// Channel 0 answers `events.subscribe` with the snapshot and a channel id; the
// channel then carries `event`/`heartbeat`/`missed`, one JSON-RPC message per
// line. Frames are not line-aligned, so every DATA chunk goes through
// `HcLineBuffer`. Events are small; credit is returned as soon as the bytes
// have been parsed (the parser runs on the read thread, so this is truthful).

import Foundation

public struct HcEventHandlers: Sendable {
    public var onEvent: @Sendable (HcEvent) -> Void
    public var onMissed: @Sendable (HcSnapshot) -> Void
    public var onHeartbeat: @Sendable (UInt64) -> Void
    public var onClosed: @Sendable (String?) -> Void

    public init(
        onEvent: @escaping @Sendable (HcEvent) -> Void,
        onMissed: @escaping @Sendable (HcSnapshot) -> Void,
        onHeartbeat: @escaping @Sendable (UInt64) -> Void,
        onClosed: @escaping @Sendable (String?) -> Void
    ) {
        self.onEvent = onEvent
        self.onMissed = onMissed
        self.onHeartbeat = onHeartbeat
        self.onClosed = onClosed
    }
}

public enum HcEventError: Error, Equatable, CustomStringConvertible {
    case missingChannel
    case missingSnapshot

    public var description: String {
        switch self {
        case .missingChannel: "events.subscribe reply has no channel"
        case .missingSnapshot: "events.subscribe reply has no snapshot"
        }
    }
}

public final class HcEventSubscription: @unchecked Sendable {
    public let channelID: UInt32
    /// The snapshot the subscribe reply carried, before any events.
    public let snapshot: HcSnapshot
    private let channel: HcChannel

    private init(channel: HcChannel, snapshot: HcSnapshot) {
        channelID = channel.id
        self.channel = channel
        self.snapshot = snapshot
    }

    public static func subscribe(
        _ connection: HcConnection,
        filter: HcEventFilter = HcEventFilter(),
        handlers: HcEventHandlers
    ) async throws -> HcEventSubscription {
        let reply = try await connection.call("events.subscribe", params: filter.params)
        guard let snapshot = HcSnapshot(json: reply) else {
            throw HcEventError.missingSnapshot
        }
        guard let channelID = reply["channel"]?.intValue, channelID >= 0 else {
            throw HcEventError.missingChannel
        }

        let relay = Relay(handlers: handlers)
        let channel = connection.openChannel(
            id: UInt32(channelID),
            handlers: HcStreamHandlers(
                onData: { data in relay.push(data) },
                onClose: { reason in
                    handlers.onClosed(reason?.stringValue ?? reason?.compactDescription)
                }
            )
        )
        relay.connect(channel)
        return HcEventSubscription(channel: channel, snapshot: snapshot)
    }

    /// Ends the subscription. The core drops its sink; no further lines arrive.
    public func close() {
        try? channel.close()
    }

    private final class Relay: @unchecked Sendable {
        private let lock = NSLock()
        private let handlers: HcEventHandlers
        private var buffer = HcLineBuffer()
        private weak var channel: HcChannel?
        private var uncredited = 0

        init(handlers: HcEventHandlers) {
            self.handlers = handlers
        }

        func connect(_ channel: HcChannel) {
            lock.lock()
            self.channel = channel
            let bytes = uncredited
            uncredited = 0
            lock.unlock()
            if bytes > 0 { try? channel.credit(bytes) }
        }

        func push(_ data: Data) {
            lock.lock()
            let lines = buffer.append(data)
            uncredited += data.count
            let channel = channel
            let bytes = uncredited
            if channel != nil { uncredited = 0 }
            lock.unlock()

            for line in lines {
                switch HcEventLine(line: line) {
                case let .event(event): handlers.onEvent(event)
                case let .missed(snapshot): handlers.onMissed(snapshot)
                case let .heartbeat(seq): handlers.onHeartbeat(seq)
                case .unknown, .malformed: continue
                }
            }
            if bytes > 0 { try? channel?.credit(bytes) }
        }
    }
}
