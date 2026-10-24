// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The seam between the encoder (#101) and the renderer (#100 / issue #37).
//
// This file exists because a review of #101 found that the encoder had **zero
// call sites in `Sources/`**: 19 tests proved it emits the right bytes, and
// nothing proved those bytes ever reach a terminal. That is the exact shape of
// this repository's three worst bugs — unit tests green, the user sees nothing —
// so the seam gets its own test rather than a promise in a commit message.
//
// What is asserted here is deliberately *not* "the encoder works" (already
// covered) and *not* "the pixels appear" (that needs a real terminal, see #103).
// It is the wiring contract:
//
//   scene → GraphicsEncoder → FrameData.graphics → SurfaceANSIRenderer.render
//
// must carry the kitty bytes, inside the synchronized-output block, wrapped in
// DECSC/DECRC. Everything on that path is pure, so the test needs no daemon, no
// GUI and no VM.

import Foundation
import Testing

@testable import KraalProtocol

@Suite("Encoder to renderer seam")
struct GraphicsSeamTests {
    /// A 2x2 RGBA image and one placement, as the daemon would send it.
    private func scene() -> SurfaceGraphicsScene {
        let key = SurfaceGraphicsAssetKey(
            source: .terminal(target: .pane(paneId: "w1:p1"), imageId: 1),
            imageWidth: 2,
            imageHeight: 2,
            format: .rgba,
            dataLen: 16,
            dataFingerprint: 0xABCD
        )
        let asset = SurfaceGraphicsAsset(key: key, data: Data(repeating: 0x7F, count: 16))
        let placement = SurfaceGraphicsPlacement(
            asset: key,
            logicalPlacementId: 1,
            cellX: 3,
            cellY: 2,
            cols: 4,
            rows: 2,
            sourceX: 0,
            sourceY: 0,
            sourceWidth: 0,
            sourceHeight: 0,
            xOffset: 0,
            yOffset: 0,
            layer: 0,
            scrollbackOffset: 0
        )
        return SurfaceGraphicsScene(assets: [asset], placements: [placement])
    }

    private func frame(graphics: Data) -> FrameData {
        let width: UInt16 = 10
        func cell(_ symbol: String) -> CellData {
            CellData(symbol: symbol, foreground: 0, background: 0,
                     modifier: 0, skip: false, hyperlink: nil)
        }
        var cells: [CellData] = []
        while cells.count < Int(width) * 2 { cells.append(cell(" ")) }
        return FrameData(
            cells: cells,
            width: width,
            height: 2,
            cursor: nil,
            hyperlinks: [],
            graphics: graphics
        )
    }

    /// The whole path, in one assertion: what the encoder produces for a scene is
    /// what the renderer hands the terminal.
    ///
    /// Before this test the two halves were only joined in a commit message. The
    /// encoder's output could have been dropped by `PaneTerminal` (it was: it
    /// passed `Data()` for months) and every existing test would still pass.
    @Test("a scene encoded and rendered reaches the terminal bytes")
    func sceneReachesTheTerminal() {
        var encoder = GraphicsEncoder()
        let kitty = encoder.encode(scene: scene(), scope: "w1:p1")
        #expect(!kitty.isEmpty, "the encoder produced nothing for a scene with one asset")

        var renderer = SurfaceANSIRenderer()
        let output = renderer.render(frame(graphics: kitty))

        // The upload and the placement, byte for byte, in the renderer's output.
        #expect(output.range(of: kitty) != nil,
                "the renderer dropped the encoder's bytes; a pane with an image would draw nothing")
    }

    /// And inside the framing the terminal needs. A pass-through that ignored the
    /// sync block would still satisfy the test above while flickering, and one
    /// that skipped DECSC/DECRC would leave the cursor wherever the graphics
    /// sequence stopped.
    @Test("the seam keeps the sync block and cursor save around the bytes")
    func seamKeepsTheFraming() {
        var encoder = GraphicsEncoder()
        let kitty = encoder.encode(scene: scene(), scope: "w1:p1")
        var renderer = SurfaceANSIRenderer()
        let output = renderer.render(frame(graphics: kitty))

        guard let bytes = output.range(of: kitty),
              let syncOpen = output.range(of: Data("\u{1B}[?2026h".utf8)),
              let syncClose = output.range(of: Data("\u{1B}[?2026l".utf8))
        else {
            Issue.record("one of the three markers is missing from the rendered output")
            return
        }
        #expect(syncOpen.lowerBound < bytes.lowerBound, "the image was written before the sync block")
        #expect(bytes.lowerBound < syncClose.lowerBound, "the image was written after the sync block")
        let before = output[output.startIndex ..< bytes.lowerBound]
        #expect(before.suffix(2) == Data("\u{1B}7".utf8), "no DECSC before the image bytes")
        let after = output[bytes.upperBound...]
        #expect(after.prefix(2) == Data("\u{1B}8".utf8), "no DECRC after the image bytes")
    }

    /// The encoder's own diffing must survive the renderer's whole-blob diffing.
    ///
    /// `SurfaceANSIRenderer` compares `frame.graphics` against the previous frame
    /// and skips the write when they are equal. That is coarser than the encoder
    /// (which diffs uploads and placements separately), and the two must not
    /// fight: a second identical scene produces empty bytes, and the renderer must
    /// therefore write nothing — not a stray DECSC/DECRC pair around nothing.
    @Test("an unchanged scene writes no framing at all")
    func unchangedSceneWritesNothing() {
        var encoder = GraphicsEncoder()
        let first = encoder.encode(scene: scene(), scope: "w1:p1")
        #expect(!first.isEmpty)

        var renderer = SurfaceANSIRenderer()
        _ = renderer.render(frame(graphics: first))

        let second = encoder.encode(scene: scene(), scope: "w1:p1")
        #expect(second.isEmpty, "the encoder re-sent an unchanged scene")
        let output = renderer.render(frame(graphics: second))
        #expect(output.range(of: Data("\u{1B}7".utf8)) == nil,
                "the renderer emitted a cursor save for an empty graphics payload")
    }

    /// A moved placement re-emits only the placement, and the renderer writes it.
    ///
    /// This is the case the encoder's diffing exists for, carried through the
    /// seam: the image must not be uploaded again, and the new position must
    /// still reach the terminal.
    @Test("a moved placement reaches the terminal without a second upload")
    func movedPlacementReachesTheTerminal() {
        var encoder = GraphicsEncoder()
        let firstScene = scene()
        let first = encoder.encode(scene: firstScene, scope: "w1:p1")

        var moved = firstScene
        moved.placements[0].cellX = 7
        let second = encoder.encode(scene: moved, scope: "w1:p1")

        let secondText = String(bytes: second, encoding: .utf8) ?? ""
        #expect(secondText.contains("a=p"), "the moved placement was not re-emitted")
        #expect(!secondText.contains("a=t"), "the image was uploaded again for a move")

        var renderer = SurfaceANSIRenderer()
        _ = renderer.render(frame(graphics: first))
        let output = renderer.render(frame(graphics: second))
        #expect(output.range(of: second) != nil,
                "the renderer dropped the placement update")
        #expect(String(bytes: output, encoding: .utf8)?.contains("a=p") == true)
    }

    /// `reset()` on the encoder and on the renderer have to happen together.
    ///
    /// `GraphicsEncoder.reset()` sends no deletes, on the grounds that the screen
    /// was cleared and the images went with it. That reasoning only holds if the
    /// clear actually happened — `SurfaceANSIRenderer.reset()` is what makes the
    /// next frame emit `2J`, and the terminal's `ED2` is what reclaims the images
    /// (Ghostty: `Terminal.zig` → `kitty_images.clearScreen()`).
    ///
    /// The failure if a call site forgets one: the terminal cleared, the encoder
    /// still believes it uploaded the image, the next frame sends no `a=t`, and the
    /// image is gone **permanently** — until something else invalidates the cache.
    /// `PaneTerminal` has six `renderer.reset()` call sites today, so this is a
    /// contract worth pinning rather than a hypothetical.
    @Test("resetting both halves re-uploads after a clear")
    func resetPairsAcrossTheSeam() {
        var encoder = GraphicsEncoder()
        var renderer = SurfaceANSIRenderer()
        let scene = scene()

        _ = renderer.render(frame(graphics: encoder.encode(scene: scene, scope: "w1:p1")))

        // The paired reset: screen cleared, cache forgotten.
        renderer.reset()
        encoder.reset()
        let afterReset = encoder.encode(scene: scene, scope: "w1:p1")
        #expect(!afterReset.isEmpty, "the encoder forgot to re-upload after a paired reset")
        #expect(String(bytes: afterReset, encoding: .utf8)?.contains("a=t") == true,
                "the image was not uploaded again, so it would stay erased")
        let output = renderer.render(frame(graphics: afterReset))
        #expect(output.range(of: Data("\u{1B}[2J".utf8)) != nil,
                "the renderer did not clear the screen after its own reset")
        #expect(output.range(of: afterReset) != nil, "the re-upload did not reach the terminal")
    }

    /// An empty scene must send the deletes the encoder produces for it.
    ///
    /// The failure this rules out: the encoder correctly says "delete that image",
    /// the renderer skips it because the *cells* did not change, and the image
    /// stays painted on top of the pane forever.
    @Test("a cleared scene sends its deletes through the renderer")
    func clearedSceneSendsDeletes() {
        var encoder = GraphicsEncoder()
        let populated = encoder.encode(scene: scene(), scope: "w1:p1")

        var renderer = SurfaceANSIRenderer()
        _ = renderer.render(frame(graphics: populated))

        let cleared = encoder.encode(scene: SurfaceGraphicsScene(), scope: "w1:p1")
        #expect(!cleared.isEmpty, "clearing a scene with one image produced no delete")
        let output = renderer.render(frame(graphics: cleared))
        #expect(output.range(of: cleared) != nil, "the renderer dropped the delete")
        #expect(String(bytes: cleared, encoding: .utf8)?.contains("d=I") == true)
    }
}
