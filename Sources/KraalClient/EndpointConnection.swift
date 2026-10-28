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
    /// modifiers (`ServerMessage::ClientShellKeyboardReportAll`).
    ///
    /// **Not** about key releases: whether a release follows a press is decided by
    /// the key itself upstream (`protocol/wire.rs:315`), and claiming otherwise
    /// makes the daemon hold every press waiting for a release this client never
    /// sends. See `TerminalInputDecoder.reportsAllKeys`.
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

    /// How long the *UI* waits for one machine's handshake before giving up on it
    /// and starting over, whatever the connection is doing (issue #67).
    ///
    /// Every layer below already has its own bound: the local socket arms
    /// `SO_RCVTIMEO` with `handshakeTimeout`, the SSH bridge has a 30 s ready
    /// deadline, and `start()` re-checks its own deadline between reads. This
    /// constant exists **because that is a delegation and delegations rot**: a
    /// new unbounded read, or one blocking step added to `StreamFactory.open`,
    /// puts the dead state straight back with nothing above it to notice. Which
    /// is exactly what happened once already — #66 was "the deadline is only
    /// checked between reads", and the fix was inside the connection. The
    /// watchdog is the layer that does not trust the ones under it.
    ///
    /// Larger than what it backstops, on purpose: 30 s SSH ready handshake + 10 s
    /// endpoint handshake, plus slack. If it fired first it would abort
    /// handshakes that are still legitimately inside their own budgets, turning a
    /// slow machine into a failing one.
    public static let handshakeWatchdog: TimeInterval = 45
}

/// The part of a connection the UI uses.
///
/// `AppStore` reaches a daemon through nine members — lifecycle, three input sends, a
/// resize, a request, the boot id, and the abort flag. Everything else here (framing,
/// handshake, the reader thread, pending-request bookkeeping) is invisible to it.
///
/// This protocol exists so a test can substitute a recorder. The store-level behaviour
/// that had no coverage until now is precisely "what did we send": a resize must send
/// the *last* size requested rather than every intermediate one, a paste must travel as
/// `.paste` rather than as keystrokes, and a refusal must be classified before the
/// caller acts on it. All three are invisible without something on the other end.
///
/// Deliberately the smallest surface that covers those call sites: adding a member here
/// is a promise that every implementation must make, so `_test` doubles stay honest.
public protocol DaemonConnection: AnyObject, Sendable {
    var currentBootId: String? { get async }
    func start() async throws
    func stop() async
    nonisolated func abort()
    func sendResize(to size: ClientSurfaceSize) async throws
    /// Corrects the cell size announced in the handshake; see `updateCellSize` below.
    func updateCellSize(width: UInt32, height: UInt32) async
    func sendPaneInput(_ paneId: String, events: [ClientPaneInputEvent]) async throws
    func sendPopupInput(_ terminalId: String, events: [ClientPaneInputEvent]) async throws
    func request(_ method: String, params: [String: Any]) async throws -> Data
}

public actor EndpointConnection: DaemonConnection {
    private let target: HerdrTarget
    /// The grid this connection last told the daemon to render, starting with the
    /// one in the hello. Tracked so a resize that matches it is not re-sent: the
    /// daemon would re-render a whole surface for nothing.
    public private(set) var surfaceSize: ClientSurfaceSize
    /// The cell size the daemon divides pixel rects by, plus whether it outran the hello.
    private var cell = CellSizeState()
    private let surfaceActive: Bool
    /// How long the handshake may take, including any single blocked read.
    ///
    /// Injectable so a test can prove the deadline fires without waiting the
    /// production ten seconds; the shipped value stays `ConnectionLimits`.
    private let handshakeTimeout: TimeInterval

    private var readThread: Thread?
    private var isRunning = false

    /// Shared with the reader thread; guards the stream handle, the frame
    /// decoder, and the queue of frames decoded ahead of the consumer.
    private let framesLock = NSLock()
    private nonisolated(unsafe) var rawFrames: [Data] = []
    private nonisolated(unsafe) var framesDecoder = FrameDecoder()
    private nonisolated(unsafe) var stream: ProtocolStream?
    /// Set by `abort()`, guarded by `framesLock`.
    ///
    /// Closing the stream only interrupts a read that is *already* parked. A
    /// watchdog that fires in the moment between `StreamFactory.open` returning
    /// and `start()` storing the stream would find nothing to close and the read
    /// that follows would park until its own deadline — the whole point of the
    /// watchdog, gone in a one-instruction window. The flag is checked after the
    /// stream is stored, so either order aborts.
    private nonisolated(unsafe) var aborted = false

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
        handshakeTimeout: TimeInterval = ConnectionLimits.handshakeTimeout,
        eventHandler: @escaping @Sendable (ConnectionEvent) -> Void
    ) {
        self.target = target
        self.surfaceSize = surfaceSize
        cell = CellSizeState(width: cellSize.width, height: cellSize.height)
        self.surfaceActive = surfaceActive
        self.handshakeTimeout = handshakeTimeout
        self.eventHandler = eventHandler
    }

    public var negotiatedWelcome: EndpointServerWelcome? { welcome }
    public var currentBootId: String? { bootId }

    // MARK: - Lifecycle

    /// Connects, sends the hello, and waits for `endpoint.welcome.v1`.
    ///
    /// The wait is bounded twice over, on purpose (issue #66):
    ///
    ///  1. the stream is opened with its read timeout armed for
    ///    `handshakeTimeout`, so one `read(2)` cannot park past the deadline; and
    ///  2. the loop still compares against its own deadline, because a read that
    ///    returns early must not extend the budget.
    ///
    /// Before this, only (2) existed: a peer that accepted the connection and
    /// stayed silent blocked the read forever, the deadline was never reached,
    /// and `start()` never returned — locally and over SSH alike.
    public func start() throws {
        guard !isRunning else { return }

        let stream = try StreamFactory.open(target, handshakeTimeout: handshakeTimeout)
        guard try claimStream(stream) else {
            throw BridgeError.transport("connection aborted before the handshake started")
        }
        isRunning = true

        let hello = EndpointClientHello(
            cols: surfaceSize.cols,
            rows: surfaceSize.rows,
            cellWidthPx: cell.width,
            cellHeightPx: cell.height,
            surfaceActive: surfaceActive
        )
        let helloJSON = String(bytes: try JSONEncoder().encode(hello), encoding: .utf8) ?? ""
        try send(.endpointControl(kind: EndpointProtocol.helloKind, data: helloJSON))

        let deadline = Date().addingTimeInterval(handshakeTimeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw BridgeError.handshakeTimedOut(seconds: handshakeTimeout)
            }
            let payload: Data?
            do {
                payload = try handshakeReadPayload(deadline: deadline)
            } catch is SocketTimeout {
                // Nothing arrived yet. Not a failure: the deadline decides.
                continue
            }
            guard let payload else {
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
            // The handshake is over: hand the socket to the frame loop, which
            // wants to wait indefinitely for the daemon (and is woken by
            // `close()`), not to poll on a ten-second cycle.
            stream.setReadTimeout(0)
            eventHandler(.connected(welcome))
            startReadThread()
            startHealthMonitor()
            return
        }
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

    /// Semantic input events for a popup's own terminal.
    ///
    /// A separate message from the pane path (`tag 14` vs `paneInput`) because a
    /// popup is a *different terminal*: its keystrokes must not be delivered to the
    /// pane underneath it. The encoder has carried this tag all along; nothing ever
    /// sent it.
    public func sendPopupInput(_ terminalId: String, events: [ClientPaneInputEvent]) throws {
        guard !events.isEmpty else { return }
        try send(.clientShellPopupInput(terminalId: terminalId, events: events))
    }

    /// Tells the daemon that this client's surface needs a different grid.
    ///
    /// `client_shell_resize` re-renders the current projection at the new size on
    /// the *existing* connection: measured against a 0.9.5 daemon, the reply is a
    /// fresh `PaneSurface` at the requested grid in 16–20 ms. Without it the only
    /// lever was a new handshake, which is why a window drag used to tear the
    /// surface down on every step and could never settle.
    public func sendResize(to size: ClientSurfaceSize) throws {
        guard size != surfaceSize || cell.stale else { return }
        surfaceSize = size
        cell.stale = false
        try send(.clientShellResize(
            cellWidthPx: cell.width,
            cellHeightPx: cell.height,
            surfaceSize: size,
            pixelMouse: false
        ))
    }

    /// Exposes the resend flag so the early-return path is testable without a socket.
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
    ///
    /// **Every** read is armed with what is left of `deadline`, including the
    /// ones that only collect the rest of a frame. Arming once per outer loop
    /// would let a peer that sends one byte per timeout window keep the
    /// handshake alive indefinitely — the same class of bug (a deadline that is
    /// only checked between reads) at a finer grain.
    private func handshakeReadPayload(deadline: Date) throws -> Data? {
        framesLock.lock()
        let activeStream = stream
        framesLock.unlock()
        guard let activeStream else { return nil }

        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw SocketTimeout() }
            activeStream.setReadTimeout(remaining)
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
    ///
    /// `start()` has already restored the socket's read timeout to "wait until
    /// the daemon speaks": `stop()` closes the socket, which turns that wait into
    /// EOF, so no timeout is needed here to notice a teardown.
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
            // Reported, not dropped (issue #20): the mode has to be observable
            // before anything can act on it. It deliberately does *not* touch
            // `tracksRelease` — see the note on the event itself.
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

// MARK: - Aborting from outside the actor

extension EndpointConnection {
    /// Drops the stream from outside the actor, so a `start()` parked in a
    /// blocking read returns instead of waiting for its own deadline.
    ///
    /// **Not the same thing as `stop()`**, and the difference is the whole point
    /// (issue #67). `stop()` is actor-isolated: while `start()` is parked in a
    /// blocking `read(2)` the actor is occupied, so `stop()` queues *behind* the
    /// call it is meant to interrupt. Measured on this Mac, against a peer that
    /// accepts and then says nothing, with `handshakeTimeout: 20`:
    ///
    ///     [ 0.32s] calling stop() (fire and forget)
    ///     ...                                        (stop() never returned)
    ///     [20.00s] outcome: ["timeout-3s", "beats done"]   <- only after start() timed out itself
    ///
    /// So "the UI calls `stop()` when its watchdog fires" does not work: it runs
    /// after the deadline it was supposed to replace. Closing the stream is what
    /// a parked read actually notices — measured directly: after
    /// `shutdown(SHUT_RDWR)` + `close()` on the same fd from another thread, the
    /// blocked `read` returned `-1 errno=9` (EBADF) immediately. This entry point
    /// does exactly that, under the same `framesLock` that `teardown` uses for the
    /// field, and clears it so the stream is closed once rather than twice.
    ///
    /// `start()` then sees EOF and throws, which is the ordinary failure path: the
    /// caller's `catch` runs its normal cleanup. Deliberately not a second
    /// teardown — `isRunning` is actor state and is left for the `stop()` the
    /// caller issues next, which the actor is now free to run.
    public nonisolated func abort() {
        framesLock.lock()
        aborted = true
        let stream = self.stream
        self.stream = nil
        framesLock.unlock()
        stream?.close()
    }

    /// Stores the freshly opened stream, or closes it and says so when the
    /// watchdog already fired.
    ///
    /// The two-step dance — claim, then read the flag — is what closes the window
    /// between `StreamFactory.open` returning and the stream becoming reachable by
    /// `abort()`. Either order aborts: an `abort()` before this call is seen by the
    /// flag, one after finds the stream.
    private func claimStream(_ stream: ProtocolStream) throws -> Bool {
        framesLock.lock()
        defer { framesLock.unlock() }
        guard !aborted else {
            stream.close()
            return false
        }
        self.stream = stream
        return true
    }
}

/// The cell size a connection tells the daemon, and whether the last correction still
/// owes a send.
///
/// Extracted from `EndpointConnection` so the correction rule lives in one place: the
/// daemon divides every pane's pixel rect by this value, the handshake can only carry a
/// default, and `sendResize` early-returns on an unchanged grid — which is exactly the
/// case a correction arrives in.
struct CellSizeState: Equatable, Sendable {
    var width: UInt32 = 10
    var height: UInt32 = 20
    /// A corrected value that has not reached the wire yet.
    var stale = false

    /// Records a measured size. False when it is not a change worth sending.
    mutating func correct(width newWidth: UInt32, height newHeight: UInt32) -> Bool {
        guard newWidth > 0, newHeight > 0 else { return false }
        guard newWidth != width || newHeight != height else { return false }
        width = newWidth
        height = newHeight
        stale = true
        return true
    }
}

extension EndpointConnection {
    /// Whether a corrected cell size is still waiting to reach the wire.
    ///
    /// In an extension, not the actor body: the body is at its lint budget, and this is
    /// the one piece of the cell-size logic that is only useful to the tests.
    var needsCellSizeResendForTesting: Bool { cell.stale }

    /// Reports the measured cell size in device pixels, marking it for resend.
    ///
    /// The daemon divides every pane's pixel rect by it, and the hello could only carry
    /// the `(10, 20)` default. See `CellSizeState`.
    public func updateCellSize(width: UInt32, height: UInt32) {
        cell.correct(width: width, height: height)
    }
}
