// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Opt-in live transport test: a real `ssh -T <host> hc connect` to a real
// herdr-core. Skipped unless KRAAL_LIVE_SSH is set. It creates its own
// terminal and removes it afterwards; it never attaches to an existing one.

#if os(macOS)

import Foundation
import Testing

@testable import KraalHC

@Suite("Live SSH link")
struct LiveHcSSHTests {
    @Test("lists terminals and attaches over ssh")
    func liveSSH() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["KRAAL_LIVE_SSH"], !host.isEmpty else {
            return // opt in with KRAAL_LIVE_SSH=user@host
        }
        let command = environment["KRAAL_LIVE_SSH_COMMAND"] ?? "hc connect"

        let link = try HcSSHLink(host: host, remoteCommand: command)
        let connection = try await openTestConnection(link: link)
        defer { connection.close() }

        #expect(HcProtocol.check(connection.hello) == .compatible)
        let listed = try await connection.call(
            "terminal.list",
            params: .object(["all": .bool(false)])
        )
        #expect(listed["terminals"]?.arrayValue != nil)

        let created = try await connection.call(
            "terminal.run",
            params: .object([
                "line": .string("printf ssh-link"),
                "keep": .bool(false),
            ])
        )
        let address = try #require(created["address"]?.stringValue)
        defer {
            Task {
                _ = try? await connection.call(
                    "terminal.rm",
                    params: .object(["terminal": .string(address)])
                )
            }
        }

        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let attach = try await HcAttachStream.attach(
            connection,
            terminal: address,
            handlers: HcAttachHandlers(
                onData: { continuation.yield($0) },
                onEnd: { _ in continuation.finish() },
                onLost: { continuation.finish() }
            )
        )
        defer { attach.close() }

        var output = Data()
        try await withTimeout(10) {
            var iterator = stream.makeAsyncIterator()
            while let chunk = await iterator.next() {
                output.append(chunk)
                attach.credit(chunk.count)
                if output.range(of: Data("ssh-link".utf8)) != nil { return }
            }
        }
        #expect(output.range(of: Data("ssh-link".utf8)) != nil)
    }
}

#endif
