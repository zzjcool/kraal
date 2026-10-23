// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// SSH transport: the bridge runs as a child process whose stdin/stdout are the
// protocol byte stream. No port forwarding and no stream-local forwarding, so
// any SSH client that can exec a command is enough — which is why this works
// on iOS later without a special library feature.
//
// The bridge script and the `herdr-remote-output-ready:1` handshake are adapted
// from `herdr-client/src/ssh.rs` (Apache-2.0).

import Foundation
import KraalProtocol

public enum SSHTransportError: Error, CustomStringConvertible {
    case sshNotFound
    /// The bridge accepted the connection but produced no ready banner in time.
    ///
    /// Distinct from `readyBannerMissing` (the remote *spoke*, just not with a
    /// banner) and from `unexpectedStreamEnd` at the client layer: a peer that is
    /// silent and a peer that closed must not look the same, which is what made
    /// issue #66 take so long to find.
    case handshakeTimedOut(seconds: TimeInterval, detail: String)
    /// The remote *spoke* — status lines arrived — but no banner followed.
    case readyBannerMissing(String)
    /// The remote wrote to stderr and then closed: a `herdr` that exists and
    /// failed, not a host without one.
    ///
    /// Split out of `noRemoteHerdr` by issue #74: a remote whose
    /// `herdr status client` exited 3 with `boom: cannot read config` on stderr
    /// was still reported as "not installed, or older than 0.9.0", which sends
    /// the user looking for a missing binary that is right there. The only case
    /// that may claim "not installed" is the one where the remote said nothing
    /// at all — the bridge script prints every candidate's stderr and nothing
    /// else, so silence there really does mean no usable `herdr` was found.
    case remoteHerdrFailed(String)
    /// The remote closed without a banner *and* without a word on stderr.
    case noRemoteHerdr(String)
    case processFailed(status: Int32, stderr: String)

    public var description: String {
        switch self {
        case .sshNotFound:
            "The `ssh` command was not found on this machine."
        case let .handshakeTimedOut(seconds, detail):
            "The remote host did not finish the Herdr bridge handshake within "
                + "\(Self.secondsText(seconds)). \(detail)"
        case let .readyBannerMissing(output):
            "The remote host answered, but not with a Herdr bridge banner: \(output)"
        case let .remoteHerdrFailed(detail):
            Self.message("Herdr is installed on the remote host, but it failed to start the bridge:", detail)
        case let .noRemoteHerdr(detail):
            Self.message("Herdr is not installed on the remote host, or it is older than 0.9.0.", detail)
        case let .processFailed(status, stderr):
            "ssh exited with status \(status). \(stderr)"
        }
    }

    /// Joins a fixed sentence with whatever the remote said, without leaving a
    /// dangling space when the remote said nothing.
    private static func message(_ sentence: String, _ detail: String) -> String {
        detail.isEmpty ? sentence : "\(sentence) \(detail)"
    }

    /// Whole numbers read as "30s", fractions keep one decimal ("0.5s") so a
    /// test budget of half a second is not reported as "0s".
    static func secondsText(_ seconds: TimeInterval) -> String {
        let rounded = (seconds * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? "\(Int(rounded))s"
            : "\(rounded)s"
    }
}

/// One live bridge child process: protocol bytes in, protocol bytes out.
public final class SSHProcessTransport: @unchecked Sendable {
    private let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private let writeLock = NSLock()
    private var stderrTail = Data()

    /// Program discovered on the remote host, for diagnostics in the UI.
    public private(set) var remoteVersionLine: String = ""

    private init(process: Process, stdin: Pipe, stdout: Pipe, stderr: Pipe) {
        self.process = process
        stdinPipe = stdin
        stdoutPipe = stdout
        stderrPipe = stderr
    }

    /// Builds the `/bin/sh` script the remote side runs.
    ///
    /// It reports `herdr status client --json`, then prints the ready banner and
    /// waits for the client to answer `accept` / `accept-idle` before exec'ing
    /// the bridge. That handshake is what lets the client refuse a host that has
    /// an old Herdr before any protocol bytes are exchanged.
    public static func bridgeScript(session: String) -> String {
        let candidates = #"""
        candidate=$(command -v herdr 2>/dev/null || :)
        case "$candidate" in /*/mise/shims/herdr) candidate=;; /*) ;; *) candidate=;; esac
        for path in "$candidate" "$HOME/.local/bin/herdr" /opt/homebrew/bin/herdr \
        /usr/local/bin/herdr /home/linuxbrew/.linuxbrew/bin/herdr "$HOME/.nix-profile/bin/herdr" \
        "/etc/profiles/per-user/$USER/bin/herdr" /nix/var/nix/profiles/default/bin/herdr \
        /run/current-system/sw/bin/herdr; do
        """#
        let sessionArgument = shellQuote(session)
        return candidates + """

            if [ -n "$path" ] && [ -x "$path" ]; then
                status=$("$path" status client --json </dev/null) || continue
                printf '%s\\n' "$status"
                printf '\\n%s\\n' 'herdr-remote-output-ready:1'
                IFS= read -r choice || exit 1
                case "$choice" in
                    accept) exec "$path" --session \(sessionArgument) remote-client-bridge;;
                    accept-idle) exec "$path" --session \(sessionArgument) remote-client-bridge --idle-timeout-v1;;
                esac
            fi
        done
        exit 127
        """
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Launches ssh, performs the ready handshake, and leaves the stream open.
    ///
    /// `executable` exists for tests: a stub that ignores its arguments and says
    /// nothing is the only way to prove the handshake deadline fires without a
    /// real remote host.
    public static func connect(
        user: String?,
        host: String,
        port: UInt16?,
        session: String,
        timeout: TimeInterval = 30,
        executable: String = "/usr/bin/ssh"
    ) throws -> SSHProcessTransport {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)

        var arguments = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "NumberOfPasswordPrompts=0",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=10",
            "-o", "ConnectionAttempts=1",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=4",
            "-o", "ForwardX11=no",
            "-o", "ClearAllForwardings=yes",
        ]
        if let port {
            arguments.append(contentsOf: ["-p", String(port)])
        }
        let destination = user.map { "\($0)@\(host)" } ?? host
        arguments.append(destination)
        arguments.append("/bin/sh -c \(shellQuote(bridgeScript(session: session)))")
        process.arguments = arguments

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw SSHTransportError.sshNotFound
        }

        let transport = SSHProcessTransport(
            process: process,
            stdin: stdinPipe,
            stdout: stdoutPipe,
            stderr: stderrPipe
        )
        try transport.performReadyHandshake(timeout: timeout)
        return transport
    }

    /// Reads the status JSON and the ready banner line by line, then answers
    /// `accept`. Anything the remote prints beforehand (motd, warnings) is
    /// ignored until the banner appears, exactly like the reference client.
    ///
    /// Every wait here is bounded. The previous version checked the deadline in a
    /// `while` loop and then blocked in `handle.availableData`, so a remote that
    /// accepted the connection and said nothing never reached the check: issue
    /// #66 measured a 30 s bridge deadline that had not fired after 50 s. The
    /// read now waits on `poll(2)` for no longer than what is left of the budget.
    private func performReadyHandshake(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var pending = Data()
        var statusLines: [String] = []

        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw timeoutError(seconds: timeout, statusLines: statusLines)
            }
            do {
                guard let data = try read(timeout: max(remaining, 0.01)) else { break }
                pending.append(data)
                if try consumeLines(&pending, statusLines: &statusLines) { return }
            } catch is SocketTimeout {
                throw timeoutError(seconds: timeout, statusLines: statusLines)
            }
        }

        // The bridge closed without a banner: that is a reportable failure of the
        // remote side, not a timeout.
        //
        // Which failure it is comes down to stderr. The bridge script writes a
        // candidate's diagnostics to stderr and nothing else, so a non-empty
        // stderr means a `herdr` was found and then refused to report its status
        // — saying "not installed" there would be false (issue #74).
        let stderr = drainStderr()
        if process.isRunning {
            process.terminate()
        }
        let said = statusLines.suffix(3).joined(separator: " | ")
        // Status lines first: if `herdr status client --json` produced output the
        // binary is demonstrably there, so "installed, but the banner never came"
        // is the fact — stderr at that point is context, not the diagnosis.
        if !said.isEmpty {
            throw SSHTransportError.readyBannerMissing(
                stderr.isEmpty ? said : "\(said) \(stderr)"
            )
        }
        if !stderr.isEmpty {
            throw SSHTransportError.remoteHerdrFailed(stderr)
        }
        throw SSHTransportError.noRemoteHerdr("")
    }

    /// Splits complete lines out of `pending`; `true` once the ready banner
    /// arrived (having answered `accept`).
    private func consumeLines(_ pending: inout Data, statusLines: inout [String]) throws -> Bool {
        while let newlineIndex = pending.firstIndex(of: 0x0A) {
            let lineData = pending[pending.startIndex ..< newlineIndex]
            pending.removeSubrange(pending.startIndex ... newlineIndex)
            let line = String(bytes: lineData, encoding: .utf8) ?? ""
            if line == "herdr-remote-output-ready:1" {
                remoteVersionLine = statusLines.last ?? ""
                try answerReady()
                return true
            }
            if !line.isEmpty {
                statusLines.append(line)
            }
        }
        return false
    }

    /// Terminates the bridge and names the deadline that expired.
    private func timeoutError(
        seconds: TimeInterval,
        statusLines: [String]
    ) -> SSHTransportError {
        let stderr = drainStderr()
        if process.isRunning {
            process.terminate()
        }
        let said = statusLines.suffix(3).joined(separator: " | ")
        let detail = [said, stderr].filter { !$0.isEmpty }.joined(separator: " — ")
        return .handshakeTimedOut(seconds: seconds, detail: detail)
    }

    private func answerReady() throws {
        try write(Data("accept\n".utf8))
    }

    /// The protocol byte stream, after the bridge banner.
    public func write(_ data: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    /// Blocks until bytes arrive. Returns `nil` at end of stream.
    ///
    /// `timeout` bounds the wait: zero blocks until the bridge speaks or exits,
    /// a positive value throws `SocketTimeout` when nothing arrives in time. The
    /// wait is a `poll(2)` on the pipe, not `availableData`, because the latter
    /// has no upper bound at all.
    public func read(maxLength: Int = 64 * 1024, timeout: TimeInterval = 0) throws -> Data? {
        let descriptor = stdoutPipe.fileHandleForReading.fileDescriptor
        if timeout > 0, !Self.waitForReadable(descriptor, seconds: timeout) {
            throw SocketTimeout()
        }
        let data = stdoutPipe.fileHandleForReading.availableData
        return data.isEmpty ? nil : data
    }

    /// Waits until `descriptor` has bytes (or hung up). `false` means the wait
    /// expired with nothing to read.
    static func waitForReadable(_ descriptor: Int32, seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(max(1, (remaining * 1000).rounded(.up)))
            let result = poll(&entry, 1, milliseconds)
            if result > 0 { return true }
            if result == 0 { return false }
            // EINTR is a signal, not an answer: recompute what is left and wait
            // again rather than reporting a spurious timeout.
            if errno != EINTR { return false }
        }
    }

    public func close() {
        try? stdinPipe.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
        stdoutPipe.fileHandleForReading.closeFile()
        stderrPipe.fileHandleForReading.closeFile()
    }

    /// Whatever stderr already has, without waiting for more.
    ///
    /// Must never block: it runs on the failure path, and a bridge that is silent
    /// on both streams is exactly the case being handled. `availableData` here
    /// used to wait forever, so the "timed out" error could not even be built.
    private func drainStderr() -> String {
        let descriptor = stderrPipe.fileHandleForReading.fileDescriptor
        guard Self.waitForReadable(descriptor, seconds: 0.05) else {
            return tailString()
        }
        let data = stderrPipe.fileHandleForReading.availableData
        guard !data.isEmpty else { return "" }
        stderrTail.append(data)
        return tailString()
    }

    private func tailString() -> String {
        (String(bytes: stderrTail.suffix(800), encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
