// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Graphics reach a pane's terminal (issue #105, parent #37).
//
// #101 built the encoder; nothing called it. The pane passed
// `surface.frame.graphics` — the *ANSI path's* field, which the daemon leaves
// empty for semantic clients — so a pane with an image drew nothing even though
// every layer below was correct and every test was green.
//
// Three things have to hold, and this file is where they are pinned:
//
//   1. The scene reaches `FrameData.graphics` on the way to the terminal.
//   2. The encoder is reset together with the renderer. `GraphicsEncoder.reset()`
//      sends no deletes because the screen was cleared and the images went with
//      it — trust that without clearing and the image is gone *permanently*, since
//      the encoder believes it already uploaded it.
//   3. A frame whose images changed but whose cells did not still repaints.
//      `needsRepaint` only compared cells, so a moved image with identical text
//      would be dropped and the picture would freeze at its old position.
//
// Scope is per `(machine, paneId)`: image ids are a hash of it, and two machines
// both name a pane `w1:p1`. Sharing a scope would put two daemons' images in one
// id namespace, where one pane's delete removes the other's picture.

import CoreGraphics
import Foundation
import Testing

@testable import KraalProtocol
@testable import KraalUI
@testable import KraalTerminalView

@Suite("Pane graphics")
@MainActor
struct PaneGraphicsTests {
    // MARK: - Builders

    private func assetKey(fingerprint: UInt64 = 0xABC) -> SurfaceGraphicsAssetKey {
        SurfaceGraphicsAssetKey(
            source: .terminal(target: .pane(paneId: "w1:p1"), imageId: 1),
            imageWidth: 2,
            imageHeight: 2,
            format: .rgba,
            dataLen: 16,
            dataFingerprint: fingerprint
        )
    }

    private func scene(fingerprint: UInt64 = 0xABC, cellX: UInt16 = 1) -> SurfaceGraphicsScene {
        let key = assetKey(fingerprint: fingerprint)
        return SurfaceGraphicsScene(
            assets: [SurfaceGraphicsAsset(key: key, data: Data(repeating: 0x11, count: 16))],
            placements: [SurfaceGraphicsPlacement(
                asset: key,
                logicalPlacementId: 1,
                cellX: cellX,
                cellY: 0,
                cols: 2,
                rows: 1,
                sourceX: 0,
                sourceY: 0,
                sourceWidth: 0,
                sourceHeight: 0,
                xOffset: 0,
                yOffset: 0,
                layer: 0,
                scrollbackOffset: 0
            )]
        )
    }

    private func blankFrame(width: UInt16 = 4, height: UInt16 = 1) -> FrameData {
        FrameData(
            cells: Array(repeating: .blank, count: Int(width) * Int(height)),
            width: width,
            height: height,
            cursor: nil,
            hyperlinks: [],
            graphics: Data()
        )
    }

    private func makeModel(machine: String = "machine-a") -> PaneTerminalModel {
        PaneTerminalModel(paneId: "w1:p1", machine: machine) { _ in }
    }

    /// The `i=` value the encoder chose, read back out of the byte stream.
    private func imageId(in bytes: Data) -> UInt32? {
        guard let text = String(bytes: bytes, encoding: .utf8) else { return nil }
        for chunk in text.components(separatedBy: "\u{1B}_G").dropFirst() {
            guard let semicolon = chunk.firstIndex(of: ";") else { continue }
            let control = chunk[chunk.startIndex ..< semicolon]
            for field in control.split(separator: ",") where field.hasPrefix("i=") {
                return UInt32(field.dropFirst(2))
            }
        }
        return nil
    }

    private func hasUpload(_ bytes: Data) -> Bool {
        guard let text = String(bytes: bytes, encoding: .utf8) else { return false }
        return text.contains("a=t")
    }

    // MARK: - Acceptance 1: the scene reaches the terminal

    /// A surface frame for `w1:p1`, 4x1 cells, with the given graphics scene.
    private func surface(_ scene: SurfaceGraphicsScene, revision: UInt64 = 1) -> PaneSurfaceFrame {
        PaneSurfaceFrame(
            bootId: "boot-1",
            projectionRevision: 1,
            surfaceRevision: revision,
            frame: blankFrame(),
            panes: [PaneSurfacePane(
                paneId: "w1:p1",
                contentRevision: revision,
                rect: SurfaceRect(originX: 0, originY: 0, width: 4, height: 1),
                innerRect: SurfaceRect(originX: 0, originY: 0, width: 4, height: 1),
                scrollbarRect: nil,
                scroll: nil,
                focused: true,
                mouseReporting: false,
                sgrPixelMouse: false,
                alternateScreenActive: false,
                pixelWidth: 0,
                pixelHeight: 0
            )],
            splits: [],
            popup: nil,
            graphics: scene
        )
    }

    /// **The real path.** `apply(surface:)` is what the SwiftUI view calls, so a
    /// cut in the wiring has to fail here. With no Ghostty grid attached the frame
    /// is parked instead of painted, and the parked frame is what this inspects.
    @Test("apply turns the daemon's scene into kitty bytes")
    func applyEncodesScene() {
        let model = makeModel()
        model.apply(surface: surface(scene()))
        let parked = model.parkedFrame
        #expect(parked != nil, "apply did not park a frame (is the pane id wrong?)")
        guard let graphics = parked?.graphics else { return }
        #expect(hasUpload(graphics), "apply produced no kitty upload from the scene")
        #expect(imageId(in: graphics) != nil, "no image id in the encoded stream")
    }

    /// The complement on the same path: an empty scene must produce empty bytes, or
    /// every frame would carry a stray transaction.
    @Test("apply produces nothing for an empty scene")
    func applyEncodesEmptyScene() {
        let model = makeModel()
        model.apply(surface: surface(SurfaceGraphicsScene()))
        #expect(model.parkedFrame?.graphics.isEmpty == true,
                "an empty scene produced graphics bytes")
    }

    /// And the whole point of the issue, end to end through the model: an asset the
    /// daemon sent becomes kitty bytes on the pane's terminal.
    @Test("a pane with an image sends kitty graphics")
    func paneSendsGraphics() {
        let model = makeModel()
        let painted = model.paint(blankFrame(), scene: scene())
        #expect(hasUpload(painted), "no kitty upload reached the terminal")
        #expect(imageId(in: painted) != nil, "no image id in the stream")
    }

    /// Acceptance 2: nothing to draw must stay nothing to draw. An encoder handed
    /// an empty scene has no deletes to send either, and the renderer must not
    /// emit a stray cursor save around an empty payload.
    @Test("a pane with no image sends no kitty graphics")
    func paneWithoutGraphicsSendsNothing() {
        let model = makeModel()
        let painted = model.paint(blankFrame(), scene: SurfaceGraphicsScene())
        #expect(!hasUpload(painted), "an empty scene produced an upload")
        // No kitty sequence at all — not "no synchronized output". `?2026h` frames
        // the *cell* update and is always there; asserting its absence would be a
        // test of the text path, not of graphics.
        guard let text = String(bytes: painted, encoding: .utf8) else {
            Issue.record("the rendered output is not text")
            return
        }
        #expect(!text.contains("\u{1B}_G"), "the renderer emitted a kitty sequence for no graphics")
    }

    /// Acceptance 3: the encoder's cache is what makes an unchanged image free.
    /// The *pane* must not defeat it by re-encoding a scene that did not change —
    /// note the second paint is a real paint (cells are re-sent if they differ),
    /// so this asserts on the graphics payload specifically, not on the output
    /// being empty.
    @Test("an unchanged scene is not uploaded twice")
    func unchangedSceneIsNotReuploaded() {
        let model = makeModel()
        _ = model.paint(blankFrame(), scene: scene())
        let second = model.paint(blankFrame(), scene: scene())
        #expect(!hasUpload(second), "the image was uploaded again for an unchanged scene")
    }

    /// The complement: a *changed* scene must be uploaded. Without this, the test
    /// above would pass on a model that never uploads anything at all.
    @Test("a changed image is uploaded")
    func changedSceneIsUploaded() {
        let model = makeModel()
        _ = model.paint(blankFrame(), scene: scene(fingerprint: 0xABC))
        let second = model.paint(blankFrame(), scene: scene(fingerprint: 0xDEF))
        #expect(hasUpload(second), "a redrawn image was not uploaded")
    }

    // MARK: - Acceptance 2 (issue #101's contract): paired reset

    /// `resetSurfaces` must forget the encoder along with the renderer. If it does
    /// not, the screen is cleared (the renderer's `2J` makes the terminal drop the
    /// images) while the encoder still believes they are there, so the next frame
    /// sends no upload and the picture is gone for good.
    @Test("resetting the surfaces makes the next frame upload again")
    func resetPairingReuploads() {
        let model = makeModel()
        _ = model.paint(blankFrame(), scene: scene())

        model.resetSurfaces()

        let afterReset = model.paint(blankFrame(), scene: scene())
        #expect(hasUpload(afterReset),
                "the encoder was not reset with the renderer, so the image would stay erased")
    }

    // MARK: - Scope

    /// Two machines both have a `w1:p1`. Their image ids must not collide, or one
    /// pane's `d=I` deletes the other pane's picture.
    @Test("the same pane on two machines uses different image ids")
    func scopeSeparatesMachines() {
        let first = makeModel(machine: "machine-a")
        let second = makeModel(machine: "machine-b")
        guard let firstId = imageId(in: first.paint(blankFrame(), scene: scene())),
              let secondId = imageId(in: second.paint(blankFrame(), scene: scene()))
        else {
            Issue.record("could not read an image id out of one of the streams")
            return
        }
        #expect(firstId != secondId,
                "two machines shared an image id (\(firstId)); a delete would cross the boundary")
    }

    /// And the scope has to be stable across paints, or every frame would look like
    /// a new image and the no-reupload optimisation would never fire.
    @Test("the same scene in the same scope keeps its image id")
    func scopeIsStable() {
        // Two separate models, so this is not just the encoder's own cache: the
        // scope string itself has to be deterministic, or every launch and every
        // new view would get fresh ids and the terminal would accumulate orphans.
        let first = makeModel()
        let second = makeModel()
        guard let firstId = imageId(in: first.paint(blankFrame(), scene: scene())),
              let secondId = imageId(in: second.paint(blankFrame(), scene: scene()))
        else {
            Issue.record("could not read an image id out of one of the streams")
            return
        }
        #expect(firstId == secondId,
                "two views of the same machine+pane disagreed on an image id")
    }
}

@Suite("Graphics repaint decisions")
struct GraphicsRepaintTests {
    /// The bug this closes: an image moves, no cell changes, and the frame is
    /// dropped. `needsRepaint` only compared cells, so the picture froze at its
    /// old position until something else happened to repaint.
    @Test("a graphics-only change forces a repaint")
    func graphicsChangeForcesRepaint() {
        let needs = SurfaceGeometry.needsRepaint(
            contentRevisionChanged: false,
            previousGrid: (width: 80, height: 24),
            currentGrid: (width: 80, height: 24),
            cellsDiffer: false,
            graphicsDiffer: true
        )
        #expect(needs, "a moved image was treated as nothing to do")
    }

    /// The complement, so the new parameter cannot be hardcoded `true`.
    @Test("an unchanged frame with no graphics change is still skipped")
    func unchangedFrameIsSkipped() {
        let needs = SurfaceGeometry.needsRepaint(
            contentRevisionChanged: false,
            previousGrid: (width: 80, height: 24),
            currentGrid: (width: 80, height: 24),
            cellsDiffer: false,
            graphicsDiffer: false
        )
        #expect(!needs, "an unchanged frame was repainted")
    }
}
