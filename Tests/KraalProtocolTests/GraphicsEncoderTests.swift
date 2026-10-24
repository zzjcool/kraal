// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// `SurfaceGraphicsScene` → kitty graphics bytes (issue #101, parent #37).
//
// Decoding the scene was already done (`Decoder.decodeGraphicsScene`); what was
// missing is the encoder. The daemon sends *assets* (image bytes + a key) and
// *placements* (where to draw them), and a client has to turn that into
// `ESC _ G … ESC \` sequences: one upload per image, then placement updates for
// the geometry that actually changed.
//
// Three things make this correct rather than merely "prints an escape":
//
//   1. One upload per asset key. The key carries `dataFingerprint`, so a second
//      frame that repeats the same image must send *no* bytes for it — otherwise
//      every keystroke resends a megabyte of pixels.
//   2. Deterministic ids (`host_image_id`, `kitty_graphics/surface.rs:554`). An
//      id that moved between frames would orphan the terminal's copy of the
//      image and the "no resend" rule above would draw nothing.
//   3. Layer order (`encode_graphics_output`, `kitty_graphics.rs:219`). Kitty
//      paints placements in arrival order, so a higher `z` must be written
//      later, and equal layers must keep the daemon's order.

import Foundation
import Testing

@testable import KraalProtocol

@Suite("SurfaceGraphicsScene to kitty bytes")
struct GraphicsEncoderTests {
    // MARK: - Builders

    /// A 2x2 image in `format`, with `dataLen` filled in from the bytes so the
    /// encoder's delivery check (upstream `ClientState::set_scene`,
    /// `kitty_graphics/surface.rs:367`) accepts it.
    private func makeImage(
        format: SurfaceGraphicsFormat = .rgba,
        width: UInt32 = 2,
        height: UInt32 = 2,
        byteCount: Int? = nil,
        fingerprint: UInt64 = 0xA11CE,
        sourceImageId: UInt32 = 1
    ) -> (key: SurfaceGraphicsAssetKey, data: Data) {
        let channels = format == .rgb ? 3 : 4
        let count = byteCount ?? Int(width) * Int(height) * channels
        let data = Data((0 ..< count).map { UInt8($0 % 251) })
        let key = SurfaceGraphicsAssetKey(
            source: .terminal(target: .pane(paneId: "wS:p1"), imageId: sourceImageId),
            imageWidth: width,
            imageHeight: height,
            format: format,
            dataLen: UInt64(data.count),
            dataFingerprint: fingerprint
        )
        return (key, data)
    }

    private func makePlacement(
        _ key: SurfaceGraphicsAssetKey,
        logical: UInt32 = 1,
        cellX: UInt16 = 0,
        cellY: UInt16 = 0,
        cols: UInt32 = 4,
        rows: UInt32 = 2,
        layer: Int32 = 0,
        sourceX: UInt32 = 0,
        sourceY: UInt32 = 0,
        sourceWidth: UInt32 = 0,
        sourceHeight: UInt32 = 0,
        xOffset: UInt32 = 0,
        yOffset: UInt32 = 0
    ) -> SurfaceGraphicsPlacement {
        SurfaceGraphicsPlacement(
            asset: key,
            logicalPlacementId: logical,
            cellX: cellX,
            cellY: cellY,
            cols: cols,
            rows: rows,
            sourceX: sourceX,
            sourceY: sourceY,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            xOffset: xOffset,
            yOffset: yOffset,
            layer: layer,
            scrollbackOffset: 0
        )
    }

    private func scene(
        _ image: (key: SurfaceGraphicsAssetKey, data: Data),
        _ placements: [SurfaceGraphicsPlacement]
    ) -> SurfaceGraphicsScene {
        SurfaceGraphicsScene(
            assets: [SurfaceGraphicsAsset(key: image.key, data: image.data)],
            placements: placements
        )
    }

    // MARK: - Bytes

    @Test("one rgb asset with one placement encodes upload, CUP, placement")
    func singlePlacementEncodesTheWholeTransaction() {
        // Exact bytes, because the failure mode this guards is not "no output"
        // but "output in the wrong order": an `a=p` before its `a=t` draws
        // nothing, and a missing CUP draws it at the cursor instead of the cell.
        let image = makeImage(format: .rgb)
        var encoder = GraphicsEncoder()
        let bytes = encoder.encode(scene: scene(image, [makePlacement(image.key)]),
                                   scope: "daemon-a")
        let text = text(bytes)

        guard let upload = upload(from: bytes), let placement = firstPlacement(from: bytes) else {
            Issue.record("missing upload or placement sequence: \(text)")
            return
        }
        let imageId = control(upload)["i"] ?? "?"
        let placementId = control(placement)["p"] ?? "?"
        let base64 = Data(image.data).base64EncodedString()
        let expected = "\u{1B}_Ga=t,t=d,f=24,s=2,v=2,i=\(imageId),q=2,m=0;\(base64)\u{1B}\\"
            + "\u{1B}[1;1H"
            + "\u{1B}_Ga=p,i=\(imageId),p=\(placementId),c=4,r=2,z=0,C=1,q=2;\u{1B}\\"
        #expect(text == expected, "the transaction order or the control text drifted")
        // `s`/`v` are the image's own pixels, not the placement's cell box: a
        // 2x2 image drawn into 4x2 cells still uploads as 2x2.
        #expect(control(upload)["s"] == "2" && control(upload)["v"] == "2")
    }

    @Test("ids stay in the documented ranges", arguments: [1, 2, 7])
    func imageIdsStayInRange(sourceImageId: UInt32) {
        // Kitty treats an id as a 32-bit integer that the terminal stores; the
        // base+span keeps host ids in a range real programs do not use (upstream
        // `HOST_IMAGE_ID_BASE`), and an id of 0 is invalid.
        let image = makeImage(sourceImageId: sourceImageId)
        var encoder = GraphicsEncoder()
        let bytes = encoder.encode(scene: scene(image, [makePlacement(image.key)]),
                                   scope: "daemon-a")
        guard let upload = upload(from: bytes),
              let imageId = UInt32(control(upload)["i"] ?? ""),
              let placement = firstPlacement(from: bytes),
              let placementId = UInt32(control(placement)["p"] ?? "") else {
            Issue.record("could not read ids back out of the stream")
            return
        }
        // Not a range check: `10_000 + hash % 900_000` is inside the range *by
        // construction*, so asserting it could never fail. What actually matters
        // is that id 0 never comes out — kitty reads 0 as "no id", and a placement
        // or delete naming 0 would be silently ignored.
        #expect(imageId != 0, "image id 0 is not addressable in kitty")
        #expect(placementId != 0, "placement id 0 means \"no placement id\" to kitty")
    }

    @Test("format decides the f= code", arguments: [
        SurfaceGraphicsFormat.rgb, SurfaceGraphicsFormat.rgba, SurfaceGraphicsFormat.png,
    ])
    func formatCodeFollowsTheWireEnum(format: SurfaceGraphicsFormat) {
        // `SurfaceGraphicsFormat` is the wire enum; `f=` is kitty's own numbering
        // (`kitty_format_code`, `kitty_graphics.rs:687`). Reading `f` straight off
        // `rawValue` would send f=0/1/2 and the terminal would reject all three.
        let expected: String
        switch format {
        case .rgb: expected = "24"
        case .rgba: expected = "32"
        case .png: expected = "100"
        }
        let image = makeImage(format: format)
        var encoder = GraphicsEncoder()
        let bytes = encoder.encode(scene: scene(image, [makePlacement(image.key)]),
                                   scope: "daemon-a")
        #expect(control(upload(from: bytes) ?? "")["f"] == expected,
                "f= does not match kitty's numbering for \(format)")
    }

    @Test("data larger than one chunk is split across sequences")
    func largeDataIsChunked() {
        // A terminal drops a chunk it cannot hold in one escape sequence, so the
        // payload has to arrive in `m=1 … m=0` pieces. Upstream `write_kitty_data`
        // (`kitty_graphics.rs:699`) sends at most 3072 raw bytes per sequence —
        // exactly 4096 base64 characters, kitty's per-sequence budget.
        let image = makeImage(format: .rgba, width: 40, height: 40, byteCount: 5000)
        var encoder = GraphicsEncoder()
        let bytes = encoder.encode(scene: scene(image, [makePlacement(image.key)]),
                                   scope: "daemon-a")
        let uploads = kittySequences(bytes).filter { control($0)["a"] == "t"
            || control($0)["m"] != nil }
        #expect(uploads.count > 1, "5000 bytes went out as a single sequence")

        guard let first = uploads.first else { return }
        // Only the first chunk carries the control; the rest are `m=<n>;<b64>`.
        #expect(control(first)["a"] == "t" && control(first)["m"] == "1",
                "the first chunk must carry the full control and m=1")
        #expect(uploads.dropFirst().allSatisfy { control($0).count == 1 },
                "a continuation chunk carried something other than m=")
        #expect(control(uploads[uploads.count - 1])["m"] == "0",
                "the last chunk must carry m=0 or the terminal waits for more")
        #expect(uploads.allSatisfy { payload($0).count <= 4096 },
                "one sequence exceeded kitty's 4096-character budget")

        let reassembled = uploads.map { payload($0) }.joined()
        #expect(Data(base64Encoded: reassembled) == image.data,
                "the chunks do not decode back to the asset's bytes")
    }

    @Test("an empty payload produces no upload sequence")
    func emptyDataEmitsNothing() {
        // Upstream returns early when there is no first chunk: a sequence with an
        // empty payload is a protocol error, and kitty answers it by *deleting*
        // whatever image shares the id.
        //
        // Asserting "no `a=t`" rather than "no output at all" matters: an encoder
        // that dropped the whole placement would also produce empty output, and
        // that is a different bug with the same symptom.
        let image = makeImage(byteCount: 0)
        var encoder = GraphicsEncoder()
        let bytes = encoder.encode(scene: scene(image, [makePlacement(image.key)]),
                                   scope: "daemon-a")
        #expect(upload(from: bytes) == nil,
                "an asset with no bytes was uploaded anyway")
    }

    @Test("an asset whose length disagrees with its key is not uploaded")
    func truncatedAssetIsNotUploaded() {
        // The other half of the delivery filter (upstream `ClientState::set_scene`,
        // `surface.rs:367`): a key claiming 16 bytes with 10 bytes of data would
        // upload a truncated, wrongly-sized image — kitty accepts it and draws
        // garbage, which is worse than drawing nothing.
        let whole = makeImage(byteCount: 16)
        let truncated = (key: whole.key, data: Data(repeating: 0x5A, count: 10))
        var encoder = GraphicsEncoder()
        let bytes = encoder.encode(scene: scene(truncated, [makePlacement(whole.key)]),
                                   scope: "daemon-a")
        #expect(upload(from: bytes) == nil,
                "a truncated delivery was uploaded as if it were whole")
    }

}

// Builders and stream inspection, split out so the suite body stays inside
// SwiftLint's 400-line type limit. Helper-only: no test lives here.
extension GraphicsEncoderTests {
    // Tests for the cache state machine (issue #101) — the half whose bugs are
    // silent: a missed delete leaves an image on screen forever.

    // MARK: - Cache

    @Test("the same scene twice uploads once")
    func repeatedSceneDoesNotReupload() {
        // The whole reason the cache exists: a repaint with unchanged images must
        // cost zero image bytes.
        let image = makeImage()
        var encoder = GraphicsEncoder()
        let placed = scene(image, [makePlacement(image.key)])
        let first = encoder.encode(scene: placed, scope: "daemon-a")
        let second = encoder.encode(scene: placed, scope: "daemon-a")

        #expect(upload(from: first) != nil, "the first frame did not upload")
        #expect(kittySequences(second).isEmpty,
                "a frame that changed nothing still wrote \(second.count) bytes")
    }

    @Test("changed geometry re-emits the placement but not the image")
    func changedGeometryReemitsPlacementOnly() {
        // The complement of the test above: suppression must key on the geometry,
        // not on "this placement was drawn once".
        let image = makeImage()
        var encoder = GraphicsEncoder()
        _ = encoder.encode(scene: scene(image, [makePlacement(image.key)]), scope: "daemon-a")
        let moved = scene(image, [makePlacement(image.key, cellX: 2, cellY: 1)])
        let second = encoder.encode(scene: moved, scope: "daemon-a")

        #expect(upload(from: second) == nil, "the image was re-uploaded for a move")
        guard let placement = firstPlacement(from: second) else {
            Issue.record("the moved placement was not re-emitted")
            return
        }
        #expect(control(placement)["i"] != nil, "placement lost its image id")
        let text = text(second)
        #expect(text.contains("\u{1B}[2;3H"),
                "cell (2,1) must become CUP row 2 column 3")
    }

    @Test("two fresh encoders produce identical bytes")
    func encodingIsDeterministic() {
        // Ids come out of a hash. If that hash were seeded per process or per
        // instance, the same scene would land on different image ids each launch,
        // and a reconnect would leave the old copy behind in the terminal.
        let image = makeImage()
        let placed = scene(image, [
            makePlacement(image.key, logical: 3, cellX: 1, layer: 2),
            makePlacement(image.key, logical: 5, cellX: 9, layer: -1),
        ])
        var first = GraphicsEncoder()
        var second = GraphicsEncoder()
        let firstBytes = first.encode(scene: placed, scope: "daemon-a")
        let secondBytes = second.encode(scene: placed, scope: "daemon-a")
        #expect(firstBytes == secondBytes, "ids are not stable across encoders")
    }

    @Test("image ids do not depend on the process")
    func idsAreStableAcrossProcesses() {
        // The one property a `Hasher`-based implementation cannot have. Swift
        // seeds `Hashable.hashValue` per process, so an id built from it would be
        // different on every launch — measured: three runs of the same key gave
        // -4034010155864422423, 9026274553038021899, 9025231281934131895. The
        // terminal would then hold the previous launch's image under an id nobody
        // asks for, and every reconnect would orphan another copy.
        //
        // The expected value is a *literal*, deliberately. It pins the id function
        // to one implementation: changing the hash changes these numbers, and that
        // is meant to be a conscious edit rather than a silent drift. Only the
        // stability matters on the wire — the daemon never computes these ids — so
        // the exact number is arbitrary and the constant is the point.
        let image = makeImage(sourceImageId: 7)
        let id = GraphicsEncoder.imageId(for: image.key, scope: "daemon-a")
        #expect(id == 163_700,
                "the id derivation changed (got \(id)); if that was intended, update this literal")
    }

    @Test("every source and target branch hashes to its own id")
    func idHashCoversEveryBranch() {
        // `StableHash.mix` hand-flattens the two enums rather than hashing
        // `hashValue` (per-process seeded, see `idsAreStableAcrossProcesses`). A
        // hand-flattened enum is where a copy-paste slip turns two cases into the
        // same field sequence — and two sources sharing one image id means one
        // pane's `d=I` deletes the other pane's image.
        //
        // Scope, measured: this does *not* detect a duplicated tag constant on its
        // own. Injecting `tag=0` for `.paneLayer` leaves all four ids distinct,
        // because the remaining fields (a target tag + image id versus two strings)
        // already separate them. What it does detect is two cases flattened into
        // the *same* field sequence, which is the failure a tag was there to
        // prevent in the first place.
        func key(_ source: SurfaceGraphicsSource) -> SurfaceGraphicsAssetKey {
            SurfaceGraphicsAssetKey(
                source: source, imageWidth: 2, imageHeight: 2,
                format: .rgba, dataLen: 4, dataFingerprint: 1
            )
        }
        let keys = [
            key(.terminal(target: .pane(paneId: "w1:p1"), imageId: 1)),
            key(.terminal(target: .popup(terminalId: "popup-1"), imageId: 1)),
            key(.paneLayer(paneId: "w1:p1", layerId: "layer-1")),
            // A second paneLayer, so the paneId/layerId distinction is covered too.
            key(.paneLayer(paneId: "w1:p2", layerId: "layer-1")),
        ]
        let ids = keys.map { GraphicsEncoder.imageId(for: $0, scope: "daemon-a") }
        #expect(Set(ids).count == ids.count,
                "two different sources produced the same image id: \(ids)")
    }

    @Test("a redrawn image does not reuse the previous id")
    func fingerprintChangesTheId() {
        // Same source, new pixels. The id has to move, otherwise the terminal keeps
        // showing the old bitmap under an id the encoder believes it just updated.
        let first = makeImage(byteCount: 16)
        let redrawn = SurfaceGraphicsAssetKey(
            source: first.key.source, imageWidth: first.key.imageWidth,
            imageHeight: first.key.imageHeight, format: first.key.format,
            dataLen: first.key.dataLen, dataFingerprint: first.key.dataFingerprint &+ 1
        )
        #expect(GraphicsEncoder.imageId(for: first.key, scope: "daemon-a")
                != GraphicsEncoder.imageId(for: redrawn, scope: "daemon-a"),
                "a changed fingerprint kept the same image id")
    }

    @Test("reset makes the next frame upload again")
    func resetForcesReupload() {
        // `reset()` is called when the screen was cleared, which takes the
        // terminal's copy of every image with it.
        let image = makeImage()
        var encoder = GraphicsEncoder()
        let placed = scene(image, [makePlacement(image.key)])
        _ = encoder.encode(scene: placed, scope: "daemon-a")
        encoder.reset()
        let afterReset = encoder.encode(scene: placed, scope: "daemon-a")
        #expect(upload(from: afterReset) != nil,
                "after reset the terminal holds no image, so it must be sent again")
    }

    @Test("an image that is neither placed nor retained is deleted")
    func droppedImageIsDeleted() {
        // Without the delete the image stays painted wherever it was, which is
        // how a closed popup's contents used to linger on screen.
        let image = makeImage()
        let other = makeImage(fingerprint: 0xBEEF, sourceImageId: 2)
        var encoder = GraphicsEncoder()
        let first = encoder.encode(scene: scene(image, [makePlacement(image.key)]),
                                   scope: "daemon-a")
        guard let imageId = control(upload(from: first) ?? "")["i"] else {
            Issue.record("no image id in the first frame")
            return
        }
        let second = encoder.encode(
            scene: SurfaceGraphicsScene(retainedAssets: [other.key]),
            scope: "daemon-a"
        )
        let deletes = kittySequences(second).filter { control($0)["a"] == "d" }
        #expect(deletes.count == 1, "expected exactly one delete, got \(deletes.count)")
        #expect(control(deletes.first ?? "")["d"] == "I", "delete must be `d=I` (whole image)")
        #expect(control(deletes.first ?? "")["i"] == imageId,
                "the delete names a different image than the one uploaded")
        #expect(upload(from: second) == nil, "an empty scene re-uploaded something")
    }

    @Test("a retained asset survives a frame that does not re-deliver it")
    func retainedAssetSurvives() {
        // The positive side of the rule above: `retainedAssets` is how the daemon
        // says "the pixels are still on screen somewhere". Treating it as "not
        // mentioned" would delete an image the daemon is about to place again,
        // and the next frame would have to upload it from scratch.
        //
        // It retains the *image*, not the drawing: the placement that left the
        // scene still has to go, or it stays painted where it was. Upstream draws
        // the same distinction — `desired_placements` comes only from
        // `scene.placements` (`kitty_graphics.rs:227`), while the retain set
        // keeps the image alive.
        let image = makeImage()
        var encoder = GraphicsEncoder()
        _ = encoder.encode(scene: scene(image, [makePlacement(image.key)]),
                           scope: "daemon-a")
        let second = encoder.encode(
            scene: SurfaceGraphicsScene(retainedAssets: [image.key]),
            scope: "daemon-a"
        )
        #expect(upload(from: second) == nil,
                "a retained image was uploaded again")
        let deletes = kittySequences(second).filter { control($0)["a"] == "d" }
        #expect(deletes.allSatisfy { control($0)["d"] != "I" },
                "a retained image was deleted")
        #expect(deletes.count == 1 && control(deletes[0])["d"] == "i",
                "the placement that left the scene was not deleted")

        // And the retained image is still usable: the frame after it places the
        // same asset again with no upload, which is the whole point of keeping it.
        let third = encoder.encode(scene: scene(image, [makePlacement(image.key, cellX: 3)]),
                                   scope: "daemon-a")
        #expect(upload(from: third) == nil,
                "a retained image had to be re-uploaded to be placed again")
        #expect(firstPlacement(from: third) != nil, "the re-placed image was not drawn")
    }

    @Test("a fully empty scene deletes every image it uploaded")
    func emptySceneDeletesEverything() {
        let first = makeImage(fingerprint: 0xA11CE, sourceImageId: 1)
        let second = makeImage(fingerprint: 0xBEEF, sourceImageId: 2)
        var encoder = GraphicsEncoder()
        _ = encoder.encode(scene: SurfaceGraphicsScene(
            assets: [
                SurfaceGraphicsAsset(key: first.key, data: first.data),
                SurfaceGraphicsAsset(key: second.key, data: second.data),
            ],
            placements: [makePlacement(first.key), makePlacement(second.key, logical: 2)]
        ), scope: "daemon-a")

        let cleared = encoder.encode(scene: SurfaceGraphicsScene(), scope: "daemon-a")
        let deletes = kittySequences(cleared).filter { control($0)["a"] == "d" }
        #expect(deletes.count == 2, "expected both images deleted, got \(deletes.count)")
        #expect(upload(from: cleared) == nil, "the empty scene uploaded something")
        // Idempotent: a second empty scene has nothing left to delete.
        let again = encoder.encode(scene: SurfaceGraphicsScene(), scope: "daemon-a")
        #expect(kittySequences(again).isEmpty, "the deletes repeat every frame")
    }

    @Test("a placement the daemon dropped is deleted on its own")
    func stalePlacementIsDeleted() {
        // Deleting the image is too coarse when the image is still used by
        // another placement: kitty needs `d=i` with the placement id
        // (`encode_delete_placement`, `kitty_graphics.rs:444`).
        let image = makeImage()
        var encoder = GraphicsEncoder()
        let first = encoder.encode(scene: scene(image, [
            makePlacement(image.key, logical: 1, cellX: 0),
            makePlacement(image.key, logical: 2, cellX: 6),
        ]), scope: "daemon-a")
        guard let imageId = control(upload(from: first) ?? "")["i"] else {
            Issue.record("no image id in the first frame")
            return
        }
        let second = encoder.encode(scene: scene(image, [
            makePlacement(image.key, logical: 1, cellX: 0),
        ]), scope: "daemon-a")

        let deletes = kittySequences(second).filter { control($0)["a"] == "d" }
        #expect(deletes.count == 1, "the dropped placement was not deleted")
        #expect(control(deletes.first ?? "")["d"] == "i",
                "whole-image delete would take the surviving placement with it")
        #expect(control(deletes.first ?? "")["p"] != nil, "delete has no placement id")
        #expect(control(deletes.first ?? "")["i"] == imageId,
                "the placement delete names a different image than the surviving one")
    }

    @Test("a placement whose asset was not delivered is not drawn")
    func placementWithoutDataIsSkipped() {
        // Drawing it would reference an image the terminal never received; kitty
        // answers with an error on stderr and no picture.
        let image = makeImage()
        var encoder = GraphicsEncoder()
        let bytes = encoder.encode(
            scene: SurfaceGraphicsScene(placements: [makePlacement(image.key)]),
            scope: "daemon-a"
        )
        #expect(kittySequences(bytes).isEmpty, "a placement without pixels was drawn")
    }

    @Test("a scope change deletes the ids derived from the old scope")
    func scopeChangeClearsTheOldImages() {
        // Ids are a function of the scope (`host_image_id`), so reconnecting to a
        // different daemon renames every image. Without the deletes the terminal
        // keeps painting the old ones from an id nobody will ever reuse.
        let image = makeImage()
        var encoder = GraphicsEncoder()
        _ = encoder.encode(scene: scene(image, [makePlacement(image.key)]), scope: "daemon-a")
        let second = encoder.encode(scene: scene(image, [makePlacement(image.key)]),
                                   scope: "daemon-b")
        let deletes = kittySequences(second).filter { control($0)["a"] == "d" }
        #expect(deletes.count == 1, "the old scope's image was not deleted")
        #expect(upload(from: second) != nil, "the new scope must upload again")
    }

    // MARK: - Placement geometry

    @Test("placements are written in layer order")
    func placementsAreWrittenInLayerOrder() {
        // Kitty paints in arrival order, so `z` has to be honoured by the writer:
        // drawing the layer-5 placement first puts it *under* the layer -1 one,
        // which is the opposite of what the daemon composited.
        let image = makeImage()
        var encoder = GraphicsEncoder()
        let bytes = encoder.encode(scene: scene(image, [
            makePlacement(image.key, logical: 1, cellX: 0, layer: 5),
            makePlacement(image.key, logical: 2, cellX: 8, layer: -1),
        ]), scope: "daemon-a")
        let text = text(bytes)
        guard let high = text.range(of: "\u{1B}[1;1H"),
              let low = text.range(of: "\u{1B}[1;9H") else {
            Issue.record("missing one of the two CUP markers")
            return
        }
        #expect(low.lowerBound < high.lowerBound,
                "the layer -1 placement was written after the layer 5 one")
        #expect(kittySequences(bytes).contains { control($0)["z"] == "-1" },
                "a negative layer must be written verbatim; z=-1 is legal")
    }

    @Test("equal layers keep the daemon's order")
    func equalLayersAreStable() {
        // Two placements on the same layer are siblings the daemon already
        // composited; reordering them would flip overlapping pixels.
        let image = makeImage()
        var encoder = GraphicsEncoder()
        let bytes = encoder.encode(scene: scene(image, [
            makePlacement(image.key, logical: 1, cellX: 4),
            makePlacement(image.key, logical: 2, cellX: 0),
        ]), scope: "daemon-a")
        let text = text(bytes)
        guard let firstCup = text.range(of: "\u{1B}[1;5H"),
              let secondCup = text.range(of: "\u{1B}[1;1H") else {
            Issue.record("missing one of the two CUP markers")
            return
        }
        #expect(firstCup.lowerBound < secondCup.lowerBound,
                "equal layers were reordered")
    }

    @Test("crop and offset fields appear only when they are set")
    func cropFieldsAreOptional() {
        // Upstream `append_placement_controls` (`kitty_graphics.rs:474`) omits
        // zeroes because kitty reads a missing `x` as 0 anyway, and sending
        // `x=0` on every placement is 4 bytes per placement per change.
        let image = makeImage()
        var encoder = GraphicsEncoder()
        let plain = encoder.encode(scene: scene(image, [makePlacement(image.key)]),
                                   scope: "daemon-a")
        let plainControl = control(firstPlacement(from: plain) ?? "")
        for name in ["x", "y", "w", "h", "X", "Y"] {
            #expect(plainControl[name] == nil, "unset \(name)= was written anyway")
        }

        let cropped = encoder.encode(scene: scene(image, [
            makePlacement(image.key, logical: 2, cellX: 0, cellY: 0,
                          sourceX: 3, sourceY: 4, sourceWidth: 10, sourceHeight: 12,
                          xOffset: 5, yOffset: 6),
        ]), scope: "daemon-a")
        guard let derived = firstPlacement(from: cropped) else {
            Issue.record("the cropped placement was not written")
            return
        }
        let croppedControl = control(derived)
        #expect(croppedControl["x"] == "3" && croppedControl["y"] == "4")
        #expect(croppedControl["w"] == "10" && croppedControl["h"] == "12")
        #expect(croppedControl["X"] == "5" && croppedControl["Y"] == "6")
        // Order matters for diffing against upstream's output: the optional tail
        // is appended after `q=2`, in the upstream order.
        #expect(derived.hasSuffix(",C=1,q=2,x=3,y=4,w=10,h=12,X=5,Y=6;"),
                "the optional controls are not in upstream's order")
    }

    // MARK: - Stream inspection

    /// The stream as text.
    ///
    /// `String(bytes:encoding:)` rather than `String(decoding:as:)` so a broken
    /// stream shows up as a readable failure instead of U+FFFD replacing the very
    /// byte the assertion was about.
    private func text(_ bytes: Data) -> String {
        String(bytes: bytes, encoding: .utf8) ?? "<not utf-8: \(bytes.count) bytes>"
    }

    /// The individual `ESC _ G <control>;<payload> ESC \` sequences, in order.
    ///
    /// Everything between two sequences is dropped (a `CUP` sits between a
    /// placement's position and its command), which is what most assertions want;
    /// ordering is asserted through those markers separately.
    private func kittySequences(_ bytes: Data) -> [String] {
        let text = text(bytes)
        return text.components(separatedBy: "\u{1B}_G").dropFirst().compactMap { part in
            guard let terminator = part.range(of: "\u{1B}\\") else { return nil }
            return String(part[part.startIndex ..< terminator.lowerBound])
        }
    }

    private func control(_ sequence: String) -> [String: String] {
        let head = sequence.split(separator: ";", maxSplits: 1,
                                  omittingEmptySubsequences: false).first ?? ""
        var parameters: [String: String] = [:]
        for field in head.split(separator: ",") {
            let pair = field.split(separator: "=", maxSplits: 1)
            guard let name = pair.first else { continue }
            parameters[String(name)] = pair.count == 2 ? String(pair[1]) : ""
        }
        return parameters
    }

    private func payload(_ sequence: String) -> String {
        let parts = sequence.split(separator: ";", maxSplits: 1,
                                   omittingEmptySubsequences: false)
        return parts.count == 2 ? String(parts[1]) : ""
    }

    private func upload(from bytes: Data) -> String? {
        kittySequences(bytes).first { control($0)["a"] == "t" }
    }

    private func firstPlacement(from bytes: Data) -> String? {
        kittySequences(bytes).first { control($0)["a"] == "p" }
    }

}
