// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// `ssh -T host hc connect`, seen as a byte pipe.
//
// herdr-core's `hc connect` speaks the same bytes over stdin/stdout as the unix
// socket. Treating the ssh process as a link means the handshake, framed
// streams, attach and events do not change; only the transport is different.
//
// The process is deliberately not wrapped in retry logic. `HcClient` owns
// reconnect/backoff; this type reports the ssh stderr so a bad login or a
// missing remote `hc` is visible instead of looking like a closed socket.

#if os(macOS)

import Darwin
import Foundation

public enum HcSSHLinkError: Error, CustomStringConvertible {
    case cannotStart(String)
    case read(String)
    case write(String)
    case closed

    public var description: String {
        switch self {
        case let .cannotStart(message):
            "cannot start ssh: \(message)"
        case let .read(message):
            "ssh read failed: \(message)"
        case let .write(message):
            "ssh write failed: \(message)"
        case .closed:
            "ssh link is closed"
        }
    }
}

public final class HcSSHLink: HcByteLink, @unchecked Sendable {
    public let host: String
    public let remoteCommand: String

    private let process: Process
    private let input: Pipe
    private let output: Pipe
    private let errorPipe: Pipe
    private let lock = NSLock()
    private var timeout: TimeInterval
    private var closed = false
    private var errorBytes = Data()
    private var stderrThread: Thread?

    /// Starts the ssh child. `extraArguments` go before `-T host`; useful for
    /// tests (`-o BatchMode=yes`) and for callers that need a jump host.
    public init(
        host: String,
        remoteCommand: String = "hc connect",
        executable: String = "/usr/bin/ssh",
        extraArguments: [String] = [],
        timeout: TimeInterval = 10
    ) throws {
        self.host = host
        self.remoteCommand = remoteCommand
        self.timeout = timeout

        let input = Pipe()
        let output = Pipe()
        let errorPipe = Pipe()
        self.input = input
        self.output = output
        self.errorPipe = errorPipe

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = extraArguments + ["-T", host, remoteCommand]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorPipe
        self.process = process

        do {
            try process.run()
        } catch {
            throw HcSSHLinkError.cannotStart("\(error)")
        }

        // FileHandle writes to a dead ssh must surface as EPIPE, not SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let thread = Thread { [weak self] in self?.drainStderr() }
        thread.name = "kraal.ssh.stderr"
        thread.stackSize = 128 * 1024
        stderrThread = thread
        thread.start()
    }

    deinit { close() }

    /// The accumulated remote stderr. Kept bounded: a broken ssh may produce
    /// pages of diagnostics, and the useful part is almost always the start.
    public var stderrText: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: errorBytes, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    public var failureDescription: String? {
        let text = stderrText
        let running = process.isRunning
        if running {
            return text.isEmpty ? nil : text
        }
        let status = process.terminationStatus
        if text.isEmpty {
            return "ssh exited with status \(status)"
        }
        return "\(text) (ssh exited with status \(status))"
    }

    // MARK: - HcByteLink

    public func setReadTimeout(_ seconds: TimeInterval) {
        lock.lock()
        timeout = seconds
        lock.unlock()
    }

    public func read(maxLength: Int) throws -> Data? {
        let descriptor = output.fileHandleForReading.fileDescriptor
        while true {
            let current = currentTimeout()
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let milliseconds: Int32 = current > 0
                ? Int32(min(current * 1000, Double(Int32.max)))
                : -1
            let ready = Darwin.poll(&pollDescriptor, 1, milliseconds)
            if ready == 0 {
                if current > 0 { throw HcLinkTimeout() }
                continue
            }
            if ready < 0 {
                if errno == EINTR { continue }
                throw HcSSHLinkError.read(String(cString: strerror(errno)))
            }
            guard !isClosed else { return nil }
            // Do not use `FileHandle.read(upToCount:)` here: Foundation loops
            // until it has *all* requested bytes, so poll saying "one byte is
            // ready" still leaves it blocked waiting for 64 KiB. Raw read
            // returns the available chunk and the frame decoder handles the
            // partial frame.
            var buffer = [UInt8](repeating: 0, count: max(1, maxLength))
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.read(descriptor, base, raw.count)
            }
            if count > 0 {
                return Data(buffer[0 ..< count])
            }
            if count == 0 { return nil }
            if errno == EINTR { continue }
            throw HcSSHLinkError.read(String(cString: strerror(errno)))
        }
    }

    public func write(_ data: Data) throws {
        guard !isClosed else { throw HcSSHLinkError.closed }
        do {
            try input.fileHandleForWriting.write(contentsOf: data)
        } catch {
            let detail = failureDescription.map { "\($0); " } ?? ""
            throw HcSSHLinkError.write("\(detail)\(error)")
        }
    }

    public func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
    }

    // MARK: - Internals

    private func currentTimeout() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return timeout
    }

    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    private func drainStderr() {
        while true {
            let data: Data?
            do {
                data = try errorPipe.fileHandleForReading.read(upToCount: 4096)
            } catch {
                return
            }
            guard let data, !data.isEmpty else { return }
            lock.lock()
            if errorBytes.count < 16 * 1024 {
                errorBytes.append(data.prefix(16 * 1024 - errorBytes.count))
            }
            lock.unlock()
        }
    }
}

#endif
