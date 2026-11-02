// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import Testing

@testable import KraalHC

@Suite("Core connection")
struct HcConnectionTests {
    @Test("completes hello and runs calls concurrently by id")
    func concurrentCalls() async throws {
        try await withFakeCore { core in
            core.onSession = { session in
                var requests: [(id: Int64, method: String)] = []
                for _ in 0 ..< 3 {
                    guard let frame = session.readFrame(),
                          frame.channel == 0,
                          let incoming = try? HcRPC.decode(frame.payload),
                          case let .request(id, method, _) = incoming,
                          let id
                    else { return }
                    requests.append((id, method))
                }
                // Answer out of order: the client must match by id, not arrival.
                for request in requests.reversed() {
                    session.writeMessage(.object([
                        "jsonrpc": .string("2.0"),
                        "id": .int(Int(request.id)),
                        "result": .object([
                            "method": .string(request.method),
                            "ok": .bool(true),
                        ]),
                    ]))
                }
            }

            let connection = try HcConnection.open(path: core.socketPath)
            defer { connection.close() }
            #expect(connection.hello.generation == 1)
            #expect(connection.hello.version == "0.1.16")

            async let first = connection.call("terminal.list", params: .object(["all": .bool(true)]))
            async let second = connection.call("terminal.list", params: .object(["all": .bool(false)]))
            async let third = connection.call("terminal.list")
            let (firstResult, secondResult, thirdResult) = try await (first, second, third)
            #expect(firstResult["ok"]?.boolValue == true)
            #expect(secondResult["ok"]?.boolValue == true)
            #expect(thirdResult["method"]?.stringValue == "terminal.list")
        }
    }

    @Test("surfaces the core's error kind and hint")
    func errorKind() async throws {
        try await withFakeCore { core in
            core.onSession = { session in
                guard let frame = session.readFrame(),
                      let incoming = try? HcRPC.decode(frame.payload),
                      case let .request(id, _, _) = incoming,
                      let id
                else { return }
                session.writeMessage(.object([
                    "jsonrpc": .string("2.0"),
                    "id": .int(Int(id)),
                    "error": .object([
                        "code": .number(-32_000),
                        "message": .string("no terminal t9"),
                        "data": .object([
                            "kind": .string("not_found"),
                            "hint": .string("run hc ls"),
                        ]),
                    ]),
                ]))
            }

            let connection = try HcConnection.open(path: core.socketPath)
            defer { connection.close() }
            do {
                _ = try await connection.call(
                    "terminal.get",
                    params: .object(["terminal": .string("t9")])
                )
                Issue.record("expected the call to throw")
            } catch let error as HcRPCError {
                #expect(error.kind == "not_found")
                #expect(error.hint == "run hc ls")
            }
        }
    }

    @Test("forwards notifications on the control channel")
    func notifications() async throws {
        try await withFakeCore { core in
            core.onSession = { session in
                session.writeMessage(.object([
                    "jsonrpc": .string("2.0"),
                    "method": .string("event"),
                    "params": .object([
                        "seq": .int(42),
                        "type": .string("status"),
                        "terminal": .string("t7"),
                    ]),
                ]))
            }

            let connection = try HcConnection.open(path: core.socketPath)
            defer { connection.close() }
            let notification = try await withTimeout(3) {
                var iterator = connection.notifications.makeAsyncIterator()
                return await iterator.next()
            }
            #expect(notification?.method == "event")
            #expect(notification?.params["seq"]?.intValue == 42)
            #expect(notification?.params["terminal"]?.stringValue == "t7")
        }
    }

    @Test("buffers stream frames that arrive before the channel is registered")
    func channelEarlyFrames() async throws {
        try await withFakeCore { core in
            core.onSession = { session in
                guard let frame = session.readFrame(),
                      let incoming = try? HcRPC.decode(frame.payload),
                      case let .request(id, "terminal.attach", _) = incoming,
                      let id
                else { return }

                session.writeMessage(.object([
                    "jsonrpc": .string("2.0"),
                    "id": .int(Int(id)),
                    "result": .object([
                        "channel": .int(1),
                        "terminal": .object(["address": .string("t7")]),
                    ]),
                ]))
                // Sent before the client can call openChannel(id: 1).
                session.writeFrame(channel: 1, kind: .data, payload: Data("ping".utf8))
                session.writeFrame(channel: 1, kind: .resize, payload: resizePayload(cols: 80, rows: 24))

                var frames: [HcFrame] = []
                for _ in 0 ..< 4 {
                    guard let clientFrame = session.readFrame() else { return }
                    frames.append(clientFrame)
                }
                #expect(frames[0].knownKind == .data)
                #expect(frames[0].payload == Data("keys".utf8))
                #expect(frames[1].knownKind == .credit)
                #expect(frames[2].knownKind == .resize)
                #expect(frames[3].knownKind == .focus)

                session.writeFrame(
                    channel: 1,
                    kind: .close,
                    payload: Data(#"{"reason":"exited","exit_code":0,"signal":null}"#.utf8)
                )
            }

            let connection = try HcConnection.open(path: core.socketPath)
            defer { connection.close() }
            let reply = try await connection.call(
                "terminal.attach",
                params: .object(["terminal": .string("t7")])
            )
            let channelID = UInt32(try #require(reply["channel"]?.intValue))

            let probe = ChannelProbe()
            let channel = connection.openChannel(id: channelID, handlers: probe.handlers())

            #expect(try #require(try await probe.next()) == .data(Data("ping".utf8)))
            #expect(try #require(try await probe.next()) == .resize(80, 24))

            try channel.send(Data("keys".utf8))
            try channel.credit(4)
            try channel.resize(cols: 100, rows: 30)
            try channel.focus(true)

            let closed = try #require(try await probe.next())
            guard case let .closed(reason) = closed else {
                Issue.record("expected close, got \(closed)")
                return
            }
            #expect(reason?["reason"]?.stringValue == "exited")
            #expect(channel.isClosed)
        }
    }

    @Test("fails an in-flight call when the core goes away")
    func disconnectFailsPending() async throws {
        try await withFakeCore { core in
            core.onSession = { session in
                // Read the request, then drop the connection without replying.
                _ = session.readFrame()
            }

            let connection = try HcConnection.open(path: core.socketPath)
            defer { connection.close() }
            do {
                _ = try await connection.call("terminal.list")
                Issue.record("expected the call to throw")
            } catch let error as HcConnectionError {
                guard case .closed = error else {
                    Issue.record("unexpected error: \(error)")
                    return
                }
            }
        }
    }
}
