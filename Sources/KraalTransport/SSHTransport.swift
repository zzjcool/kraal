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
    case handshakeTimeout
    case readyBannerMissing(String)
    case noRemoteHerdr(String)
    case processFailed(status: Int32, stderr: String)

    public var description: String {
        switch self {
        case .sshNotFound:
            "The `ssh` command was not found on this machine."
        case .handshakeTimeout:
            "The remote host did not finish the Herdr bridge handshake in time."
        case let .readyBannerMissing(output):
            "The remote host answered, but not with a Herdr bridge banner: \(output)"
        case let .noRemoteHerdr(detail):
            "Herdr is not installed on the remote host, or it is older than 0.9.0. \(detail)"
        case let .processFailed(status, stderr):
            "ssh exited with status \(status). \(stderr)"
        }
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
    public static func connect(
        user: String?,
        host: String,
        port: UInt16?,
        session: String,
        timeout: TimeInterval = 30
    ) throws -> SSHProcessTransport {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")

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
    private func performReadyHandshake(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        let handle = stdoutPipe.fileHandleForReading
        var pending = Data()
        var statusLines: [String] = []

        while Date() < deadline {
            if process.isRunning == false, handle.availableData.isEmpty {
                break
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }

            var chunk = Data()
            // `availableData` blocks until something arrives or EOF.
            let data = handle.availableData
            if data.isEmpty { break }
            chunk.append(data)
            pending.append(chunk)

            while let newlineIndex = pending.firstIndex(of: 0x0A) {
                let lineData = pending[pending.startIndex ..< newlineIndex]
                pending.removeSubrange(pending.startIndex ... newlineIndex)
                let line = String(bytes: lineData, encoding: .utf8) ?? ""
                if line == "herdr-remote-output-ready:1" {
                    remoteVersionLine = statusLines.last ?? ""
                    try answerReady()
                    return
                }
                if !line.isEmpty {
                    statusLines.append(line)
                }
            }
        }

        let stderr = drainStderr()
        if process.isRunning {
            process.terminate()
        }
        if !statusLines.isEmpty {
            throw SSHTransportError.readyBannerMissing(
                "\(statusLines.suffix(3).joined(separator: " | ")) \(stderr)"
            )
        }
        throw SSHTransportError.noRemoteHerdr(stderr)
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
    public func read(maxLength: Int = 64 * 1024) -> Data? {
        let data = stdoutPipe.fileHandleForReading.availableData
        return data.isEmpty ? nil : data
    }

    public func close() {
        try? stdinPipe.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
        stdoutPipe.fileHandleForReading.closeFile()
        stderrPipe.fileHandleForReading.closeFile()
    }

    private func drainStderr() -> String {
        let data = stderrPipe.fileHandleForReading.availableData
        guard !data.isEmpty else { return "" }
        stderrTail.append(data)
        return (String(bytes: stderrTail.suffix(800), encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
