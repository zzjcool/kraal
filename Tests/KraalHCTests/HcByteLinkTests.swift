// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The transport seam. These tests do not open a unix socket: `HcConnection`
// gets a scripted byte pipe, so the SSH/embedded transports share the exact
// handshake and attach path with the normal client.

import Foundation
import Testing

@testable import KraalHC

@Suite("Byte links")
struct HcByteLinkTests {
    @Test("an injected link completes hello and calls")
    func injectedHelloAndCall() async throws {
        let link = ScriptedLink()
        let connection = try await openTestLink(link)
        defer { connection.close() }

        #expect(connection.hello.generation == 1)
        #expect(connection.hello.coreName == "fake")
        let reply = try await connection.call("terminal.list")
        #expect(reply["terminals"]?.arrayValue?.count == 2)
        #expect(link.methods.contains("terminal.list"))
    }

    @Test("attach bytes and client frames cross the injected link")
    func attachOverInjectedLink() async throws {
        let link = ScriptedLink()
        let connection = try await openTestLink(link)
        defer { connection.close() }

        let reply = try await connection.call(
            "terminal.attach",
            params: .object(["terminal": .string("t7")])
        )
        let channelID = UInt32(try #require(reply["channel"]?.intValue))
        let probe = ChannelProbe()
        let channel = connection.openChannel(id: channelID, handlers: probe.handlers())

        #expect(try #require(try await probe.next()) == .data(Data("ping".utf8)))
        try channel.send(Data("keys".utf8))
        #expect(link.lastFrame(channel: channelID)?.payload == Data("keys".utf8))
    }

    @Test("a handshake read timeout maps to handshakeTimeout")
    func handshakeTimeout() async throws {
        let link = TimeoutLink()
        do {
            _ = try await openTestLink(link)
            Issue.record("expected the handshake to time out")
        } catch let error as HcConnectionError {
            #expect(error.description == HcConnectionError.handshakeTimeout.description)
        }
    }

    #if os(macOS)
    @Test("ssh stderr is reported when the remote command fails")
    func sshStderr() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let script = directory + "/fake-ssh"
        try "#!/bin/sh\necho 'Permission denied (publickey).' >&2\nexit 255\n"
            .write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: script
        )

        let link = try HcSSHLink(host: "test", executable: script)
        defer { link.close() }
        // Let the script exit and the stderr drain thread run before the
        // handshake consumes its EOF.
        try await Task.sleep(for: .milliseconds(150))

        do {
            _ = try await openTestLink(link)
            Issue.record("expected the ssh link to end")
        } catch let error as HcConnectionError {
            #expect(error.description.contains("Permission denied"))
        }
    }
    #endif
}

private func makeTemporaryDirectory() throws -> String {
    let path = "/tmp/kraal-link-\(UUID().uuidString.prefix(8))"
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

/// Opens a link off the cooperative pool: `HcConnection.open` blocks during the
/// handshake, and doing that on a test task starves the other tasks.
private func openTestLink(_ link: any HcByteLink) async throws -> HcConnection {
    try await withCheckedThrowingContinuation { continuation in
        let thread = Thread {
            do {
                continuation.resume(returning: try HcConnection.open(link: link))
            } catch {
                continuation.resume(throwing: error)
            }
        }
        thread.name = "kraal.test.link"
        thread.stackSize = 512 * 1024
        thread.start()
    }
}

/// A byte pipe that answers the handful of requests these tests make. It is
/// deliberately not a unix socket: this is the transport contract, not the
/// socket implementation.
private final class ScriptedLink: HcByteLink, @unchecked Sendable {
    private let condition = NSCondition()
    private var buffered = Data()
    private var closed = false
    private var writes: [Data] = []

    var methods: [String] {
        condition.lock()
        defer { condition.unlock() }
        return writes.flatMap(Self.methods(in:))
    }

    private static func methods(in data: Data) -> [String] {
        var found: [String] = []
        if let incoming = try? HcRPC.decode(data),
           case let .request(_, method, _) = incoming {
            found.append(method)
        }
        var decoder = HcFrameDecoder()
        decoder.append(data)
        while let frame = try? decoder.next() {
            guard frame.channel == 0,
                  let incoming = try? HcRPC.decode(frame.payload),
                  case let .request(_, method, _) = incoming
            else { continue }
            found.append(method)
        }
        return found
    }

    func lastFrame(channel: UInt32) -> HcFrame? {
        condition.lock()
        defer { condition.unlock() }
        for data in writes.reversed() {
            var decoder = HcFrameDecoder()
            decoder.append(data)
            if let frame = try? decoder.next(), frame.channel == channel {
                return frame
            }
        }
        return nil
    }

    func read(maxLength: Int) throws -> Data? {
        condition.lock()
        defer { condition.unlock() }
        while buffered.isEmpty, !closed {
            condition.wait()
        }
        guard !buffered.isEmpty else { return nil }
        let count = min(maxLength, buffered.count)
        let chunk = Data(buffered.prefix(count))
        buffered.removeFirst(count)
        return chunk
    }

    func write(_ data: Data) throws {
        condition.lock()
        writes.append(data)
        condition.unlock()
        answer(data)
    }

    func setReadTimeout(_ seconds: TimeInterval) {}

    func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    private func answer(_ data: Data) {
        if data.last == 0x0A, let incoming = try? HcRPC.decode(data) {
            switch incoming {
            case let .request(id, "hello", _):
                guard let id else { return }
                let result = try? FakeCore.defaultHello()
                reply(id: id, result: result ?? .null, newline: true)
            default:
                break
            }
            return
        }
        var decoder = HcFrameDecoder()
        decoder.append(data)
        while let frame = try? decoder.next() {
            guard frame.channel == 0,
                  let incoming = try? HcRPC.decode(frame.payload),
                  case let .request(requestID, method, _) = incoming,
                  let requestID
            else { continue }
            let id = requestID
            switch method {
            case "terminal.list":
                frameReply(id: id, result: .object([
                    "terminals": .array([
                        .object(["address": .string("t1")]),
                        .object(["address": .string("t2")]),
                    ]),
                ]))
            case "terminal.attach":
                frameReply(id: id, result: .object([
                    "channel": .int(1),
                    "terminal": .object(["address": .string("t7")]),
                ]))
                if let ping = try? HcWire.dataFrame(channel: 1, payload: Data("ping".utf8)) {
                    feed(ping)
                }
            default:
                frameReply(id: id, result: .object(["ok": .bool(true)]))
            }
        }
    }

    private func reply(id: Int64, result: JSONValue, newline: Bool = false) {
        let message = JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .int(Int(id)),
            "result": result,
        ])
        guard let data = try? JSONEncoder().encode(message) else { return }
        feed(newline ? data + Data([0x0A]) : data)
    }

    private func frameReply(id: Int64, result: JSONValue) {
        let message = JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .int(Int(id)),
            "result": result,
        ])
        guard let payload = try? JSONEncoder().encode(message),
              let frame = try? HcWire.dataFrame(channel: 0, payload: payload)
        else { return }
        feed(frame)
    }

    private func feed(_ data: Data) {
        condition.lock()
        buffered.append(data)
        condition.broadcast()
        condition.unlock()
    }
}

private final class TimeoutLink: HcByteLink, @unchecked Sendable {
    func read(maxLength: Int) throws -> Data? { throw HcLinkTimeout() }
    func write(_ data: Data) throws {}
    func setReadTimeout(_ seconds: TimeInterval) {}
    func close() {}
}
