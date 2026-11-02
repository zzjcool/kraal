// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// A connection that survives core restarts.
//
// A core restart wipes the socket and every channel; `seq` starts over. This
// wrapper reconnects with backoff and republishes state. Re-subscribing and
// rebuilding the snapshot belong to the events layer (#225); calls made while
// the link is down fail with `notConnected` instead of queueing forever.

import Foundation

public enum HcClientEvent: Sendable {
    case connecting(attempt: Int)
    case ready(HcHelloResult)
    /// The core is too old/new or lacks a method; retrying cannot fix it.
    case incompatible(HcCompatibility)
    case disconnected(reason: String?)
    case failed(HcConnectionError)
}

public final class HcClient: @unchecked Sendable {
    public let path: String
    public let events: AsyncStream<HcClientEvent>

    private let eventContinuation: AsyncStream<HcClientEvent>.Continuation
    private let stateLock = NSLock()
    private let initialBackoff: TimeInterval
    private let maxBackoff: TimeInterval
    private var connection: HcConnection?
    private var runTask: Task<Void, Never>?
    private var stopped = false

    public init(
        path: String,
        initialBackoff: TimeInterval = 0.5,
        maxBackoff: TimeInterval = 30
    ) {
        self.path = path
        self.initialBackoff = initialBackoff
        self.maxBackoff = maxBackoff
        let (stream, continuation) = AsyncStream<HcClientEvent>.makeStream()
        events = stream
        eventContinuation = continuation
    }

    public var isConnected: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return connection != nil
    }

    public func start() {
        stateLock.lock()
        guard runTask == nil, !stopped else {
            stateLock.unlock()
            return
        }
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.run()
        }
        runTask = task
        stateLock.unlock()
    }

    public func stop() {
        stateLock.lock()
        if stopped {
            stateLock.unlock()
            return
        }
        stopped = true
        let task = runTask
        let current = connection
        runTask = nil
        connection = nil
        stateLock.unlock()

        current?.close()
        task?.cancel()
        eventContinuation.finish()
    }

    public func call(_ method: String, params: JSONValue = .object([:])) async throws -> JSONValue {
        guard let connection = currentConnection() else {
            throw HcConnectionError.notConnected
        }
        return try await connection.call(method, params: params)
    }

    /// Subscribes to events on the current link. A reconnect drops the
    /// channel; subscribe again and replace the store with the new snapshot.
    public func subscribeEvents(
        filter: HcEventFilter = HcEventFilter(),
        handlers: HcEventHandlers
    ) async throws -> HcEventSubscription {
        guard let connection = currentConnection() else {
            throw HcConnectionError.notConnected
        }
        return try await HcEventSubscription.subscribe(connection, filter: filter, handlers: handlers)
    }

    /// Attaches to a terminal on the current link.
    ///
    /// A reconnect drops every channel, so the caller must be ready to attach
    /// again: the streams are not restored behind its back.
    public func attach(
        terminal: String,
        options: HcAttachOptions = HcAttachOptions(),
        handlers: HcAttachHandlers
    ) async throws -> HcAttachStream {
        guard let connection = currentConnection() else {
            throw HcConnectionError.notConnected
        }
        return try await HcAttachStream.attach(
            connection,
            terminal: terminal,
            options: options,
            handlers: handlers
        )
    }

    private func currentConnection() -> HcConnection? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return connection
    }

    private func install(_ newValue: HcConnection?) {
        stateLock.lock()
        connection = newValue
        stateLock.unlock()
    }

    private func isStopped() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    private func run() async {
        var attempt = 0
        var delay = initialBackoff

        while !isStopped() {
            eventContinuation.yield(.connecting(attempt: attempt))

            do {
                let opened = try await withCheckedThrowingContinuation { continuation in
                    // The handshake blocks; keep it off the cooperative pool so
                    // it cannot starve the tasks waiting for this one.
                    DispatchQueue.global(qos: .userInitiated).async { [path] in
                        do {
                            continuation.resume(returning: try HcConnection.open(path: path))
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }

                if isStopped() {
                    opened.close()
                    return
                }

                let compatibility = HcProtocol.check(opened.hello)
                guard compatibility.isOK else {
                    opened.close()
                    install(nil)
                    eventContinuation.yield(.incompatible(compatibility))
                    eventContinuation.finish()
                    return
                }

                install(opened)
                eventContinuation.yield(.ready(opened.hello))

                attempt = 0
                delay = initialBackoff

                var reason: String?
                for await value in opened.closed {
                    reason = value
                }
                install(nil)

                if isStopped() { return }
                eventContinuation.yield(.disconnected(reason: reason))
            } catch let error as HcConnectionError {
                install(nil)
                eventContinuation.yield(.failed(error))
            } catch {
                install(nil)
                eventContinuation.yield(.failed(.socket("\(error)")))
            }

            if isStopped() { return }
            let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            delay = min(max(delay * 2, initialBackoff), maxBackoff)
            attempt += 1
        }
    }
}
