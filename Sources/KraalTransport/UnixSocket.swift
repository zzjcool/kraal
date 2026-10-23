// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// A small POSIX unix-domain-socket wrapper.
//
// `Network.framework` can carry unix sockets on macOS/iOS but adds framing
// latency and makes partial reads harder to reason about. The endpoint protocol
// is a raw byte stream, so a plain `socket(2)` with a dedicated read thread is
// both simpler and closer to what the daemon's own Rust client does.

import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum SocketError: Error, CustomStringConvertible {
    case pathTooLong(String)
    case createFailed(errno: Int32)
    case setNonBlockingFailed(errno: Int32)
    case connectFailed(path: String, errno: Int32)
    case writeFailed(errno: Int32)
    case closed

    public var description: String {
        switch self {
        case let .pathTooLong(path):
            "socket path longer than the platform limit: \(path)"
        case let .createFailed(code):
            "socket() failed: \(String(cString: strerror(code)))"
        case let .setNonBlockingFailed(code):
            "fcntl(O_NONBLOCK) failed: \(String(cString: strerror(code)))"
        case let .connectFailed(path, code):
            "connect(\(path)) failed: \(String(cString: strerror(code)))"
        case let .writeFailed(code):
            "write() failed: \(String(cString: strerror(code)))"
        case .closed:
            "socket closed"
        }
    }
}

/// One connected unix socket. Reads are blocking and are expected to run on a
/// dedicated thread; writes may come from any thread and are serialized here.
/// The largest socket path this platform accepts.
///
/// `sun_path` is 104 bytes on Darwin, one of which is the NUL terminator, so a
/// path may be 103 bytes. Exposed as a constant because it is a *budget* other
/// code has to plan against, not a detail of this file: issue #90 was a session
/// name check that allowed 64 characters while the path those characters produce
/// could not fit.
public let unixSocketMaxPathBytes = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

public final class UnixSocket: @unchecked Sendable {
    private var handle: Int32
    private let writeLock = NSLock()
    private let readLock = NSLock()
    private var isClosed = false

    private init(handle: Int32) {
        self.handle = handle
    }

    deinit {
        close()
    }

    /// Connects to a filesystem socket path.
    ///
    /// A positive `timeoutSeconds` arms `SO_RCVTIMEO`, so any later read that
    /// finds no data throws `SocketTimeout` instead of parking forever. Zero (or
    /// negative) means "block forever".
    ///
    /// Which one a caller wants depends on the phase, not the socket: a handshake
    /// needs the bound (otherwise a peer that accepts and says nothing blocks
    /// `read(2)` forever and the caller's own deadline never gets checked), while
    /// the frame loop wants to wait indefinitely and be woken by `close()`.
    /// `setReadTimeout` switches between them.
    public static func connect(
        path: String,
        timeoutSeconds: TimeInterval = 10
    ) throws -> UnixSocket {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(path.utf8)
        let maxLength = unixSocketMaxPathBytes
        guard pathBytes.count <= maxLength else {
            throw SocketError.pathTooLong(path)
        }
        withUnsafeMutablePointer(to: &address.sun_path.0) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maxLength + 1) { destination in
                for (index, byte) in pathBytes.enumerated() {
                    destination[index] = CChar(bitPattern: byte)
                }
                destination[pathBytes.count] = 0
            }
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw SocketError.createFailed(errno: errno)
        }

        // SO_NOSIGPIPE: a peer that dies mid-write must surface as EPIPE, not
        // as a delivered SIGPIPE that kills the app.
        var noSigPipe: Int32 = 1
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(descriptor, sockaddrPointer, size)
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw SocketError.connectFailed(path: path, errno: code)
        }

        if timeoutSeconds > 0 {
            applyReadTimeout(descriptor, timeoutSeconds)
        }

        return UnixSocket(handle: descriptor)
    }

    /// Changes how long one `read` may block. Zero restores "wait forever".
    ///
    /// Used to hand the socket from the handshake (bounded) to the frame loop
    /// (unbounded) without reopening it: the reader thread that takes over is
    /// built around a read that parks until the daemon speaks or the socket is
    /// closed by `close()`.
    public func setReadTimeout(_ seconds: TimeInterval) {
        readLock.lock()
        defer { readLock.unlock() }
        guard !isClosed else { return }
        if seconds > 0 {
            Self.applyReadTimeout(handle, seconds)
        } else {
            // POSIX reads a zero `timeval` as "no timeout", which is exactly the
            // original, never-armed state.
            var none = timeval(tv_sec: 0, tv_usec: 0)
            setsockopt(
                handle,
                SOL_SOCKET,
                SO_RCVTIMEO,
                &none,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
    }

    /// Arms `SO_RCVTIMEO` with sub-second precision.
    ///
    /// Whole seconds only would make any deadline overshoot by up to a second;
    /// `timeval` carries microseconds, and a test that pins a one-second budget
    /// cannot afford that slack.
    private static func applyReadTimeout(_ descriptor: Int32, _ seconds: TimeInterval) {
        let whole = Int(seconds)
        var timeout = timeval(
            tv_sec: whole,
            tv_usec: Int32(((seconds - Double(whole)) * 1_000_000).rounded())
        )
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
    }

    /// Blocks until at least one byte arrives. Returns `nil` at end of stream.
    public func read(maxLength: Int = 64 * 1024) throws -> Data? {
        readLock.lock()
        defer { readLock.unlock() }
        guard !isClosed else { return nil }

        var buffer = [UInt8](repeating: 0, count: maxLength)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.read(handle, base, maxLength)
            }
            if count > 0 {
                return Data(buffer[0 ..< count])
            }
            if count == 0 {
                return nil
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                // Timed out waiting; report "nothing yet" rather than an error
                // so the caller can re-check its own deadlines.
                throw SocketTimeout()
            }
            throw SocketError.writeFailed(errno: errno)
        }
    }

    /// Writes the whole buffer. Returns only after every byte is queued.
    public func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !isClosed else { throw SocketError.closed }

        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < data.count {
                let count = Darwin.write(
                    handle,
                    base.advanced(by: written),
                    data.count - written
                )
                if count > 0 {
                    written += count
                    continue
                }
                if count < 0, errno == EINTR { continue }
                throw SocketError.writeFailed(errno: errno)
            }
        }
    }

    public func close() {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        Darwin.shutdown(handle, SHUT_RDWR)
        Darwin.close(handle)
    }
}

/// Thrown by `UnixSocket.read` when `SO_RCVTIMEO` expires with no data. Not an
/// error condition for the caller, which may simply retry.
public struct SocketTimeout: Error {
    public init() {}
}
