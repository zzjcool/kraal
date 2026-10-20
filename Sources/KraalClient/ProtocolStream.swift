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
    case frame(FrameError)
    case wire(WireDecodeError)
    case transport(String)
    case requestTimeout(method: String)

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
        case let .frame(error):
            error.description
        case let .wire(error):
            error.description
        case let .transport(detail):
            detail
        case let .requestTimeout(method):
            "the daemon did not answer \(method) within the timeout"
        }
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
}

public final class UnixSocketStream: ProtocolStream, @unchecked Sendable {
    private let socket: UnixSocket

    public init(socket: UnixSocket) {
        self.socket = socket
    }

    public func read(maxLength: Int) throws -> Data? {
        do {
            return try socket.read(maxLength: maxLength)
        } catch is SocketTimeout {
            // A read timeout is a "nothing yet", not a failure.
            return Data()
        }
    }

    public func write(_ data: Data) throws {
        try socket.write(data)
    }

    public func close() {
        socket.close()
    }
}

public final class SSHStream: ProtocolStream, @unchecked Sendable {
    private let transport: SSHProcessTransport

    public init(transport: SSHProcessTransport) {
        self.transport = transport
    }

    public func read(maxLength: Int) throws -> Data? {
        transport.read(maxLength: maxLength)
    }

    public func write(_ data: Data) throws {
        try transport.write(data)
    }

    public func close() {
        transport.close()
    }
}

public enum StreamFactory {
    /// Opens a stream to a resolved target.
    public static func open(_ target: HerdrTarget) throws -> ProtocolStream {
        switch target {
        case let .unixSocket(path):
            let socket = try UnixSocket.connect(path: path, timeoutSeconds: 0)
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
