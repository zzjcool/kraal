// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import Testing

@testable import KraalHC

/// A stream recorded from a real core (2026-11-02, hc 0.1.16):
/// `sh` started before subscribing, then label, two OSC 7501 reports (working,
/// done), a second terminal, kill and rm. The first line carries the snapshot;
/// the rest are the channel's notification lines verbatim.
@Suite("Recorded event stream")
struct HcEventFixtureTests {
    private func loadLines() throws -> [Data] {
        let url = try #require(
            Bundle.module.url(forResource: "events", withExtension: "ndjson", subdirectory: "Fixtures")
        )
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(whereSeparator: \.isNewline).map { Data($0.utf8) }
    }

    @Test("the recorded stream replays into the expected terminal set")
    func replays() throws {
        let lines = try loadLines()
        #expect(lines.count == 11)

        let first = try #require(try JSONDecoder().decode(JSONValue.self, from: lines[0]))
        let snapshot = try #require(HcSnapshot(json: first["snapshot"] ?? .null))
        #expect(snapshot.terminals.count == 1)
        let address = try #require(snapshot.terminals.first?.address)

        let store = HcStateStore()
        store.replace(with: snapshot)

        var types: [String] = []
        for line in lines.dropFirst() {
            switch HcEventLine(line: line) {
            case let .event(event):
                types.append(event.type)
                #expect(store.apply(event))
                if event.type == "foreground" {
                    // The frame after `created` may be about the other terminal.
                    if event.terminal == address {
                        #expect(store.terminal(address)?.foreground != nil)
                    }
                }
            case .heartbeat, .missed:
                Issue.record("unexpected non-event line")
            case let .unknown(method):
                Issue.record("unknown method \(method)")
            case .malformed:
                Issue.record("malformed line")
            }
        }

        for expected in ["created", "labels", "status", "turn", "finished", "removed"] {
            #expect(types.contains(expected), "missing \(expected) in \(types)")
        }

        #expect(store.view().seq == 11)
        #expect(store.view().terminals.count == 1)
        #expect(store.view().terminals.first?.address != address)
        #expect(store.terminal(address) == nil)
    }

    @Test("the recorded status and turn facts land on the record")
    func statusAndTurn() throws {
        let lines = try loadLines()
        let first = try #require(try JSONDecoder().decode(JSONValue.self, from: lines[0]))
        let snapshot = try #require(HcSnapshot(json: first["snapshot"] ?? .null))
        let address = try #require(snapshot.terminals.first?.address)
        let store = HcStateStore()
        store.replace(with: snapshot)

        var sawWorking = false
        var sawDone = false
        var sawLabel = false
        for line in lines.dropFirst() {
            guard case let .event(event) = HcEventLine(line: line), event.terminal == address else { continue }
            #expect(store.apply(event))
            if store.terminal(address)?.agentState == "working" { sawWorking = true }
            if store.terminal(address)?.agentState == "done" { sawDone = true }
            if store.terminal(address)?.labels["role"] == "agent" { sawLabel = true }
        }
        #expect(sawWorking)
        #expect(sawDone)
        #expect(sawLabel)
    }
}
