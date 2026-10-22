// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The endpoint connection: handshake, frame loop, and API request correlation.
//
// Shape follows `herdr-client/src/session.rs` (Apache-2.0) but is restructured
// for Swift concurrency: one actor owns the socket and the pending-request
// table, one detached thread does blocking reads, and everything observed by
// the UI is delivered as a `ConnectionEvent`.

import Foundation
import KraalProtocol
import KraalTransport

public enum ConnectionEvent: Sendable {
    case connected(EndpointServerWelcome)
    case snapshot(ClientShellSnapshot)
    case surface(PaneSurfaceFrame)
    case surfacePatch(PaneSurfacePatch)
    case response(bootId: String, requestId: String, data: Data, finalChunk: Bool)
    case windowTitle(String?)
    case mouseCapture(enabled: Bool, sgrPixels: Bool)
    /// The focused program asked the host to report every key, including bare
    /// modifiers and key releases (`ServerMessage::ClientShellKeyboardReportAll`).
    case keyboardReportAll(enabled: Bool)
    case notification(SemanticNotification)
    case bell(count: UInt16)
    /// A pane asked this machine to put something on the clipboard (OSC 52).
    ///
    /// `data` is **base64**, exactly as the daemon sent it (`wire.rs:1421-1424`
    /// documents the field that way). Decoding is the consumer's job — see
    /// `ClipboardPayload` — so the transport stays a faithful copy of the wire and
    /// the "what does the clipboard actually become" rule is testable.
    case clipboard(data: String)
    case serverShutdown(String?)
    case error(String)
    case disconnected(reason: String?)
}

/// Timing constants lifted from `herdr-client/src/limits.rs`.
public enum ConnectionLimits {
    public static let quietPing: TimeInterval = 5
    public static let pingTimeout: TimeInterval = 10
    public static let handshakeTimeout: TimeInterval = 10
    public static let commandTimeout: TimeInterval = 60
    public static let maxResponseBytes = FrameLimits.maxResponseBytes
}

public actor EndpointConnection {
    private let target: HerdrTarget
    /// The grid this connection last told the daemon to render, starting with the
    /// one in the hello. Tracked so a resize that matches it is not re-sent: the
    /// daemon would re-render a whole surface for nothing.
    public private(set) var surfaceSize: ClientSurfaceSize
    private let cellSize: (width: UInt32, height: UInt32)
    private let surfaceActive: Bool

    private var readThread: Thread?
    private var isRunning = false

    /// Shared with the reader thread; guards the stream handle, the frame
    /// decoder, and the queue of frames decoded ahead of the consumer.
    private let framesLock = NSLock()
    private nonisolated(unsafe) var rawFrames: [Data] = []
    private nonisolated(unsafe) var framesDecoder = FrameDecoder()
    private nonisolated(unsafe) var stream: ProtocolStream?

    private var welcome: EndpointServerWelcome?
    private var bootId: String?
    private var nextRequestId = 0
    private var pendingResponses: [String: PendingRequest] = [:]

    private var lastReceivedAt = Date()
    private var pingOutstandingAt: Date?
    private var healthTimer: Task<Void, Never>?

    private let eventHandler: @Sendable (ConnectionEvent) -> Void

    private struct PendingRequest {
        let method: String
        let startedAt: Date
        var data: Data
        let continuation: CheckedContinuation<Data, Error>
    }

    public init(
        target: HerdrTarget,
        surfaceSize: ClientSurfaceSize,
        cellSize: (width: UInt32, height: UInt32) = (10, 20),
        surfaceActive: Bool = true,
        eventHandler: @escaping @Sendable (ConnectionEvent) -> Void
    ) {
        self.target = target
        self.surfaceSize = surfaceSize
        self.cellSize = cellSize
        self.surfaceActive = surfaceActive
        self.eventHandler = eventHandler
    }

    public var negotiatedWelcome: EndpointServerWelcome? { welcome }
    public var currentBootId: String? { bootId }

    // MARK: - Lifecycle

    /// Connects, sends the hello, and waits for `endpoint.welcome.v1`.
    public func start() throws {
        guard !isRunning else { return }

        let stream = try StreamFactory.open(target)
        framesLock.lock()
        self.stream = stream
        framesLock.unlock()
        isRunning = true

        let hello = EndpointClientHello(
            cols: surfaceSize.cols,
            rows: surfaceSize.rows,
            cellWidthPx: cellSize.width,
            cellHeightPx: cellSize.height,
            surfaceActive: surfaceActive
        )
        let helloJSON = String(bytes: try JSONEncoder().encode(hello), encoding: .utf8) ?? ""
        try send(.endpointControl(kind: EndpointProtocol.helloKind, data: helloJSON))

        let deadline = Date().addingTimeInterval(ConnectionLimits.handshakeTimeout)
        while Date() < deadline {
            guard let payload = try handshakeReadPayload() else {
                throw BridgeError.unexpectedStreamEnd
            }
            guard case let .endpointControl(kind, data) = try ServerMessageDecoder.decode(payload)
            else {
                continue
            }
            guard kind == EndpointProtocol.welcomeKind else {
                throw BridgeError.welcomeKind(kind)
            }
            let welcome = try JSONDecoder().decode(
                EndpointServerWelcome.self,
                from: Data(data.utf8)
            )
            let compatibility = Compatibility.evaluate(welcome)
            guard compatibility.isOK else {
                throw BridgeError.handshakeRejected(
                    compatibility.userMessage ?? "handshake rejected"
                )
            }
            self.welcome = welcome
            lastReceivedAt = Date()
            eventHandler(.connected(welcome))
            startReadThread()
            startHealthMonitor()
            return
        }
        throw BridgeError.unexpectedStreamEnd
    }

    public func stop() {
        guard isRunning else { return }
        teardown(reason: nil)
    }

    /// Closes the stream and fails every in-flight request, so no caller is
    /// left awaiting a response that can never arrive.
    private func teardown(reason: String?) {
        isRunning = false
        healthTimer?.cancel()
        healthTimer = nil
        framesLock.lock()
        stream?.close()
        stream = nil
        framesLock.unlock()
        let pending = pendingResponses
        pendingResponses.removeAll()
        for (_, request) in pending {
            request.continuation.resume(
                throwing: BridgeError.transport("connection closed")
            )
        }
        eventHandler(.disconnected(reason: reason))
    }

    // MARK: - Sending

    /// Sends one message, framed.
    public func send(_ message: ClientMessage) throws {
        framesLock.lock()
        let activeStream = stream
        framesLock.unlock()
        guard let activeStream, isRunning else {
            throw BridgeError.transport("connection is not open")
        }
        let payload = ClientMessageEncoder.encode(message)
        let framed = try FrameEncoder.encode(payload)
        try activeStream.write(framed)
    }

    /// Per-pane keystroke bytes: the lowest-latency input path (tag 1).
    public func sendInput(_ data: Data) throws {
        try send(.input(data: data))
    }

    /// Semantic input events for a pane (mouse, paste, special keys).
    public func sendPaneInput(_ paneId: String, events: [ClientPaneInputEvent]) throws {
        guard !events.isEmpty else { return }
        try send(.clientShellPaneInput(paneId: paneId, events: events))
    }

    /// Tells the daemon that this client's surface needs a different grid.
    ///
    /// `client_shell_resize` re-renders the current projection at the new size on
    /// the *existing* connection: measured against a 0.9.5 daemon, the reply is a
    /// fresh `PaneSurface` at the requested grid in 16–20 ms. Without it the only
    /// lever was a new handshake, which is why a window drag used to tear the
    /// surface down on every step and could never settle.
    public func sendResize(to size: ClientSurfaceSize) throws {
        guard size != surfaceSize else { return }
        surfaceSize = size
        try send(.clientShellResize(
            cellWidthPx: cellSize.width,
            cellHeightPx: cellSize.height,
            surfaceSize: size,
            pixelMouse: false
        ))
    }

    /// Issues an endpoint API call and returns the reassembled response body.
    ///
    /// Responses may arrive in several chunks; they are accumulated here and
    /// completed on `finalChunk`, so callers see one `Data`.
    @discardableResult
    public func request(
        _ method: String,
        params: [String: Any] = [:]
    ) async throws -> Data {
        guard let bootId else {
            throw BridgeError.transport("no snapshot yet: boot id unknown")
        }
        nextRequestId += 1
        let requestId = "kraal-\(nextRequestId)"
        let envelope: [String: Any] = [
            "id": requestId,
            "method": method,
            "params": params,
        ]
        let json = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        guard let requestString = String(bytes: json, encoding: .utf8) else {
            throw BridgeError.transport("could not encode request")
        }

        let data = try await withCheckedThrowingContinuation { continuation in
            pendingResponses[requestId] = PendingRequest(
                method: method,
                startedAt: Date(),
                data: Data(),
                continuation: continuation
            )
            do {
                try send(
                    .clientShellEndpointRequest(bootId: bootId, request: requestString)
                )
            } catch {
                pendingResponses.removeValue(forKey: requestId)
                continuation.resume(throwing: error)
            }
        }
        try Self.throwIfErrorEnvelope(data, method: method)
        return data
    }

    /// Turns an `{"error":{...}}` reply body into a thrown error.
    ///
    /// The endpoint protocol reports refusals *in band*: the daemon answers the
    /// request it was given, the frame arrives complete, and the failure lives in
    /// the JSON body. Every caller that only checked for a thrown error therefore
    /// treated a refusal as success. `pane.split` failed this way — the reply was
    /// `{"error":{"code":"endpoint_busy","message":"this endpoint is still
    /// processing another command"}}`, the app logged `call: ok`, and the split
    /// silently never happened.
    public static func throwIfErrorEnvelope(_ data: Data, method: String) throws {
        guard !data.isEmpty else { return }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let envelope = object as? [String: Any],
              let error = envelope["error"] as? [String: Any] else { return }
        let code = error["code"] as? String ?? "unknown"
        let message = error["message"] as? String ?? ""
        throw BridgeError.daemon(method: method, code: code, message: message)
    }

    /// Whether an error is the daemon's "one command at a time" refusal.
    ///
    /// Worth retrying, and worth retrying *here* rather than at each call site:
    /// a single connection serves one request at a time, so any two commands
    /// issued in the same tick race for it. Sending focus and then acting on the
    /// result of that focus is exactly that pattern.
    public static func isBusyRefusal(_ error: Error) -> Bool {
        guard case let BridgeError.daemon(_, code, _) = error else { return false }
        return code == "endpoint_busy"
    }

    // MARK: - Receiving

    /// Reads one framed payload during the handshake, before the reader thread
    /// exists. Blocking on the caller's task is fine there: nothing else is
    /// using the connection yet.
    private func handshakeReadPayload() throws -> Data? {
        framesLock.lock()
        let activeStream = stream
        framesLock.unlock()
        guard let activeStream else { return nil }

        while true {
            guard let chunk = try activeStream.read(maxLength: 64 * 1024) else {
                return nil
            }
            if chunk.isEmpty { continue }
            let frames: [Data]
            do {
                framesLock.lock()
                defer { framesLock.unlock() }
                frames = try framesDecoder.append(chunk)
                if frames.count > 1 {
                    rawFrames.append(contentsOf: frames.dropFirst())
                }
            } catch let error as FrameError {
                throw BridgeError.frame(error)
            }
            if let first = frames.first { return first }
        }
    }

    /// Starts the blocking reader.
    ///
    /// The socket is a blocking stream, so reads must not run on the actor's
    /// executor: a single parked `read(2)` would occupy a cooperative thread and
    /// make every `send`/`stop` wait behind it. A dedicated `Thread` owns the
    /// socket, decodes frames, and hands each payload back to the actor.
    private func startReadThread() {
        let thread = Thread { [weak self] in
            guard let self else { return }
            self.readLoopBlocking()
        }
        thread.name = "kraal.endpoint.read"
        thread.stackSize = 512 * 1024
        readThread = thread
        thread.start()
    }

    /// Runs on the dedicated thread; must never touch actor state directly.
    private nonisolated func readLoopBlocking() {
        while true {
            let payload: Data?
            do {
                payload = try nextPayloadBlocking()
            } catch {
                let description = "\(error)"
                Task { await self.readFailed(description) }
                return
            }
            guard let payload else {
                Task { await self.readReachedEnd() }
                return
            }
            // Hand off in order. `ingest` is an actor call, so delivery is
            // serialized without blocking the reader.
            Task { await self.ingest(payload: payload) }
        }
    }

    private nonisolated func nextPayloadBlocking() throws -> Data? {
        framesLock.lock()
        if !rawFrames.isEmpty {
            let frame = rawFrames.removeFirst()
            framesLock.unlock()
            return frame
        }
        framesLock.unlock()

        while true {
            guard let chunk = try streamRead() else { return nil }
            if chunk.isEmpty { continue }
            framesLock.lock()
            let frames = try framesDecoder.append(chunk)
            if frames.isEmpty {
                framesLock.unlock()
                continue
            }
            rawFrames.append(contentsOf: frames.dropFirst())
            framesLock.unlock()
            return frames[0]
        }
    }

    /// Blocking read that tolerates `SO_RCVTIMEO` expiries.
    private nonisolated func streamRead() throws -> Data? {
        framesLock.lock()
        let activeStream = stream
        framesLock.unlock()
        guard let activeStream else { return nil }
        while true {
            do {
                return try activeStream.read(maxLength: 64 * 1024)
            } catch is SocketTimeout {
                // Nothing yet; keep waiting. `stop()` closes the socket, which
                // turns the next read into EOF.
                continue
            }
        }
    }

    private func readFailed(_ description: String) {
        guard isRunning else { return }
        teardown(reason: description)
    }

    private func readReachedEnd() {
        guard isRunning else { return }
        teardown(reason: "The daemon closed the connection.")
    }

    private func ingest(payload: Data) {
        guard isRunning else { return }
        handle(payload: payload)
    }

    private func handle(payload: Data) {
        lastReceivedAt = Date()
        pingOutstandingAt = nil

        let message: ServerMessage
        do {
            message = try ServerMessageDecoder.decode(payload)
        } catch {
            eventHandler(.error("Undecodable frame: \(error)"))
            return
        }

        switch message {
        case let .endpointControl(kind, data):
            handleEndpointControl(kind: kind, data: data)
        case let .clientShellSnapshot(snapshot):
            bootId = snapshot.bootId
            eventHandler(.snapshot(snapshot))
        case let .paneSurface(surface):
            // A surface from a previous daemon boot is stale; the boot id is
            // the fence, exactly as upstream treats it.
            guard bootId == nil || surface.bootId == bootId else { return }
            eventHandler(.surface(surface))
        case let .paneSurfacePatch(patch):
            guard bootId == nil || patch.bootId == bootId else { return }
            eventHandler(.surfacePatch(patch))
        case let .clientShellEndpointResponseChunk(chunkBootId, requestId, finalChunk, data):
            handleResponseChunk(
                bootId: chunkBootId,
                requestId: requestId,
                finalChunk: finalChunk,
                data: data
            )
        case let .semanticNotification(notification):
            eventHandler(.notification(notification))
        case let .notify(_, message, body):
            eventHandler(.notification(SemanticNotification(
                kind: .custom,
                title: message,
                body: body
            )))
        case let .serverShutdown(reason):
            eventHandler(.serverShutdown(reason))
            teardown(reason: reason)
        default:
            // Single-event pass-throughs (title, mouse mode, bell, OSC 52
            // clipboard, errors, keyboard report-all) live in their own function:
            // this switch is the state machine, and folding seven one-line
            // forwards into it pushed it past swiftlint's complexity limit twice.
            handleForwardedEvent(message)
        }
    }

    private func handleResponseChunk(
        bootId chunkBootId: String,
        requestId: String,
        finalChunk: Bool,
        data: Data
    ) {
        guard let currentBootId = bootId, chunkBootId == currentBootId else { return }
        eventHandler(.response(
            bootId: chunkBootId,
            requestId: requestId,
            data: data,
            finalChunk: finalChunk
        ))
        guard var pending = pendingResponses[requestId] else { return }
        pending.data.append(data)
        if finalChunk {
            pendingResponses.removeValue(forKey: requestId)
            pending.continuation.resume(returning: pending.data)
        } else if pending.data.count > ConnectionLimits.maxResponseBytes {
            pendingResponses.removeValue(forKey: requestId)
            pending.continuation.resume(
                throwing: BridgeError.transport(
                    "response to \(pending.method) exceeded the size limit"
                )
            )
        } else {
            pendingResponses[requestId] = pending
        }
    }

    private func handleEndpointControl(kind: String, data: String) {
        switch kind {
        case EndpointProtocol.snapshotKind:
            do {
                let snapshot = try JSONDecoder().decode(
                    ClientShellSnapshot.self,
                    from: Data(data.utf8)
                )
                bootId = snapshot.bootId
                eventHandler(.snapshot(snapshot))
            } catch {
                eventHandler(.error("Snapshot did not decode: \(error)"))
            }

        case EndpointProtocol.healthPongKind:
            pingOutstandingAt = nil

        case "endpoint.error.v1", "endpoint.handshake-error.v1":
            eventHandler(.error(data))

        default:
            // Unknown optional named controls are ignored, matching upstream.
            break
        }
    }

}

// Kept out of the actor body to hold it under the type-length limit. These are
// still actor-isolated members of `EndpointConnection`: a same-file extension
// sees the same private state, and nothing here changes behaviour.
extension EndpointConnection {
    /// Forwards the events whose only job is to reach a consumer unchanged.
    ///
    /// None of these change connection state, which is what makes them a
    /// separate concern from the switch above.
    private func handleForwardedEvent(_ message: ServerMessage) {
        switch message {
        case let .windowTitle(title):
            eventHandler(.windowTitle(title))
        case let .mouseCapture(enabled, sgrPixels):
            eventHandler(.mouseCapture(enabled: enabled, sgrPixels: sgrPixels))
        case let .terminalBell(count):
            eventHandler(.bell(count: count))
        case let .clipboard(data):
            // OSC 52. `herdr` renders the escape sequence into the pane and then
            // sends the payload here, because a pane's escape output stops at the
            // daemon rather than reaching this client's own terminal. Dropping it
            // meant a remote `pbcopy` (or tmux's copy) silently did nothing.
            //
            // `data` stays base64 here on purpose: the transport is a faithful
            // copy of the wire, and decoding lives in `ClipboardPayload` where it
            // can be asserted.
            eventHandler(.clipboard(data: data))
        case let .clientShellError(message):
            eventHandler(.error(message))
        case .reloadSoundConfig:
            break
        case let .welcome(_, _, error):
            if let error {
                eventHandler(.error("daemon: \(error)"))
            }
        case let .clientShellKeyboardReportAll(enabled):
            // Reported, not dropped: without it the decoder keeps sending
            // `tracksRelease: false`, so a program that turned on kitty's
            // report-all-keys mode never hears about releases (issue #20).
            eventHandler(.keyboardReportAll(enabled: enabled))
        default:
            // Byte-level terminal traffic belongs to the per-pane channels, and
            // the optional surface encodings are off, so these arrive only
            // unsolicited (or not at all) on this connection. Spelled `default`
            // rather than listing them: adding a consumed case (clipboard) to an
            // exhaustive list keeps pushing this switch past swiftlint's
            // complexity limit, and the "we do nothing with these" set only ever
            // grows.
            break
        }
    }

    // MARK: - Health

    private func startHealthMonitor() {
        healthTimer?.cancel()
        healthTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await self?.tickHealth()
            }
        }
    }

    private func tickHealth() {
        guard isRunning else { return }
        let now = Date()

        if let pingOutstandingAt {
            if now.timeIntervalSince(pingOutstandingAt) > ConnectionLimits.pingTimeout {
                self.pingOutstandingAt = nil
                teardown(reason: "The daemon stopped answering.")
            }
            return
        }

        guard now.timeIntervalSince(lastReceivedAt) >= ConnectionLimits.quietPing else {
            return
        }
        do {
            try send(.endpointControl(kind: EndpointProtocol.healthPingKind, data: ""))
            pingOutstandingAt = Date()
        } catch {
            // A failed ping is handled by the read loop's EOF/error path.
        }
    }
}
