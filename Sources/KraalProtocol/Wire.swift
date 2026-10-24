// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Wire types for the Herdr endpoint protocol, generation 1.
//
// Adapted from `herdr-gpui/crates/herdr-protocol/src/wire.rs`, which is itself
// adapted from Herdr `src/protocol/wire.rs` (Apache-2.0, see NOTICE).
//
// **Variant and field order is a binary compatibility contract.** bincode is
// positional: an enum variant's index *is* its wire tag, and a struct's fields
// are written in declaration order with no names. Never reorder, never insert
// in the middle. Additions go at the end, and only after the upstream daemon
// does the same.

import Foundation

// MARK: - Scalar wire types

public struct ClientSurfaceSize: Equatable, Sendable {
    public var cols: UInt16
    public var rows: UInt16

    public init(cols: UInt16, rows: UInt16) {
        self.cols = cols
        self.rows = rows
    }
}

public struct SurfaceRect: Equatable, Sendable {
    /// Column of the top-left cell.
    public var originX: UInt16
    /// Row of the top-left cell.
    public var originY: UInt16
    public var width: UInt16
    public var height: UInt16

    public init(originX: UInt16, originY: UInt16, width: UInt16, height: UInt16) {
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
    }
}

public enum RenderEncoding: UInt64, Sendable {
    case semanticFrame = 0
    case terminalAnsi = 1
}

public enum ClientKeyKind: UInt64, Sendable {
    case press = 0
    case `repeat` = 1
    case release = 2
}

public enum ClientKeyCode: Equatable, Sendable {
    case backspace
    case enter
    case arrowLeft
    case arrowRight
    case arrowUp
    case arrowDown
    case home
    case end
    case pageUp
    case pageDown
    case tab
    case backTab
    case delete
    case insert
    case esc
    /// Rust `char`: a Unicode scalar value written as a varint u32.
    case char(Unicode.Scalar)
    case function(UInt8)
    case null
}

public enum ClientMouseButton: UInt64, Sendable {
    case left = 0
    case right = 1
    case middle = 2
}

public enum ClientMouseKind: Equatable, Sendable {
    case press(ClientMouseButton)
    case release(ClientMouseButton)
    case drag(ClientMouseButton)
    case moved
    case scrollUp
    case scrollDown
    case scrollLeft
    case scrollRight
}

public enum ClientMousePosition: Equatable, Sendable {
    case cell(column: UInt16, row: UInt16)
    case pixels(pixelX: UInt32, pixelY: UInt32, column: UInt16, row: UInt16)
}

public struct ClientMouseGeometry: Equatable, Sendable {
    public var cols: UInt16
    public var rows: UInt16
    public var widthPx: UInt32
    public var heightPx: UInt32

    public init(cols: UInt16, rows: UInt16, widthPx: UInt32, heightPx: UInt32) {
        self.cols = cols
        self.rows = rows
        self.widthPx = widthPx
        self.heightPx = heightPx
    }
}

/// Kept for wire parity even on non-Windows hosts; the daemon's enum carries it.
public struct WindowsKeyRecord: Equatable, Sendable {
    public var keyDown: Bool
    public var repeatCount: UInt16
    public var virtualKeyCode: UInt16
    public var virtualScanCode: UInt16
    public var unicode: UInt16
    public var controlKeyState: UInt32

    public init(
        keyDown: Bool,
        repeatCount: UInt16,
        virtualKeyCode: UInt16,
        virtualScanCode: UInt16,
        unicode: UInt16,
        controlKeyState: UInt32
    ) {
        self.keyDown = keyDown
        self.repeatCount = repeatCount
        self.virtualKeyCode = virtualKeyCode
        self.virtualScanCode = virtualScanCode
        self.unicode = unicode
        self.controlKeyState = controlKeyState
    }
}

/// Modifier bits: shift = 1, control = 2, alt = 4, super = 8, hyper = 16, meta = 32.
public struct InputModifiers: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let shift = InputModifiers(rawValue: 1 << 0)
    public static let control = InputModifiers(rawValue: 1 << 1)
    public static let alt = InputModifiers(rawValue: 1 << 2)
    public static let `super` = InputModifiers(rawValue: 1 << 3)
    public static let hyper = InputModifiers(rawValue: 1 << 4)
    public static let meta = InputModifiers(rawValue: 1 << 5)
}

public enum ClientPaneInputEvent: Equatable, Sendable {
    case key(
        code: ClientKeyCode,
        modifiers: UInt8,
        kind: ClientKeyKind,
        repeatCount: UInt16,
        shiftedCodepoint: UInt32?,
        generatedText: String?,
        tracksRelease: Bool,
        physicalKeyId: UInt32?,
        windowsRecord: WindowsKeyRecord?
    )
    case textCommit(String)
    case mouse(
        kind: ClientMouseKind,
        position: ClientMousePosition,
        geometry: ClientMouseGeometry?,
        modifiers: UInt8,
        lines: UInt16
    )
    case paste(String)

    /// Convenience for the common "type this character" case.
    public static func typed(_ text: String) -> ClientPaneInputEvent {
        .textCommit(text)
    }
}

// MARK: - Surface payloads

/// Cell modifier bits.
/// ratatui / daemon `Modifier` bits, in the order the daemon defines them
/// (`render_ansi.rs:428-458`, matching ratatui 0.30's `Modifier`).
///
/// These are a wire contract: bit 5 is **rapid** blink and bit 6 is **reversed**.
/// An earlier version of this type had no rapid-blink entry and called bit 5
/// `reverse`, so a rapidly blinking region was drawn in reverse video instead
/// of blinking, and SGR 6 could never be emitted.
public enum CellModifier {
    public static let bold: UInt16 = 1 << 0
    public static let dim: UInt16 = 1 << 1
    public static let italic: UInt16 = 1 << 2
    public static let underline: UInt16 = 1 << 3
    public static let slowBlink: UInt16 = 1 << 4
    public static let rapidBlink: UInt16 = 1 << 5
    public static let reversed: UInt16 = 1 << 6
    public static let hidden: UInt16 = 1 << 7
    public static let strikethrough: UInt16 = 1 << 8

    /// The underline style lives in bits 12–15 (`UNDERLINE_STYLE_SHIFT` /
    /// `_MASK` in `wire.rs:1576`): 1 single, 2 double, 3 curly, 4 dotted,
    /// 5 dashed.
    public static let underlineStyleMask: UInt16 = 0xF000
    public static let underlineStyleShift: UInt16 = 12

    /// `0` means "no extended style" — a plain `4`.
    public static func underlineStyle(_ modifier: UInt16) -> UInt8 {
        UInt8((modifier & underlineStyleMask) >> underlineStyleShift)
    }
}

/// A single terminal cell.
///
/// `fg`/`bg` are **not** ARGB. See ``TerminalColor``.
public struct CellData: Equatable, Sendable {
    /// One grapheme cluster; empty for a continuation cell.
    public var symbol: String
    public var foreground: UInt32
    public var background: UInt32
    public var modifier: UInt16
    /// True for the second column of a wide glyph: do not draw.
    public var skip: Bool
    /// Index into ``FrameData/hyperlinks``.
    public var hyperlink: UInt32?

    public init(
        symbol: String,
        foreground: UInt32,
        background: UInt32,
        modifier: UInt16,
        skip: Bool,
        hyperlink: UInt32?
    ) {
        self.symbol = symbol
        self.foreground = foreground
        self.background = background
        self.modifier = modifier
        self.skip = skip
        self.hyperlink = hyperlink
    }

    public static let blank = CellData(
        symbol: " ",
        foreground: 0,
        background: 0,
        modifier: 0,
        skip: false,
        hyperlink: nil
    )
}

public struct CursorState: Equatable, Sendable {
    public var column: UInt16
    public var row: UInt16
    public var visible: Bool
    /// `CursorShapeParam` is a `u8` upstream.
    public var shape: UInt8

    public init(column: UInt16, row: UInt16, visible: Bool, shape: UInt8) {
        self.column = column
        self.row = row
        self.visible = visible
        self.shape = shape
    }
}

public struct FrameData: Equatable, Sendable {
    /// The cell grid, one copy-on-write array per row.
    ///
    /// Row-chunked rather than one flat array so a patch can rewrite a row or two
    /// without copying the whole screen (issue #50; the reasoning is in
    /// `CellBuffer`'s header). Writes go through this property on purpose —
    /// `flatCells` deliberately has no setter, so no call site can reintroduce a
    /// full-screen write by indexing into a temporary array.
    public var buffer: CellBuffer
    public var width: UInt16
    public var height: UInt16
    public var cursor: CursorState?
    public var hyperlinks: [String]
    public var graphics: Data

    public init(
        cells: [CellData],
        width: UInt16,
        height: UInt16,
        cursor: CursorState?,
        hyperlinks: [String],
        graphics: Data
    ) {
        buffer = CellBuffer(cells, width: Int(width))
        self.width = width
        self.height = height
        self.cursor = cursor
        self.hyperlinks = hyperlinks
        self.graphics = graphics
    }

    /// A frame whose cells are already in rows, e.g. a pane crop.
    ///
    /// The `cells:` initialiser chunks a flat array, which copies every row out of
    /// the slice it came from (`Array(slice)` does not share storage). A caller
    /// that already loops per row — `PaneTerminalModel.paneFrame` does — should use
    /// this one and skip both the flattening and the re-chunking; see
    /// docs/PERFORMANCE.md, "`paneFrame`：本次改动自己制造、又自己还回去的那笔存储拷贝".
    public init(
        buffer: CellBuffer,
        width: UInt16,
        height: UInt16,
        cursor: CursorState?,
        hyperlinks: [String],
        graphics: Data
    ) {
        self.buffer = buffer
        self.width = width
        self.height = height
        self.cursor = cursor
        self.hyperlinks = hyperlinks
        self.graphics = graphics
    }

    /// The cells in frame order, as a plain array.
    ///
    /// **Not** for hot paths: it allocates one `CellData` per cell. It exists for
    /// tests and for debug output. The renderer, the row diff and pane cropping
    /// all go through ``buffer`` — by row, which is the shape both of them want.
    public var flatCells: [CellData] { buffer.flattened }

    public func cell(column: Int, row: Int) -> CellData? {
        // Delegated to the buffer, which indexes in its own chunking: `width` is a
        // stored property a caller could reassign after the frame was built, and a
        // read must not land in the neighbouring row because of that.
        buffer.cell(column: column, row: row)
    }
}

public struct PaneSurfaceScrollMetrics: Equatable, Sendable {
    public var offsetFromBottom: UInt64
    public var maxOffsetFromBottom: UInt64
    public var viewportRows: UInt64
}

public struct PaneSurfacePane: Equatable, Sendable {
    public var paneId: String
    public var contentRevision: UInt64
    /// Outer box, including the border cell.
    public var rect: SurfaceRect
    /// Content area. Layout and `terminal attach` sizing both use this.
    public var innerRect: SurfaceRect
    public var scrollbarRect: SurfaceRect?
    public var scroll: PaneSurfaceScrollMetrics?
    public var focused: Bool
    public var mouseReporting: Bool
    public var sgrPixelMouse: Bool
    public var alternateScreenActive: Bool
    public var pixelWidth: UInt32
    public var pixelHeight: UInt32
}

public enum PaneSurfaceSplitDirection: UInt64, Sendable {
    case horizontal = 0
    case vertical = 1
}

public struct PaneSurfaceSplit: Equatable, Sendable {
    public var direction: PaneSurfaceSplitDirection
    public var position: UInt16
    public var area: SurfaceRect
    public var hitRect: SurfaceRect
    /// BSP path: `true` takes the first child.
    public var path: [Bool]
}

public enum SurfaceGraphicsTarget: Equatable, Hashable, Sendable {
    case pane(paneId: String)
    case popup(terminalId: String)
}

public enum SurfaceGraphicsSource: Equatable, Hashable, Sendable {
    case terminal(target: SurfaceGraphicsTarget, imageId: UInt32)
    case paneLayer(paneId: String, layerId: String)
}

public enum SurfaceGraphicsFormat: UInt64, Sendable {
    case rgb = 0
    case rgba = 1
    case png = 2
}

public struct SurfaceGraphicsAssetKey: Equatable, Hashable, Sendable {
    public var source: SurfaceGraphicsSource
    public var imageWidth: UInt32
    public var imageHeight: UInt32
    public var format: SurfaceGraphicsFormat
    public var dataLen: UInt64
    public var dataFingerprint: UInt64

    /// Public so a scene can be built outside this module — the performance probe
    /// (`Scripts/bench.sh`) has no testable import, and issue #105 asks for a
    /// measured cost for graphics encoding.
    public init(
        source: SurfaceGraphicsSource,
        imageWidth: UInt32,
        imageHeight: UInt32,
        format: SurfaceGraphicsFormat,
        dataLen: UInt64,
        dataFingerprint: UInt64
    ) {
        self.source = source
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.format = format
        self.dataLen = dataLen
        self.dataFingerprint = dataFingerprint
    }
}

public struct SurfaceGraphicsAsset: Equatable, Sendable {
    public var key: SurfaceGraphicsAssetKey
    public var data: Data

    public init(key: SurfaceGraphicsAssetKey, data: Data) {
        self.key = key
        self.data = data
    }
}

public struct SurfaceGraphicsPlacement: Equatable, Sendable {
    public var asset: SurfaceGraphicsAssetKey
    public var logicalPlacementId: UInt32
    public var cellX: UInt16
    public var cellY: UInt16
    public var cols: UInt32
    public var rows: UInt32
    public var sourceX: UInt32
    public var sourceY: UInt32
    public var sourceWidth: UInt32
    public var sourceHeight: UInt32
    public var xOffset: UInt32
    public var yOffset: UInt32
    public var layer: Int32
    public var scrollbackOffset: UInt32

    public init(
        asset: SurfaceGraphicsAssetKey,
        logicalPlacementId: UInt32,
        cellX: UInt16,
        cellY: UInt16,
        cols: UInt32,
        rows: UInt32,
        sourceX: UInt32,
        sourceY: UInt32,
        sourceWidth: UInt32,
        sourceHeight: UInt32,
        xOffset: UInt32,
        yOffset: UInt32,
        layer: Int32,
        scrollbackOffset: UInt32
    ) {
        self.asset = asset
        self.logicalPlacementId = logicalPlacementId
        self.cellX = cellX
        self.cellY = cellY
        self.cols = cols
        self.rows = rows
        self.sourceX = sourceX
        self.sourceY = sourceY
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.xOffset = xOffset
        self.yOffset = yOffset
        self.layer = layer
        self.scrollbackOffset = scrollbackOffset
    }
}

public struct SurfaceGraphicsScene: Equatable, Sendable {
    public var assets: [SurfaceGraphicsAsset]
    public var placements: [SurfaceGraphicsPlacement]
    public var retainedAssets: [SurfaceGraphicsAssetKey]

    public init(
        assets: [SurfaceGraphicsAsset] = [],
        placements: [SurfaceGraphicsPlacement] = [],
        retainedAssets: [SurfaceGraphicsAssetKey] = []
    ) {
        self.assets = assets
        self.placements = placements
        self.retainedAssets = retainedAssets
    }
}

public enum ClientShellPopupSize: Equatable, Sendable {
    case cells(UInt16)
    case percent(UInt8)
}

public struct ClientShellPopupSurface: Equatable, Sendable {
    public var terminalId: String
    public var title: String
    public var width: ClientShellPopupSize?
    public var height: ClientShellPopupSize?
    public var frame: FrameData
    public var mouseReporting: Bool
    public var sgrPixelMouse: Bool
    public var pixelWidth: UInt32
    public var pixelHeight: UInt32
}

/// One tab's whole rendered surface: the composited cell grid plus the
/// geometry of every pane in it.
public struct PaneSurfaceFrame: Equatable, Sendable {
    public var bootId: String
    public var projectionRevision: UInt64
    public var surfaceRevision: UInt64
    public var frame: FrameData
    public var panes: [PaneSurfacePane]
    public var splits: [PaneSurfaceSplit]
    public var popup: ClientShellPopupSurface?
    public var graphics: SurfaceGraphicsScene
}

public struct PaneSurfacePatchRow: Equatable, Sendable {
    public var column: UInt16
    public var row: UInt16
    public var cells: [CellData]
}

public struct PaneSurfacePatch: Equatable, Sendable {
    public var bootId: String
    public var projectionRevision: UInt64
    public var baseSurfaceRevision: UInt64
    public var surfaceRevision: UInt64
    public var rows: [PaneSurfacePatchRow]
    public var panes: [PaneSurfacePane]
    public var cursor: CursorState?
}

// MARK: - Terminal stream payloads

public struct TerminalFrame: Equatable, Sendable {
    public var seq: UInt64
    public var width: UInt16
    public var height: UInt16
    public var full: Bool
    public var bytes: Data
}

public enum NotifyKind: UInt64, Sendable {
    case sound = 0
    case toast = 1
    case systemToast = 2
}

public enum SemanticNotificationKind: UInt64, Sendable {
    case needsAttention = 0
    case finished = 1
    case updateInstalled = 2
    case custom = 3
}

public enum SemanticNotificationSound: UInt64, Sendable {
    case done = 0
    case request = 1
}

public enum ToastHerdrPosition: UInt64, Sendable {
    case topLeft = 0
    case topRight = 1
    case bottomLeft = 2
    case bottomRight = 3
}

public struct SemanticNotification: Equatable, Sendable {
    public var kind: SemanticNotificationKind
    public var title: String
    public var body: String?
    public var sound: SemanticNotificationSound?
    public var agent: String?
    public var workspaceId: String?
    public var tabId: String?
    public var paneId: String?
    public var position: ToastHerdrPosition?

    public init(
        kind: SemanticNotificationKind,
        title: String,
        body: String? = nil,
        sound: SemanticNotificationSound? = nil,
        agent: String? = nil,
        workspaceId: String? = nil,
        tabId: String? = nil,
        paneId: String? = nil,
        position: ToastHerdrPosition? = nil
    ) {
        self.kind = kind
        self.title = title
        self.body = body
        self.sound = sound
        self.agent = agent
        self.workspaceId = workspaceId
        self.tabId = tabId
        self.paneId = paneId
        self.position = position
    }
}

// MARK: - Client → server messages (21 variants)

public enum ClientMessage: Equatable, Sendable {
    case terminalHello(
        version: UInt32,
        cols: UInt16,
        rows: UInt16,
        cellWidthPx: UInt32,
        cellHeightPx: UInt32,
        pixelMouse: Bool
    )
    case input(data: Data)
    case clipboardImage(target: ClientClipboardImageTarget, extension: String, data: Data)
    case resize(
        cols: UInt16,
        rows: UInt16,
        cellWidthPx: UInt32,
        cellHeightPx: UInt32,
        pixelMouse: Bool
    )
    case detach
    case attachTerminal(terminalId: String, takeover: Bool)
    case attachScroll(
        source: AttachScrollSource,
        direction: AttachScrollDirection,
        lines: UInt16,
        column: UInt16?,
        row: UInt16?,
        modifiers: UInt8
    )
    case observeTerminal(target: String)
    case controlTerminal(target: String, takeover: Bool)
    case graphicsTransmissionResult(transferId: UInt64, imageId: UInt32, success: Bool)
    case graphicsTransmissionStarted(transferId: UInt64, imageId: UInt32)
    case clientShellHello(
        version: UInt32,
        cellWidthPx: UInt32,
        cellHeightPx: UInt32,
        surfaceSize: ClientSurfaceSize,
        pixelMouse: Bool,
        directGraphics: Bool,
        endpointKeybindings: Bool,
        mouseCapture: Bool
    )
    case clientShellResize(
        cellWidthPx: UInt32,
        cellHeightPx: UInt32,
        surfaceSize: ClientSurfaceSize,
        pixelMouse: Bool
    )
    case clientShellPaneInput(paneId: String, events: [ClientPaneInputEvent])
    case clientShellPopupInput(terminalId: String, events: [ClientPaneInputEvent])
    case clientShellEndpointRequest(bootId: String, request: String)
    case attachMouse(
        kind: ClientMouseKind,
        position: ClientMousePosition,
        geometry: ClientMouseGeometry?,
        modifiers: UInt8,
        lines: UInt16
    )
    case clientShellHostTheme(update: ClientHostThemeUpdate)
    case clientShellFocus(focused: Bool)
    case clientShellMouseCapture(enabled: Bool)
    case endpointControl(kind: String, data: String)

    /// Positional index on the wire. Do not renumber.
    public var tag: UInt64 {
        switch self {
        case .terminalHello: 0
        case .input: 1
        case .clipboardImage: 2
        case .resize: 3
        case .detach: 4
        case .attachTerminal: 5
        case .attachScroll: 6
        case .observeTerminal: 7
        case .controlTerminal: 8
        case .graphicsTransmissionResult: 9
        case .graphicsTransmissionStarted: 10
        case .clientShellHello: 11
        case .clientShellResize: 12
        case .clientShellPaneInput: 13
        case .clientShellPopupInput: 14
        case .clientShellEndpointRequest: 15
        case .attachMouse: 16
        case .clientShellHostTheme: 17
        case .clientShellFocus: 18
        case .clientShellMouseCapture: 19
        case .endpointControl: 20
        }
    }
}

public enum ClientClipboardImageTarget: Equatable, Sendable {
    case directTerminal
    case pane(String)
    case popup(String)
}

public enum AttachScrollDirection: UInt64, Sendable {
    case upward = 0
    case downward = 1
}

public enum AttachScrollSource: Equatable, Sendable {
    case wheel
    case pageKey(input: [UInt8])
}

public struct ClientHostColor: Equatable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public enum ClientHostDefaultColorKind: UInt64, Sendable {
    case foreground = 0
    case background = 1
}

public enum ClientHostAppearance: UInt64, Sendable {
    case dark = 0
    case light = 1
}

public struct PaletteColor: Equatable, Sendable {
    public var index: UInt8
    public var color: ClientHostColor

    public init(index: UInt8, color: ClientHostColor) {
        self.index = index
        self.color = color
    }
}

public enum ClientHostThemeUpdate: Equatable, Sendable {
    case defaultColor(kind: ClientHostDefaultColorKind, color: ClientHostColor)
    case paletteColors([PaletteColor])
    case appearance(ClientHostAppearance)
}

// MARK: - Server → client messages (21 variants)

public enum ServerMessage: Equatable, Sendable {
    case welcome(version: UInt32, encoding: RenderEncoding, error: String?)
    case terminal(TerminalFrame)
    case graphics(bytes: Data)
    case serverShutdown(reason: String?)
    case notify(kind: NotifyKind, message: String, body: String?)
    case clipboard(data: String)
    case windowTitle(title: String?)
    case reloadSoundConfig
    case mouseCapture(enabled: Bool, sgrPixels: Bool)
    case terminalBell(count: UInt16)
    case graphicsFile(
        path: String,
        expectedLen: UInt64,
        imageId: UInt32,
        transferId: UInt64,
        leading: Data,
        control: String,
        surfaceAsset: SurfaceGraphicsAssetKey?
    )
    case graphicsTransmissionRetired(transferId: UInt64, imageId: UInt32)
    case clientShellSnapshot(ClientShellSnapshot)
    case paneSurface(PaneSurfaceFrame)
    case semanticNotification(SemanticNotification)
    case clientShellError(message: String)
    case directTerminalKeyboardProtocol(flags: UInt16, modifyOtherKeysLevel: UInt8)
    case clientShellKeyboardReportAll(enabled: Bool)
    case clientShellEndpointResponseChunk(
        bootId: String,
        requestId: String,
        finalChunk: Bool,
        data: Data
    )
    case paneSurfacePatch(PaneSurfacePatch)
    case endpointControl(kind: String, data: String)

    public var tag: UInt64 {
        switch self {
        case .welcome: 0
        case .terminal: 1
        case .graphics: 2
        case .serverShutdown: 3
        case .notify: 4
        case .clipboard: 5
        case .windowTitle: 6
        case .reloadSoundConfig: 7
        case .mouseCapture: 8
        case .terminalBell: 9
        case .graphicsFile: 10
        case .graphicsTransmissionRetired: 11
        case .clientShellSnapshot: 12
        case .paneSurface: 13
        case .semanticNotification: 14
        case .clientShellError: 15
        case .directTerminalKeyboardProtocol: 16
        case .clientShellKeyboardReportAll: 17
        case .clientShellEndpointResponseChunk: 18
        case .paneSurfacePatch: 19
        case .endpointControl: 20
        }
    }

    public static let caseCount = 21
}
