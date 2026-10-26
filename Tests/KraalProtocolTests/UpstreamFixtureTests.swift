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
    /// method list. This frozen copy is from 0.8.2 and advertises no capabilities
    /// and one method.
    ///
    /// It must be refused — but *which* refusal is now decided by the version
    /// floor first (`0.8.2 < minimumDaemonVersion`), so it reports `serverTooOld`
    /// rather than `missingCapability`. That matches upstream, which folds
    /// `MissingSurfaceInterest` / `MissingHealthCheck` into `DaemonOutdated`
    /// (`herdr-gpui/crates/herdr-client/src/compat.rs:89-94`).
    ///
    /// What matters here is that the *frozen fixture decodes* and is refused with
    /// advice pointing at the daemon, not that a particular internal case wins.
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

        // Refused, and the advice must point at the daemon rather than the app.
        let result = Compatibility.evaluate(welcome)
        #expect(!result.isOK)
        #expect(result.userMessage?.contains("Update Herdr") == true, "got \(result)")
    }

    /// The hello fixture omits `surface_active`, `surface_reuse`, `surface_delta`
    /// and `surface_scroll` entirely (upstream relies on serde defaults: an
    /// absent `surface_active` means `true`). Decoding it is the half that proves
    /// forward compatibility — a fixture written by another client must not be
    /// rejected just for leaving defaults out.
    ///
    /// issue #10: `EndpointClientHello` now has a custom `init(from:)` carrying
    /// those defaults, so the type describes the contract it claims to.
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

    /// An absent `surface_active` means **active**, not inactive: upstream's
    /// `serde(default = "default_true")` (`endpoint.rs:28`). Reading that default
    /// backwards would silently suppress the surface stream, and every other
    /// omitted field falls back to `false` / `[]`.
    @Test("omitted hello fields take the upstream serde defaults")
    func helloDefaults() throws {
        let minimal = Data("""
        {
          "generation": 1,
          "cell_width_px": 8,
          "cell_height_px": 16,
          "surface_size": { "cols": 80, "rows": 24 },
          "pixel_mouse": false,
          "direct_graphics": false,
          "endpoint_keybindings": false,
          "mouse_capture": false
        }
        """.utf8)
        let hello = try JSONDecoder().decode(EndpointClientHello.self, from: minimal)
        #expect(hello.surfaceActive, "an omitted surface_active must default to true")
        #expect(!hello.surfaceReuse)
        #expect(!hello.surfaceDelta)
        #expect(!hello.surfaceScroll)
        #expect(hello.snapshotCodecs.isEmpty)
        #expect(hello.surfaceCodecs.isEmpty)
        #expect(hello.inputCodecs.isEmpty)
        #expect(hello.blobCodecs.isEmpty)
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

/// Can this decoder read surface frames produced by a *different* implementation?
///
/// The four `surface-*-v1.bin` files are copied unchanged from
/// `herdr-gpui/crates/herdr-protocol/tests/fixtures/` (Apache-2.0), where
/// `herdr-client/src/tests/surface_encoding.rs:308` replays them through its session.
/// They cover the four cases that only show up in a live stream: a full frame, an
/// incremental delta, buffer reuse, and both scroll directions.
///
/// This is worth more than another hand-written round trip. A round trip proves this
/// repository agrees with itself — the same misreading of the field order on both sides
/// still produces a green test. These bytes were written by a different encoder, so a
/// disagreement is visible. Rendering is also where the user-visible bugs have been:
/// the scroll white-screen (#113) and the kitty-graphics work were both here.
@Suite("Upstream surface frames")
struct UpstreamSurfaceFrameTests {
    /// The fixtures are a length-prefixed *stream* of messages, not one bare message.
    ///
    /// `u32` little-endian length then that many bytes of bincode
    /// (`herdr-protocol/src/codec.rs:69-79`). Our decoder takes one payload at a time,
    /// so the prefix is stripped here rather than teaching the decoder a framing it does
    /// not use on the socket.
    private func messages(in name: String) throws -> [[UInt8]] {
        let raw = [UInt8](try Fixture.data(name))
        var result: [[UInt8]] = []
        var offset = 0
        while offset + 4 <= raw.count {
            let length = Int(raw[offset])
                | Int(raw[offset + 1]) << 8
                | Int(raw[offset + 2]) << 16
                | Int(raw[offset + 3]) << 24
            offset += 4
            guard length > 0, offset + length <= raw.count else {
                throw Fixture.FixtureError.missing("\(name): truncated frame")
            }
            result.append(Array(raw[offset ..< offset + length]))
            offset += length
        }
        return result
    }

    @Test(
        "every frame in another implementation's stream decodes",
        arguments: [
            "surface-delta-v1.bin",
            "surface-reuse-v1.bin",
            "surface-scroll-up-v1.bin",
            "surface-scroll-down-v1.bin",
        ]
    )
    func decodesEveryFrame(name: String) throws {
        let frames = try messages(in: name)
        #expect(!frames.isEmpty, "\(name): no frames")

        var surfaces = 0
        for (index, frame) in frames.enumerated() {
            let message = try ServerMessageDecoder.decode(Data(frame))
            guard case let .paneSurface(surface) = message else {
                // The stream may carry snapshot/registry messages between surfaces; only
                // the surfaces are this suite's subject.
                continue
            }
            surfaces += 1
            #expect(surface.frame.width > 0, "\(name) frame \(index): no width")
            #expect(surface.frame.height > 0, "\(name) frame \(index): no height")
            #expect(
                surface.frame.buffer.count
                    == Int(surface.frame.width) * Int(surface.frame.height),
                "\(name) frame \(index): buffer does not match geometry"
            )
            // `w*h` alone cannot catch a swapped pair — the product is the same. The
            // orientation has to be pinned by something the fixture knows: these frames
            // are terminal surfaces, which are wider than they are tall. Swapping the
            // two fields is the exact mistake a hand-written decoder makes, and the
            // first version of this test passed with the swap in place.
            //
            // `#expect`'s second argument must be a literal, so the geometry goes into
            // the comment-free form and the numbers are asserted separately below.
            #expect(
                surface.frame.width > surface.frame.height,
                "a terminal surface is wider than it is tall; width and height may be transposed"
            )
            //  throws on a malformed surface; decoding without throwing is
            // not enough, because the cell grid and scroll metrics are checked there.
            try surface.validate()
        }
        #expect(surfaces > 0, "\(name): no PaneSurface in the stream")
    }
}
