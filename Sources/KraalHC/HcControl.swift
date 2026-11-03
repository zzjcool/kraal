// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The small control channel between a running Kraal window and the `kraal`
// CLI. It deliberately copies the shape of herdr-app's control socket:
// one JSON object per line, one command per connection, and no framing.

import Foundation
import KraalSocket

public enum HcControlError: Error, CustomStringConvertible {
    case pathTooLong(String)
    case badRequest(String)
    case malformedResponse(String)

    public var description: String {
        switch self {
        case let .pathTooLong(path):
            "control socket path is longer than \(unixSocketMaxPathBytes) bytes: \(path)"
        case let .badRequest(message):
            "bad control request: \(message)"
        case let .malformedResponse(message):
            "malformed control response: \(message)"
        }
    }
}

public enum HcControlRequest: Sendable, Equatable {
    case list
    case status
    case doAction(name: String, arguments: JSONValue)
    case shot(path: String)
    case raise

    public init(json: JSONValue) throws {
        guard let object = json.objectValue else {
            throw HcControlError.badRequest("expected a JSON object")
        }
        if object["ls"]?.boolValue == true {
            self = .list
        } else if object["status"]?.boolValue == true {
            self = .status
        } else if let name = object["do"]?.stringValue {
            let arguments = object["args"] ?? .null
            guard arguments.isNull || arguments.objectValue != nil else {
                throw HcControlError.badRequest("args must be an object or null")
            }
            self = .doAction(name: name, arguments: arguments)
        } else if let path = object["shot"]?.stringValue {
            guard !path.isEmpty else {
                throw HcControlError.badRequest("shot needs a path")
            }
            self = .shot(path: path)
        } else if object["raise"]?.boolValue == true {
            self = .raise
        } else {
            throw HcControlError.badRequest("expected { ls }, { status }, { do }, { shot } or { raise }")
        }
    }

    public var json: JSONValue {
        switch self {
        case .list:
            .object(["ls": .bool(true)])
        case .status:
            .object(["status": .bool(true)])
        case let .doAction(name, arguments):
            .object(["do": .string(name), "args": arguments])
        case let .shot(path):
            .object(["shot": .string(path)])
        case .raise:
            .object(["raise": .bool(true)])
        }
    }
}

public enum HcControlPaths {
    /// `KRAAL_CONTROL_SOCKET` wins. Otherwise a custom `KRAAL_HC_VIEW` gets a
    /// sibling `control.sock` so split test windows cannot talk to each other;
    /// the normal path is `$XDG_CONFIG_HOME/kraal/control.sock`.
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> String {
        let explicit = environment["KRAAL_CONTROL_SOCKET"] ?? ""
        if !explicit.isEmpty { return try checked(explicit) }
        if let view = environment["KRAAL_HC_VIEW"], !view.isEmpty {
            return try checked(
                URL(fileURLWithPath: view).deletingLastPathComponent()
                    .appendingPathComponent("control.sock").path
            )
        }
        let config = environment["XDG_CONFIG_HOME"].flatMap { value -> URL? in
            value.isEmpty ? nil : URL(fileURLWithPath: value)
        } ?? home.appendingPathComponent(".config")
        return try checked(config.appendingPathComponent("kraal/control.sock").path)
    }

    private static func checked(_ path: String) throws -> String {
        guard Array(path.utf8).count <= unixSocketMaxPathBytes else {
            throw HcControlError.pathTooLong(path)
        }
        return path
    }
}

public enum HcControlClient {
    /// Sends one request and returns the decoded object. Throws when no window
    /// is listening; a well-formed `{"error": …}` reply is returned, not thrown,
    /// because the CLI prints it and exits 1 (matching herdr-app).
    public static func send(
        _ request: HcControlRequest,
        path: String,
        timeout: TimeInterval = 5
    ) throws -> JSONValue {
        let socket = try UnixSocket.connect(path: path, timeoutSeconds: timeout)
        defer { socket.close() }
        var data = try JSONEncoder().encode(request.json)
        data.append(0x0A)
        try socket.write(data)
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        while Date() < deadline {
            guard let chunk = try socket.read(maxLength: 64 * 1024) else { break }
            buffer.append(chunk)
            if let newline = buffer.firstIndex(of: 0x0A) {
                return try decode(buffer.prefix(upTo: newline))
            }
            guard buffer.count <= 4 * 1024 * 1024 else {
                throw HcControlError.malformedResponse("reply is too large")
            }
        }
        throw HcControlError.malformedResponse("window did not answer")
    }

    private static func decode(_ data: Data) throws -> JSONValue {
        guard !data.isEmpty else {
            throw HcControlError.malformedResponse("empty reply")
        }
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw HcControlError.malformedResponse("\(error)")
        }
    }
}

/// The app-side listener. The handler runs on the main actor; the socket loop
/// never does, because blocking reads there would freeze the window.
public final class HcControlServer: @unchecked Sendable {
    public typealias Handler = @MainActor @Sendable (HcControlRequest) async -> JSONValue

    private let path: String
    private let handler: Handler
    private var server: UnixSocketServer?
    private var thread: Thread?
    private let stateLock = NSLock()
    private var running = false

    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    deinit { stop() }

    public func start() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !running else { return }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let listener = try UnixSocketServer(path: path)
        server = listener
        running = true
        let thread = Thread { [weak self] in self?.acceptLoop(listener) }
        thread.name = "kraal.control"
        self.thread = thread
        thread.start()
    }

    public func stop() {
        stateLock.lock()
        guard running else {
            stateLock.unlock()
            return
        }
        running = false
        let listener = server
        server = nil
        let worker = thread
        thread = nil
        stateLock.unlock()
        listener?.close()
        worker?.cancel()
    }

    private func acceptLoop(_ listener: UnixSocketServer) {
        while isRunning, let client = listener.accept() {
            handle(client)
        }
    }

    private var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    private func handle(_ socket: UnixSocket) {
        defer { socket.close() }
        do {
            socket.setReadTimeout(5)
            let line = try readLine(socket)
            let request = try HcControlRequest(json: JSONDecoder().decode(JSONValue.self, from: line))
            let response = respond(to: request)
            var data = try JSONEncoder().encode(response)
            data.append(0x0A)
            try socket.write(data)
        } catch {
            let response = HcControlServer.errorResponse("\(error)")
            if let data = try? JSONEncoder().encode(response) {
                var line = data
                line.append(0x0A)
                try? socket.write(line)
            }
        }
    }

    private func readLine(_ socket: UnixSocket) throws -> Data {
        var buffer = Data()
        while true {
            guard let chunk = try socket.read(maxLength: 64 * 1024) else {
                throw HcControlError.badRequest("connection closed before a newline")
            }
            buffer.append(chunk)
            if let newline = buffer.firstIndex(of: 0x0A) {
                return Data(buffer[..<newline])
            }
            guard buffer.count <= 1024 * 1024 else {
                throw HcControlError.badRequest("request is too large")
            }
        }
    }

    private func respond(to request: HcControlRequest) -> JSONValue {
        let box = LockedBox<JSONValue>(.object(["error": .string("the window did not answer")]))
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor [handler] in
            box.value = await handler(request)
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 35) == .timedOut {
            return .object(["error": .string("the window did not answer")])
        }
        return box.value
    }

    private static func errorResponse(_ message: String) -> JSONValue {
        .object(["error": .string(message)])
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}
