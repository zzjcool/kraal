// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Wire order, pinned by an independent second source.
//
// Ported from `herdr-gpui/crates/herdr-protocol/tests/compatibility.rs`
// (`all_client_tags_match_frozen_source_order`,
// `semantic_key_matches_independent_source_shape`,
// `surface_matches_independent_source_field_order`) and
// `tests/host_theme.rs`, `tests/clipboard.rs` (Apache-2.0, see NOTICE).
//
// Why these exist: bincode is *positional*. A reordered field does not fail to
// decode anywhere — the daemon just renders a different grid, or reads the
// wrong colour, with no error on either side. The only way to catch that is to
// assert the bytes against a table written by hand from `wire.rs`, never from
// this repository's own encoder. That is what the arrays below are: a second,
// independent description of the wire order.

import Foundation
import Testing

@testable import KraalProtocol

@Suite("Client wire tags")
struct ClientWireTagTests {
    /// One representative value per `ClientMessage` variant, in declaration
    /// order. The index of each entry *is* its expected tag.
    private static func messages() -> [ClientMessage] {
        let size = ClientSurfaceSize(cols: 80, rows: 24)
        return [
            .terminalHello(
                version: 22,
                cols: 80,
                rows: 24,
                cellWidthPx: 8,
                cellHeightPx: 16,
                pixelMouse: false
            ),
            .input(data: Data()),
            .clipboardImage(target: .directTerminal, extension: "png", data: Data()),
            .resize(cols: 80, rows: 24, cellWidthPx: 8, cellHeightPx: 16, pixelMouse: false),
            .detach,
            .attachTerminal(terminalId: "t", takeover: false),
            .attachScroll(
                source: .wheel,
                direction: .upward,
                lines: 1,
                column: nil,
                row: nil,
                modifiers: 0
            ),
            .observeTerminal(target: "p"),
            .controlTerminal(target: "p", takeover: false),
            .graphicsTransmissionResult(transferId: 1, imageId: 2, success: true),
            .graphicsTransmissionStarted(transferId: 1, imageId: 2),
            .clientShellHello(
                version: 22,
                cellWidthPx: 8,
                cellHeightPx: 16,
                surfaceSize: size,
                pixelMouse: false,
                directGraphics: false,
                endpointKeybindings: false,
                mouseCapture: false
            ),
            .clientShellResize(
                cellWidthPx: 8,
                cellHeightPx: 16,
                surfaceSize: size,
                pixelMouse: false
            ),
            .clientShellPaneInput(paneId: "p", events: []),
            .clientShellPopupInput(terminalId: "t", events: []),
            .clientShellEndpointRequest(bootId: "b", request: "{}"),
            .attachMouse(
                kind: .scrollDown,
                position: .cell(column: 1, row: 2),
                geometry: nil,
                modifiers: 0,
                lines: 3
            ),
            .clientShellHostTheme(update: .appearance(.dark)),
            .clientShellFocus(focused: true),
            .clientShellMouseCapture(enabled: true),
            .endpointControl(kind: "", data: ""),
        ]
    }

    /// The frozen order of `ClientMessage` in `wire.rs`. Renumbering any variant
    /// silently changes the meaning of every message sent after it.
    @Test("every client tag matches its declaration index")
    func clientTags() {
        let messages = Self.messages()
        #expect(messages.count == 21, "the wire has 21 client variants")
        for (index, message) in messages.enumerated() {
            let payload = ClientMessageEncoder.encode(message)
            #expect(
                payload.first == UInt8(index),
                "tag \(payload.first ?? 0xFF) for \(message) at index \(index)"
            )
            #expect(message.tag == UInt64(index))
        }
        // The last variant is also the one the tag table used to get wrong:
        // `endpointControl` (20), not `clientShellHello` (11).
        #expect(Array(ClientMessageEncoder.encode(.endpointControl(kind: "", data: ""))) == [20, 0, 0])
    }
}

@Suite("Independent wire shape")
struct IndependentWireShapeTests {
    /// A `Key` event with every optional and Windows-only field populated,
    /// asserted against a hand-written positional byte table. This is the one
    /// message where a single swapped optional flips meaning without any decode
    /// error, and the field list is long enough that a mechanical translation
    /// from Rust is easy to get subtly wrong.
    @Test("a fully populated key event matches the handmade layout")
    func semanticKeyEvent() {
        let event = ClientPaneInputEvent.key(
            code: .char("a"),
            modifiers: 6,
            kind: .repeat,
            repeatCount: 2,
            shiftedCodepoint: 65,
            generatedText: "A",
            tracksRelease: true,
            physicalKeyId: 30,
            windowsRecord: WindowsKeyRecord(
                keyDown: true,
                repeatCount: 2,
                virtualKeyCode: 65,
                virtualScanCode: 30,
                unicode: 65,
                controlKeyState: 8
            )
        )
        let payload = ClientMessageEncoder.encode(
            .clientShellPaneInput(paneId: "w1:p1", events: [event])
        )
        let expected: [UInt8] = [
            13, // client_shell_pane_input
            5, 0x77, 0x31, 0x3A, 0x70, 0x31, // "w1:p1"
            1, // one event
            0, // InputEvent::Key
            15, 0x61, // key code tag 15 = Char('a')
            6, // modifiers
            1, // ClientKeyKind::Repeat
            2, // repeat count
            1, 65, // shifted codepoint: Some(65)
            1, 1, 0x41, // generated text: Some("A")
            1, // tracks release
            1, 30, // physical key id: Some(30)
            1, // windows record: Some(..)
            1, // key down
            2, // repeat count
            65, // virtual key code
            30, // virtual scan code
            65, // unicode
            8, // control key state
        ]
        #expect(Array(payload) == expected)
    }

    /// `u8` fields are one raw byte. The 4 `modifiers` fields and
    /// `ClientKeyCode.function(u8)` only ever carry small values, so a varint
    /// there is invisible — but `AttachScrollSource.pageKey` carries arbitrary
    /// bytes, and `0xFF` is where the two encodings diverge (raw `FF` vs
    /// `251 FF 00`). This is the one input that can actually catch it.
    @Test("page-key scroll input keeps raw u8 bytes")
    func pageKeyRawBytes() {
        let payload = ClientMessageEncoder.encode(
            .attachScroll(
                source: .pageKey(input: [0xFF, 0x00, 0xFA]),
                direction: .downward,
                lines: 3,
                column: 7,
                row: nil,
                modifiers: 0xFF
            )
        )
        let expected: [UInt8] = [
            6, // attach_scroll
            1, // AttachScrollSource::PageKey
            3, // input length
            0xFF, 0x00, 0xFA, // the three raw bytes
            1, // direction: Downward
            3, // lines
            1, 7, // column: Some(7)
            0, // row: None
            0xFF, // modifiers
        ]
        #expect(Array(payload) == expected, "encoded \(Array(payload))")
    }

    @Test("resize and endpoint-request layouts are frozen")
    func smallLayouts() {
        let resize = ClientMessageEncoder.encode(
            .clientShellResize(
                cellWidthPx: 8,
                cellHeightPx: 16,
                surfaceSize: ClientSurfaceSize(cols: 80, rows: 24),
                pixelMouse: false
            )
        )
        #expect(Array(resize) == [12, 8, 16, 80, 24, 0])

        let request = ClientMessageEncoder.encode(
            .clientShellEndpointRequest(bootId: "b", request: "{}")
        )
        #expect(Array(request) == [15, 1, 0x62, 2, 0x7B, 0x7D])
    }

    /// Field order inside `PaneSurface`, checked on the decode side against a
    /// payload assembled by hand: boot id, projection revision, surface
    /// revision, frame(cells, width, height, cursor, hyperlinks, graphics),
    /// panes, splits, popup, graphics scene.
    @Test("a hand-built surface payload decodes field for field")
    func surfaceFieldOrder() throws {
        var writer = BincodeWriter()
        writer.writeVarint(13)
        writer.writeString("boot")
        writer.writeVarint(7)
        writer.writeVarint(1)
        // frame.cells (flat on the wire; `CellBuffer` on our side)
        writer.writeVarint(1)
        writer.writeString("x")
        writer.writeVarint(0x0212_3456)
        writer.writeVarint(0x0100_00FF)
        writer.writeVarint(5)
        writer.writeBool(false)
        writer.writeBool(false) // no hyperlink
        writer.writeVarint(1) // width
        writer.writeVarint(1) // height
        writer.writeBool(true) // cursor: Some
        writer.writeVarint(0) // column
        writer.writeVarint(0) // row
        writer.writeBool(true) // visible
        writer.writeVarint(6) // shape
        // hyperlinks
        writer.writeVarint(1)
        writer.writeString("https://herdr.dev")
        // graphics bytes
        writer.writeVarint(0)
        // panes, splits, popup
        writer.writeVarint(0)
        writer.writeVarint(0)
        writer.writeBool(false)
        // graphics scene: assets, placements, retained
        writer.writeVarint(0)
        writer.writeVarint(0)
        writer.writeVarint(0)

        guard case let .paneSurface(surface) = try ServerMessageDecoder.decode(Data(writer.bytes)) else {
            Issue.record("expected a PaneSurface")
            return
        }
        #expect(surface.bootId == "boot")
        #expect(surface.projectionRevision == 7)
        #expect(surface.surfaceRevision == 1)
        #expect(surface.frame.width == 1)
        #expect(surface.frame.height == 1)
        #expect(surface.frame.buffer.count == 1)
        #expect(surface.frame.buffer[0].symbol == "x")
        #expect(surface.frame.buffer[0].foreground == 0x0212_3456)
        #expect(surface.frame.buffer[0].background == 0x0100_00FF)
        #expect(surface.frame.buffer[0].modifier == 5)
        #expect(surface.frame.cursor?.shape == 6)
        #expect(surface.frame.hyperlinks == ["https://herdr.dev"])
        #expect(surface.panes.isEmpty)
        #expect(surface.splits.isEmpty)
        #expect(surface.popup == nil)
    }
}

@Suite("Host theme encoding")
struct HostThemeEncodingTests {
    /// Ported from `herdr-gpui/.../tests/host_theme.rs`. The expected bytes are
    /// hand-written bincode, not derived from this encoder.
    ///
    /// bincode writes `u8` fields as one raw byte (only integers wider than 8
    /// bits get the varint treatment). This was red until #4 fixed
    /// `encodeHostTheme` to use `writeU8`; it now guards that encoding.
    @Test("each update variant matches the handmade layout")
    func hostThemeLayout() {
        let color = ClientHostColor(red: 0x2E, green: 0x34, blue: 0x40)
        let cases: [(ClientHostThemeUpdate, [UInt8])] = [
            (
                .defaultColor(kind: .foreground, color: color),
                [17, 0, 0, 0x2E, 0x34, 0x40]
            ),
            (
                .defaultColor(kind: .background, color: color),
                [17, 0, 1, 0x2E, 0x34, 0x40]
            ),
            (
                .paletteColors([
                    PaletteColor(index: 4, color: color),
                    PaletteColor(index: 255, color: ClientHostColor(red: 1, green: 2, blue: 3)),
                ]),
                [17, 1, 2, 4, 0x2E, 0x34, 0x40, 255, 1, 2, 3]
            ),
            (.appearance(.dark), [17, 2, 0]),
            (.appearance(.light), [17, 2, 1]),
        ]
        for (update, expected) in cases {
            let payload = ClientMessageEncoder.encode(.clientShellHostTheme(update: update))
            #expect(Array(payload) == expected, "\(update) encoded \(Array(payload))")
        }
    }

    /// `u8` fields are one raw byte in bincode; only integers wider than 8 bits
    /// are varints. Palette indices and colour components above 250 are the only
    /// places that difference is observable, so this is the smallest input that
    /// separates them.
    @Test("colour bytes above 250 stay single bytes")
    func wideColorBytes() {
        let payload = ClientMessageEncoder.encode(
            .clientShellHostTheme(update: .defaultColor(
                kind: .background,
                color: ClientHostColor(red: 255, green: 254, blue: 251)
            ))
        )
        #expect(Array(payload) == [17, 0, 1, 255, 254, 251])
    }

    /// 256 palette entries cross the `250` varint boundary, so the *array
    /// length* switches to the three-byte form — while each entry stays 4 raw
    /// bytes (index + r + g + b). Getting that backwards either truncates the
    /// last colours or shifts every entry after index 250.
    @Test("a full palette fits one frame with a varint length")
    func fullPalette() {
        let colors = (0 ... 255).map { index in
            PaletteColor(
                index: UInt8(index),
                color: ClientHostColor(red: UInt8(index), green: 0, blue: 0)
            )
        }
        let payload = ClientMessageEncoder.encode(
            .clientShellHostTheme(update: .paletteColors(colors))
        )
        #expect(Array(payload.prefix(5)) == [17, 1, 251, 0, 1])
        #expect(payload.count == 5 + 256 * 4)
    }
}

@Suite("Clipboard image envelope")
struct ClipboardImageEnvelopeTests {
    /// Ported from `herdr-gpui/.../tests/clipboard.rs`. The fixture is a
    /// hand-written bincode payload, cross-checked against a real PNG header.
    @Test("a pane-targeted image keeps field and variant order")
    func paneTargetLayout() {
        let payload = ClientMessageEncoder.encode(
            .clipboardImage(
                target: .pane("p1"),
                extension: "png",
                data: Data([137, 80, 78, 71, 13])
            )
        )
        #expect(Array(payload) == [
            2, 1, 2, 0x70, 0x31, 3, 0x70, 0x6E, 0x67, 5, 137, 80, 78, 71, 13,
        ])
    }

    /// Target tags are 0 (direct terminal), 1 (pane), 2 (popup). A swap would
    /// paste an image into the wrong surface with no error.
    @Test("each clipboard target has its own tag")
    func targetTags() {
        let cases: [(ClientClipboardImageTarget, UInt8)] = [
            (.directTerminal, 0),
            (.pane("p1"), 1),
            (.popup("t1"), 2),
        ]
        for (target, tag) in cases {
            let payload = ClientMessageEncoder.encode(
                .clipboardImage(target: target, extension: "png", data: Data([137]))
            )
            #expect(Array(payload.prefix(2)) == [2, tag], "\(target)")
        }
    }
}
