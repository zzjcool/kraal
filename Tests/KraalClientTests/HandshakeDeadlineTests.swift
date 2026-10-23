// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Issue #66: the handshake deadline was only *checked between* reads, never
// enforced on them.
//
// Measured before the fix, against a unix socket that accepts and then says
// nothing and never closes:
//
//     $ kraal --socket /tmp/silent2.sock probe --timeout 6
//     STILL RUNNING after 28s  ->  the 10 s handshake deadline never fired
//
// and over SSH against a remote `herdr status client` that hangs:
//
//     STILL RUNNING after 50s  ->  30 s bridge deadline NOT enforced
//
// The tests below reproduce that peer: a real listening socket, a real accept,
// and silence afterwards. They are the ones that must go red if the read bound is
// removed — see the A/B note in `silentPeerTimesOut`.

import Darwin
import Foundation
import Testing

import KraalClient
import KraalProtocol
import KraalTransport

/// A unix-socket peer that behaves exactly like the one in the issue: it accepts
/// the connection and then neither writes nor closes.
///
/// A `reply` turns it into a healthy one-shot daemon instead, which is what the
/// "did the fix break the success path" test needs. `trickle` makes it dribble
/// bytes out slowly without ever completing a frame.
final class ScriptedSocketPeer: @unchecked Sendable {
    enum Failure: Error {
        case socket(errno: Int32)
        case bind(path: String, errno: Int32)
        case listen(errno: Int32)
    }

    let path: String
    private let listenDescriptor: Int32
    private let reply: Data?
    private let trickle: Data?
    private let trickleInterval: TimeInterval
    private let lock = NSLock()
    private var clientDescriptors: [Int32] = []

    init(
        reply: Data? = nil,
        trickle: Data? = nil,
        trickleInterval: TimeInterval = 0.2
    ) throws {
        self.reply = reply
        self.trickle = trickle
        self.trickleInterval = trickleInterval
        // `/tmp` directly, not `NSTemporaryDirectory()`: the per-app temp path is
        // long enough to be worth worrying about against `sun_path`'s 104 bytes.
        path = "/tmp/kraal-hs-\(UUID().uuidString.prefix(8)).sock"
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.socket(errno: errno) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        withUnsafeMutablePointer(to: &address.sun_path.0) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { destination in
                for (index, byte) in pathBytes.enumerated() {
                    destination[index] = CChar(bitPattern: byte)
                }
                destination[pathBytes.count] = 0
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw Failure.bind(path: path, errno: code)
        }
        guard listen(descriptor, 8) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw Failure.listen(errno: code)
        }
        listenDescriptor = descriptor
    }

    /// Accepts in the background. Each accepted socket is kept **open** and, when
    /// `reply` is nil, never written to.
    func startAccepting() {
        let thread = Thread { [self] in
            while true {
                let client = accept(listenDescriptor, nil, nil)
                if client < 0 { return }
                lock.lock()
                clientDescriptors.append(client)
                lock.unlock()
                if let reply { writeAll(reply, to: client) }
                if let trickle { dribble(trickle, to: client, every: trickleInterval) }
            }
        }
        thread.name = "kraal.test.silent-peer"
        thread.start()
    }

    private func writeAll(_ data: Data, to descriptor: Int32) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < data.count {
                let count = Darwin.write(descriptor, base.advanced(by: written), data.count - written)
                if count > 0 {
                    written += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }

    /// Sends one byte per interval, forever. A frame is never completed, so the
    /// client keeps waiting for the rest of it.
    private func dribble(_ data: Data, to descriptor: Int32, every interval: TimeInterval) {
        let thread = Thread { [self] in
            while true {
                for byte in data {
                    writeAll(Data([byte]), to: descriptor)
                    Thread.sleep(forTimeInterval: interval)
                }
            }
        }
        thread.name = "kraal.test.trickle-peer"
        thread.start()
    }

    func stop() {
        // Closing the listener makes the parked `accept` return -1.
        Darwin.close(listenDescriptor)
        lock.lock()
        let clients = clientDescriptors
        clientDescriptors = []
        lock.unlock()
        for client in clients { Darwin.close(client) }
        unlink(path)
    }
}

/// Runs `start()` off the test's executor and records whether it ever returned.
///
/// `start()` blocks by design (it reads the welcome synchronously), so the test
/// has to be able to say "it did not come back within N seconds" — that is the
/// symptom being fixed. A `DispatchSemaphore` gives that, and the two-step wait
/// in `silenceIsNotAnEarlyFailure` needs the same probe to be polled twice.
final class StartProbe: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stored: Result<Void, Error>?
    private let startedAt = Date()

    init(connection: EndpointConnection) {
        Task.detached {
            do {
                try await connection.start()
                self.record(.success(()))
            } catch {
                self.record(.failure(error))
            }
            self.semaphore.signal()
        }
    }

    private func record(_ result: Result<Void, Error>) {
        lock.lock()
        stored = result
        lock.unlock()
    }

    var result: Result<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }

    /// `true` when `start()` returned inside the window.
    func wait(_ seconds: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + seconds) == .success
    }
}

extension EndpointConnection {
    /// Drops the connection without waiting for it.
    ///
    /// `stop()` is an actor method, so it queues behind whatever the actor is
    /// doing — and in the failing case the actor *is* the problem: `start()` never
    /// returns, which is exactly what these tests are looking for. Awaiting a
    /// cleanup there would hang the run instead of reporting a red test, so the
    /// teardown is fire-and-forget.
    nonisolated func abandon() {
        Task.detached { await self.stop() }
    }
}

@Suite("Handshake deadline", .serialized)
struct HandshakeDeadlineTests {
    /// The test budget. Deliberately not `ConnectionLimits.handshakeTimeout` (10 s)
    /// — the point is that the bound is enforced, not what its production value
    /// is, and a test suite cannot spend ten seconds per case.
    private static let budget: TimeInterval = 0.5
    /// Generous slack for a loaded machine: the assertion is "bounded", not
    /// "bounded to the millisecond".
    private static let slack: TimeInterval = 3.0

    private static func connection(
        to path: String,
        timeout: TimeInterval,
        events: EventSink? = nil
    ) -> EndpointConnection {
        EndpointConnection(
            target: .unixSocket(path: path),
            surfaceSize: ClientSurfaceSize(cols: 80, rows: 24),
            handshakeTimeout: timeout
        ) { event in
            events?.append(event)
        }
    }

    /// **The decisive test for issue #66.**
    ///
    /// A peer that accepts and then says nothing, with a read that has no upper
    /// bound, is what made `start()` hang forever. This must go red if the
    /// handshake's read bound is removed (A/B: revert the `setReadTimeout` calls
    /// in `EndpointConnection.start()` and it hangs past the window below).
    ///
    /// It also pins the *kind* of failure: a timeout, not "the stream ended".
    /// Conflating the two is why "the daemon closed" and "the daemon is silent"
    /// looked identical while the issue was being traced.
    @Test("a silent peer cannot make start() hang")
    func silentPeerTimesOut() async throws {
        let peer = try ScriptedSocketPeer()
        peer.startAccepting()
        defer { peer.stop() }

        let connection = Self.connection(to: peer.path, timeout: Self.budget)
        let probe = StartProbe(connection: connection)

        let returned = probe.wait(Self.budget + Self.slack)
        let elapsed = probe.elapsed
        // Report before asserting so a red run says *how long* it hung.
        print(String(format: "silent peer: returned=%@ after %.2fs", "\(returned)", elapsed))

        #expect(returned, "start() never returned against a silent peer (\(elapsed)s)")
        guard returned, let result = probe.result else {
            connection.abandon()
            return
        }
        guard case let .failure(error) = result else {
            Issue.record("start() succeeded against a peer that never sent a welcome")
            connection.abandon()
            return
        }
        guard case let BridgeError.handshakeTimedOut(seconds) = error else {
            Issue.record("expected .handshakeTimedOut, got \(error)")
            connection.abandon()
            return
        }
        #expect(seconds == Self.budget, "the error must name the budget it applied; got \(seconds)s")
        let message = "\(error)"
        #expect(message.contains("0.5s"), "the message must carry the seconds: \(message)")
        connection.abandon()
    }

    /// The fix must not turn "silent" into "fails instantly": a peer that is
    /// merely slow (or simply has not answered yet) still gets its full budget.
    ///
    /// Without this, a `throw` placed on the first `SocketTimeout` would pass the
    /// test above while breaking every handshake that takes longer than one read
    /// window.
    @Test("silence is not a failure before the deadline")
    func silenceIsNotAnEarlyFailure() async throws {
        let budget: TimeInterval = 1.0
        let peer = try ScriptedSocketPeer()
        peer.startAccepting()
        defer { peer.stop() }

        let connection = Self.connection(to: peer.path, timeout: budget)
        let probe = StartProbe(connection: connection)

        let returnedEarly = probe.wait(0.3)
        print(String(format: "after 0.30s: returned=%@ elapsed=%.2fs", "\(returnedEarly)", probe.elapsed))
        #expect(!returnedEarly, "start() failed at \(probe.elapsed)s, well before the \(budget)s deadline")

        let returned = probe.wait(budget + Self.slack)
        let elapsed = probe.elapsed
        print(String(format: "silent peer: returned=%@ after %.2fs", "\(returned)", elapsed))
        #expect(returned, "start() never returned (\(elapsed)s)")
        #expect(elapsed >= budget * 0.8, "start() gave up after \(elapsed)s; the budget was \(budget)s")
        if let result = probe.result, case .success = result {
            Issue.record("start() succeeded against a peer that never sent a welcome")
        }
        connection.abandon()
    }

    /// A peer that dribbles bytes without ever completing a frame must not be
    /// able to extend the budget either.
    ///
    /// This is the same bug one level down: the socket timeout bounds *one* read,
    /// so arming it once per outer loop would let a slow-sender keep resetting the
    /// clock. The deadline has to be re-armed from what is left, on every read.
    @Test("a peer that trickles bytes cannot extend the deadline")
    func tricklingPeerStillTimesOut() async throws {
        let budget: TimeInterval = 0.5
        // A length prefix of 200 with none of the 200 body bytes: the decoder can
        // never complete a frame, so the read loop keeps asking for more.
        let peer = try ScriptedSocketPeer(
            trickle: Data([0xC8, 0x00, 0x00, 0x00]),
            trickleInterval: 0.2
        )
        peer.startAccepting()
        defer { peer.stop() }

        let connection = Self.connection(to: peer.path, timeout: budget)
        let probe = StartProbe(connection: connection)

        let returned = probe.wait(budget + Self.slack)
        let elapsed = probe.elapsed
        print(String(format: "trickling peer: returned=%@ after %.2fs", "\(returned)", elapsed))
        #expect(returned, "start() never returned against a trickling peer (\(elapsed)s)")
        guard returned, let result = probe.result else {
            connection.abandon()
            return
        }
        guard case let .failure(error) = result else {
            Issue.record("start() succeeded on a frame that never completed")
            connection.abandon()
            return
        }
        guard case BridgeError.handshakeTimedOut = error else {
            Issue.record("expected .handshakeTimedOut, got \(error)")
            connection.abandon()
            return
        }
        #expect(elapsed < budget + Self.slack, "the trickle stretched the deadline to \(elapsed)s")
        connection.abandon()
    }

    /// The other direction: a peer that *does* answer still handshakes, and does
    /// so immediately. A bound that is enforced by breaking the success path
    /// would be worse than the bug.
    @Test("a daemon that answers still handshakes")
    func welcomeStillCompletes() async throws {
        let peer = try ScriptedSocketPeer(reply: try Self.welcomeFrame())
        peer.startAccepting()
        defer { peer.stop() }

        let events = EventSink()
        let connection = Self.connection(
            to: peer.path,
            timeout: Self.budget + Self.slack,
            events: events
        )
        let probe = StartProbe(connection: connection)

        let returned = probe.wait(Self.slack)
        #expect(returned, "a peer that sent a welcome did not complete the handshake")
        guard returned, let result = probe.result else {
            connection.abandon()
            return
        }
        if case let .failure(error) = result {
            Issue.record("handshake failed against a well-behaved peer: \(error)")
        }
        let welcome = await connection.negotiatedWelcome
        #expect(welcome?.serverVersion == "0.9.4", "welcome was not decoded")
        #expect(events.connectedCount == 1, "no .connected event was delivered")
        connection.abandon()
    }

    /// One frame carrying `endpointControl("endpoint.welcome.v1", <json>)`.
    ///
    /// Built here rather than through the daemon so the test stays hermetic: the
    /// only thing this peer does is prove the read path still accepts a real
    /// frame.
    static func welcomeFrame(version: String = "0.9.4") throws -> Data {
        let json = """
        {
          "generation": 1,
          "server_version": "\(version)",
          "snapshot_codec": "shell.snapshot.v1",
          "surface_codec": "shell.surface.v1",
          "input_codec": "shell.input.semantic.v1",
          "blob_codec": "shell.blob.v1",
          "methods": ["client_shell.surface.set"],
          "capabilities": ["surface_interest", "health_check"]
        }
        """
        var writer = BincodeWriter()
        writer.writeVarint(20) // ServerMessage.endpointControl
        writer.writeString(EndpointProtocol.welcomeKind)
        writer.writeString(json)
        return try FrameEncoder.encode(Data(writer.bytes))
    }
}

/// Collects the connection events a test cares about.
final class EventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ConnectionEvent] = []

    func append(_ event: ConnectionEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var connectedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return events.filter {
            if case .connected = $0 { return true }
            return false
        }.count
    }
}
