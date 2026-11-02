// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// One pane's view of a terminal: `terminal.attach` plus the framed stream it opens.
//
// The stream is deliberately dumb about the bytes. A VT replay, a live PTY chunk
// and a repaint after a resize are all `DATA` here; deciding what they mean is the
// renderer's job (see `HcTerminalSession`). What it does own is the lifetime rules:
// reading `channel`, never crediting bytes it has not handed on, and telling the
// difference between "the program ended" (a CLOSE carrying the exit record) and
// "the link went away" (a nil reason).

import Foundation

/// The core's record of why a terminal stream ended.
public struct HcTerminalEnd: Sendable, Equatable {
    /// `exited`, `killed`, `lost`, … as the core wrote it.
    public let reason: String?
    public let exitCode: Int?
    public let signal: Int?
    public let finishedMilliseconds: Int64?

    public init(json: JSONValue) {
        reason = json["reason"]?.stringValue
        exitCode = json["exit_code"]?.intValue
        signal = json["signal"]?.intValue
        finishedMilliseconds = json["finished_ms"]?.int64Value
    }
}

public enum HcAttachError: Error, Equatable, CustomStringConvertible {
    case missingChannel
    case refused(String)

    public var description: String {
        switch self {
        case .missingChannel: "terminal.attach reply has no channel"
        case let .refused(message): "terminal.attach refused: \(message)"
        }
    }
}

/// How the pane wants its first paint.
public struct HcAttachOptions: Sendable, Equatable {
    public var columns: Int
    public var rows: Int
    public var history: Int

    public init(columns: Int = 80, rows: Int = 24, history: Int = 1000) {
        self.columns = columns
        self.rows = rows
        self.history = history
    }
}

/// Where the bytes and the two endings go.
public struct HcAttachHandlers: Sendable {
    public var onData: @Sendable (Data) -> Void
    public var onEnd: @Sendable (HcTerminalEnd) -> Void
    public var onLost: @Sendable () -> Void

    public init(
        onData: @escaping @Sendable (Data) -> Void,
        onEnd: @escaping @Sendable (HcTerminalEnd) -> Void,
        onLost: @escaping @Sendable () -> Void
    ) {
        self.onData = onData
        self.onEnd = onEnd
        self.onLost = onLost
    }
}

public final class HcAttachStream: @unchecked Sendable {
    public let channelID: UInt32
    /// The terminal record from the attach reply.
    public let terminal: JSONValue

    private let channel: HcChannel
    private let relay: Relay

    private init(channel: HcChannel, terminal: JSONValue, relay: Relay) {
        channelID = channel.id
        self.terminal = terminal
        self.channel = channel
        self.relay = relay
    }

    /// Attaches to `terminal` and starts the stream.
    ///
    /// `onData` runs on the connection's read thread, in wire order. The caller
    /// must return credit only for bytes it has actually taken (`credit(_:)`).
    /// `onEnd` means the program ended; `onLost` means the core or the socket went
    /// away and the pane should reattach rather than show an exit.
    public static func attach(
        _ connection: HcConnection,
        terminal: String,
        options: HcAttachOptions = HcAttachOptions(),
        handlers: HcAttachHandlers
    ) async throws -> HcAttachStream {
        let reply = try await connection.call("terminal.attach", params: .object([
            "terminal": .string(terminal),
            "cols": .int(options.columns),
            "rows": .int(options.rows),
            "history": .int(options.history),
        ]))
        guard let channelID = reply["channel"]?.intValue, channelID >= 0 else {
            throw HcAttachError.missingChannel
        }

        let relay = Relay(
            onData: handlers.onData,
            onEnd: handlers.onEnd,
            onLost: handlers.onLost
        )
        let channel = connection.openChannel(
            id: UInt32(channelID),
            handlers: HcStreamHandlers(
                onData: { data in relay.receive(data) },
                onClose: { reason in relay.close(reason) }
            )
        )
        return HcAttachStream(
            channel: channel,
            terminal: reply["terminal"] ?? .null,
            relay: relay
        )
    }

    /// Returns credit for `bytes` already handed to the renderer.
    ///
    /// Withholding it is the only backpressure the core understands; RESIZE and
    /// FOCUS do not consume the window.
    /// Raw bytes to the program: keystrokes, pastes, mouse reports.
    public func send(_ data: Data) {
        guard !data.isEmpty else { return }
        try? channel.send(data)
    }

    public func credit(_ bytes: Int) {
        guard bytes > 0 else { return }
        try? channel.credit(bytes)
    }

    public func resize(columns: Int, rows: Int) {
        guard let cols = UInt16(exactly: max(1, columns)),
              let count = UInt16(exactly: max(1, rows))
        else { return }
        try? channel.resize(cols: cols, rows: count)
    }

    public func focus(_ focused: Bool) {
        try? channel.focus(focused)
    }

    public func facts(_ facts: JSONValue) {
        try? channel.facts(facts)
    }

    /// Detaches. The core keeps the program running; the pane can attach again.
    public func close() {
        try? channel.close()
    }

    public var isClosed: Bool {
        channel.isClosed
    }

    /// One delivery, whichever thread it comes from, and never twice.
    private final class Relay: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private let onData: @Sendable (Data) -> Void
        private let onEnd: @Sendable (HcTerminalEnd) -> Void
        private let onLost: @Sendable () -> Void

        init(
            onData: @escaping @Sendable (Data) -> Void,
            onEnd: @escaping @Sendable (HcTerminalEnd) -> Void,
            onLost: @escaping @Sendable () -> Void
        ) {
            self.onData = onData
            self.onEnd = onEnd
            self.onLost = onLost
        }

        func receive(_ data: Data) {
            lock.lock()
            let open = !finished
            lock.unlock()
            if open { onData(data) }
        }

        /// `reason == nil` is a dead link, not an exit: the connection failed
        /// before the core could say how the program ended.
        func close(_ reason: JSONValue?) {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            lock.unlock()
            if let reason, reason != .null {
                onEnd(HcTerminalEnd(json: reason))
            } else {
                onLost()
            }
        }
    }
}
