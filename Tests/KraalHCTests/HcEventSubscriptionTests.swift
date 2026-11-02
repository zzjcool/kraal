// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import Testing

@testable import KraalHC

@Suite("Event subscription")
struct HcEventSubscriptionTests {
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var eventValues: [HcEvent] = []
        private var missedValues: [HcSnapshot] = []
        private var heartbeatValues: [UInt64] = []
        private var closeValues: [String?] = []

        func handlers() -> HcEventHandlers {
            HcEventHandlers(
                onEvent: { [self] event in
                    lock.lock()
                    eventValues.append(event)
                    lock.unlock()
                },
                onMissed: { [self] snapshot in
                    lock.lock()
                    missedValues.append(snapshot)
                    lock.unlock()
                },
                onHeartbeat: { [self] seq in
                    lock.lock()
                    heartbeatValues.append(seq)
                    lock.unlock()
                },
                onClosed: { [self] reason in
                    lock.lock()
                    closeValues.append(reason)
                    lock.unlock()
                }
            )
        }

        var events: [HcEvent] {
            lock.lock()
            defer { lock.unlock() }
            return eventValues
        }

        var missed: [HcSnapshot] {
            lock.lock()
            defer { lock.unlock() }
            return missedValues
        }

        var heartbeats: [UInt64] {
            lock.lock()
            defer { lock.unlock() }
            return heartbeatValues
        }

        var closes: [String?] {
            lock.lock()
            defer { lock.unlock() }
            return closeValues
        }
    }

    private func notification(_ method: String, _ params: String) -> Data {
        Data((#"{"jsonrpc":"2.0","method":"\#(method)","params":\#(params)}"# + "\n").utf8)
    }

    private func subscribeRequest(_ frame: HcFrame?) -> JSONValue? {
        guard let frame, frame.channel == 0,
              let json = try? JSONDecoder().decode(JSONValue.self, from: frame.payload)
        else { return nil }
        return json
    }

    private func waitFor(_ condition: @escaping @Sendable () -> Bool, seconds: Double = 15) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @Test("snapshot, early lines, heartbeat, missed and close arrive in order")
    func endToEnd() async throws {
        try await withFakeCore { core in
            let probe = Probe()
            core.onSession = { session in
                session.setReadTimeout(3)
                guard let request = self.subscribeRequest(session.readFrame()) else {
                    Issue.record("no subscribe request")
                    return
                }
                #expect(request["method"]?.stringValue == "events.subscribe")
                #expect(request["params"]?["labels"]?["role"]?.stringValue == "agent")

                session.writeMessage(.object([
                    "jsonrpc": .string("2.0"),
                    "id": request["id"] ?? .int(2),
                    "result": .object([
                        "seq": .int(10),
                        "terminals": .array([
                            .object(["address": .string("t1"), "name": .string("one"), "state": .string("live")]),
                        ]),
                        "channel": .int(4),
                    ]),
                ]))
                // Early frames: written before the client registers the channel.
                let title = self.notification(
                    "event",
                    #"{"seq":11,"type":"title","terminal":"t1","data":{"title":"early"}}"#
                )
                session.writeFrame(channel: 4, kind: .data, payload: title)
                let heartbeat = self.notification("heartbeat", #"{"seq":12}"#)
                // A line split across two frames.
                session.writeFrame(channel: 4, kind: .data, payload: heartbeat.prefix(10))
                session.writeFrame(channel: 4, kind: .data, payload: heartbeat.dropFirst(10))

                // The early bytes are credited as one sum once the client
                // registers the channel.
                _ = session.readFrame()

                let missed = self.notification(
                    "missed",
                    #"{"seq":20,"terminals":[{"address":"t2","name":"two","state":"live"}]}"#
                )
                session.writeFrame(channel: 4, kind: .data, payload: missed)
                session.writeFrame(channel: 4, kind: .close, payload: Data())
                // Hold the socket open until the client closes: closing with
                // unread input races the last DATA frame on Darwin.
                session.setReadTimeout(5)
                while session.readFrame() != nil {}
            }

            let connection = try await openTestConnection(path: core.socketPath)
            defer { connection.close() }
            let subscription = try await HcEventSubscription.subscribe(
                connection,
                filter: HcEventFilter(labels: ["role": "agent"]),
                handlers: probe.handlers()
            )
            #expect(subscription.snapshot.seq == 10)
            #expect(subscription.snapshot.terminals.map(\.address) == ["t1"])

            await waitFor {
                probe.heartbeats.count == 1 && probe.missed.count == 1 && probe.closes.count == 1
            }
            #expect(probe.events.map(\.type) == ["title"])
            #expect(probe.events.first?.data["title"]?.stringValue == "early")
            #expect(probe.heartbeats == [12])
            #expect(probe.missed.map(\.seq) == [20])
            #expect(probe.missed.first?.terminals.map(\.address) == ["t2"])
            #expect(probe.closes.count == 1)
        }
    }

    @Test("a malformed line and an unknown method do not stop the stream")
    func unknownAndMalformed() async throws {
        try await withFakeCore { core in
            let probe = Probe()
            core.onSession = { session in
                session.setReadTimeout(3)
                guard let request = self.subscribeRequest(session.readFrame()) else { return }
                session.writeMessage(.object([
                    "jsonrpc": .string("2.0"),
                    "id": request["id"] ?? .int(2),
                    "result": .object([
                        "seq": .int(0),
                        "terminals": .array([]),
                        "channel": .int(6),
                    ]),
                ]))
                session.writeFrame(channel: 6, kind: .data, payload: Data("not json\n".utf8))
                session.writeFrame(
                    channel: 6, kind: .data,
                    payload: self.notification("future_method", #"{"x":1}"#)
                )
                session.writeFrame(
                    channel: 6, kind: .data,
                    payload: self.notification(
                        "event",
                        #"{"seq":1,"type":"future_type","terminal":"t1","data":{"x":1}}"#
                    )
                )
                session.writeFrame(channel: 6, kind: .close, payload: Data())
                session.setReadTimeout(5)
                while session.readFrame() != nil {}
            }

            let connection = try await openTestConnection(path: core.socketPath)
            defer { connection.close() }
            let subscription = try await HcEventSubscription.subscribe(connection, handlers: probe.handlers())
            _ = subscription
            await waitFor { probe.closes.isEmpty == false }
            #expect(probe.events.map(\.type) == ["future_type"])
        }
    }

    @Test("closing the subscription sends CLOSE on the channel")
    func closeSendsFrame() async throws {
        try await withFakeCore { core in
            let closed = Flag()
            core.onSession = { session in
                session.setReadTimeout(3)
                guard let request = self.subscribeRequest(session.readFrame()) else { return }
                session.writeMessage(.object([
                    "jsonrpc": .string("2.0"),
                    "id": request["id"] ?? .int(2),
                    "result": .object(["seq": .int(0), "terminals": .array([]), "channel": .int(8)]),
                ]))
                while let frame = session.readFrame() {
                    if frame.kind == HcFrameKind.close.rawValue, frame.channel == 8 {
                        closed.set()
                        return
                    }
                }
            }

            let connection = try await openTestConnection(path: core.socketPath)
            defer { connection.close() }
            let subscription = try await HcEventSubscription.subscribe(connection, handlers: Probe().handlers())
            subscription.close()
            await waitFor { closed.isSet }
            #expect(closed.isSet)
        }
    }

    private final class Flag: @unchecked Sendable {
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
}
