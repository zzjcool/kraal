// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Upstream fixtures, verbatim.
//
// The three JSON files in `Fixtures/upstream-*.json` are copied unchanged from
// `herdr-gpui/crates/herdr-protocol/tests/fixtures/` (Apache-2.0; adapted there
// from Herdr 0.9.1 commit `856b64b9`, see that repo's NOTICE.md). They are
// useful precisely because this repository did not write them: they are a frozen
// sample of the handshake and sidebar formats from a *different* client, so
// decoding them proves Kraal agrees with a second implementation rather than with
// itself.
//
// Sources ported: `compatibility.rs:117` `upstream_json_fixtures_and_future_values`,
// `herdr/src/protocol/endpoint.rs:262` `frozen_generation_one_handshake_decodes`,
// `endpoint.rs:284` `frozen_generation_one_snapshot_decodes`.

import Foundation
import Testing

@testable import KraalProtocol

@Suite("Upstream fixtures")
struct UpstreamFixtureTests {
    private func json(_ name: String) throws -> Data {
        try Fixture.data(name)
    }

    /// The welcome is the compatibility contract: generation, four codecs, the
    /// method list. This frozen copy advertises no capabilities and one method,
    /// so it must be refused for the *right* reason.
    @Test("the frozen welcome decodes and names the missing capability")
    func welcomeDecodes() throws {
        let welcome = try JSONDecoder().decode(
            EndpointServerWelcome.self,
            from: json("upstream-welcome-v1.json")
        )
        #expect(welcome.generation == 1)
        #expect(welcome.serverVersion == "0.8.2")
        #expect(welcome.inputCodec == EndpointProtocol.inputCodecV1)
        #expect(welcome.capabilities.isEmpty)
        #expect(welcome.methods == ["pane.focus"])

        // No capabilities at all: the first required one is what we should say.
        guard case let .missingCapability(capability) = Compatibility.evaluate(welcome) else {
            Issue.record("expected a missing capability, got \(Compatibility.evaluate(welcome))")
            return
        }
        #expect(EndpointProtocol.requiredSurfaceCapabilities.contains(capability))
    }

    /// The hello fixture omits `surface_active`, `surface_reuse`, `surface_delta`
    /// and `surface_scroll` entirely (upstream relies on serde defaults: an
    /// absent `surface_active` means `true`). Decoding it is the half that proves
    /// forward compatibility — a fixture written by another client must not be
    /// rejected just for leaving defaults out.
    ///
    /// RED AS PORTED: `EndpointClientHello` has no custom `init(from:)`, so every
    /// field is required. Kraal only ever *sends* a hello today, so nothing in the
    /// app breaks — but the type does not describe the wire contract it claims to
    /// (upstream's serde defaults are part of that contract), and a future reader
    /// of a hello, or a test double, would fail on a perfectly valid payload.
    @Test("the frozen hello keeps every negotiated field")
    func helloDecodes() throws {
        let hello = try JSONDecoder().decode(
            EndpointClientHello.self,
            from: json("upstream-hello-v1.json")
        )
        #expect(hello.generation == 1)
        #expect(hello.surfaceSize.cols == 80)
        #expect(hello.surfaceSize.rows == 24)
        #expect(hello.pixelMouse)
        #expect(!hello.directGraphics)
        #expect(hello.snapshotCodecs == [EndpointProtocol.snapshotCodecV1])
        #expect(hello.surfaceCodecs == [EndpointProtocol.surfaceCodecV1])
        #expect(hello.inputCodecs == [EndpointProtocol.inputCodecV1])
        #expect(hello.blobCodecs == [EndpointProtocol.blobCodecV1])
    }

    /// A snapshot from another client, including `agent_status` values no version
    /// of this client has seen (`future_status_from_new_server`). An unknown
    /// status must degrade to `.unknown` rather than failing the whole sidebar.
    @Test("the frozen snapshot decodes with future enum values")
    func snapshotDecodes() throws {
        let snapshot = try JSONDecoder().decode(
            ClientShellSnapshot.self,
            from: json("upstream-snapshot-v1.json")
        )
        #expect(snapshot.bootId == "boot-v1")
        #expect(snapshot.revision == 7)
        #expect(snapshot.workspaces.count == 1)
        #expect(snapshot.workspaces[0].agentStatus == .unknown)
        #expect(snapshot.tabs[0].agentStatus == .working)
        #expect(snapshot.agents[0].agentStatus == .blocked)
        #expect(snapshot.commands[0].action == .shell)
        #expect(snapshot.workspaces[0].tokens == [["model", "opus"]])
        #expect(snapshot.workspaces[0].aheadBehind?.ahead == 1)
        #expect(snapshot.workspaces[0].worktree?.isLinkedWorktree == true)
        #expect(snapshot.focusedPaneId == "w1:p1")
    }

    /// `compatibility.rs:117`: unknown *keys* are ignored by `Decodable`, which is
    /// what lets a newer daemon add a field without breaking this client. Unknown
    /// enum *values* degrade to `.unknown` explicitly, because `Decodable` would
    /// otherwise throw and take the whole snapshot with it.
    @Test("future keys and future command actions degrade instead of throwing")
    func futureValues() throws {
        var object = try #require(
            JSONSerialization.jsonObject(with: json("upstream-snapshot-v1.json")) as? [String: Any]
        )
        object["future"] = ["anything": true]
        var commands = try #require(object["commands"] as? [[String: Any]])
        commands[0]["action"] = "FutureAction"
        object["commands"] = commands

        let data = try JSONSerialization.data(withJSONObject: object)
        let snapshot = try JSONDecoder().decode(ClientShellSnapshot.self, from: data)
        #expect(snapshot.commands[0].action == .unknown)
    }
}
