// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The listening half of the unix-socket wrapper. Kept separate from
// `UnixSocket` because a server has different lifetime rules: it owns a path,
// must refuse to steal a live listener, and unlinks only the socket it bound.

import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum UnixSocketServerError: Error, CustomStringConvertible {
    case pathTooLong(String)
    case createFailed(errno: Int32)
    case addressInUse(String)
    case bindFailed(path: String, errno: Int32)
    case listenFailed(errno: Int32)
    case acceptFailed(errno: Int32)

    public var description: String {
        switch self {
        case let .pathTooLong(path):
            "socket path longer than the platform limit: \(path)"
        case let .createFailed(code):
            "socket() failed: \(String(cString: strerror(code)))"
        case let .addressInUse(path):
            "another process is already listening on \(path)"
        case let .bindFailed(path, code):
            "bind(\(path)) failed: \(String(cString: strerror(code)))"
        case let .listenFailed(code):
            "listen() failed: \(String(cString: strerror(code)))"
        case let .acceptFailed(code):
            "accept() failed: \(String(cString: strerror(code)))"
        }
    }
}

/// A blocking unix-domain listener. `accept` is expected on a dedicated thread;
/// the caller handles each returned stream and closes it.
public final class UnixSocketServer: @unchecked Sendable {
    private var handle: Int32
    public let path: String
    private let closeLock = NSLock()
    private var closed = false

    public init(path: String, backlog: Int32 = 8) throws {
        self.path = path
        let bytes = Array(path.utf8)
        guard bytes.count <= unixSocketMaxPathBytes else {
            throw UnixSocketServerError.pathTooLong(path)
        }

        // Do not unlink a live listener. A connect that succeeds is the only
        // cheap proof that a process is still accepting there; a stale file
        // refuses the connection and may be removed.
        if (try? UnixSocket.connect(path: path, timeoutSeconds: 0.2)) != nil {
            throw UnixSocketServerError.addressInUse(path)
        }
        unlink(path)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw UnixSocketServerError.createFailed(errno: errno)
        }
        var noSigPipe: Int32 = 1
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path.0) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: unixSocketMaxPathBytes + 1) { destination in
                for (index, byte) in bytes.enumerated() {
                    destination[index] = CChar(bitPattern: byte)
                }
                destination[bytes.count] = 0
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(descriptor, sockaddrPointer, size)
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw UnixSocketServerError.bindFailed(path: path, errno: code)
        }
        chmod(path, 0o600)
        guard Darwin.listen(descriptor, backlog) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            unlink(path)
            throw UnixSocketServerError.listenFailed(errno: code)
        }
        handle = descriptor
    }

    deinit {
        close()
    }

    /// Blocks until a client connects. Returns nil after `close()`.
    public func accept() -> UnixSocket? {
        while true {
            let client = Darwin.accept(handle, nil, nil)
            if client >= 0 {
                var noSigPipe: Int32 = 1
                setsockopt(
                    client,
                    SOL_SOCKET,
                    SO_NOSIGPIPE,
                    &noSigPipe,
                    socklen_t(MemoryLayout<Int32>.size)
                )
                return UnixSocket.connected(handle: client)
            }
            if errno == EINTR { continue }
            return nil
        }
    }

    public func close() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.shutdown(handle, SHUT_RDWR)
        Darwin.close(handle)
        unlink(path)
    }
}
