// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// One connection to a herdr-core session.
//
// Handshake is plain JSON-RPC over the socket; `hello {framed: true}` switches
// the connection to frames afterwards. A dedicated thread does blocking reads;
// calls are matched by id and may run concurrently. Streams (terminal attach)
// get their own channel ids.

import Foundation
import KraalSocket

public enum HcConnectionError: Error, CustomStringConvertible {
    case socket(String)
    case notConnected
    case closed(reason: String?)
    case handshakeTimeout
    case protocolViolation(String)
    case incompatible(HcCompatibility)

    public var description: String {
        switch self {
        case let .socket(message):
            "core socket: \(message)"
        case .notConnected:
            "not connected to a core"
        case let .closed(reason):
            "the core connection closed" + (reason.map { ": \($0)" } ?? "")
        case .handshakeTimeout:
            "the core accepted the socket but did not answer hello"
        case let .protocolViolation(detail):
            "core protocol violation: \(detail)"
        case let .incompatible(compatibility):
            compatibility.message
        }
    }
}

public struct HcNotification: Sendable, Equatable {
    public let method: String
    public let params: JSONValue
}

public struct HcStreamHandlers: Sendable {
    public var onData: @Sendable (Data) -> Void
    public var onResize: @Sendable (UInt16, UInt16) -> Void
    public var onClose: @Sendable (JSONValue?) -> Void

    public init(
        onData: @escaping @Sendable (Data) -> Void = { _ in },
        onResize: @escaping @Sendable (UInt16, UInt16) -> Void = { _, _ in },
        onClose: @escaping @Sendable (JSONValue?) -> Void = { _ in }
    ) {
        self.onData = onData
        self.onResize = onResize
        self.onClose = onClose
    }
}

public final class HcConnection: @unchecked Sendable {
    public let hello: HcHelloResult
    /// JSON-RPC notifications (`event`, `heartbeat`, `missed`). Unbounded: the
    /// core already caps its own queue and sends a fresh snapshot when a
    /// subscriber falls behind, so dropping here would break `seq` handling.
    public let notifications: AsyncStream<HcNotification>
    /// Finishes after the connection ends; yields the reason once when known.
    public let closed: AsyncStream<String?>

    private let socket: UnixSocket
    /// Bytes that arrived in the same read as the hello reply's newline. They
    /// belong to the frame stream and must not be dropped.
    private let initialBytes: Data
    private let stateLock = NSLock()
    private var pending: [Int64: CheckedContinuation<JSONValue, Error>] = [:]
    private var cancelledIDs: Set<Int64> = []
    private var channels: [UInt32: HcChannel] = [:]
    /// Frames that arrived between an attach reply and the caller registering the
    /// channel. The core pauses every stream until its reply is queued, so this
    /// window is tiny, but it is not zero.
    private var earlyFrames: [UInt32: [HcFrame]] = [:]
    private var earlyBytes: [UInt32: Int] = [:]
    private var retiredChannels: Set<UInt32> = []
    private var nextRequestID: Int64 = 2
    private var nextChannelID: UInt32 = 1
    private var isClosed = false

    private let notificationContinuation: AsyncStream<HcNotification>.Continuation
    private let closedContinuation: AsyncStream<String?>.Continuation
    private var readThread: Thread?

    private static let maxEarlyBytes = 1024 * 1024

    private init(socket: UnixSocket, hello: HcHelloResult, initialBytes: Data) {
        self.socket = socket
        self.hello = hello
        self.initialBytes = initialBytes

        let (notificationStream, notificationContinuation) = AsyncStream<HcNotification>.makeStream()
        notifications = notificationStream
        self.notificationContinuation = notificationContinuation

        let (closedStream, closedContinuation) = AsyncStream<String?>.makeStream()
        closed = closedStream
        self.closedContinuation = closedContinuation
    }

    /// Connects and completes `hello`. Blocking: the handshake is bounded by
    /// `timeout`, but callers off the main thread should still own the call.
    public static func open(path: String, timeout: TimeInterval = 10) throws -> HcConnection {
        let socket: UnixSocket
        do {
            socket = try UnixSocket.connect(path: path, timeoutSeconds: timeout)
        } catch {
            throw HcConnectionError.socket("\(error)")
        }

        do {
            let request = try HcRPC.requestLine(
                id: 1,
                method: "hello",
                params: .object([
                    "framed": .bool(true),
                    "generation": .int(HcProtocol.generation),
                ])
            )
            try socket.write(request)
            let (reply, rest) = try readLine(socket: socket, timeout: timeout)
            let incoming = try HcRPC.decode(reply)
            switch incoming {
            case let .response(id, result) where id == 1:
                let hello = try HcHelloResult(json: result)
                guard hello.framed else {
                    throw HcConnectionError.protocolViolation("the core did not switch to framed mode")
                }
                socket.setReadTimeout(0)
                let connection = HcConnection(socket: socket, hello: hello, initialBytes: rest)
                connection.startReader()
                return connection
            case let .failure(_, error):
                throw error
            default:
                throw HcConnectionError.protocolViolation("unexpected hello reply")
            }
        } catch {
            socket.close()
            if error is SocketTimeout {
                throw HcConnectionError.handshakeTimeout
            }
            throw error
        }
    }

    /// Sends one request and waits for its reply. Concurrent calls get distinct
    /// ids; a refusal is thrown as `HcRPCError` so callers can read `kind`.
    public func call(_ method: String, params: JSONValue = .object([:])) async throws -> JSONValue {
        let id = allocateRequestID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                switch register(id: id, continuation: continuation) {
                case .closed:
                    continuation.resume(throwing: HcConnectionError.closed(reason: nil))
                    return
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                    return
                case .registered:
                    break
                }
                do {
                    let payload = try HcRPC.requestJSON(id: id, method: method, params: params)
                    try write(try HcWire.dataFrame(channel: 0, payload: payload))
                } catch {
                    // `finish` may already have failed this continuation.
                    takePending(id: id)?.resume(throwing: error)
                }
            }
        } onCancel: {
            cancelPending(id: id)
        }
    }

    /// Registers a stream channel. `id` is the channel the core returned (for
    /// `terminal.attach`, the `channel` field of the reply).
    public func openChannel(id: UInt32, handlers: HcStreamHandlers) -> HcChannel {
        let channel = HcChannel(id: id, connection: self, handlers: handlers)
        var early: [HcFrame] = []
        stateLock.lock()
        if let frames = earlyFrames.removeValue(forKey: id) {
            early = frames
            earlyBytes.removeValue(forKey: id)
        }
        channels[id] = channel
        stateLock.unlock()

        for frame in early {
            deliver(frame: frame, to: channel)
        }
        return channel
    }

    /// A channel id for callers that create the stream themselves (tests, future
    /// non-attach streams). Attach uses the core's id instead.
    public func allocateChannelID() -> UInt32 {
        stateLock.lock()
        defer { stateLock.unlock() }
        let id = nextChannelID
        nextChannelID += 1
        return id
    }

    public func close() {
        finish(reason: nil)
    }

    // MARK: - Handshake

    private static func readLine(
        socket: UnixSocket,
        timeout: TimeInterval
    ) throws -> (line: Data, rest: Data) {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex ..< newline)
                let rest = buffer.subdata(in: buffer.index(after: newline) ..< buffer.endIndex)
                return (line, rest)
            }
            if Date() > deadline {
                throw HcConnectionError.handshakeTimeout
            }
            guard let chunk = try socket.read(maxLength: 64 * 1024) else {
                throw HcConnectionError.closed(reason: "end of stream during hello")
            }
            buffer.append(chunk)
            guard buffer.count <= 4 * 1024 * 1024 else {
                throw HcConnectionError.protocolViolation("hello reply is oversized")
            }
        }
    }

    // MARK: - Reader

    private func startReader() {
        let thread = Thread { [weak self] in
            self?.readLoop()
        }
        thread.name = "kraal.hc.read"
        thread.stackSize = 512 * 1024
        readThread = thread
        thread.start()
    }

    private func readLoop() {
        var decoder = HcFrameDecoder()
        if !initialBytes.isEmpty {
            decoder.append(initialBytes)
        }
        while true {
            let chunk: Data?
            do {
                chunk = try socket.read()
            } catch {
                finish(reason: "read failed: \(error)")
                return
            }
            guard let chunk else {
                finish(reason: nil)
                return
            }
            decoder.append(chunk)
            do {
                while let frame = try decoder.next() {
                    handle(frame: frame)
                }
            } catch {
                finish(reason: "\(error)")
                return
            }
        }
    }

    private func handle(frame: HcFrame) {
        if frame.channel == 0 {
            handleControlFrame(frame)
            return
        }

        stateLock.lock()
        let channel = channels[frame.channel]
        if channel == nil, retiredChannels.contains(frame.channel) {
            stateLock.unlock()
            return
        }
        if channel == nil, bufferEarlyFrame(frame) == false {
            stateLock.unlock()
            finish(reason: "stream channel \(frame.channel) flooded before registration")
            return
        }
        stateLock.unlock()

        guard let channel else { return }
        deliver(frame: frame, to: channel)
    }

    private func handleControlFrame(_ frame: HcFrame) {
        let incoming: HcRPCIncoming
        do {
            incoming = try HcRPC.decode(frame.payload)
        } catch {
            finish(reason: "\(error)")
            return
        }

        switch incoming {
        case let .response(id, result):
            resumePending(id: id, with: .success(result))
        case let .failure(id, error):
            if let id {
                resumePending(id: id, with: .failure(error))
            } else {
                finish(reason: error.description)
            }
        case let .notification(method, params):
            notificationContinuation.yield(HcNotification(method: method, params: params))
        case let .request(id, method, _):
            // The core only calls a client that advertised `calls_you`; we don't.
            reject(requestID: id, method: method)
        }
    }

    private func deliver(frame: HcFrame, to channel: HcChannel) {
        switch frame.knownKind {
        case .data:
            channel.deliver(data: frame.payload)
        case .resize:
            guard let size = try? HcWire.decodeResize(frame.payload) else { return }
            channel.deliverResize(cols: size.cols, rows: size.rows)
        case .close:
            let reason = try? JSONDecoder().decode(JSONValue.self, from: frame.payload)
            stateLock.lock()
            channels.removeValue(forKey: frame.channel)
            stateLock.unlock()
            channel.deliverClose(reason: reason)
        default:
            // credit/focus/facts from the core apply to relays, not this viewer.
            break
        }
    }

    /// Returns false when the buffered backlog exceeds the protocol's own cap.
    private func bufferEarlyFrame(_ frame: HcFrame) -> Bool {
        let bytes = (earlyBytes[frame.channel] ?? 0) + frame.payload.count
        guard bytes <= Self.maxEarlyBytes else { return false }
        earlyBytes[frame.channel] = bytes
        earlyFrames[frame.channel, default: []].append(frame)
        return true
    }

    private func reject(requestID: Int64?, method: String) {
        guard let requestID else { return }
        let response = JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .int(Int(requestID)),
            "error": .object([
                "code": .number(-32_601),
                "message": .string("Kraal does not accept callbacks from the core (\(method))"),
            ]),
        ])
        guard let payload = try? JSONEncoder().encode(response),
              let frame = try? HcWire.dataFrame(channel: 0, payload: payload)
        else { return }
        try? write(frame)
    }

    // MARK: - Pending calls

    private enum Registration {
        case registered
        case closed
        case cancelled
    }

    private func allocateRequestID() -> Int64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        let id = nextRequestID
        nextRequestID += 1
        return id
    }

    private func register(
        id: Int64,
        continuation: CheckedContinuation<JSONValue, Error>
    ) -> Registration {
        stateLock.lock()
        defer { stateLock.unlock() }
        if isClosed { return .closed }
        if cancelledIDs.remove(id) != nil { return .cancelled }
        pending[id] = continuation
        return .registered
    }

    private func takePending(id: Int64) -> CheckedContinuation<JSONValue, Error>? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pending.removeValue(forKey: id)
    }

    private func cancelPending(id: Int64) {
        stateLock.lock()
        let continuation = pending.removeValue(forKey: id)
        if continuation == nil { cancelledIDs.insert(id) }
        stateLock.unlock()
        continuation?.resume(throwing: CancellationError())
    }

    private func resumePending(id: Int64, with result: Result<JSONValue, Error>) {
        stateLock.lock()
        let continuation = pending.removeValue(forKey: id)
        stateLock.unlock()
        continuation?.resume(with: result)
    }

    // MARK: - Writing

    fileprivate func write(_ data: Data) throws {
        do {
            try socket.write(data)
        } catch {
            finish(reason: "write failed: \(error)")
            throw HcConnectionError.socket("\(error)")
        }
    }

    func sendFrame(_ data: Data) throws {
        try write(data)
    }

    func closeChannel(id: UInt32) {
        stateLock.lock()
        channels.removeValue(forKey: id)
        // The core may still send its own CLOSE for this channel; drop it
        // instead of buffering frames nobody will ever read.
        retiredChannels.insert(id)
        earlyFrames.removeValue(forKey: id)
        earlyBytes.removeValue(forKey: id)
        stateLock.unlock()
    }

    // MARK: - Teardown

    private func finish(reason: String?) {
        stateLock.lock()
        guard !isClosed else {
            stateLock.unlock()
            return
        }
        isClosed = true
        let waiting = pending
        pending.removeAll()
        let openChannels = channels
        channels.removeAll()
        earlyFrames.removeAll()
        earlyBytes.removeAll()
        retiredChannels.removeAll()
        cancelledIDs.removeAll()
        stateLock.unlock()

        socket.close()

        for (_, continuation) in waiting {
            continuation.resume(throwing: HcConnectionError.closed(reason: reason))
        }
        for channel in openChannels.values {
            channel.deliverClose(reason: nil)
        }
        notificationContinuation.finish()
        closedContinuation.yield(reason)
        closedContinuation.finish()
    }
}
