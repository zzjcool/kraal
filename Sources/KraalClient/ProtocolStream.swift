// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Transport abstraction: one bidirectional byte stream carrying framed protocol
// messages. A local unix socket and an SSH child process both reduce to this, so
// everything above the frame loop is transport-agnostic.

import Foundation
import KraalProtocol
import KraalTransport

public enum BridgeError: Error, CustomStringConvertible {
    case expectedWelcome(String)
    case welcomeKind(String)
    case handshakeRejected(String)
    case unexpectedStreamEnd
    /// The peer accepted the connection and then said nothing until the deadline.
    ///
    /// Deliberately **not** `unexpectedStreamEnd`: "the daemon closed" and "the
    /// daemon is silent" are different faults with different fixes, and merging
    /// them is what made issue #66 hard to see — the silent case never even
    /// reached an error, it simply never returned.
    case handshakeTimedOut(seconds: TimeInterval)
    case frame(FrameError)
    case wire(WireDecodeError)
    case transport(String)
    case requestTimeout(method: String)
    /// The daemon answered with an `error` envelope instead of a result.
    ///
    /// This is a *reply*, not a transport failure, so nothing throws at the
    /// socket layer — the envelope has to be inspected. Missing that is how a
    /// refused `pane.split` looked like a success: the body carried
    /// `{"error":{"code":"endpoint_busy"}}` and every caller that only checked
    /// for a thrown error treated it as done.
    case daemon(method: String, code: String, message: String)

    public var description: String {
        switch self {
        case let .expectedWelcome(kind):
            "expected endpoint.welcome.v1 but the daemon sent \"\(kind)\""
        case let .welcomeKind(kind):
            "the daemon answered the hello with unexpected control \"\(kind)\""
        case let .handshakeRejected(detail):
            detail
        case .unexpectedStreamEnd:
            "the connection closed before the handshake finished"
        case let .handshakeTimedOut(seconds):
            "the daemon did not answer the handshake within \(Self.secondsText(seconds))"
        case let .frame(error):
            error.description
        case let .wire(error):
            error.description
        case let .transport(detail):
            detail
        case let .requestTimeout(method):
            "the daemon did not answer \(method) within the timeout"
        case let .daemon(method, code, message):
            "\(method) refused by the daemon: \(code) — \(message)"
        }
    }

    /// Whole seconds read as "10s", fractions keep one decimal ("0.5s") — a test
    /// budget under a second must not print as "0s".
    static func secondsText(_ seconds: TimeInterval) -> String {
        let rounded = (seconds * 10).rounded() / 10
        return rounded == rounded.rounded() ? "\(Int(rounded))s" : "\(rounded)s"
    }
}

/// One connected byte stream.
///
/// `read` blocks; the bridge calls it from a dedicated thread, so no locks are
/// needed between reads and writes.
public protocol ProtocolStream: AnyObject, Sendable {
    func read(maxLength: Int) throws -> Data?
    func write(_ data: Data) throws
    func close()
    /// Bounds how long one `read` may wait. Zero means "until the peer speaks".
    ///
    /// The two phases want opposite answers: a handshake must give up (else a
    /// silent peer blocks `read(2)` forever and the deadline is never checked),
    /// while the frame loop must wait as long as it takes. Streams whose reads are
    /// already bounded by something else — the SSH bridge polls its pipe — treat
    /// this as a no-op.
    func setReadTimeout(_ seconds: TimeInterval)
}

public extension ProtocolStream {
    func setReadTimeout(_ seconds: TimeInterval) {}
}

public final class UnixSocketStream: ProtocolStream, @unchecked Sendable {
    private let socket: UnixSocket

    public init(socket: UnixSocket) {
        self.socket = socket
    }

    public func read(maxLength: Int) throws -> Data? {
        // A socket read timeout surfaces as `SocketTimeout` on purpose: the
        // handshake loop has to see it to re-check its deadline. Swallowing it
        // here turned "silent peer" into an endless loop of empty reads.
        try socket.read(maxLength: maxLength)
    }

    public func write(_ data: Data) throws {
        try socket.write(data)
    }

    public func close() {
        socket.close()
    }

    public func setReadTimeout(_ seconds: TimeInterval) {
        socket.setReadTimeout(seconds)
    }
}

public final class SSHStream: ProtocolStream, @unchecked Sendable {
    private let transport: SSHProcessTransport
    private let timeoutLock = NSLock()
    private var readTimeout: TimeInterval = 0

    public init(transport: SSHProcessTransport) {
        self.transport = transport
    }

    public func read(maxLength: Int) throws -> Data? {
        timeoutLock.lock()
        let timeout = readTimeout
        timeoutLock.unlock()
        return try transport.read(maxLength: maxLength, timeout: timeout)
    }

    public func write(_ data: Data) throws {
        try transport.write(data)
    }

    public func close() {
        transport.close()
    }

    /// The pipe has no `SO_RCVTIMEO`; the bound is carried here and handed to the
    /// transport's `poll(2)`. Without it the welcome read after the bridge banner
    /// would block forever, which is the SSH half of issue #66.
    public func setReadTimeout(_ seconds: TimeInterval) {
        timeoutLock.lock()
        readTimeout = seconds
        timeoutLock.unlock()
    }
}

public enum StreamFactory {
    /// Opens a stream to a resolved target.
    ///
    /// `handshakeTimeout` bounds **one read on the returned stream**, not the
    /// whole connect: a local socket is opened with that bound armed so a peer
    /// that accepts and stays silent cannot park the first read forever.
    ///
    /// The SSH bridge keeps its own, longer budget (`SSHProcessTransport`'s 30 s
    /// default). Not an oversight: `ssh` itself is allowed `ConnectTimeout=10`
    /// before the remote even starts running `herdr status`, so the bridge cannot
    /// be squeezed into a handshake budget meant for an already-established
    /// socket. That deadline is enforced too — see `performReadyHandshake`.
    public static func open(
        _ target: HerdrTarget,
        handshakeTimeout: TimeInterval = ConnectionLimits.handshakeTimeout
    ) throws -> ProtocolStream {
        switch target {
        case let .unixSocket(path):
            let socket = try UnixSocket.connect(
                path: path,
                timeoutSeconds: handshakeTimeout
            )
            return UnixSocketStream(socket: socket)
        case let .sshShell(user, host, port, session):
            let transport = try SSHProcessTransport.connect(
                user: user,
                host: host,
                port: port,
                session: session
            )
            return SSHStream(transport: transport)
        }
    }
}
