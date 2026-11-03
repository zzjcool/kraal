// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// A connection that survives core restarts.
//
// A core restart wipes the socket and every channel; `seq` starts over. This
// wrapper reconnects with backoff and republishes state. Re-subscribing and
// rebuilding the snapshot belong to the events layer (#225); calls made while
// the link is down fail with `notConnected` instead of queueing forever.

import Foundation
import KraalSocket

/// Creates a fresh byte pipe on every reconnect attempt. The closure must not
/// reuse a closed link.
public typealias HcLinkFactory = @Sendable () throws -> any HcByteLink

public enum HcClientEvent: Sendable {
    case connecting(attempt: Int)
    case ready(HcHelloResult)
    /// The core is too old/new or lacks a method; retrying cannot fix it.
    case incompatible(HcCompatibility)
    case disconnected(reason: String?)
    case failed(HcConnectionError)
}

public final class HcClient: @unchecked Sendable {
    /// A human-readable label for logs/status. For a socket this is the path;
    /// for SSH it is `ssh:<host>`.
    public let path: String
    public let events: AsyncStream<HcClientEvent>

    private let linkFactory: HcLinkFactory
    private let eventContinuation: AsyncStream<HcClientEvent>.Continuation
    private let stateLock = NSLock()
    private let initialBackoff: TimeInterval
    private let maxBackoff: TimeInterval
    private var connection: HcConnection?
    private var runTask: Task<Void, Never>?
    private var stopped = false

    public convenience init(
        path: String,
        initialBackoff: TimeInterval = 0.5,
        maxBackoff: TimeInterval = 30
    ) {
        self.init(
            linkFactory: {
                let socket = try UnixSocket.connect(path: path, timeoutSeconds: 10)
                return socket
            },
            label: path,
            initialBackoff: initialBackoff,
            maxBackoff: maxBackoff
        )
    }

    /// Connects through an injected pipe. The factory is called once per
    /// reconnect, so an SSH implementation can start a fresh `ssh -T host hc
    /// connect` after the old process exits.
    public init(
        linkFactory: @escaping HcLinkFactory,
        label: String,
        initialBackoff: TimeInterval = 0.5,
        maxBackoff: TimeInterval = 30
    ) {
        self.path = label
        self.linkFactory = linkFactory
        self.initialBackoff = initialBackoff
        self.maxBackoff = maxBackoff
        let (stream, continuation) = AsyncStream<HcClientEvent>.makeStream()
        events = stream
        eventContinuation = continuation
    }

    #if os(macOS)
    /// The `ssh -T <host> hc connect` transport. The remote command is passed
    /// as a single argument to ssh, which is what makes it a remote shell
    /// command rather than a local one.
    public convenience init(
        sshHost: String,
        remoteCommand: String = "hc connect",
        initialBackoff: TimeInterval = 0.5,
        maxBackoff: TimeInterval = 30
    ) {
        self.init(
            linkFactory: {
                try HcSSHLink(host: sshHost, remoteCommand: remoteCommand)
            },
            label: "ssh:\(sshHost)",
            initialBackoff: initialBackoff,
            maxBackoff: maxBackoff
        )
    }
    #endif

    public var isConnected: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return connection != nil
    }

    public func start() {
        stateLock.lock()
        guard runTask == nil, !stopped else {
            stateLock.unlock()
            return
        }
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.run()
        }
        runTask = task
        stateLock.unlock()
    }

    public func stop() {
        stateLock.lock()
        if stopped {
            stateLock.unlock()
            return
        }
        stopped = true
        let task = runTask
        let current = connection
        runTask = nil
        connection = nil
        stateLock.unlock()

        current?.close()
        task?.cancel()
        eventContinuation.finish()
    }

    public func call(_ method: String, params: JSONValue = .object([:])) async throws -> JSONValue {
        guard let connection = currentConnection() else {
            throw HcConnectionError.notConnected
        }
        return try await connection.call(method, params: params)
    }

    /// Subscribes to events on the current link. A reconnect drops the
    /// channel; subscribe again and replace the store with the new snapshot.
    public func subscribeEvents(
        filter: HcEventFilter = HcEventFilter(),
        handlers: HcEventHandlers
    ) async throws -> HcEventSubscription {
        guard let connection = currentConnection() else {
            throw HcConnectionError.notConnected
        }
        return try await HcEventSubscription.subscribe(connection, filter: filter, handlers: handlers)
    }

    /// The machines this core has added. `temporary` ones are included: the
    /// filter is a client decision, and `machine.rename`/`rm` still need them.
    public func machines() async throws -> [HcMachine] {
        let reply = try await call("machine.list")
        return (reply["machines"]?.arrayValue ?? []).map(HcMachine.init(json:))
    }

    /// Adds a machine reached by ssh (`target`) or by a command (`via`).
    ///
    /// The core owns the connection; this replies with the profile before the
    /// first dial finishes. `machine.list` carries the state afterwards.
    public func addMachine(
        target: String? = nil,
        via: String? = nil,
        name: String? = nil,
        session: String? = nil,
        temporary: Bool = false
    ) async throws -> HcMachine {
        var params: [String: JSONValue] = [:]
        if let target { params["target"] = .string(target) }
        if let via { params["via"] = .string(via) }
        if let name { params["name"] = .string(name) }
        if let session { params["session"] = .string(session) }
        if temporary { params["temporary"] = .bool(true) }
        return HcMachine(json: try await call("machine.add", params: .object(params)))
    }

    /// Dials now instead of at the next retry (after a login, for instance).
    public func connectMachine(_ name: String) async throws -> HcMachine {
        HcMachine(json: try await call("machine.connect", params: .object(["machine": .string(name)])))
    }

    /// Only this core's name changes; addresses using the old one stop working.
    public func renameMachine(_ name: String, to newName: String) async throws -> HcMachine {
        HcMachine(json: try await call(
            "machine.rename",
            params: .object(["machine": .string(name), "new_name": .string(newName)])
        ))
    }

    public func removeMachine(_ name: String) async throws {
        _ = try await call("machine.rm", params: .object(["machine": .string(name)]))
    }

    // MARK: Terminals

    /// Starts a terminal. `line` runs through the machine's shell; `argv` runs
    /// directly; neither starts that machine's own shell.
    ///
    /// Labels are how the client claims a terminal for a space/tab: the core
    /// stores them and emits a `labels` event, so a terminal started outside the
    /// window is adopted the same way.
    @discardableResult
    public func runTerminal(
        argv: [String] = [],
        line: String? = nil,
        cwd: String? = nil,
        env: [String: String] = [:],
        labels: [String: String] = [:],
        name: String? = nil,
        keep: Bool? = nil,
        parent: String? = nil,
        on machine: String? = nil
    ) async throws -> HcTerminal {
        var params: [String: JSONValue] = [:]
        if !argv.isEmpty { params["argv"] = .array(argv.map(JSONValue.string)) }
        if let line { params["line"] = .string(line) }
        if let cwd { params["cwd"] = .string(cwd) }
        if !env.isEmpty { params["env"] = .object(env.mapValues(JSONValue.string)) }
        if !labels.isEmpty { params["labels"] = .object(labels.mapValues(JSONValue.string)) }
        if let name { params["name"] = .string(name) }
        if let keep { params["keep"] = .bool(keep) }
        if let parent { params["parent"] = .string(parent) }
        if let machine { params["on"] = .string(machine) }
        return HcTerminal(json: try await call("terminal.run", params: .object(params)))
    }

    public func terminal(_ address: String) async throws -> HcTerminal {
        HcTerminal(json: try await call(
            "terminal.get",
            params: .object(["terminal": .string(address)])
        ))
    }

    /// Ends the program (SIGHUP, then SIGKILL). A `keep: true` terminal comes
    /// back as a fresh shell instead of disappearing.
    @discardableResult
    public func killTerminal(_ address: String) async throws -> HcTerminal {
        HcTerminal(json: try await call(
            "terminal.kill",
            params: .object(["terminal": .string(address)])
        ))
    }

    /// Sets labels; an empty value removes the key.
    @discardableResult
    public func labelTerminal(_ address: String, labels: [String: String]) async throws -> HcTerminal {
        HcTerminal(json: try await call(
            "terminal.label",
            params: .object([
                "terminal": .string(address),
                "labels": .object(labels.mapValues(JSONValue.string)),
            ])
        ))
    }

    @discardableResult
    public func keepTerminal(_ address: String, keep: Bool) async throws -> HcTerminal {
        HcTerminal(json: try await call(
            "terminal.keep",
            params: .object(["terminal": .string(address), "keep": .bool(keep)])
        ))
    }

    /// Removes a finished terminal's record (it must not be live).
    public func removeTerminal(_ address: String) async throws {
        _ = try await call("terminal.rm", params: .object(["terminal": .string(address)]))
    }

    /// Attaches to a terminal on the current link.
    ///
    /// A reconnect drops every channel, so the caller must be ready to attach
    /// again: the streams are not restored behind its back.
    public func attach(
        terminal: String,
        options: HcAttachOptions = HcAttachOptions(),
        handlers: HcAttachHandlers
    ) async throws -> HcAttachStream {
        guard let connection = currentConnection() else {
            throw HcConnectionError.notConnected
        }
        return try await HcAttachStream.attach(
            connection,
            terminal: terminal,
            options: options,
            handlers: handlers
        )
    }

    private func currentConnection() -> HcConnection? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return connection
    }

    private func install(_ newValue: HcConnection?) {
        stateLock.lock()
        connection = newValue
        stateLock.unlock()
    }

    private func isStopped() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    private func run() async {
        var attempt = 0
        var delay = initialBackoff

        while !isStopped() {
            eventContinuation.yield(.connecting(attempt: attempt))

            do {
                let opened = try await withCheckedThrowingContinuation { continuation in
                    // The handshake blocks; keep it off the cooperative pool so
                    // it cannot starve the tasks waiting for this one.
                    let factory = linkFactory
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            continuation.resume(returning: try HcConnection.open(link: try factory()))
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }

                if isStopped() {
                    opened.close()
                    return
                }

                let compatibility = HcProtocol.check(opened.hello)
                guard compatibility.isOK else {
                    opened.close()
                    install(nil)
                    eventContinuation.yield(.incompatible(compatibility))
                    eventContinuation.finish()
                    return
                }

                install(opened)
                eventContinuation.yield(.ready(opened.hello))

                attempt = 0
                delay = initialBackoff

                var reason: String?
                for await value in opened.closed {
                    reason = value
                }
                install(nil)

                if isStopped() { return }
                eventContinuation.yield(.disconnected(reason: reason))
            } catch let error as HcConnectionError {
                install(nil)
                eventContinuation.yield(.failed(error))
            } catch {
                install(nil)
                eventContinuation.yield(.failed(.socket("\(error)")))
            }

            if isStopped() { return }
            let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            delay = min(max(delay * 2, initialBackoff), maxBackoff)
            attempt += 1
        }
    }
}
