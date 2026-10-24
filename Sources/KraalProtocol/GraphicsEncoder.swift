// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// `SurfaceGraphicsScene` → kitty graphics bytes (issue #101, parent #37).
//
// The daemon composites graphics itself: it sends *assets* (image bytes behind a
// `SurfaceGraphicsAssetKey`) and *placements* (cell geometry, crop, layer). A
// client has to turn that into `ESC _ G <control>;<base64> ESC \` sequences plus
// a `CUP` per placement. This type is the Rust side's counterpart:
//
//   upstream `ClientState::encode_output`   (`kitty_graphics/surface.rs:480`)
//   upstream `encode_graphics_output`       (`kitty_graphics.rs:219`)
//   upstream `encode_placement_update`      (`kitty_graphics.rs:129`)
//   upstream `write_kitty_data`             (`kitty_graphics.rs:699`)
//
// Why keep a cache instead of encoding the scene fresh every frame:
//
//   * An upload is the expensive part (megabytes of base64 through the pty). The
//     key already carries `dataLen`/`dataFingerprint`, so a frame that repeats an
//     image must cost zero upload bytes — otherwise every keystroke resends it.
//   * A placement that did not move must not be re-emitted either: kitty places
//     at the *current cursor*, so a redundant placement also needs a redundant
//     CUP, and a flapping z-order is visible.
//   * What is no longer in the scene has to be *deleted*. Kitty keeps an image
//     until told otherwise, so a closed popup's image would otherwise stay
//     painted on top of the cells forever.
//
// **Why a `struct` and not a `class`.** The state this type owns (which ids the
// terminal currently holds) is per-view: it mirrors what one terminal — one
// `SurfaceANSIRenderer` — has been sent. A struct makes that ownership explicit,
// matches `SurfaceANSIRenderer`'s shape (also a struct with mutating methods), and
// makes a copy a *correct* second view rather than two views silently sharing a
// cache and deleting each other's images. There is no background work and no
// reference-counted sharing, so a class would buy only aliasing bugs.

import Foundation

public struct GraphicsEncoder: Sendable {
    /// Raw image bytes per escape sequence.
    ///
    /// Kitty caps the payload of one sequence at 4096 *characters*, and base64
    /// grows by 4/3 — so 3072 raw bytes is exactly the 4096-character budget
    /// (measured: `Data(count: 3072).base64EncodedData().count == 4096`; 4096 raw
    /// bytes would be 5464 characters per sequence and a strict terminal drops
    /// the chunk). Upstream's `KITTY_CHUNK_BYTES` (`kitty_graphics.rs:22`) is
    /// 3072 for the same reason.
    static let chunkBytes = 3072

    /// Kitty image ids live above the range real programs use, and `0` is not a
    /// valid id at all (upstream `HOST_IMAGE_ID_BASE`, `kitty_graphics.rs:23`).
    static let imageIdBase: UInt32 = 10_000
    /// 10_000 + 900_000 = 909_999 stays well inside `u32`; the span is upstream's.
    static let imageIdSpan: UInt32 = 900_000
    /// Placement ids start at 1; 0 means "no placement id" to kitty.
    static let placementIdBase: UInt32 = 1

    /// Image ids the terminal is currently holding, with the pixels they hold.
    private var images: [UInt32: GraphicsImageSignature] = [:]
    /// Placements the terminal is currently showing, with their geometry.
    private var placements: [GraphicsPlacementKey: GraphicsPlacementSignature] = [:]
    /// The scope the cached ids were derived from. `nil` until the first frame.
    ///
    /// Ids are a function of the scope (`host_image_id`, `surface.rs:554`), so a
    /// scope change renames every image. Without noticing that, the terminal
    /// would keep painting images from an id namespace nobody will reuse.
    private var activeScope: String?

    public init() {}

    /// Forgets everything the terminal was told.
    ///
    /// Call this when the screen was cleared: the images went with it, so the
    /// next frame has to upload them again. No deletes are emitted — deleting ids
    /// the terminal already dropped is pure byte noise (and `q=2` would suppress
    /// any answer anyway, so the round trip buys nothing).
    ///
    /// Call it together with `SurfaceANSIRenderer.reset()`: that is what makes the
    /// next frame emit `2J`, and the terminal's `ED2` is what reclaimed the images
    /// this type is now forgetting. One without the other leaves the image
    /// permanently erased (`GraphicsSeamTests.resetPairsAcrossTheSeam`).
    public mutating func reset() {
        images.removeAll()
        placements.removeAll()
        activeScope = nil
    }

    /// Encodes `scene` into the kitty bytes that bring a terminal from the last
    /// encoded scene to this one, and records what the terminal now holds.
    ///
    /// `scope` isolates this view's ids from every other consumer of the same
    /// terminal (upstream `ClientState::scope`): two panes showing the same image
    /// must not collide on one id, or one pane's delete takes the other's image.
    public mutating func encode(scene: SurfaceGraphicsScene, scope: String) -> Data {
        var output = Data()
        if activeScope != scope {
            // Emit the deletes for the namespace we are leaving *before*
            // adopting the new one; the ids in the cache are old-scope ids.
            for imageId in images.keys.sorted() {
                Self.appendDeleteImage(imageId, to: &output)
            }
            reset()
            activeScope = scope
        }

        // Only assets the daemon actually delivered count. Upstream
        // `ClientState::set_scene` (`surface.rs:367`) keeps an asset only when its
        // byte count matches the key — a truncated delivery would otherwise be
        // uploaded as a valid-looking but wrong image.
        var delivered: [SurfaceGraphicsAssetKey: Data] = [:]
        for asset in scene.assets
            where !asset.data.isEmpty && UInt64(asset.data.count) == asset.key.dataLen {
            delivered[asset.key] = asset.data
        }

        let ordered = orderedPlacements(scene.placements, delivered: delivered, scope: scope)
        let desiredPlacements = Set(ordered.map(\.key))
        var desiredImages = Set(ordered.map(\.imageId))
        for key in scene.retainedAssets {
            desiredImages.insert(Self.imageId(for: key, scope: scope))
        }

        // 1. Images nobody wants any more. Whole-image deletes come first because
        //    deleting an image also removes its placements from the terminal —
        //    emitting `d=i` for each of them afterwards would name a placement
        //    that no longer exists, and kitty answers that with an error.
        for imageId in images.keys.sorted() where !desiredImages.contains(imageId) {
            Self.appendDeleteImage(imageId, to: &output)
            images.removeValue(forKey: imageId)
            placements = placements.filter { $0.key.imageId != imageId }
        }

        // 2. Placements of surviving images that the daemon dropped. Sorted by
        //    (image, placement) so the byte stream is deterministic — a hash
        //    order would make two identical scenes encode differently.
        let stalePlacements = placements.keys
            .filter { !desiredPlacements.contains($0) }
            .sorted { ($0.imageId, $0.placementId) < ($1.imageId, $1.placementId) }
        for key in stalePlacements {
            Self.appendDeletePlacement(key, to: &output)
            placements.removeValue(forKey: key)
        }

        // 3. The visible placements, in layer order.
        for item in ordered {
            let imageCurrent = images[item.imageId] == item.imageSignature
            let placementCurrent = placements[item.key] == item.placementSignature
            if imageCurrent && placementCurrent { continue }

            if !imageCurrent {
                guard let data = delivered[item.asset] else { continue }
                if images[item.imageId] != nil {
                    // Same id, different pixels — a hash collision, or the same
                    // source redrawn at another size. The terminal would keep
                    // showing the old bitmap, so `d=I` first. That delete also
                    // drops every placement of the image, including ones already
                    // written this frame (they are now gone from the terminal),
                    // so those are forgotten here and re-emitted by the next frame
                    // — a one-frame blink, limited to genuine collisions.
                    Self.appendDeleteImage(item.imageId, to: &output)
                    placements = placements.filter { $0.key.imageId != item.imageId }
                }
                Self.appendUpload(item, data: data, to: &output)
                images[item.imageId] = item.imageSignature
            }

            Self.appendDisplayPlacement(item, to: &output)
            placements[item.key] = item.placementSignature
        }
        return output
    }

    /// Placements that can actually be drawn, stable-sorted by layer.
    ///
    /// A placement with no delivered pixels and no image already in the terminal
    /// is skipped: `a=p` for an image the terminal never received draws nothing
    /// and prints an error to the pane (`encode_placement_update` bails on empty
    /// data for the same reason).
    private func orderedPlacements(
        _ placements: [SurfaceGraphicsPlacement],
        delivered: [SurfaceGraphicsAssetKey: Data],
        scope: String
    ) -> [GraphicsPreparedPlacement] {
        var prepared: [GraphicsPreparedPlacement] = []
        prepared.reserveCapacity(placements.count)
        for placement in placements {
            let imageId = Self.imageId(for: placement.asset, scope: scope)
            let signature = GraphicsImageSignature(key: placement.asset)
            let known = images[imageId] == signature
            guard known || delivered[placement.asset] != nil else { continue }
            prepared.append(GraphicsPreparedPlacement(
                placement: placement,
                asset: placement.asset,
                imageId: imageId,
                placementId: Self.placementId(
                    for: placement.asset,
                    logical: placement.logicalPlacementId,
                    scope: scope
                ),
                imageSignature: signature
            ))
        }
        // Stable: equal layers keep the daemon's order, because the daemon already
        // composited them and swapping siblings flips overlapping pixels. Swift's
        // `sort` is not documented as stable, so the index is the tie-breaker.
        return prepared.enumerated()
            .sorted { left, right in
                left.element.placement.layer == right.element.placement.layer
                    ? left.offset < right.offset
                    : left.element.placement.layer < right.element.placement.layer
            }
            .map(\.element)
    }

    // MARK: - Kitty format mapping

    /// `SurfaceGraphicsFormat` is the wire enum; `f=` is kitty's own numbering
    /// (upstream `kitty_format_code`, `kitty_graphics.rs:687`). They do not agree
    /// — reading `f` off `rawValue` would send f=0/1/2 and be rejected.
    static func formatCode(_ format: SurfaceGraphicsFormat) -> UInt32 {
        switch format {
        case .rgb: return 24
        case .rgba: return 32
        case .png: return 100
        }
    }
}

// MARK: - Id derivation

extension GraphicsEncoder {
    /// Stable image id for an asset key inside a scope (`host_image_id`,
    /// `surface.rs:554`).
    ///
    /// Deterministic on purpose: the id is what lets a later frame say "that image
    /// is already there". A random or per-process-seeded id would orphan the
    /// terminal's copy every launch and the no-resend rule would draw nothing.
    static func imageId(for key: SurfaceGraphicsAssetKey, scope: String) -> UInt32 {
        var hash = StableHash()
        hash.mix(scope)
        hash.mix(key)
        return imageIdBase + UInt32(hash.value % UInt64(imageIdSpan))
    }

    /// Stable placement id for `(asset key, logical placement id)` inside a
    /// scope. Upstream `host_placement_id` (`kitty_graphics.rs:412`) hashes the
    /// source key plus the logical placement id the same way.
    static func placementId(
        for key: SurfaceGraphicsAssetKey,
        logical: UInt32,
        scope: String
    ) -> UInt32 {
        var hash = StableHash()
        hash.mix(scope)
        hash.mix(key)
        hash.mix(UInt64(logical))
        return placementIdBase + UInt32(hash.value % UInt64(imageIdSpan))
    }
}

// MARK: - Sequence writers

extension GraphicsEncoder {
    /// One `a=t` transaction, chunked into `m=1 … m=0` sequences
    /// (upstream `write_kitty_data`, `kitty_graphics.rs:699`).
    ///
    /// Empty data writes nothing: a sequence with an empty payload is a protocol
    /// error, and kitty answers it by deleting whatever image shares the id.
    private static func appendUpload(
        _ item: GraphicsPreparedPlacement,
        data: Data,
        to output: inout Data
    ) {
        let control = item.uploadControl
        var offset = data.startIndex
        var first = true
        while offset < data.endIndex {
            let stop = min(offset + chunkBytes, data.endIndex)
            let more = stop == data.endIndex ? 0 : 1
            if first {
                output.appendUTF8("\u{1B}_G\(control),m=\(more);")
                first = false
            } else {
                // Continuation chunks carry nothing but `m=`.
                output.appendUTF8("\u{1B}_Gm=\(more);")
            }
            output.append(data[offset ..< stop].base64EncodedData())
            output.appendUTF8("\u{1B}\\")
            offset = stop
        }
    }

    /// `CUP` then `a=p`. The cursor position *is* the placement anchor, which is
    /// why it cannot be folded into the control string
    /// (upstream `encode_display_placement`, `kitty_graphics.rs:458`).
    private static func appendDisplayPlacement(
        _ item: GraphicsPreparedPlacement,
        to output: inout Data
    ) {
        let placement = item.placement
        // Wire coordinates are 0-based, CUP is 1-based.
        output.appendUTF8("\u{1B}[\(Int(placement.cellY) + 1);\(Int(placement.cellX) + 1)H")

        var control = "a=p,i=\(item.imageId),p=\(item.placementId)"
            + ",c=\(placement.cols),r=\(placement.rows)"
            + ",z=\(placement.layer),C=1,q=2"
        // Optional tail, appended only when non-zero and in upstream's order
        // (`append_placement_controls`, `kitty_graphics.rs:474`): kitty reads a
        // missing `x` as 0, so sending `x=0` on every placement is pure overhead.
        if placement.sourceX > 0 { control += ",x=\(placement.sourceX)" }
        if placement.sourceY > 0 { control += ",y=\(placement.sourceY)" }
        if placement.sourceWidth > 0 { control += ",w=\(placement.sourceWidth)" }
        if placement.sourceHeight > 0 { control += ",h=\(placement.sourceHeight)" }
        if placement.xOffset > 0 { control += ",X=\(placement.xOffset)" }
        if placement.yOffset > 0 { control += ",Y=\(placement.yOffset)" }
        output.appendUTF8("\u{1B}_G\(control);\u{1B}\\")
    }

    /// `a=d,d=I` — drop the whole image and every placement of it
    /// (upstream `encode_delete_image`, `kitty_graphics.rs:440`).
    private static func appendDeleteImage(_ imageId: UInt32, to output: inout Data) {
        output.appendUTF8("\u{1B}_Ga=d,d=I,i=\(imageId),q=2;\u{1B}\\")
    }

    /// `a=d,d=i` — drop one placement, leave the image for its other placements
    /// (upstream `encode_delete_placement`, `kitty_graphics.rs:444`).
    private static func appendDeletePlacement(_ key: GraphicsPlacementKey, to output: inout Data) {
        output.appendUTF8("\u{1B}_Ga=d,d=i,i=\(key.imageId),p=\(key.placementId),q=2;\u{1B}\\")
    }
}

// MARK: - State types

/// What the terminal holds under one image id. Every field comes from the asset
/// key, so a redrawn image (new fingerprint) is not mistaken for the old one
/// (upstream `ImageSignature`, `kitty_graphics.rs:63`).
private struct GraphicsImageSignature: Equatable {
    var imageWidth: UInt32
    var imageHeight: UInt32
    var formatCode: UInt32
    var dataLen: UInt64
    var dataFingerprint: UInt64

    init(key: SurfaceGraphicsAssetKey) {
        imageWidth = key.imageWidth
        imageHeight = key.imageHeight
        formatCode = GraphicsEncoder.formatCode(key.format)
        dataLen = key.dataLen
        dataFingerprint = key.dataFingerprint
    }
}

/// `(image id, placement id)` — the pair kitty uses to address a placement
/// (upstream `HostGraphicsCache::placements`).
private struct GraphicsPlacementKey: Hashable {
    var imageId: UInt32
    var placementId: UInt32
}

/// Everything that changes where or how the image is drawn. Compared field by
/// field so a move re-emits the placement and nothing else
/// (upstream `PlacementSignature`, `kitty_graphics.rs:72`).
private struct GraphicsPlacementSignature: Equatable {
    var cellX: UInt16
    var cellY: UInt16
    var cols: UInt32
    var rows: UInt32
    var sourceX: UInt32
    var sourceY: UInt32
    var sourceWidth: UInt32
    var sourceHeight: UInt32
    var xOffset: UInt32
    var yOffset: UInt32
    var layer: Int32
    var scrollbackOffset: UInt32

    init(_ placement: SurfaceGraphicsPlacement) {
        cellX = placement.cellX
        cellY = placement.cellY
        cols = placement.cols
        rows = placement.rows
        sourceX = placement.sourceX
        sourceY = placement.sourceY
        sourceWidth = placement.sourceWidth
        sourceHeight = placement.sourceHeight
        xOffset = placement.xOffset
        yOffset = placement.yOffset
        layer = placement.layer
        scrollbackOffset = placement.scrollbackOffset
    }
}

/// A placement plus the ids and signature it was resolved to.
private struct GraphicsPreparedPlacement {
    var placement: SurfaceGraphicsPlacement
    var asset: SurfaceGraphicsAssetKey
    var imageId: UInt32
    var placementId: UInt32
    var imageSignature: GraphicsImageSignature

    var key: GraphicsPlacementKey {
        GraphicsPlacementKey(imageId: imageId, placementId: placementId)
    }

    var placementSignature: GraphicsPlacementSignature {
        GraphicsPlacementSignature(placement)
    }

    /// `a=t,t=d,f=…,s=…,v=…,i=…,q=2` (upstream `upload_control`,
    /// `kitty_graphics.rs:451`).
    ///
    /// `s`/`v` are the image's own pixel size, not the placement's cell box: a
    /// 2x2 image drawn into 4x2 cells still uploads as 2x2, and kitty scales it.
    var uploadControl: String {
        "a=t,t=d,f=\(imageSignature.formatCode)"
            + ",s=\(imageSignature.imageWidth),v=\(imageSignature.imageHeight)"
            + ",i=\(imageId),q=2"
    }
}

// MARK: - Deterministic hashing

/// FNV-1a, 64-bit.
///
/// `Hasher` is deliberately unusable here: Swift seeds it per process, so the
/// same scene would encode to different ids on every launch, orphaning the
/// image the terminal already holds. Upstream uses `DefaultHasher` (which is
/// fixed in Rust), so a hand-rolled hash is what keeps the two sides' *property*
/// — stability — rather than their exact numbers, which never cross the wire.
private struct StableHash {
    private static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let prime: UInt64 = 0x0000_0100_0000_01b3

    private var state = StableHash.offsetBasis

    var value: UInt64 { state }

    private mutating func mix(_ byte: UInt8) {
        state ^= UInt64(byte)
        state = state &* Self.prime
    }

    /// Little-endian, so the same number hashes the same on any host.
    mutating func mix(_ integer: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            mix(UInt8(truncatingIfNeeded: integer >> UInt64(shift)))
        }
    }

    /// Length-prefixed: without it `"ab" + "c"` and `"a" + "bc"` would collide.
    mutating func mix(_ text: String) {
        mix(UInt64(text.utf8.count))
        for byte in text.utf8 { mix(byte) }
    }

    /// Every field of the asset key, plus the enum tags as explicit integers.
    /// `SurfaceGraphicsSource` is `Hashable`, but its `hashValue` is per-process
    /// seeded, so the case is flattened here by hand.
    mutating func mix(_ key: SurfaceGraphicsAssetKey) {
        switch key.source {
        case let .terminal(target, imageId):
            mix(UInt64(0))
            mix(target)
            mix(UInt64(imageId))
        case let .paneLayer(paneId, layerId):
            mix(UInt64(1))
            mix(paneId)
            mix(layerId)
        }
        mix(UInt64(key.imageWidth))
        mix(UInt64(key.imageHeight))
        mix(key.format.rawValue)
        mix(key.dataLen)
        mix(key.dataFingerprint)
    }

    private mutating func mix(_ target: SurfaceGraphicsTarget) {
        switch target {
        case let .pane(paneId):
            mix(UInt64(0))
            mix(paneId)
        case let .popup(terminalId):
            mix(UInt64(1))
            mix(terminalId)
        }
    }
}
