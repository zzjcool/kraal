// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Decoders for every server message. One place per wire type, in the same
// order as `Wire.swift`, so a diff against `wire.rs` stays mechanical.

import Foundation

public enum WireDecodeError: Error, CustomStringConvertible, Equatable {
    case emptyPayload
    case unknownServerTag(UInt64)
    case bincode(BincodeError)
    case snapshotDecode(String)

    public var description: String {
        switch self {
        case .emptyPayload:
            "empty payload"
        case let .unknownServerTag(tag):
            "unknown server message tag \(tag)"
        case let .bincode(error):
            "bincode: \(error.description)"
        case let .snapshotDecode(detail):
            "snapshot JSON did not decode: \(detail)"
        }
    }
}

// MARK: - Composite decoders

enum WireDecoder {
    static func decodeClientSurfaceSize(_ reader: inout BincodeReader) throws -> ClientSurfaceSize {
        let cols = try reader.readU16Varint()
        let rows = try reader.readU16Varint()
        return ClientSurfaceSize(cols: cols, rows: rows)
    }

    static func decodeRect(_ reader: inout BincodeReader) throws -> SurfaceRect {
        let originX = try reader.readU16Varint()
        let originY = try reader.readU16Varint()
        let width = try reader.readU16Varint()
        let height = try reader.readU16Varint()
        return SurfaceRect(
            originX: originX,
            originY: originY,
            width: width,
            height: height
        )
    }

    static func decodeCell(_ reader: inout BincodeReader) throws -> CellData {
        let symbol = try reader.readString()
        let foreground = try reader.readU32Varint()
        let background = try reader.readU32Varint()
        let modifier = try reader.readU16Varint()
        let skip = try reader.readBool()
        let hyperlink = try reader.readOptional { try $0.readU32Varint() }
        return CellData(
            symbol: symbol,
            foreground: foreground,
            background: background,
            modifier: modifier,
            skip: skip,
            hyperlink: hyperlink
        )
    }

    /// A minimum of 1 byte per cell bounds the count against the payload before
    /// allocating: a corrupt length can then only fail, never exhaust memory.
    static func decodeFrameData(_ reader: inout BincodeReader) throws -> FrameData {
        let cells = try reader.readArray(minimumElementBytes: 1) { try decodeCell(&$0) }
        let width = try reader.readU16Varint()
        let height = try reader.readU16Varint()

        let cursor = try reader.readOptional { reader -> CursorState in
            let column = try reader.readU16Varint()
            let row = try reader.readU16Varint()
            let visible = try reader.readBool()
            let shape = try reader.readU8()
            return CursorState(column: column, row: row, visible: visible, shape: shape)
        }

        let hyperlinks = try reader.readArray(minimumElementBytes: 1) { try $0.readString() }
        let graphics = try reader.readByteBuffer()

        return FrameData(
            cells: cells,
            width: width,
            height: height,
            cursor: cursor,
            hyperlinks: hyperlinks,
            graphics: graphics
        )
    }

    static func decodeScrollMetrics(
        _ reader: inout BincodeReader
    ) throws -> PaneSurfaceScrollMetrics {
        let offset = try reader.readUInt64()
        let maxOffset = try reader.readUInt64()
        let rows = try reader.readUInt64()
        return PaneSurfaceScrollMetrics(
            offsetFromBottom: offset,
            maxOffsetFromBottom: maxOffset,
            viewportRows: rows
        )
    }

    static func decodePane(_ reader: inout BincodeReader) throws -> PaneSurfacePane {
        let paneId = try reader.readString()
        let contentRevision = try reader.readUInt64()
        let rect = try decodeRect(&reader)
        let innerRect = try decodeRect(&reader)
        let scrollbarRect = try reader.readOptional { try decodeRect(&$0) }
        let scroll = try reader.readOptional { try decodeScrollMetrics(&$0) }
        let focused = try reader.readBool()
        let mouseReporting = try reader.readBool()
        let sgrPixelMouse = try reader.readBool()
        let alternateScreenActive = try reader.readBool()
        let pixelWidth = try reader.readU32Varint()
        let pixelHeight = try reader.readU32Varint()
        return PaneSurfacePane(
            paneId: paneId,
            contentRevision: contentRevision,
            rect: rect,
            innerRect: innerRect,
            scrollbarRect: scrollbarRect,
            scroll: scroll,
            focused: focused,
            mouseReporting: mouseReporting,
            sgrPixelMouse: sgrPixelMouse,
            alternateScreenActive: alternateScreenActive,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    static func decodeSplit(_ reader: inout BincodeReader) throws -> PaneSurfaceSplit {
        let directionTag = try reader.readTag(caseCount: 2, type: "PaneSurfaceSplitDirection")
        let direction: PaneSurfaceSplitDirection = directionTag == 0 ? .horizontal : .vertical
        let position = try reader.readU16Varint()
        let area = try decodeRect(&reader)
        let hitRect = try decodeRect(&reader)
        let path = try reader.readArray(minimumElementBytes: 1) { try $0.readBool() }
        return PaneSurfaceSplit(
            direction: direction,
            position: position,
            area: area,
            hitRect: hitRect,
            path: path
        )
    }

    static func decodeGraphicsTarget(_ reader: inout BincodeReader) throws -> SurfaceGraphicsTarget {
        let tag = try reader.readTag(caseCount: 2, type: "SurfaceGraphicsTarget")
        let id = try reader.readString()
        return tag == 0 ? .pane(paneId: id) : .popup(terminalId: id)
    }

    static func decodeGraphicsSource(_ reader: inout BincodeReader) throws -> SurfaceGraphicsSource {
        let tag = try reader.readTag(caseCount: 2, type: "SurfaceGraphicsSource")
        if tag == 0 {
            let target = try decodeGraphicsTarget(&reader)
            let imageId = try reader.readU32Varint()
            return .terminal(target: target, imageId: imageId)
        }
        let paneId = try reader.readString()
        let layerId = try reader.readString()
        return .paneLayer(paneId: paneId, layerId: layerId)
    }

    static func decodeGraphicsFormat(
        _ reader: inout BincodeReader
    ) throws -> SurfaceGraphicsFormat {
        let tag = try reader.readTag(caseCount: 3, type: "SurfaceGraphicsFormat")
        switch tag {
        case 0: return .rgb
        case 1: return .rgba
        default: return .png
        }
    }

    static func decodeAssetKey(
        _ reader: inout BincodeReader
    ) throws -> SurfaceGraphicsAssetKey {
        let source = try decodeGraphicsSource(&reader)
        let imageWidth = try reader.readU32Varint()
        let imageHeight = try reader.readU32Varint()
        let format = try decodeGraphicsFormat(&reader)
        let dataLen = try reader.readUInt64()
        let fingerprint = try reader.readUInt64()
        return SurfaceGraphicsAssetKey(
            source: source,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            format: format,
            dataLen: dataLen,
            dataFingerprint: fingerprint
        )
    }

    static func decodeAsset(_ reader: inout BincodeReader) throws -> SurfaceGraphicsAsset {
        let key = try decodeAssetKey(&reader)
        let data = try reader.readByteBuffer()
        return SurfaceGraphicsAsset(key: key, data: data)
    }

    static func decodePlacement(
        _ reader: inout BincodeReader
    ) throws -> SurfaceGraphicsPlacement {
        let asset = try decodeAssetKey(&reader)
        let logicalPlacementId = try reader.readU32Varint()
        let cellX = try reader.readU16Varint()
        let cellY = try reader.readU16Varint()
        let cols = try reader.readU32Varint()
        let rows = try reader.readU32Varint()
        let sourceX = try reader.readU32Varint()
        let sourceY = try reader.readU32Varint()
        let sourceWidth = try reader.readU32Varint()
        let sourceHeight = try reader.readU32Varint()
        let xOffset = try reader.readU32Varint()
        let yOffset = try reader.readU32Varint()
        // i32 on the wire: varint-encoded, zigzag-free (bincode writes the
        // value as an unsigned varint after a sign-preserving cast).
        let layerRaw = try reader.readVarint()
        let layer = Int32(bitPattern: UInt32(truncatingIfNeeded: layerRaw))
        let scrollbackOffset = try reader.readU32Varint()
        return SurfaceGraphicsPlacement(
            asset: asset,
            logicalPlacementId: logicalPlacementId,
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
            scrollbackOffset: scrollbackOffset
        )
    }

    static func decodeGraphicsScene(
        _ reader: inout BincodeReader
    ) throws -> SurfaceGraphicsScene {
        let assets = try reader.readArray(minimumElementBytes: 1) { try decodeAsset(&$0) }
        let placements = try reader.readArray(minimumElementBytes: 1) { try decodePlacement(&$0) }
        let retained = try reader.readArray(minimumElementBytes: 1) { try decodeAssetKey(&$0) }
        return SurfaceGraphicsScene(
            assets: assets,
            placements: placements,
            retainedAssets: retained
        )
    }

    static func decodePopup(_ reader: inout BincodeReader) throws -> ClientShellPopupSurface {
        let terminalId = try reader.readString()
        let title = try reader.readString()

        func decodeSize(_ reader: inout BincodeReader) throws -> ClientShellPopupSize? {
            try reader.readOptional { reader -> ClientShellPopupSize in
                let tag = try reader.readTag(caseCount: 2, type: "ClientShellPopupSize")
                if tag == 0 {
                    return .cells(try reader.readU16Varint())
                }
                return .percent(try reader.readU8())
            }
        }

        let width = try decodeSize(&reader)
        let height = try decodeSize(&reader)
        let frame = try decodeFrameData(&reader)
        let mouseReporting = try reader.readBool()
        let sgrPixelMouse = try reader.readBool()
        let pixelWidth = try reader.readU32Varint()
        let pixelHeight = try reader.readU32Varint()
        return ClientShellPopupSurface(
            terminalId: terminalId,
            title: title,
            width: width,
            height: height,
            frame: frame,
            mouseReporting: mouseReporting,
            sgrPixelMouse: sgrPixelMouse,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }
}

// MARK: - Message decoding

public enum ServerMessageDecoder {
    /// Decodes one frame payload (tag + body) into a `ServerMessage`.
    public static func decode(_ payload: Data) throws -> ServerMessage {
        var reader = BincodeReader(payload)
        guard !reader.isAtEnd else { throw WireDecodeError.emptyPayload }
        let tag = try reader.readVarint()
        let message: ServerMessage
        do {
            message = try decodeBody(tag: tag, &reader)
        } catch let error as BincodeError {
            throw WireDecodeError.bincode(error)
        }
        // The payload must be consumed exactly. Without this, a stream that has
        // slipped by one byte decodes garbage as a "legal extra tail" and the
        // *next* message starts from the wrong offset — surfacing later as a
        // random unknown tag, or as a structurally valid message with wrong
        // contents. `BincodeError.trailingBytes` existed but was never thrown.
        //
        // Ported from `herdr-gpui/.../tests/compatibility.rs:430` and `codec.rs`
        // (`if used != payload.len() { return Err(Error::TrailingBytes) }`).
        guard reader.isAtEnd else {
            throw WireDecodeError.bincode(.trailingBytes(count: reader.remaining))
        }
        return message
    }

    /// Splits the 21 tags into readability-sized groups; the wire order stays
    /// visible in `ServerMessage.tag`.
    private static func decodeBody(
        tag: UInt64,
        _ reader: inout BincodeReader
    ) throws -> ServerMessage {
        switch tag {
        case 0 ... 11: return try decodeTerminalBody(tag: tag, &reader)
        case 12: return try decodeSnapshot(&reader)
        case 13: return try decodeSurface(&reader)
        case 14: return try decodeNotification(&reader)
        case 15 ... 18: return try decodeShellBody(tag: tag, &reader)
        case 19: return try decodePatch(&reader)
        case 20: return try decodeEndpointControl(&reader)
        default: throw WireDecodeError.unknownServerTag(tag)
        }
    }

    // MARK: Bytes back from the PTY

    private static func decodeTerminalBody(
        tag: UInt64,
        _ reader: inout BincodeReader
    ) throws -> ServerMessage {
        switch tag {
        case 0:
            let version = try reader.readU32Varint()
            let encodingTag = try reader.readTag(caseCount: 2, type: "RenderEncoding")
            let encoding: RenderEncoding = encodingTag == 0 ? .semanticFrame : .terminalAnsi
            let error = try reader.readOptional { try $0.readString() }
            return .welcome(version: version, encoding: encoding, error: error)

        case 1:
            let seq = try reader.readUInt64()
            let width = try reader.readU16Varint()
            let height = try reader.readU16Varint()
            let full = try reader.readBool()
            let bytes = try reader.readByteBuffer()
            return .terminal(TerminalFrame(
                seq: seq,
                width: width,
                height: height,
                full: full,
                bytes: bytes
            ))

        case 2:
            return .graphics(bytes: try reader.readByteBuffer())

        case 3:
            return .serverShutdown(reason: try reader.readOptional { try $0.readString() })

        case 4:
            let kindTag = try reader.readTag(caseCount: 3, type: "NotifyKind")
            let kind: NotifyKind = switch kindTag {
            case 0: .sound
            case 1: .toast
            default: .systemToast
            }
            let message = try reader.readString()
            let body = try reader.readOptional { try $0.readString() }
            return .notify(kind: kind, message: message, body: body)

        case 5:
            return .clipboard(data: try reader.readString())

        case 6:
            return .windowTitle(title: try reader.readOptional { try $0.readString() })

        case 7:
            return .reloadSoundConfig

        case 8:
            let enabled = try reader.readBool()
            let sgrPixels = try reader.readBool()
            return .mouseCapture(enabled: enabled, sgrPixels: sgrPixels)

        case 9:
            return .terminalBell(count: try reader.readU16Varint())

        case 10:
            return try decodeGraphicsFile(&reader)

        case 11:
            let transferId = try reader.readUInt64()
            let imageId = try reader.readU32Varint()
            return .graphicsTransmissionRetired(transferId: transferId, imageId: imageId)

        default:
            throw WireDecodeError.unknownServerTag(tag)
        }
    }

    private static func decodeGraphicsFile(_ reader: inout BincodeReader) throws -> ServerMessage {
        let path = try reader.readString()
        let expectedLen = try reader.readUInt64()
        let imageId = try reader.readU32Varint()
        let transferId = try reader.readUInt64()
        let leading = try reader.readByteBuffer()
        let control = try reader.readString()
        let surfaceAsset = try reader.readOptional { try WireDecoder.decodeAssetKey(&$0) }
        return .graphicsFile(
            path: path,
            expectedLen: expectedLen,
            imageId: imageId,
            transferId: transferId,
            leading: leading,
            control: control,
            surfaceAsset: surfaceAsset
        )
    }

    // MARK: Shell control plane

    /// Tag 12: the sidebar payload, JSON nested inside a bincode string.
    private static func decodeSnapshot(_ reader: inout BincodeReader) throws -> ServerMessage {
        let json = try reader.readString()
        let data = Data(json.utf8)
        do {
            return .clientShellSnapshot(try JSONDecoder().decode(ClientShellSnapshot.self, from: data))
        } catch {
            throw WireDecodeError.snapshotDecode(String(describing: error))
        }
    }

    private static func decodeShellBody(
        tag: UInt64,
        _ reader: inout BincodeReader
    ) throws -> ServerMessage {
        switch tag {
        case 15:
            return .clientShellError(message: try reader.readString())

        case 16:
            let flags = try reader.readU16Varint()
            let level = try reader.readU8()
            return .directTerminalKeyboardProtocol(flags: flags, modifyOtherKeysLevel: level)

        case 17:
            return .clientShellKeyboardReportAll(enabled: try reader.readBool())

        case 18:
            let bootId = try reader.readString()
            let requestId = try reader.readString()
            let finalChunk = try reader.readBool()
            let data = try reader.readByteBuffer()
            return .clientShellEndpointResponseChunk(
                bootId: bootId,
                requestId: requestId,
                finalChunk: finalChunk,
                data: data
            )

        default:
            throw WireDecodeError.unknownServerTag(tag)
        }
    }

    private static func decodeEndpointControl(_ reader: inout BincodeReader) throws -> ServerMessage {
        let kind = try reader.readString()
        let data = try reader.readString()
        return .endpointControl(kind: kind, data: data)
    }

    // MARK: Surfaces

    private static func decodeSurface(_ reader: inout BincodeReader) throws -> ServerMessage {
        let bootId = try reader.readString()
        let projectionRevision = try reader.readUInt64()
        let surfaceRevision = try reader.readUInt64()
        let frame = try WireDecoder.decodeFrameData(&reader)
        let panes = try reader.readArray(minimumElementBytes: 1) {
            try WireDecoder.decodePane(&$0)
        }
        let splits = try reader.readArray(minimumElementBytes: 1) {
            try WireDecoder.decodeSplit(&$0)
        }
        let popup = try reader.readOptional { try WireDecoder.decodePopup(&$0) }
        let graphics = try WireDecoder.decodeGraphicsScene(&reader)
        return .paneSurface(PaneSurfaceFrame(
            bootId: bootId,
            projectionRevision: projectionRevision,
            surfaceRevision: surfaceRevision,
            frame: frame,
            panes: panes,
            splits: splits,
            popup: popup,
            graphics: graphics
        ))
    }

    private static func decodePatch(_ reader: inout BincodeReader) throws -> ServerMessage {
        let bootId = try reader.readString()
        let projectionRevision = try reader.readUInt64()
        let baseRevision = try reader.readUInt64()
        let surfaceRevision = try reader.readUInt64()
        let rows = try reader.readArray(minimumElementBytes: 1) { reader -> PaneSurfacePatchRow in
            let column = try reader.readU16Varint()
            let row = try reader.readU16Varint()
            let cells = try reader.readArray(minimumElementBytes: 1) {
                try WireDecoder.decodeCell(&$0)
            }
            return PaneSurfacePatchRow(column: column, row: row, cells: cells)
        }
        let panes = try reader.readArray(minimumElementBytes: 1) {
            try WireDecoder.decodePane(&$0)
        }
        let cursor = try reader.readOptional { reader -> CursorState in
            let column = try reader.readU16Varint()
            let row = try reader.readU16Varint()
            let visible = try reader.readBool()
            let shape = try reader.readU8()
            return CursorState(column: column, row: row, visible: visible, shape: shape)
        }
        return .paneSurfacePatch(PaneSurfacePatch(
            bootId: bootId,
            projectionRevision: projectionRevision,
            baseSurfaceRevision: baseRevision,
            surfaceRevision: surfaceRevision,
            rows: rows,
            panes: panes,
            cursor: cursor
        ))
    }

    // MARK: Notifications

    private static func decodeNotification(_ reader: inout BincodeReader) throws -> ServerMessage {
        let kindTag = try reader.readTag(caseCount: 4, type: "SemanticNotificationKind")
        let kind: SemanticNotificationKind = switch kindTag {
        case 0: .needsAttention
        case 1: .finished
        case 2: .updateInstalled
        default: .custom
        }
        let title = try reader.readString()
        let body = try reader.readOptional { try $0.readString() }
        let sound = try reader.readOptional { reader -> SemanticNotificationSound in
            let tag = try reader.readTag(caseCount: 2, type: "SemanticNotificationSound")
            return tag == 0 ? .done : .request
        }
        let agent = try reader.readOptional { try $0.readString() }
        let workspaceId = try reader.readOptional { try $0.readString() }
        let tabId = try reader.readOptional { try $0.readString() }
        let paneId = try reader.readOptional { try $0.readString() }
        let position = try reader.readOptional { reader -> ToastHerdrPosition in
            let tag = try reader.readTag(caseCount: 4, type: "ToastHerdrPosition")
            switch tag {
            case 0: return .topLeft
            case 1: return .topRight
            case 2: return .bottomLeft
            default: return .bottomRight
            }
        }
        return .semanticNotification(SemanticNotification(
            kind: kind,
            title: title,
            body: body,
            sound: sound,
            agent: agent,
            workspaceId: workspaceId,
            tabId: tabId,
            paneId: paneId,
            position: position
        ))
    }
}
