// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import Testing

@testable import KraalHC

@Suite("JSON-RPC")
struct HcRPCTests {
    @Test("encodes a request with a newline only in plain mode")
    func requestEncoding() throws {
        let json = try HcRPC.requestJSON(id: 3, method: "terminal.list", params: .object(["all": .bool(true)]))
        let line = try HcRPC.requestLine(id: 3, method: "terminal.list", params: .object(["all": .bool(true)]))
        #expect(!json.contains(0x0A))
        #expect(line.last == 0x0A)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: json)
        #expect(decoded["id"]?.intValue == 3)
        #expect(decoded["method"]?.stringValue == "terminal.list")
        #expect(decoded["params"]?["all"]?.boolValue == true)
    }

    @Test("decodes a result")
    func response() throws {
        let data = Data(#"{"jsonrpc":"2.0","id":7,"result":{"terminals":[]}}"#.utf8)
        let incoming = try HcRPC.decode(data)
        guard case let .response(id, result) = incoming else {
            Issue.record("expected response, got \(incoming)")
            return
        }
        #expect(id == 7)
        #expect(result["terminals"]?.arrayValue?.isEmpty == true)
    }

    @Test("keeps the stable error kind and hint")
    func failure() throws {
        let json = """
        {"jsonrpc":"2.0","id":9,"error":{"code":-32000,"message":"no terminal t9",\
        "data":{"kind":"not_found","hint":"run hc ls"}}}
        """
        let data = Data(json.utf8)
        let incoming = try HcRPC.decode(data)
        guard case let .failure(id, error) = incoming else {
            Issue.record("expected failure, got \(incoming)")
            return
        }
        #expect(id == 9)
        #expect(error.code == -32_000)
        #expect(error.kind == "not_found")
        #expect(error.hint == "run hc ls")
        #expect(error.description.contains("no terminal t9"))
        #expect(error.description.contains("[not_found]"))
    }

    @Test("decodes notifications without an id")
    func notification() throws {
        let data = Data(#"{"jsonrpc":"2.0","method":"event","params":{"seq":42}}"#.utf8)
        let incoming = try HcRPC.decode(data)
        guard case let .notification(method, params) = incoming else {
            Issue.record("expected notification, got \(incoming)")
            return
        }
        #expect(method == "event")
        #expect(params["seq"]?.intValue == 42)
    }

    @Test("recognises a core-to-client request")
    func request() throws {
        let data = Data(#"{"jsonrpc":"2.0","id":11,"method":"ping","params":{}}"#.utf8)
        let incoming = try HcRPC.decode(data)
        guard case let .request(id, method, _) = incoming else {
            Issue.record("expected request, got \(incoming)")
            return
        }
        #expect(id == 11)
        #expect(method == "ping")
    }

    @Test("rejects malformed messages")
    func malformed() {
        #expect(throws: HcConnectionError.self) {
            _ = try HcRPC.decode(Data(#"{"id":1}"#.utf8))
        }
        #expect(throws: HcConnectionError.self) {
            _ = try HcRPC.decode(Data("not json".utf8))
        }
    }
}
