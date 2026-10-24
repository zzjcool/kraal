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

    private func scene(
        fingerprint: UInt64 = 0xABC,
        cellX: UInt16 = 1,
        cellY: UInt16 = 0
    ) -> SurfaceGraphicsScene {
        let key = assetKey(fingerprint: fingerprint)
        return SurfaceGraphicsScene(
            assets: [SurfaceGraphicsAsset(key: key, data: Data(repeating: 0x11, count: 16))],
            placements: [SurfaceGraphicsPlacement(
                asset: key,
                logicalPlacementId: 1,
                cellX: cellX,
                cellY: cellY,
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
    private func surface(
        _ scene: SurfaceGraphicsScene,
        revision: UInt64 = 1,
        gridWidth: UInt16 = 4,
        paneOrigin: (x: UInt16, y: UInt16) = (x: 0, y: 0)
    ) -> PaneSurfaceFrame {
        PaneSurfaceFrame(
            bootId: "boot-1",
            projectionRevision: 1,
            surfaceRevision: revision,
            frame: blankFrame(width: gridWidth),
            panes: [PaneSurfacePane(
                paneId: "w1:p1",
                contentRevision: revision,
                rect: SurfaceRect(originX: 0, originY: 0, width: 4, height: 1),
                innerRect: SurfaceRect(
                    originX: paneOrigin.x,
                    originY: paneOrigin.y,
                    width: 4,
                    height: 1
                ),
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

    /// The whole point of the issue, end to end through the model: an asset the
    /// daemon sent becomes kitty bytes for the pane's terminal.
    ///
    /// Through `apply`, not a test-only helper: `apply` is what the view calls, and
    /// a helper that encodes on its own would keep passing with the real wiring cut
    /// (that is exactly how the first version of these tests was green while the
    /// product was broken).
    @Test("a pane with an image sends kitty graphics")
    func paneSendsGraphics() {
        let model = makeModel()
        model.apply(surface: surface(scene()))
        let graphics = model.parkedFrame?.graphics ?? Data()
        #expect(hasUpload(graphics), "no kitty upload for the pane")
        #expect(imageId(in: graphics) != nil, "no image id in the stream")
    }

    /// Acceptance 2: nothing to draw must stay nothing to draw. An encoder handed
    /// an empty scene has no deletes to send either, and the renderer must not
    /// emit a stray cursor save around an empty payload.
    @Test("a pane with no image sends no kitty graphics")
    func paneWithoutGraphicsSendsNothing() {
        let model = makeModel()
        model.apply(surface: surface(SurfaceGraphicsScene()))
        let painted = model.parkedFrame?.graphics ?? Data()
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

    /// A repeat of the same scene still reaches the terminal.
    ///
    /// The *caching* half of this (a second identical frame costs zero bytes) belongs
    /// to `GraphicsEncoderTests` — it cannot be observed here, because in a test every
    /// `apply` takes the reset branch: with no Ghostty grid `previousGrid` is nil, so
    /// `needsScreenReset` always says yes, which clears the encoder and forces a
    /// re-upload. What this pins is the safety property that matters on this side:
    /// repeating a scene never yields a frame with no image.
    @Test("repeating a scene still carries the image")
    func repeatedSceneStillCarriesTheImage() {
        let model = makeModel()
        model.apply(surface: surface(scene(), revision: 1))
        let first = model.parkedFrame?.graphics ?? Data()
        model.apply(surface: surface(scene(), revision: 2))
        let second = model.parkedFrame?.graphics ?? Data()
        #expect(hasUpload(first) && hasUpload(second),
                "one of the two frames carried no image")
    }

    /// The complement: a *changed* scene must be uploaded, and its id must differ.
    /// Without this, the assertion above would pass on a model that uploads the same
    /// thing forever regardless of what the daemon sent.
    @Test("a changed image is uploaded under a new id")
    func changedSceneIsUploaded() {
        let model = makeModel()
        model.apply(surface: surface(scene(fingerprint: 0xABC), revision: 1))
        let first = model.parkedFrame?.graphics ?? Data()
        model.apply(surface: surface(scene(fingerprint: 0xDEF), revision: 2))
        let second = model.parkedFrame?.graphics ?? Data()
        #expect(hasUpload(second), "a redrawn image was not uploaded")
        #expect(imageId(in: first) != imageId(in: second),
                "a redrawn image kept the old image id, so the terminal keeps the old bitmap")
    }

    // MARK: - Acceptance 2 (issue #101's contract): paired reset

    /// `resetSurfaces` must forget the encoder along with the renderer. If it does
    /// not, the screen is cleared (the renderer's `2J` makes the terminal drop the
    /// images) while the encoder still believes they are there, so the next frame
    /// sends no upload and the picture is gone for good.
    @Test("resetting the surfaces makes the next frame upload again")
    func resetPairingReuploads() {
        let model = makeModel()
        model.apply(surface: surface(scene(), revision: 1))

        model.resetSurfaces()

        model.apply(surface: surface(scene(), revision: 2))
        let afterReset = model.parkedFrame?.graphics ?? Data()
        #expect(hasUpload(afterReset),
                "the encoder was not reset with the renderer, so the image would stay erased")
    }

    /// The reset must run **before** the encode, not after.
    ///
    /// `GraphicsEncoder` is stateful: a frame whose images did not change encodes to
    /// zero bytes. If `resetSurfaces()` ran after that encode, the frame would carry
    /// the pre-reset (empty) bytes while the `2J` that follows erases the picture —
    /// and it would stay erased until the next frame, which for a still program may
    /// never come. A grid change reaches this on every resize, so it is not rare.
    ///
    /// This is asserted as a *contract* rather than by reconstructing the race: in a
    /// test the encoder is never in the "cached, unchanged" state when a reset lands,
    /// because every `apply` here resets (no Ghostty grid means `previousGrid` is
    /// nil). So the observable consequence is stated directly — a frame that resets
    /// the screen must re-upload — and the ordering that guarantees it lives in the
    /// code with a comment explaining why it cannot be moved.
    @Test("a frame that resets the screen re-uploads the image")
    func resetFrameReuploads() {
        let model = makeModel()
        model.apply(surface: surface(scene(), revision: 1))
        #expect(model.parkedFrame?.graphics.isEmpty == false)

        let resetsBefore = model.screenResetCount
        model.apply(surface: surface(scene(), revision: 1, gridWidth: 5))
        #expect(model.screenResetCount > resetsBefore,
                "the fixture never reached the reset branch, so it proves nothing")
        #expect(hasUpload(model.parkedFrame?.graphics ?? Data()),
                "the frame that cleared the screen carried no upload")
    }

    /// Placements are in **surface** coordinates; this terminal is only the pane.
    ///
    /// A split pane's `innerRect` origin is not (0,0), so an image whose placement
    /// says column 20 must be drawn at column 20 minus this pane's origin. Without
    /// the shift the picture lands in the neighbouring pane — and the GUI gate would
    /// not notice, because its fixture is a single pane at the origin.
    ///
    /// Upstream does the inverse addition (`client_host_piece`,
    /// `kitty_graphics/surface.rs:1032`), which is what makes the shift correct
    /// rather than invented.
    @Test("a placement is shifted into the pane's own coordinates")
    func placementIsShiftedIntoPaneSpace() {
        let model = makeModel()
        // The pane starts at column 20, so a placement at surface column 22 must be
        // drawn at column 2 of this pane.
        model.apply(surface: surface(scene(cellX: 22, cellY: 5), paneOrigin: (x: 20, y: 5)))
        guard let graphics = model.parkedFrame?.graphics else {
            Issue.record("no parked frame")
            return
        }
        let text = String(bytes: graphics, encoding: .utf8) ?? ""
        // Placement row 6 (surface row 5 + 1) becomes row 1 here; column 22 becomes 2.
        #expect(text.contains("\u{1B}[1;3H"),
                "the placement was not shifted to the pane origin: \(text.prefix(160))")
    }

    /// A placement entirely outside the pane is dropped, not clamped: drawing it at
    /// column 0 would put the image over this pane's own cells, where it does not
    /// belong.
    @Test("a placement outside the pane is dropped")
    func placementOutsidePaneIsDropped() {
        let model = makeModel()
        // Origin column 20, width 4: a placement at surface column 30 is outside.
        model.apply(surface: surface(scene(cellX: 30), paneOrigin: (x: 20, y: 0)))
        let graphics = model.parkedFrame?.graphics ?? Data()
        #expect(!hasUpload(graphics),
                "a placement outside the pane was still uploaded/placed")
    }

    // MARK: - Scope
    // MARK: - Scope
    // MARK: - Scope

    /// Two machines both have a `w1:p1`. Their image ids must not collide, or one
    /// pane's `d=I` deletes the other pane's picture.
    @Test("the same pane on two machines uses different image ids")
    func scopeSeparatesMachines() {
        let first = makeModel(machine: "machine-a")
        let second = makeModel(machine: "machine-b")
        first.apply(surface: surface(scene()))
        second.apply(surface: surface(scene()))
        guard let firstId = imageId(in: first.parkedFrame?.graphics ?? Data()),
              let secondId = imageId(in: second.parkedFrame?.graphics ?? Data())
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
        first.apply(surface: surface(scene()))
        second.apply(surface: surface(scene()))
        guard let firstId = imageId(in: first.parkedFrame?.graphics ?? Data()),
              let secondId = imageId(in: second.parkedFrame?.graphics ?? Data())
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
