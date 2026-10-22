// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import Testing

@testable import KraalProtocol

/// Fixtures are real captures (see `research/06_capture_fixtures.py`): they are
/// the only thing here that was produced by the daemon rather than by us, so
/// they are what pins the wire contract.
enum Fixture {
    static func data(_ name: String) throws -> Data {
        // Copied as a `Fixtures` directory resource, so the file lives one
        // level down from the bundle root.
        let url = Bundle.module.url(forResource: name, withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        guard let url else { throw FixtureError.missing(name) }
        return try Data(contentsOf: url)
    }

    static func string(_ name: String) throws -> String {
        try String(bytes: data(name), encoding: .utf8) ?? ""
    }

    enum FixtureError: Error { case missing(String) }
}

@Suite("Bincode primitives")
struct BincodeTests {
    @Test("varint encodes the documented boundaries")
    func varintBoundaries() {
        var writer = BincodeWriter()

        writer.writeVarint(0)
        #expect(writer.bytes == [0x00])

        writer = BincodeWriter()
        writer.writeVarint(250)
        #expect(writer.bytes == [0xFA])

        writer = BincodeWriter()
        writer.writeVarint(251)
        #expect(writer.bytes == [0xFB, 0xFB, 0x00])

        writer = BincodeWriter()
        writer.writeVarint(0xFFFF)
        #expect(writer.bytes == [0xFB, 0xFF, 0xFF])

        writer = BincodeWriter()
        writer.writeVarint(0x1_0000)
        #expect(writer.bytes == [0xFC, 0x00, 0x00, 0x01, 0x00])

        writer = BincodeWriter()
        writer.writeVarint(0xFFFF_FFFF)
        #expect(writer.bytes == [0xFC, 0xFF, 0xFF, 0xFF, 0xFF])

        writer = BincodeWriter()
        writer.writeVarint(0x1_0000_0000)
        #expect(writer.bytes == [0xFD, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00])
    }

    @Test("varint round-trips", arguments: [0, 1, 249, 250, 251, 65_535, 65_536] as [UInt64])
    func varintRoundTrip(value: UInt64) throws {
        var writer = BincodeWriter()
        writer.writeVarint(value)
        var reader = BincodeReader(Data(writer.bytes))
        #expect(try reader.readVarint() == value)
        #expect(reader.isAtEnd)
    }

    @Test("a u8 is one raw byte, not a varint")
    func u8IsRawByte() {
        // bincode only variable-length-encodes integers wider than 8 bits. The
        // two encodings agree for 0...250, so the difference is only observable
        // at the top of the range — which is exactly where the host-theme
        // palette lives (index 255, pure white 255/255/255).
        var writer = BincodeWriter()
        writer.writeU8(0)
        writer.writeU8(250)
        writer.writeU8(251)
        writer.writeU8(255)
        #expect(writer.bytes == [0x00, 0xFA, 0xFB, 0xFF])

        // The same values through writeVarint grow past 250. Pinned here so a
        // future "helpful" refactor cannot quietly re-widen these fields.
        var varint = BincodeWriter()
        for value in [UInt8(251), 255] {
            varint.writeVarint(UInt64(value))
        }
        #expect(varint.bytes == [0xFB, 0xFB, 0x00, 0xFB, 0xFF, 0x00])
    }

    @Test("writeU8 round-trips through readU8")
    func u8RoundTrip() throws {
        var writer = BincodeWriter()
        for value in [UInt8(0), 1, 249, 250, 251, 254, 255] {
            writer.writeU8(value)
        }
        var reader = BincodeReader(Data(writer.bytes))
        for value in [UInt8(0), 1, 249, 250, 251, 254, 255] {
            #expect(try reader.readU8() == value)
        }
        #expect(reader.isAtEnd)
    }

    @Test("a truncated payload throws instead of reading past the end")
    func truncated() {
        var reader = BincodeReader(Data([0xFB, 0x01]))
        #expect(throws: BincodeError.self) { try reader.readVarint() }
    }

    @Test("an array length larger than the payload is rejected before allocating")
    func arrayLengthGuard() {
        // Claims 255 elements but carries none.
        var reader = BincodeReader(Data([0xFA]))
        #expect(throws: BincodeError.self) {
            try reader.readArray { try $0.readU8() }
        }
    }

    @Test("strings round-trip including multi-byte scalars")
    func stringRoundTrip() throws {
        let original = "中文测试 ＡＢＣ 🐑"
        var writer = BincodeWriter()
        writer.writeString(original)
        var reader = BincodeReader(Data(writer.bytes))
        #expect(try reader.readString() == original)
    }
}

@Suite("Framing")
struct FrameTests {
    @Test("frames survive arbitrary chunk boundaries")
    func chunkedDecode() throws {
        var decoder = FrameDecoder()
        let first = try FrameEncoder.encode(Data([1, 2, 3]))
        let second = try FrameEncoder.encode(Data([4, 5]))

        // Byte-at-a-time feeding: the decoder must not assume whole frames.
        var frames: [Data] = []
        for byte in first + second {
            frames.append(contentsOf: try decoder.append(Data([byte])))
        }
        #expect(frames == [Data([1, 2, 3]), Data([4, 5])])
        #expect(decoder.pendingByteCount == 0)
    }

    @Test("the length prefix is u32 little endian")
    func lengthPrefixLayout() throws {
        let encoded = try FrameEncoder.encode(Data(repeating: 0xAA, count: 3))
        #expect(Array(encoded.prefix(5)) == [0x03, 0x00, 0x00, 0x00, 0xAA])
    }

    @Test("oversized frames are refused")
    func oversized() {
        let payload = Data(repeating: 0, count: 32)
        #expect(throws: FrameError.self) {
            try FrameEncoder.encode(payload, limit: 16)
        }
    }

    @Test("an empty frame is refused")
    func empty() {
        #expect(throws: FrameError.self) { try FrameEncoder.encode(Data(), limit: 16) }
    }
}

@Suite("Fixture: PaneSurface")
struct SurfaceFixtureTests {
    /// 120×40 surface captured from a real daemon. This is the test that says
    /// the hand-written decoder agrees with the Rust encoder byte for byte.
    @Test("decodes 4800 cells with the expected geometry")
    func geometry() throws {
        let raw = try Fixture.data("surface_120x40.bin")
        let message = try ServerMessageDecoder.decode(raw)
        guard case let .paneSurface(surface) = message else {
            Issue.record("expected PaneSurface, got \(message.tag)")
            return
        }

        #expect(surface.frame.width == 120)
        #expect(surface.frame.height == 40)
        #expect(surface.frame.cells.count == 4800)
        #expect(surface.panes.count == 1)
        #expect(try surface.validateSucceeds())

        let pane = try #require(surface.panes.first)
        #expect(pane.paneId == "wP:p9")
        #expect(pane.rect == SurfaceRect(originX: 0, originY: 0, width: 120, height: 40))
        #expect(pane.innerRect == SurfaceRect(originX: 0, originY: 0, width: 119, height: 40))
        #expect(pane.focused)
        #expect(pane.pixelWidth == 1190)
        #expect(pane.pixelHeight == 800)
        #expect(surface.frame.cursor?.visible == true)
    }

    @Test("the text projection matches the captured reference line for line")
    func textMatchesReference() throws {
        let raw = try Fixture.data("surface_120x40.bin")
        guard case let .paneSurface(surface) = try ServerMessageDecoder.decode(raw) else {
            Issue.record("expected PaneSurface")
            return
        }

        let expected = try Fixture.string("surface_120x40.txt")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        let actual = SurfaceText.lines(surface.frame).map {
            $0.trimmingCharacters(in: .whitespaces)
        }

        #expect(actual.count == 40)
        for (row, (got, want)) in zip(actual, expected).enumerated() {
            #expect(got == want, "row \(row): \(got.debugDescription) != \(want.debugDescription)")
        }
    }

    @Test("wide glyphs keep column alignment")
    func wideGlyphColumns() throws {
        let raw = try Fixture.data("surface_120x40.bin")
        guard case let .paneSurface(surface) = try ServerMessageDecoder.decode(raw) else {
            Issue.record("expected PaneSurface")
            return
        }
        // Row 3 of the fixture is "wide: 中文测试 ＡＢＣ".
        let columns = SurfaceText.columns(surface.frame, row: 3)
        #expect(columns.count == 120)
        #expect(columns[6] == "中")
        // The column after a wide glyph is a continuation: empty, not a space.
        #expect(columns[7] == "")
        #expect(SurfaceText.line(surface.frame, row: 3).hasPrefix("wide: 中文测试 ＡＢＣ"))
    }

    @Test("cell colors decode from the non-ARGB encoding")
    func cellColors() throws {
        let raw = try Fixture.data("surface_120x40.bin")
        guard case let .paneSurface(surface) = try ServerMessageDecoder.decode(raw) else {
            Issue.record("expected PaneSurface")
            return
        }
        // Row 1 is "colors: red green bold" with explicit 256-color attributes.
        let red = try #require(surface.frame[8, 1])
        #expect(red.symbol == "r")
        #expect(TerminalColor(raw: red.foreground) == .indexed(1))

        let green = try #require(surface.frame[12, 1])
        #expect(green.symbol == "g")
        #expect(TerminalColor(raw: green.foreground) == .indexed(2))
    }
}

private extension PaneSurfaceFrame {
    /// Small adapter so a `#expect` can assert "validates cleanly".
    func validateSucceeds() throws -> Bool {
        try validate()
        return true
    }
}

@Suite("Fixture: welcome")
struct WelcomeFixtureTests {
    @Test("decodes the captured welcome and finds the daemon compatible")
    func decode() throws {
        let json = try Fixture.string("welcome.json")
        let welcome = try JSONDecoder().decode(
            EndpointServerWelcome.self,
            from: Data(json.utf8)
        )
        #expect(welcome.generation == 1)
        #expect(welcome.serverVersion == "0.9.4")
        #expect(welcome.snapshotCodec == "shell.snapshot.v1")
        #expect(welcome.methods.contains("tab.create"))
        #expect(welcome.capabilities.contains("health_check"))
        #expect(Compatibility.evaluate(welcome) == .compatible)
    }

    @Test("a newer generation is refused with a client-too-old reason")
    func newerGeneration() throws {
        var welcome = try JSONDecoder().decode(
            EndpointServerWelcome.self,
            from: Data(try Fixture.string("welcome.json").utf8)
        )
        welcome.generation = 2
        #expect(
            Compatibility.evaluate(welcome)
                == .clientTooOld(serverVersion: "0.9.4", generation: 2)
        )
    }

    @Test("a daemon without the surface capability is refused")
    func missingCapability() throws {
        var welcome = try JSONDecoder().decode(
            EndpointServerWelcome.self,
            from: Data(try Fixture.string("welcome.json").utf8)
        )
        welcome.capabilities = ["surface_reuse"]
        #expect(Compatibility.evaluate(welcome) == .missingCapability("surface_interest"))
    }
}

@Suite("Daemon version floor")
struct DaemonVersionTests {
    /// Only the numeric prefix is compared; forks and build metadata must not be
    /// locked out. `0.9.0-rootshell.0.1.2` is a real downstream version string.
    @Test("parses the shapes a real server_version takes")
    func parsesRealStrings() throws {
        let cases: [(String, DaemonVersion)] = [
            ("0.9.4", DaemonVersion(major: 0, minor: 9, patch: 4)),
            ("0.9.0", DaemonVersion(major: 0, minor: 9, patch: 0)),
            ("1.0.0+build.7", DaemonVersion(major: 1, minor: 0, patch: 0)),
            ("0.9.0-rootshell.0.1.2", DaemonVersion(major: 0, minor: 9, patch: 0)),
            ("0.9", DaemonVersion(major: 0, minor: 9, patch: 0)),
            (" 0.9.5 ", DaemonVersion(major: 0, minor: 9, patch: 5)),
        ]
        for (raw, expected) in cases {
            #expect(try DaemonVersion.parse(raw).get() == expected, "\(raw)")
        }
    }

    /// Unparsable input fails instead of defaulting to 0.0.0 — a daemon that
    /// cannot say what it is must be refused, not trusted.
    @Test("refuses to guess at an unreadable version")
    func refusesGarbage() {
        for raw in ["not-a-version", "", "v0.9.0", "0", "...", "1.x.0"] {
            #expect(
                (try? DaemonVersion.parse(raw).get()) == nil,
                "\(raw) was accepted"
            )
        }
    }

    @Test("orders by major, then minor, then patch")
    func ordering() {
        let sorted = ["0.9.10", "1.0.0", "0.10.0", "0.9.2"]
            .compactMap { try? DaemonVersion.parse($0).get() }
            .sorted()
            .map(\.description)
        #expect(sorted == ["0.9.2", "0.9.10", "0.10.0", "1.0.0"])
    }
}

@Suite("Surface patch invariants")
struct SurfacePatchTests {
    private func baseline(revision: UInt64 = 7) -> PaneSurfaceFrame {
        let cells = (0 ..< 4).map { _ in CellData.blank }
        return PaneSurfaceFrame(
            bootId: "boot-a",
            projectionRevision: 3,
            surfaceRevision: revision,
            frame: FrameData(
                cells: cells,
                width: 2,
                height: 2,
                cursor: CursorState(column: 0, row: 0, visible: true, shape: 0),
                hyperlinks: [],
                graphics: Data()
            ),
            panes: [],
            splits: [],
            popup: nil,
            graphics: SurfaceGraphicsScene()
        )
    }

    private func patch(
        base: UInt64 = 7,
        next: UInt64 = 8,
        boot: String = "boot-a",
        projection: UInt64 = 3
    ) -> PaneSurfacePatch {
        PaneSurfacePatch(
            bootId: boot,
            projectionRevision: projection,
            baseSurfaceRevision: base,
            surfaceRevision: next,
            rows: [
                PaneSurfacePatchRow(
                    column: 0,
                    row: 1,
                    cells: [
                        CellData(
                            symbol: "X",
                            foreground: 0,
                            background: 0,
                            modifier: 0,
                            skip: false,
                            hyperlink: nil
                        ),
                        CellData(
                            symbol: "Y",
                            foreground: 0,
                            background: 0,
                            modifier: 0,
                            skip: false,
                            hyperlink: nil
                        ),
                    ]
                ),
            ],
            panes: [],
            cursor: CursorState(column: 1, row: 1, visible: true, shape: 0)
        )
    }

    @Test("a valid patch replaces the row and advances the revision")
    func applies() throws {
        var surface = baseline()
        try surface.apply(patch())
        #expect(surface.surfaceRevision == 8)
        #expect(surface.frame.cells[2].symbol == "X")
        #expect(surface.frame.cells[3].symbol == "Y")
        #expect(surface.frame.cells[0].symbol == " ")
        #expect(surface.frame.cursor?.column == 1)
    }

    @Test("a revision gap is rejected and leaves the frame untouched")
    func revisionGap() {
        var surface = baseline()
        let before = surface
        #expect(throws: SurfaceError.patchIdentity) {
            try surface.apply(patch(base: 6, next: 8))
        }
        #expect(surface == before)
    }

    @Test("a foreign boot id is rejected")
    func bootMismatch() {
        var surface = baseline()
        #expect(throws: SurfaceError.patchIdentity) {
            try surface.apply(patch(boot: "boot-b"))
        }
    }

    @Test("a projection change is rejected")
    func projectionMismatch() {
        var surface = baseline()
        #expect(throws: SurfaceError.patchIdentity) {
            try surface.apply(patch(projection: 4))
        }
    }

    @Test("a row that runs past the frame is rejected")
    func rowBounds() {
        var surface = baseline()
        var overflowing = patch()
        overflowing.rows = [
            PaneSurfacePatchRow(column: 1, row: 0, cells: [.blank, .blank]),
        ]
        #expect(throws: SurfaceError.patchRowBounds) {
            try surface.apply(overflowing)
        }
    }
}

@Suite("Client message encoding")
struct ClientMessageEncodingTests {
    @Test("EndpointControl is tag 20, not 11")
    func endpointControlTag() throws {
        let payload = ClientMessageEncoder.encode(
            .endpointControl(kind: "endpoint.hello.v1", data: "{}")
        )
        #expect(payload.first == 20)
    }

    @Test("the hello JSON matches the daemon's field names")
    func helloJSON() throws {
        let hello = EndpointClientHello(cols: 120, rows: 40)
        let data = try JSONEncoder().encode(hello)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["generation"] as? Int == 1)
        #expect(object["snapshot_codecs"] as? [String] == ["shell.snapshot.v1"])
        #expect(object["surface_active"] as? Bool == true)
        #expect(object["surface_delta"] as? Bool == false)
        let size = try #require(object["surface_size"] as? [String: Any])
        #expect(size["cols"] as? Int == 120)
        #expect(size["rows"] as? Int == 40)
    }

    @Test("a typed-character event encodes as TextCommit (tag 1)")
    func textCommit() {
        let event = ClientPaneInputEvent.typed("λ")
        let payload = ClientMessageEncoder.encode(
            .clientShellPaneInput(paneId: "w1:p1", events: [event])
        )
        // tag 13 | string len 5 "w1:p1" | event count 1 | event tag 1 | "λ"
        #expect(Array(payload.prefix(2)) == [13, 5])
        #expect(payload.last == 0xBB) // UTF-8 second byte of λ
    }

    /// The resize path a window drag uses. Field order is positional on the wire,
    /// so a reordering would silently make the daemon render a different grid
    /// (here: columns and rows swapped) rather than fail loudly.
    @Test("ClientShellResize is tag 12 with cell size before the grid")
    func clientShellResize() {
        let payload = ClientMessageEncoder.encode(
            .clientShellResize(
                cellWidthPx: 17,
                cellHeightPx: 37,
                surfaceSize: ClientSurfaceSize(cols: 92, rows: 36),
                pixelMouse: false
            )
        )
        #expect(Array(payload) == [12, 17, 37, 92, 36, 0])
    }

    @Test("a right-button press encodes as mouse kind 0 with button 1")
    func rightButtonPress() {
        let event = ClientPaneInputEvent.mouse(
            kind: .press(.right),
            position: .cell(column: 3, row: 4),
            geometry: nil,
            modifiers: 0,
            lines: 0
        )
        let payload = ClientMessageEncoder.encode(
            .clientShellPaneInput(paneId: "p", events: [event])
        )
        // tag 13 | "p" | 1 event | mouse(2) | press(0) | right(1)
        // | cell(0) | col 3 | row 4 | no geometry | mods 0 | lines 0
        #expect(Array(payload) == [13, 1, 0x70, 1, 2, 0, 1, 0, 3, 4, 0, 0, 0])
    }

    /// Issue #20: pasted text was sent as keystrokes, so every newline arrived as
    /// Enter and a three-line paste ran three commands. The wire already has a
    /// dedicated paste event; this pins that it is tag 3 and carries the text as
    /// one unit, newlines included.
    @Test("paste encodes as its own event, not as text commits")
    func pasteEvent() {
        let payload = ClientMessageEncoder.encode(
            .clientShellPaneInput(paneId: "p", events: [.paste("a\nb\n")])
        )
        // tag 13 | "p" | 1 event | paste(3) | len 4 | "a\nb\n"
        #expect(Array(payload) == [13, 1, 0x70, 1, 3, 4, 0x61, 0x0A, 0x62, 0x0A])
    }

    /// A popup's keystrokes go out as tag 14, addressed by *terminal id*, not as
    /// tag 13 addressed by pane id.
    ///
    /// The distinction is the whole feature. `tag 13` names a pane, and there is no
    /// pane for a popup — sending these there would type them into whatever is
    /// focused underneath the popup. The encoder has carried tag 14 all along; no
    /// caller ever sent it, so nothing pinned what the bytes look like.
    @Test("popup input encodes as tag 14 with the terminal id")
    func popupInputEvent() {
        let payload = ClientMessageEncoder.encode(
            .clientShellPopupInput(terminalId: "t1", events: [.paste("hi")])
        )
        // tag 14 | "t1" | 1 event | paste(3) | len 2 | "hi"
        #expect(Array(payload) == [14, 2, 0x74, 0x31, 1, 3, 2, 0x68, 0x69])
    }

    /// Why the contrast is worth stating: the decoder coalesces runs of text into
    /// one `textCommit`, so sending a paste as bytes does *not* produce a
    /// per-character event stream on this side. The damage happens at the daemon:
    /// a `textCommit` is typed into the program, newline by newline, whereas
    /// `paste` tells it the text arrived as a unit. That difference is visible in
    /// the tag (1 vs 3) — which the test above pins — not in the event count here.
    @Test("pasted text decoded as input collapses into one text commit")
    func textIsCoalesced() {
        var decoder = TerminalInputDecoder()
        let events = decoder.decode(Data("a\nb\n".utf8))
        #expect(events.count == 1)
        guard case let .textCommit(text) = events.first else {
            Issue.record("expected a text commit, got \(events)")
            return
        }
        #expect(text == "a\nb\n")
    }
}

@Suite("Text projection")
struct SurfaceTextTests {
    @Test("a blank frame projects to blank lines")
    func blankFrame() {
        let frame = FrameData(
            cells: Array(repeating: .blank, count: 9),
            width: 3,
            height: 3,
            cursor: nil,
            hyperlinks: [],
            graphics: Data()
        )
        #expect(SurfaceText.lines(frame) == ["   ", "   ", "   "])
    }

    @Test("a wide glyph consumes the following column")
    func wideGlyph() {
        var cells = Array(repeating: CellData.blank, count: 4)
        cells[0] = CellData(
            symbol: "中",
            foreground: 0,
            background: 0,
            modifier: 0,
            skip: false,
            hyperlink: nil
        )
        cells[1] = CellData(
            symbol: "",
            foreground: 0,
            background: 0,
            modifier: 0,
            skip: true,
            hyperlink: nil
        )
        cells[2] = CellData(
            symbol: "a",
            foreground: 0,
            background: 0,
            modifier: 0,
            skip: false,
            hyperlink: nil
        )
        let frame = FrameData(
            cells: cells,
            width: 4,
            height: 1,
            cursor: nil,
            hyperlinks: [],
            graphics: Data()
        )
        #expect(SurfaceText.columns(frame, row: 0) == ["中", "", "a", " "])
        #expect(SurfaceText.line(frame, row: 0) == "中a ")
    }
}

@Suite("Terminal input decoding")
struct TerminalInputDecoderTests {
    private func codes(_ events: [ClientPaneInputEvent]) -> [String] {
        events.map { event in
            switch event {
            case let .textCommit(text): "text(\(text))"
            case let .paste(text): "paste(\(text))"
            case let .key(code, modifiers, _, _, _, _, _, _, _):
                "key(\(code), m\(modifiers))"
            case let .mouse(kind, _, _, _, _): "mouse(\(kind))"
            }
        }
    }

    @Test("printable runs become one TextCommit")
    func printable() {
        var decoder = TerminalInputDecoder()
        let events = decoder.decode(Data("echo hi".utf8))
        #expect(codes(events) == ["text(echo hi)"])
    }

    @Test("multi-byte UTF-8 survives splitting across writes")
    func splitUTF8() {
        var decoder = TerminalInputDecoder()
        let bytes = Array("中".utf8) // e4 b8 ad
        let first = decoder.decode(Data(bytes.prefix(1)))
        #expect(first.isEmpty, "an incomplete scalar must not emit")
        let second = decoder.decode(Data(bytes.dropFirst(1)))
        #expect(codes(second) == ["text(中)"])
    }

    @Test("control bytes map to their key codes")
    func controlKeys() {
        var decoder = TerminalInputDecoder()
        let events = decoder.decode(Data([0x0D, 0x09, 0x7F]))
        #expect(codes(events) == ["key(enter, m0)", "key(tab, m0)", "key(backspace, m0)"])
    }

    @Test("Ctrl-A..Ctrl-Z carry the control modifier")
    func controlModifier() {
        var decoder = TerminalInputDecoder()
        let events = decoder.decode(Data([0x03])) // Ctrl-C
        #expect(codes(events) == ["key(char(\"c\"), m2)"])
    }

    @Test("arrow keys decode from CSI sequences")
    func arrows() {
        var decoder = TerminalInputDecoder()
        let events = decoder.decode(Data([0x1B, 0x5B, 0x41, 0x1B, 0x5B, 0x42]))
        #expect(codes(events) == ["key(arrowUp, m0)", "key(arrowDown, m0)"])
    }

    @Test("SS3 arrows decode too")
    func ss3Arrows() {
        var decoder = TerminalInputDecoder()
        let events = decoder.decode(Data([0x1B, 0x4F, 0x43]))
        #expect(codes(events) == ["key(arrowRight, m0)"])
    }

    @Test("an escape sequence split across writes is held until complete")
    func splitSequence() {
        var decoder = TerminalInputDecoder()
        let partial = decoder.decode(Data([0x1B, 0x5B]))
        #expect(partial.isEmpty)
        let complete = decoder.decode(Data([0x43]))
        #expect(codes(complete) == ["key(arrowRight, m0)"])
    }

    @Test("a lone Esc is flushed when the stream idles")
    func loneEscape() {
        var decoder = TerminalInputDecoder()
        #expect(decoder.decode(Data([0x1B])).isEmpty)
        let flushed = decoder.flushEscape()
        #expect(flushed != nil)
        #expect(decoder.flushEscape() == nil)
    }

    @Test("Alt-modified characters carry the alt modifier")
    func altKey() {
        var decoder = TerminalInputDecoder()
        let events = decoder.decode(Data([0x1B, 0x62])) // ESC b
        #expect(codes(events) == ["key(char(\"b\"), m4)"])
    }

    @Test("xterm modifiers translate to wire modifier bits")
    func xtermModifiers() {
        // ESC [ 1;5 A is Ctrl-Up.
        var decoder = TerminalInputDecoder()
        let events = decoder.decode(Data([0x1B, 0x5B, 0x31, 0x3B, 0x35, 0x41]))
        #expect(codes(events) == ["key(arrowUp, m2)"])
        // xterm: 2 = shift, 3 = alt, 5 = ctrl; 1 means "no modifier".
        #expect(TerminalInputDecoder.modifiers(fromXterm: 1) == 0)
        #expect(TerminalInputDecoder.modifiers(fromXterm: 2) == InputModifiers.shift.rawValue)
        #expect(TerminalInputDecoder.modifiers(fromXterm: 3) == InputModifiers.alt.rawValue)
        #expect(TerminalInputDecoder.modifiers(fromXterm: 5) == InputModifiers.control.rawValue)
    }

    @Test("delete and paging keys decode from tilde sequences")
    func tildeKeys() {
        var decoder = TerminalInputDecoder()
        let events = decoder.decode(Data([
            0x1B, 0x5B, 0x33, 0x7E, // DEL
            0x1B, 0x5B, 0x35, 0x7E, // PGUP
            0x1B, 0x5B, 0x36, 0x7E, // PGDN
        ]))
        #expect(codes(events) == ["key(delete, m0)", "key(pageUp, m0)", "key(pageDown, m0)"])
    }

    /// Issue #20: SS3 was parsed as exactly three bytes with the modifier
    /// hard-wired to 0, so `ESC O 1;5 P` (F1 with Ctrl, what a terminal sends when
    /// modifyOtherKeys is on) decoded the `1` as the final byte and left `;5 P` to
    /// be typed into the pane as literal text. Both halves are asserted: the key
    /// event must be right, and nothing may be left over.
    @Test("SS3 sequences carry their modifier parameter")
    func ss3Modifiers() {
        var decoder = TerminalInputDecoder()
        // ESC O 1;5 P -> F1 with Ctrl.
        let events = decoder.decode(Data([0x1B, 0x4F, 0x31, 0x3B, 0x35, 0x50]))
        #expect(codes(events) == ["key(function(1), m2)"], "got \(codes(events))")
        // Nothing may remain to be typed as text.
        #expect(decoder.decode(Data()).isEmpty)

        // A bare SS3 sequence still means "no modifier": `ESC O P` has no
        // parameter at all, and `1` is xterm's way of writing "no modifier".
        for bytes: [UInt8] in [
            [0x1B, 0x4F, 0x50],
            [0x1B, 0x4F, 0x31, 0x3B, 0x31, 0x50],
        ] {
            var bare = TerminalInputDecoder()
            #expect(codes(bare.decode(Data(bytes))) == ["key(function(1), m0)"],
                    "bytes \(bytes)")
        }
        // Arrows take the parameter too.
        var arrow = TerminalInputDecoder()
        #expect(codes(arrow.decode(Data([0x1B, 0x4F, 0x31, 0x3B, 0x33, 0x44])))
            == ["key(arrowLeft, m4)"])
    }

    /// `tracksRelease` must stay false even when the program asked for every key.
    ///
    /// The tempting fix for issue #20 was to set it from the report-all flag, and
    /// that is wrong: the daemon *holds* a press whose `tracks_release` is true
    /// until the matching release arrives (`server/clients.rs:275-311`), and Kraal
    /// never emits releases. So the claim would make keys vanish. Upstream decides
    /// the field from the key itself (`protocol/wire.rs:315`), which needs release
    /// events this client does not produce yet.
    ///
    /// This test exists to stop that mistake from being made again — it pins the
    /// opposite of what it looks like it should.
    @Test("report-all-keys does not claim to track releases")
    func reportAllKeysDoesNotClaimReleases() {
        for reportAll in [false, true] {
            var decoder = TerminalInputDecoder()
            decoder.reportsAllKeys = reportAll
            let events = decoder.decode(Data([0x1B, 0x5B, 0x41])) // Up arrow
            #expect(events.count == 1)
            guard case let .key(_, _, kind, _, _, _, tracksRelease, _, _) = events.first else {
                Issue.record("expected a key event, got \(events)")
                return
            }
            #expect(!tracksRelease, "reportAll=\(reportAll) must not claim a release follows")
            #expect(kind == .press)
        }
    }

    @Test("function keys decode from both SS3 and CSI forms")
    func functionKeys() {
        var decoder = TerminalInputDecoder()
        let ss3 = decoder.decode(Data([0x1B, 0x4F, 0x50])) // F1
        #expect(codes(ss3) == ["key(function(1), m0)"])
        let csi = decoder.decode(Data([0x1B, 0x5B, 0x31, 0x35, 0x7E])) // F5
        #expect(codes(csi) == ["key(function(5), m0)"])
    }

    @Test("a buffer of junk cannot stall the decoder")
    func malformedByte() {
        var decoder = TerminalInputDecoder()
        let events = decoder.decode(Data([0xFF, 0x41]))
        // The malformed byte is dropped, the printable one survives.
        #expect(codes(events).contains("text(A)"))
    }
}
