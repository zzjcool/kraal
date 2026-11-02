// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// One framed stream channel (`terminal.attach` today).
//
// Handlers run on the connection's read thread, in frame order. A consumer that
// cannot take more bytes yet must not call `credit` for them: the core sends at
// most the credit it was given, so withholding credit is the backpressure.

import Foundation

public final class HcChannel: @unchecked Sendable {
    public let id: UInt32
    private weak var connection: HcConnection?
    private let handlers: HcStreamHandlers
    private let lock = NSLock()
    private var closed = false

    init(id: UInt32, connection: HcConnection, handlers: HcStreamHandlers) {
        self.id = id
        self.connection = connection
        self.handlers = handlers
    }

    public var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    /// Raw bytes to the program (the viewer's keyboard/mouse/paste).
    public func send(_ data: Data) throws {
        try requireOpen()
        guard let connection else { throw HcConnectionError.notConnected }
        try connection.sendFrame(try HcWire.dataFrame(channel: id, payload: data))
    }

    /// Returns credit for bytes already consumed. RESIZE does not consume credit.
    public func credit(_ bytes: Int) throws {
        guard bytes > 0 else { return }
        try requireOpen()
        guard let connection else { throw HcConnectionError.notConnected }
        try connection.sendFrame(HcWire.creditFrame(channel: id, bytes: bytes))
    }

    public func resize(cols: UInt16, rows: UInt16) throws {
        try requireOpen()
        guard let connection else { throw HcConnectionError.notConnected }
        try connection.sendFrame(try HcWire.resizeFrame(channel: id, cols: cols, rows: rows))
    }

    public func focus(_ focused: Bool) throws {
        try requireOpen()
        guard let connection else { throw HcConnectionError.notConnected }
        try connection.sendFrame(try HcWire.focusFrame(channel: id, focused: focused))
    }

    /// Display facts: foreground/background/cursor colors and cell size.
    public func facts(_ facts: JSONValue) throws {
        try requireOpen()
        guard let connection else { throw HcConnectionError.notConnected }
        try connection.sendFrame(try HcWire.factsFrame(channel: id, facts: facts))
    }

    public func close(reason: JSONValue? = nil) throws {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()

        guard let connection else { return }
        try? connection.sendFrame(try HcWire.closeFrame(channel: id, reason: reason))
        connection.closeChannel(id: id)
    }

    // MARK: - Delivery (connection's read thread)

    func deliver(data: Data) {
        guard !isClosed else { return }
        handlers.onData(data)
    }

    func deliverResize(cols: UInt16, rows: UInt16) {
        guard !isClosed else { return }
        handlers.onResize(cols, rows)
    }

    func deliverClose(reason: JSONValue?) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        handlers.onClose(reason)
    }

    private func requireOpen() throws {
        if isClosed {
            throw HcConnectionError.closed(reason: "stream channel \(id) is closed")
        }
    }
}
