// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import Testing

@testable import KraalHC

@Suite("Attach stream")
struct HcAttachStreamTests {
    /// Collects the three stream outcomes in order.
    private final class AttachProbe: @unchecked Sendable {
        let data = DataBox()
        let end = EndBox()
        let lost = FlagBox()
    }

    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Data()
        func append(_ chunk: Data) {
            lock.lock()
            value.append(chunk)
            lock.unlock()
        }

        var bytes: Data {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private final class EndBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: HcTerminalEnd?
        func set(_ end: HcTerminalEnd) {
            lock.lock()
            value = end
            lock.unlock()
        }

        var end: HcTerminalEnd? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private final class FlagBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private func attachRequest(_ frame: HcFrame?) -> JSONValue? {
        guard let frame, frame.channel == 0,
              let json = try? JSONDecoder().decode(JSONValue.self, from: frame.payload)
        else { return nil }
        return json
    }

    @Test("feeds raw bytes, credits them, and reports the exit record")
    func dataCreditEnd() async throws {
        try await withFakeCore { core in
            let probe = AttachProbe()

            core.onSession = { session in
                guard let request = self.attachRequest(session.readFrame()) else {
                    Issue.record("no attach request")
                    return
                }
                #expect(request["method"]?.stringValue == "terminal.attach")
                #expect(request["params"]?["terminal"]?.stringValue == "t7")
                #expect(request["params"]?["cols"]?.intValue == 100)
                #expect(request["params"]?["rows"]?.intValue == 30)
                #expect(request["params"]?["history"]?.intValue == 42)

                session.writeMessage(.object([
                    "jsonrpc": .string("2.0"),
                    "id": request["id"] ?? .int(2),
                    "result": .object([
                        "channel": .int(7),
                        "terminal": .object(["address": .string("t7"), "name": .string("build")]),
                        "resize_notifications": .bool(false),
                    ]),
                ]))
                // The replay starts with CAN and is arbitrary bytes to this layer.
                session.writeFrame(channel: 7, kind: .data, payload: Data([0x18, 0x1B, 0x5B, 0x48]))
                session.writeFrame(channel: 7, kind: .data, payload: Data("hi\n".utf8))
                session.writeFrame(
                    channel: 7,
                    kind: .close,
                    payload: Data(#"{"exit_code":0,"signal":null,"reason":"exited","finished_ms":5}"#.utf8)
                )
            }

            let connection = try await HcConnection.open(path: core.socketPath)
            defer { connection.close() }
            let stream = try await HcAttachStream.attach(
                connection,
                terminal: "t7",
                options: HcAttachOptions(columns: 100, rows: 30, history: 42),
                handlers: HcAttachHandlers(
                    onData: { probe.data.append($0) },
                    onEnd: { probe.end.set($0) },
                    onLost: { probe.lost.set() }
                )
            )
            #expect(stream.channelID == 7)
            #expect(stream.terminal["name"]?.stringValue == "build")

            stream.credit(6)

            let deadline = Date().addingTimeInterval(5)
            while probe.end.end == nil, Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(probe.lost.isSet == false)
            #expect(probe.data.bytes == Data([0x18, 0x1B, 0x5B, 0x48]) + Data("hi\n".utf8))
            #expect(probe.end.end == HcTerminalEnd(json: .object([
                "exit_code": .int(0),
                "signal": .null,
                "reason": .string("exited"),
                "finished_ms": .int(5),
            ])))
        }
    }

    @Test("a closed channel without a reason is a lost link, not an exit")
    func lostLink() async throws {
        try await withFakeCore { core in
            let probe = AttachProbe()
            core.onSession = { session in
                guard let request = self.attachRequest(session.readFrame()) else { return }
                session.writeMessage(.object([
                    "jsonrpc": .string("2.0"),
                    "id": request["id"] ?? .int(2),
                    "result": .object(["channel": .int(3), "terminal": .object([:])]),
                ]))
                session.writeFrame(channel: 3, kind: .close, payload: Data())
            }

            let connection = try await HcConnection.open(path: core.socketPath)
            defer { connection.close() }
            _ = try await HcAttachStream.attach(
                connection,
                terminal: "t3",
                handlers: HcAttachHandlers(
                    onData: { probe.data.append($0) },
                    onEnd: { probe.end.set($0) },
                    onLost: { probe.lost.set() }
                )
            )

            let deadline = Date().addingTimeInterval(5)
            while !probe.lost.isSet, Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(probe.lost.isSet)
            #expect(probe.end.end == nil)
        }
    }

    @Test("resize and focus travel as their own frames")
    func resizeAndFocus() async throws {
        try await withFakeCore { core in
            let frames = FrameCollector()
            core.onSession = { session in
                guard let request = self.attachRequest(session.readFrame()) else { return }
                session.writeMessage(.object([
                    "jsonrpc": .string("2.0"),
                    "id": request["id"] ?? .int(2),
                    "result": .object(["channel": .int(9), "terminal": .object([:])]),
                ]))
                for _ in 0 ..< 2 {
                    if let frame = session.readFrame() { frames.append(frame) }
                }
            }

            let connection = try await HcConnection.open(path: core.socketPath)
            defer { connection.close() }
            let stream = try await HcAttachStream.attach(
                connection,
                terminal: "t9",
                handlers: HcAttachHandlers(onData: { _ in }, onEnd: { _ in }, onLost: {})
            )
            stream.resize(columns: 120, rows: 40)
            stream.focus(true)

            let deadline = Date().addingTimeInterval(5)
            while frames.count < 2, Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(frames.snapshot.map(\.kind) == [HcFrameKind.resize.rawValue, HcFrameKind.focus.rawValue])
            #expect(frames.snapshot.first?.channel == 9)
            #expect(frames.snapshot.first?.payload == resizePayload(cols: 120, rows: 40))
            #expect(frames.snapshot.last?.payload == Data([1]))
        }
    }

    private final class FrameCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [HcFrame] = []
        func append(_ frame: HcFrame) {
            lock.lock()
            frames.append(frame)
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return frames.count
        }

        var snapshot: [HcFrame] {
            lock.lock()
            defer { lock.unlock() }
            return frames
        }
    }
}
