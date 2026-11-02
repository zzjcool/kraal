// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// A scriptable core for the wire tests: a unix socket that answers `hello`,
// then speaks framed herdr-core until the test closes it. It never starts a real
// core, so the tests are deterministic and cannot touch a developer's sessions.

import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@testable import KraalHC

enum FakeCoreError: Error, CustomStringConvertible {
    case socket(String)
    case bind(String)
    case listen(String)
    case pathTooLong

    var description: String {
        switch self {
        case let .socket(message): "fake core socket: \(message)"
        case let .bind(message): "fake core bind: \(message)"
        case let .listen(message): "fake core listen: \(message)"
        case .pathTooLong: "fake core socket path is too long"
        }
    }
}

final class FakeCore: @unchecked Sendable {
    let socketPath: String
    var hello: JSONValue
    /// Written in the same `write` as the hello reply, before `onSession`: the
    /// bytes a client sees coalesced with the handshake.
    ///
    /// Locked: the test sets these on its thread while the accept thread reads
    /// them, and an unsynchronized read made the handler appear nil under load
    /// (the core answered hello, then never the attach call).
    var helloAppend: Data? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return helloAppendValue
        }
        set {
            lock.lock()
            helloAppendValue = newValue
            lock.unlock()
        }
    }

    /// Runs on the accept thread. The session is already past `hello`; frames
    /// written before the client registers a channel are buffered by the client.
    var onSession: ((FakeCoreSession) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return onSessionValue
        }
        set {
            lock.lock()
            onSessionValue = newValue
            lock.unlock()
        }
    }
    private var connectionCount = 0

    var acceptedConnections: Int {
        lock.lock()
        defer { lock.unlock() }
        return connectionCount
    }

    private let listener: Int32
    private let lock = NSLock()
    private var helloAppendValue: Data?
    private var onSessionValue: ((FakeCoreSession) -> Void)?
    private var running = true
    private var acceptThread: Thread?

    init(directory: String, hello: JSONValue? = nil) throws {
        socketPath = directory + "/core.sock"
        self.hello = if let hello { hello } else { try FakeCore.defaultHello() }
        unlink(socketPath)

        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else {
            throw FakeCoreError.socket("socket() failed: \(errno)")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw FakeCoreError.pathTooLong
        }
        withUnsafeMutablePointer(to: &address.sun_path.0) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { destination in
                for (index, byte) in bytes.enumerated() {
                    destination[index] = CChar(bitPattern: byte)
                }
                destination[bytes.count] = 0
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, size)
            }
        }
        guard bound == 0 else {
            throw FakeCoreError.bind("bind(\(socketPath)) failed: \(errno)")
        }
        guard listen(listener, 8) == 0 else {
            throw FakeCoreError.listen("listen() failed: \(errno)")
        }
    }

    deinit {
        stop()
    }

    func start() {
        let thread = Thread { [weak self] in
            self?.acceptLoop()
        }
        thread.name = "kraal.fake-core"
        thread.start()
        acceptThread = thread
    }

    func stop() {
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        running = false
        lock.unlock()
        shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        unlink(socketPath)
    }

    private func isRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func acceptLoop() {
        while isRunning() {
            let descriptor = accept(listener, nil, nil)
            if descriptor < 0 {
                if errno == EINTR { continue }
                return
            }
            lock.lock()
            connectionCount += 1
            lock.unlock()
            let session = FakeCoreSession(descriptor: descriptor)
            serve(session)
            session.close()
        }
    }

    private func serve(_ session: FakeCoreSession) {
        guard let line = session.readLine() else { return }
        guard (try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))) != nil else {
            return
        }
        let reply = JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .int(1),
            "result": hello,
        ])
        if let extra = helloAppend {
            var bytes = Data((reply.compactDescription + "\n").utf8)
            bytes.append(extra)
            session.writeRaw(bytes)
        } else {
            session.writeLine(reply.compactDescription)
        }
        onSession?(session)
    }

    static func defaultHello(
        generation: Int = 1,
        version: String = "0.1.16",
        methods: [String] = HcProtocol.requiredMethods
    ) throws -> JSONValue {
        .object([
            "generation": .int(generation),
            "version": .string(version),
            "core": .object(["id": .string("fake-core"), "name": .string("fake")]),
            "framed": .bool(true),
            "methods": .array(methods.map(JSONValue.string)),
            "features": .array([.string("framed"), .string("attach"), .string("events"), .string("status")]),
        ])
    }
}

final class FakeCoreSession {
    private let descriptor: Int32
    private var buffer = Data()
    private var writeFailed = false
    private var closed = false

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func close() {
        guard !closed else { return }
        closed = true
        shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }

    /// Gives `readFrame`/`readLine` a deadline so a test script cannot block the
    /// accept thread forever when the client stops sending.
    func setReadTimeout(_ seconds: Double) {
        var value = timeval(
            tv_sec: Int(seconds),
            tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000)
        )
        setsockopt(
            descriptor, SOL_SOCKET, SO_RCVTIMEO,
            &value, socklen_t(MemoryLayout<timeval>.size)
        )
    }

    func readLine() -> String? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex ..< newline)
                buffer.removeFirst(buffer.distance(from: buffer.startIndex, to: newline) + 1)
                return String(bytes: line, encoding: .utf8)
            }
            guard readMore() else { return nil }
        }
    }

    func readFrame() -> HcFrame? {
        while buffer.count < HcWire.headerSize {
            guard readMore() else { return nil }
        }
        let header = [UInt8](buffer.prefix(HcWire.headerSize))
        let channel = UInt32(header[0])
            | (UInt32(header[1]) << 8)
            | (UInt32(header[2]) << 16)
            | (UInt32(header[3]) << 24)
        let kind = header[4]
        let length = Int(header[5])
            | (Int(header[6]) << 8)
            | (Int(header[7]) << 16)
            | (Int(header[8]) << 24)
        while buffer.count < HcWire.headerSize + length {
            guard readMore() else { return nil }
        }
        let start = buffer.startIndex + HcWire.headerSize
        let payload = buffer.subdata(in: start ..< start + length)
        buffer.removeFirst(HcWire.headerSize + length)
        return HcFrame(channel: channel, kind: kind, payload: payload)
    }

    func writeLine(_ text: String) {
        write(Data((text + "\n").utf8))
    }

    func writeMessage(_ message: JSONValue) {
        guard let payload = try? JSONEncoder().encode(message),
              let frame = try? HcWire.dataFrame(channel: 0, payload: payload)
        else { return }
        write(frame)
    }

    func writeRaw(_ data: Data) {
        write(data)
    }

    func writeFrame(channel: UInt32, kind: HcFrameKind, payload: Data = Data()) {
        guard let frame = try? HcWire.frame(channel: channel, kind: kind.rawValue, payload: payload) else {
            return
        }
        write(frame)
    }

    private func readMore() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 32 * 1024)
        let count = chunk.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return Darwin.read(descriptor, base, raw.count)
        }
        if count <= 0 { return false }
        buffer.append(contentsOf: chunk[0 ..< count])
        return true
    }

    private func write(_ data: Data) {
        guard !writeFailed else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < data.count {
                let count = Darwin.write(descriptor, base.advanced(by: written), data.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    writeFailed = true
                    return
                }
                written += count
            }
        }
    }
}
