// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import Testing

@testable import KraalHC

@Suite("Hello and compatibility")
struct HcHelloTests {
    private func hello(
        generation: Int = 1,
        version: String = "0.1.16",
        methods: [String] = HcProtocol.requiredMethods
    ) throws -> HcHelloResult {
        try HcHelloResult(json: .object([
            "generation": .int(generation),
            "version": .string(version),
            "core": .object(["id": .string("abc"), "name": .string("machine")]),
            "framed": .bool(true),
            "methods": .array(methods.map(JSONValue.string)),
            "features": .array([.string("framed"), .string("attach")]),
        ]))
    }

    @Test("parses the fields the client uses")
    func parse() throws {
        let result = try hello()
        #expect(result.generation == 1)
        #expect(result.version == "0.1.16")
        #expect(result.coreID == "abc")
        #expect(result.coreName == "machine")
        #expect(result.framed)
        #expect(result.methods.contains("terminal.attach"))
        #expect(result.features == ["framed", "attach"])
    }

    @Test("accepts the tested core")
    func compatible() throws {
        #expect(HcProtocol.check(try hello()) == .compatible)
    }

    @Test("rejects another protocol generation")
    func generation() throws {
        #expect(
            HcProtocol.check(try hello(generation: 2))
                == .unsupportedGeneration(have: 2, expected: 1)
        )
    }

    @Test("rejects an older core by name")
    func tooOld() throws {
        let compatibility = HcProtocol.check(try hello(version: "0.1.9"))
        #expect(compatibility == .tooOld(have: "0.1.9", need: HcProtocol.minimumVersion))
        #expect(compatibility.message.contains("0.1.9"))
    }

    @Test("rejects a core missing a method we call")
    func missingMethod() throws {
        var methods = HcProtocol.requiredMethods
        methods.removeAll { $0 == "doc.set" }
        let compatibility = HcProtocol.check(try hello(methods: methods))
        #expect(compatibility == .missingMethods(["doc.set"]))
        #expect(compatibility.message.contains("doc.set"))
    }

    @Test("reports an unreadable version instead of guessing")
    func unreadableVersion() throws {
        let compatibility = HcProtocol.check(try hello(version: "nightly"))
        #expect(compatibility == .unreadableVersion("nightly"))
    }

    @Test("compares semantic versions, ignoring prerelease suffixes")
    func versionOrdering() throws {
        #expect(HcVersion("0.1.16") == HcVersion("hc 0.1.16"))
        #expect(HcVersion("0.1.16-rc1") == HcVersion("0.1.16"))
        #expect(try #require(HcVersion("0.1.9")) < #require(HcVersion("0.1.16")))
        #expect(HcVersion("nightly") == nil)
        #expect(HcVersion("1") == nil)
    }
}
