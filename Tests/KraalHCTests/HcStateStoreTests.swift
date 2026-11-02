// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import Testing

@testable import KraalHC

@Suite("Event reduction")
struct HcStateStoreTests {
    private func record(
        _ address: String,
        name: String = "shell",
        state: String = "live",
        parent: String? = nil,
        labels: [String: String] = [:]
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "address": .string(address),
            "name": .string(name),
            "state": .string(state),
            "cols": .int(80),
            "rows": .int(24),
            "turn": .int(0),
            "cwd": .string("/tmp"),
            "pid": .int(42),
            "keep": .bool(false),
            "labels": .object(labels.mapValues(JSONValue.string)),
        ]
        if let parent { object["parent"] = .string(parent) }
        return .object(object)
    }

    private func event(_ seq: UInt64, _ type: String, _ terminal: String?, _ data: JSONValue) -> HcEvent {
        HcEvent(seq: seq, type: type, terminal: terminal, data: data)
    }

    private func snapshot(_ seq: UInt64, _ records: [JSONValue]) -> HcSnapshot {
        HcSnapshot(seq: seq, terminals: records.map(HcTerminal.init(json:)))
    }

    @Test("a snapshot installs the set and every patch lands on its record")
    func patches() {
        let store = HcStateStore()
        store.replace(with: snapshot(5, [record("t1"), record("t2")]))
        #expect(store.view().terminals.map(\.address) == ["t1", "t2"])

        #expect(store.apply(event(6, "status", "t1", .object([
            "status": .object(["state": .string("working")]),
            "records": .object(["build": .object(["state": .string("running")])]),
            "reported": .bool(true),
        ]))))
        #expect(store.terminal("t1")?.agentState == "working")
        #expect(store.terminal("t1")?.reported == true)
        #expect(store.terminal("t1")?.statusRecords["build"] != nil)

        #expect(store.apply(event(7, "turn", "t1", .object([
            "turn": .int(3), "state": .string("idle"),
        ]))))
        #expect(store.terminal("t1")?.turn == 3)

        #expect(store.apply(event(8, "title", "t1", .object(["title": .string("vim")]))))
        #expect(store.terminal("t1")?.title == "vim")

        #expect(store.apply(event(9, "labels", "t1", .object([
            "labels": .object(["role": .string("agent")]),
        ]))))
        #expect(store.terminal("t1")?.labels == ["role": "agent"])

        #expect(store.apply(event(10, "size", "t1", .object(["cols": .int(120), "rows": .int(40)]))))
        #expect(store.terminal("t1")?.cols == 120)
        #expect(store.terminal("t1")?.rows == 40)

        #expect(store.apply(event(11, "foreground", "t1", .object([
            "pid": .int(99), "name": .string("nvim"),
            "argv": .array([.string("nvim"), .string("-")]), "cwd": .string("/src"),
        ]))))
        #expect(store.terminal("t1")?.foreground?.name == "nvim")
        #expect(store.terminal("t1")?.agent == "nvim")

        #expect(store.apply(event(12, "keep", "t2", .object(["keep": .bool(true)]))))
        #expect(store.terminal("t2")?.keep == true)

        // `lost` keeps the record live, clears the pid and the foreground, and
        // records why — the terminal is still there, its program is not.
        #expect(store.apply(event(13, "lost", "t2", .object([
            "reason": .string("signaled"), "exit_code": .null,
            "signal": .int(1), "finished_ms": .null,
        ]))))
        #expect(store.terminal("t2")?.isLive == true)
        #expect(store.terminal("t2")?.pid == nil)
        #expect(store.terminal("t2")?.foreground == nil)
        #expect(store.terminal("t2")?.reason == "signaled")
        #expect(store.terminal("t2")?.signal == 1)

        #expect(store.apply(event(14, "finished", "t1", .object([
            "reason": .string("exited"), "exit_code": .int(0),
            "signal": .null, "finished_ms": .int(1_700_000_000_000),
        ]))))
        #expect(store.terminal("t1")?.state == "finished")
        #expect(store.terminal("t1")?.exitCode == 0)
        #expect(store.terminal("t1")?.foreground == nil)

        #expect(store.apply(event(15, "removed", "t2", .object([:]))) )
        #expect(store.terminal("t2") == nil)
        #expect(store.view().terminals.map(\.address) == ["t1"])
        #expect(store.view().seq == 15)
    }

    @Test("created replaces, restarted replaces, and unknown types are ignored")
    func replacements() {
        let store = HcStateStore()
        store.replace(with: snapshot(1, [record("t1", name: "old")]))
        #expect(store.apply(event(2, "created", "t1", record("t1", name: "new"))))
        #expect(store.terminal("t1")?.name == "new")

        #expect(store.apply(event(3, "restarted", "t1", record("t1", name: "restarted"))))
        #expect(store.terminal("t1")?.name == "restarted")

        // A future type must advance the sequence and change nothing else.
        #expect(store.apply(event(4, "some_future_fact", "t1", .object(["x": .int(1)]))))
        #expect(store.view().seq == 4)
        #expect(store.terminal("t1")?.name == "restarted")
    }

    @Test("a stale event is dropped and a gap asks for a resync")
    func sequenceGuard() {
        let store = HcStateStore()
        store.replace(with: snapshot(5, [record("t1")]))
        #expect(store.apply(event(5, "title", "t1", .object(["title": .string("stale")]))) == false)
        #expect(store.terminal("t1")?.title == "")

        #expect(store.apply(event(7, "title", "t1", .object(["title": .string("gap")]))) )
        #expect(store.view().needsResync)
        #expect(store.terminal("t1")?.title == "gap")

        store.replace(with: snapshot(20, [record("t1", name: "fresh")]))
        #expect(store.view().needsResync == false)
        #expect(store.apply(event(19, "title", "t1", .object(["title": .string("old")]))) == false)
        #expect(store.apply(event(21, "title", "t1", .object(["title": .string("next")]))) )
    }

    @Test("missed replaces the set, and events from before it are discarded")
    func missedResync() {
        let store = HcStateStore()
        store.replace(with: snapshot(1, [record("t1")]))
        for seq in 2 ... 5 {
            _ = store.apply(event(UInt64(seq), "title", "t1", .object(["title": .string("v\(seq)")])))
        }

        // The core fell behind and sent `missed` with a fresh snapshot at seq 10.
        store.replace(with: snapshot(10, [record("t2"), record("t3")]))
        #expect(store.view().terminals.map(\.address) == ["t2", "t3"])
        #expect(store.apply(event(6, "title", "t1", .object(["title": .string("late")]))) == false)
        #expect(store.terminal("t1") == nil)

        #expect(store.apply(event(11, "title", "t2", .object(["title": .string("new")]))) )
        #expect(store.terminal("t2")?.title == "new")
    }

    @Test("label filters drop a terminal that stops matching and adopt one that starts")
    func labelFilter() {
        let filter = HcEventFilter(labels: ["role": "agent"])
        let store = HcStateStore(filter: filter)
        store.replace(with: snapshot(1, [record("t1", labels: ["role": "agent"])]))
        #expect(store.view().terminals.count == 1)

        // No longer matches: the event still arrives (so the client can drop it).
        #expect(store.apply(event(2, "labels", "t1", .object([
            "labels": .object(["role": .string("shell")]),
        ]))))
        #expect(store.terminal("t1") == nil)

        // Newly matches: the event carries the whole record.
        let new = record("t2", labels: ["role": "agent"])
        #expect(store.apply(event(3, "labels", "t2", .object([
            "labels": .object(["role": .string("agent")]),
            "record": new,
        ]))))
        #expect(store.terminal("t2")?.address == "t2")
    }

    @Test("heartbeats do not move the event sequence, but they do age")
    func heartbeat() {
        let store = HcStateStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        store.replace(with: snapshot(5, [record("t1")]), at: now)
        store.heartbeat(seq: 9, at: now.addingTimeInterval(15))
        #expect(store.view().seq == 5)
        #expect(store.heartbeatIsStale(now: now.addingTimeInterval(20)) == false)
        #expect(store.heartbeatIsStale(now: now.addingTimeInterval(60)))
    }

    @Test("doc events advance the sequence without entering the terminal set")
    func documentsAreNotTerminals() {
        let store = HcStateStore()
        store.replace(with: snapshot(0, []))
        let doc = HcEvent(seq: 1, type: "doc", terminal: nil, data: .object(["name": .string("herdr-app")]))
        #expect(store.apply(doc) == false)
        #expect(store.view().seq == 1)
        #expect(store.view().terminals.isEmpty)
    }
}

@Suite("Event lines")
struct HcEventLineTests {
    @Test("a notification split at every byte boundary still parses")
    func splitLines() {
        let line = Data((#"{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":7}}"# + "\n").utf8)
        var buffer = HcLineBuffer()
        var parsed: [Data] = []
        for byte in line {
            parsed += buffer.append(Data([byte]))
        }
        #expect(parsed.count == 1)
        #expect(HcEventLine(line: parsed[0]) == .heartbeat(seq: 7))
    }

    @Test("several lines in one chunk are all returned")
    func multipleLines() {
        var buffer = HcLineBuffer()
        let first = Data((#"{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":1}}"# + "\n").utf8)
        let second = Data((#"{"jsonrpc":"2.0","method":"whatever","params":{}}"# + "\n").utf8)
        let lines = buffer.append(first + second)
        #expect(lines.count == 2)
        #expect(HcEventLine(line: lines[0]) == .heartbeat(seq: 1))
        #expect(HcEventLine(line: lines[1]) == .unknown(method: "whatever"))
    }

    @Test("an unknown method and a malformed line do not throw")
    func unknownAndMalformed() {
        #expect(HcEventLine(line: Data(#"{"jsonrpc":"2.0","method":"future","params":{}}"#.utf8))
            == .unknown(method: "future"))
        #expect(HcEventLine(line: Data("not json".utf8)) == .malformed)
        #expect(HcEventLine(line: Data(#"{"jsonrpc":"2.0","method":"event","params":{}}"#.utf8)) == .malformed)
    }
}

@Suite("Line buffer splitting")
struct HcLineBufferSplitTests {
    @Test("two chunks of one heartbeat line reassemble")
    func twoChunks() {
        let line = Data((#"{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":12}}"# + "\n").utf8)
        var buffer = HcLineBuffer()
        #expect(buffer.append(line.prefix(10)).isEmpty)
        let lines = buffer.append(line.dropFirst(10))
        #expect(lines.count == 1)
        #expect(HcEventLine(line: lines.first ?? Data()) == .heartbeat(seq: 12))
    }
}
