// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// A pane: one attached stream, one Ghostty session, no cell translation.
//
// The core replays the terminal as VT (`CAN`, a reset prologue, optional
// history, then the grid) and from then on sends the program's raw PTY bytes.
// Both go straight into the engine. Nothing here parses escape sequences,
// encodes images, or diffs rows — the engine is the terminal, as it is for
// every other Ghostty host.

import AppKit
import Foundation
import GhosttyTerminal
import KraalHC

@MainActor
public final class HcTerminalSession {
    public let state = TerminalViewState()
    public let address: String
    public let terminal: JSONValue

    /// Set once the core says the program ended. `nil` while it is still running.
    public private(set) var end: HcTerminalEnd?
    /// The socket or core went away; the pane should reattach, not show an exit.
    public private(set) var lost = false
    public var onEnd: ((HcTerminalEnd) -> Void)?

    /// Built by the model so a menu item can target a pane without this
    /// session knowing about workspaces. Read when the menu opens, not when
    /// the surface is created.
    public var contextMenuProvider: (() -> NSMenu?)?
    public var onFocusRequest: (() -> Void)?

    private let engine: InMemoryTerminalSession
    private let stream: HcAttachStream
    private let gate: HcCreditGate
    private let endRelay: HcStreamEndRelay

    private init(
        address: String,
        terminal: JSONValue,
        engine: InMemoryTerminalSession,
        stream: HcAttachStream,
        gate: HcCreditGate,
        endRelay: HcStreamEndRelay
    ) {
        self.address = address
        self.terminal = terminal
        self.engine = engine
        self.stream = stream
        self.gate = gate
        self.endRelay = endRelay
        state.configuration = TerminalSurfaceOptions(backend: .inMemory(engine))
        state.makePlatformView = { [weak self] in
            let view = HcTerminalPlatformView(frame: .zero)
            view.menuProvider = { [weak self] in self?.contextMenuProvider?() }
            view.onFocusRequest = { [weak self] in self?.onFocusRequest?() }
            return view
        }
        endRelay.connect { [weak self] event in
            self?.apply(event)
        }
    }

    /// Attaches and starts feeding the engine.
    ///
    /// `columns`/`rows` only seed the first paint; the view's real grid arrives
    /// through the engine's resize callback and is forwarded as RESIZE, so the
    /// core repaints at the size the pane actually has.
    public static func open(
        connection: HcConnection,
        terminal: String,
        columns: Int = 80,
        rows: Int = 24,
        history: Int = 1000
    ) async throws -> HcTerminalSession {
        try await open(terminal: terminal, options: HcAttachOptions(columns: columns, rows: rows, history: history)) {
            try await HcAttachStream.attach(connection, terminal: $0, options: $1, handlers: $2)
        }
    }

    /// Attaches on a reconnecting client: the link is the client's current one.
    public static func open(
        client: HcClient,
        terminal: String,
        columns: Int = 80,
        rows: Int = 24,
        history: Int = 1000
    ) async throws -> HcTerminalSession {
        try await open(terminal: terminal, options: HcAttachOptions(columns: columns, rows: rows, history: history)) {
            try await client.attach(terminal: $0, options: $1, handlers: $2)
        }
    }

    private typealias AttachBody = @Sendable (
        _ terminal: String,
        _ options: HcAttachOptions,
        _ handlers: HcAttachHandlers
    ) async throws -> HcAttachStream

    private static func open(
        terminal: String,
        options: HcAttachOptions,
        attach: AttachBody
    ) async throws -> HcTerminalSession {
        let channelBox = HcChannelBox()
        let gate = HcCreditGate()
        let endRelay = HcStreamEndRelay()
        let engine = InMemoryTerminalSession(
            write: { data in
                // Ghostty -> core: keystrokes, pastes, mouse reports.
                //
                // Its own size reports are not input: they are the engine telling
                // *this host* what grid it ended up with. Forwarded, they would be
                // typed into the program (mode 2048 is a host protocol).
                guard !HcEngineSizeReport.isReport(data) else { return }
                channelBox.send(data)
            },
            resize: { viewport in
                gate.surfaceReady()
                channelBox.resize(columns: Int(viewport.columns), rows: Int(viewport.rows))
            },
            suppressesPixelOnlyResizes: true
        )

        let stream = try await attach(
            terminal,
            options,
            HcAttachHandlers(
                onData: { data in
                    engine.receive(data)
                    gate.received(data.count)
                },
                onEnd: { end in
                    engine.finish(
                        exitCode: UInt32(clamping: end.exitCode ?? 0),
                        runtimeMilliseconds: 0
                    )
                    endRelay.deliver(.exited(end))
                },
                onLost: { endRelay.deliver(.lost) }
            )
        )
        channelBox.connect(stream)
        gate.connect(stream)
        engine.setOutputBacklogHandler(
            highWater: HcCreditGate.defaultHighWater,
            lowWater: HcCreditGate.defaultLowWater
        ) { backlogged in
            gate.setBacklogged(backlogged)
        }

        let session = HcTerminalSession(
            address: terminal,
            terminal: stream.terminal,
            engine: engine,
            stream: stream,
            gate: gate,
            endRelay: endRelay
        )
        return session
    }

    /// What the engine currently shows, one string per viewport row.
    ///
    /// The same read a screenshot would use; tests assert on it instead of pixels.
    public var viewportText: String? {
        engine.readViewportText()
    }

    /// The grid the engine last laid out. The core is told this as RESIZE.
    public var grid: TerminalGridMetrics? {
        state.surfaceSize
    }

    /// Raw bytes to the program, as if typed. The UI's path is Ghostty's own
    /// key handling; this exists for automation and tests.
    public func send(_ data: Data) {
        stream.send(data)
    }

    /// Applies the terminal look to this live surface. Ghostty reconfigures in
    /// place; the pane's stream and scrollback are untouched.
    public func apply(_ settings: HcTerminalSettings) {
        _ = state.controller.setTerminalConfiguration(settings.terminalConfiguration)
        state.objectWillChange.send()
    }

    /// Detaches without killing the program.
    public func close() {
        stream.close()
    }

    public func focus(_ focused: Bool) {
        stream.focus(focused)
    }

    private func apply(_ event: HcStreamEnd) {
        switch event {
        case let .exited(end):
            guard self.end == nil else { return }
            self.end = end
            onEnd?(end)
        case .lost:
            guard self.end == nil else { return }
            lost = true
        }
    }
}

enum HcStreamEnd: Sendable {
    case exited(HcTerminalEnd)
    case lost
}

/// Carries the end (or the lost link) from the read thread to the main actor,
/// including when it arrives before the session exists.
private final class HcStreamEndRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: HcStreamEnd?
    private var handler: (@MainActor (HcStreamEnd) -> Void)?

    func deliver(_ event: HcStreamEnd) {
        lock.lock()
        if let handler {
            lock.unlock()
            Task { @MainActor in handler(event) }
            return
        }
        pending = event
        lock.unlock()
    }

    func connect(_ handler: @escaping @MainActor (HcStreamEnd) -> Void) {
        lock.lock()
        self.handler = handler
        let queued = pending
        pending = nil
        lock.unlock()
        if let queued {
            Task { @MainActor in handler(queued) }
        }
    }
}

/// The stream is created after the engine's callbacks are installed; this box is
/// how those callbacks reach it. Before it is set there is nothing to send — the
/// engine cannot produce input without a surface, and a resize is re-sent by the
/// first grid after attach.
private final class HcChannelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: HcAttachStream?

    func connect(_ stream: HcAttachStream) {
        lock.lock()
        self.stream = stream
        lock.unlock()
    }

    func send(_ data: Data) {
        lock.lock()
        let stream = stream
        lock.unlock()
        try? stream?.send(data)
    }

    func resize(columns: Int, rows: Int) {
        lock.lock()
        let stream = stream
        lock.unlock()
        stream?.resize(columns: columns, rows: rows)
    }
}
