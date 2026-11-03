// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import Testing
@testable import KraalHC

@Suite("Control socket")
struct HcControlTests {
    @Test("control path honours the explicit override and view sibling")
    func paths() throws {
        let home = URL(fileURLWithPath: "/tmp/control-home")
        #expect(try HcControlPaths.resolve(
            environment: ["KRAAL_CONTROL_SOCKET": "/tmp/explicit.sock"],
            home: home
        ) == "/tmp/explicit.sock")
        #expect(try HcControlPaths.resolve(
            environment: ["KRAAL_HC_VIEW": "/tmp/window/view.json"],
            home: home
        ) == "/tmp/window/control.sock")
        #expect(try HcControlPaths.resolve(
            environment: ["XDG_CONFIG_HOME": "/tmp/config"],
            home: home
        ) == "/tmp/config/kraal/control.sock")
    }

    @Test("requests use the herdr-app one-object vocabulary")
    func requests() throws {
        #expect(try HcControlRequest(json: .object(["ls": .bool(true)])) == .list)
        #expect(try HcControlRequest(json: .object(["status": .bool(true)])) == .status)
        let doValue = try HcControlRequest(json: .object([
            "do": .string("pane.split"),
            "args": .object(["direction": .string("right")]),
        ]))
        #expect(doValue == .doAction(
            name: "pane.split",
            arguments: .object(["direction": .string("right")])
        ))
        #expect(throws: HcControlError.self) {
            try HcControlRequest(json: .object(["do": .string("pane.split"), "args": .array([])]))
        }
    }

    @Test("one connection answers one request")
    func roundTrip() async throws {
        let path = "/tmp/kraal-control-\(UUID().uuidString).sock"
        let server = HcControlServer(path: path) { request in
            if case .list = request {
                return .object(["spaces": .array([]), "recent": .array([])])
            }
            return .object(["error": .string("unexpected request")])
        }
        try server.start()
        defer { server.stop() }
        let reply = try await Task.detached {
            try HcControlClient.send(.list, path: path, timeout: 5)
        }.value
        #expect(reply["spaces"]?.arrayValue?.isEmpty == true)
        #expect(reply["recent"]?.arrayValue?.isEmpty == true)
    }

    @Test("a second listener refuses to steal the socket")
    func addressInUse() throws {
        let path = "/tmp/kraal-control-\(UUID().uuidString).sock"
        let server = HcControlServer(path: path) { _ in .object(["ok": .bool(true)]) }
        try server.start()
        defer { server.stop() }
        do {
            _ = try HcControlServer(path: path) { _ in .object(["ok": .bool(true)]) }.start()
            Issue.record("a second listener started on the same path")
        } catch {
            #expect(String(describing: error).contains("already listening"))
        }
    }
}
