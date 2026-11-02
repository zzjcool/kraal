// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import Testing

@testable import KraalHC

@Suite("JSON value")
struct JSONValueTests {
    @Test("round-trips every JSON shape")
    func roundTrip() throws {
        let value = JSONValue.object([
            "null": .null,
            "bool": .bool(true),
            "number": .number(42),
            "string": .string("héllo"),
            "array": .array([.int(1), .string("two")]),
        ])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    @Test("keeps booleans and numbers apart")
    func boolVersusNumber() throws {
        let one = try JSONDecoder().decode(JSONValue.self, from: Data("1".utf8))
        let yes = try JSONDecoder().decode(JSONValue.self, from: Data("true".utf8))
        #expect(one == .number(1))
        #expect(yes == .bool(true))
        #expect(one.boolValue == nil)
        #expect(yes.intValue == nil)
    }

    @Test("reads nested fields and array elements")
    func accessors() throws {
        let value: JSONValue = .object([
            "terminal": .object([
                "address": .string("t7"),
                "turn": .number(3),
                "labels": .object(["herdr.seen": .string("2")]),
            ]),
            "terminals": .array([.object(["address": .string("t1")])]),
        ])
        #expect(value["terminal"]?["address"]?.stringValue == "t7")
        #expect(value["terminal"]?["turn"]?.intValue == 3)
        #expect(value["terminal"]?["labels"]?["herdr.seen"]?.stringValue == "2")
        #expect(value["terminals"]?[0]?["address"]?.stringValue == "t1")
        #expect(value["missing"] == nil)
        #expect(value["terminals"]?[5] == nil)
    }

    @Test("rejects non-integral numbers from intValue")
    func nonIntegral() {
        #expect(JSONValue.number(1.5).intValue == nil)
        #expect(JSONValue.number(-2).intValue == -2)
    }
}
