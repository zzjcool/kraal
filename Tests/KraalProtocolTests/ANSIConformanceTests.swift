// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// ANSI re-encoding conformance, ported from the daemon's own renderer tests.
//
// Source: `herdr/src/protocol/render_ansi.rs` (`#[cfg(test)]`, 51 cases) at
// Herdr 0.9.1. The daemon renders a `PaneSurface` to a real terminal too, so its
// tests are the only place that says what the *correct* VT bytes are — our
// renderer has to agree with it cell for cell, or Kraal paints a screen Ghostty
// and the desktop client disagree about.
//
// Several of these are expected to fail: they are the port of the upstream
// expectations onto a renderer that has never been compared against them. RED
// HERE IS THE POINT — each failure is a concrete divergence, noted in the test's
// own comment.

import Foundation
import Testing

@testable import KraalProtocol

@Suite("Terminal color encoding")
struct TerminalColorEncodingTests {
    /// A cell with the given encoded colors and modifier, so `StyleCode` can be
    /// driven without a whole frame.
    private static func cell(
        foreground: UInt32 = 0,
        background: UInt32 = 0,
        modifier: UInt16 = 0
    ) -> CellData {
        CellData(
            symbol: "x",
            foreground: foreground,
            background: background,
            modifier: modifier,
            skip: false,
            hyperlink: nil
        )
    }

    /// `render_ansi.rs:1110` `color_to_sgr_fg_named_colors`.
    ///
    /// The daemon maps the 16 named palette entries onto SGR 30–37 / 90–97 — an
    /// explicit table, not the 256-colour index. issue #1 replaced the
    /// `38;5;<n>` fallback: `named(1)` is black and must be `30`; as `38;5;1` it
    /// was drawn as palette entry 1, which is red.
    @Test("named foreground colors use SGR 30-37 / 90-97")
    func namedForeground() {
        let cases: [(UInt32, String)] = [
            (0x0000_0000, "39"),
            (0x0000_0001, "30"),
            (0x0000_0002, "31"),
            (0x0000_0003, "32"),
            (0x0000_0004, "33"),
            (0x0000_0005, "34"),
            (0x0000_0006, "35"),
            (0x0000_0007, "36"),
            (0x0000_0008, "37"),
            (0x0000_0009, "90"),
            (0x0000_000A, "91"),
            (0x0000_0010, "97"),
        ]
        for (raw, expected) in cases {
            let code = StyleCode.encode(Self.cell(foreground: raw))
            #expect(code.contains(expected), "\(raw) -> \(code), expected \(expected)")
        }
    }

    /// `render_ansi.rs:1128` `color_to_sgr_bg_named_colors`: the background side
    /// is 40–47 / 100–107 with `49` as reset.
    @Test("named background colors use SGR 40-47 / 100-107")
    func namedBackground() {
        let cases: [(UInt32, String)] = [
            (0x0000_0000, "49"),
            (0x0000_0001, "40"),
            (0x0000_0002, "41"),
            (0x0000_0010, "107"),
        ]
        for (raw, expected) in cases {
            let code = StyleCode.encode(Self.cell(background: raw))
            #expect(code.contains(expected), "\(raw) -> \(code), expected \(expected)")
        }
    }

    /// `render_ansi.rs:1118` / `:1123` — indexed and RGB already match.
    @Test("indexed and RGB colors agree with the daemon")
    func indexedAndRGB() {
        #expect(
            StyleCode.encode(Self.cell(foreground: 0x0100_00AB)).contains("38;5;171")
        )
        #expect(
            StyleCode.encode(Self.cell(foreground: 0x02FF_8040)).contains("38;2;255;128;64")
        )
        #expect(
            StyleCode.encode(Self.cell(background: 0x02FF_8040)).contains("48;2;255;128;64")
        )
    }

    /// `render_ansi.rs:1194` `build_sgr_preserves_curly_underline_style`.
    ///
    /// The modifier's top nibble carries the underline style (1 = single,
    /// 2 = double, 3 = curly, …) and the daemon renders it as the extended
    /// `4:<style>` form. RED AS PORTED: `StyleCode` only ever emits plain `4`, so
    /// a curly underline draws as a straight one.
    @Test("curly underline keeps its style parameter")
    func curlyUnderline() {
        // modifier with UNDERLINED set plus style 3 in the top nibble.
        let modifier = CellModifier.underline | (3 << 12)
        let code = StyleCode.encode(Self.cell(modifier: modifier))
        #expect(code.contains("4:3"), "got \(code)")
    }

    /// `render_ansi.rs:1169` — a plain cell resets to exactly `39;49`, so the
    /// renderer does not leave a previous cell's colour applied.
    @Test("a plain cell resets both colors")
    func plainCellResets() {
        let code = StyleCode.encode(Self.cell())
        #expect(code == "39;49")
    }
}

@Suite("Wide glyph measurement")
struct WideGlyphTests {
    /// `render_ansi.rs:2360` `full_redraw_skips_trailing_cells_covered_by_halfwidth_voiced_kana`.
    ///
    /// A halfwidth katakana base plus its voiced mark is one grapheme that
    /// occupies **two** columns. The daemon special-cases it because the base is
    /// not wide on its own. RED AS PORTED: `SurfaceText.isWide` looks only at the
    /// first scalar and `U+FF66…U+FF9D` is outside every range it tests, so the
    /// renderer advances one column and shifts the rest of the row left by one.
    @Test("halfwidth katakana plus voiced mark is two columns")
    func halfwidthVoicedKana() {
        // U+FF76 (ｶ) + U+FF9E (゛): one cluster, two columns.
        #expect(SurfaceText.isWide("\u{FF76}\u{FF9E}"))
        #expect(SurfaceText.isWide("\u{FF76}\u{FF9F}"))
        // A bare halfwidth katakana is one column.
        #expect(!SurfaceText.isWide("\u{FF76}"))
    }

    /// Full-width forms the existing table already gets right; guards against a
    /// fix for the case above widening everything in the FF00 block.
    @Test("fullwidth forms stay wide and ASCII stays narrow")
    func fullwidthAndASCII() {
        #expect(SurfaceText.isWide("\u{FF21}")) // Ａ
        #expect(!SurfaceText.isWide("A"))
        #expect(SurfaceText.isWide("\u{4E2D}")) // 中
    }
}

@Suite("ANSI cursor and hyperlinks")
struct ANSICursorAndHyperlinkTests {
    private func frame(
        symbol: String = "a",
        cursor: CursorState?,
        hyperlinks: [String] = [],
        linkIndex: UInt32? = nil
    ) -> FrameData {
        FrameData(
            cells: [
                CellData(
                    symbol: symbol,
                    foreground: 0,
                    background: 0,
                    modifier: 0,
                    skip: false,
                    hyperlink: linkIndex
                ),
            ],
            width: 1,
            height: 1,
            cursor: cursor,
            hyperlinks: hyperlinks,
            graphics: Data()
        )
    }

    private func render(_ frame: FrameData) -> String {
        var renderer = SurfaceANSIRenderer()
        return String(bytes: renderer.render(frame), encoding: .utf8) ?? ""
    }

    /// `render_ansi.rs:1284` `blit_frame_wraps_frame_in_synchronized_output`.
    ///
    /// Synchronized output (`?2026h` … `?2026l`) is what keeps a terminal from
    /// painting a half-built grid. Upstream wraps *every* frame, not just the
    /// first: a diff frame writes several rows and is just as visible mid-write.
    ///
    /// RED AS PORTED: `render` only emits the pair when `full` is true, so every
    /// patch-driven repaint is visible half-painted — exactly the tear this
    /// sequence exists to prevent.
    @Test("every frame is wrapped in synchronized output")
    func synchronizedOutputOnDiffs() {
        var renderer = SurfaceANSIRenderer()
        let first = FrameData(
            cells: Array(repeating: .blank, count: 8),
            width: 4,
            height: 2,
            cursor: nil,
            hyperlinks: [],
            graphics: Data()
        )
        _ = renderer.render(first)

        var changed = first
        changed.cells[5] = CellData(
            symbol: "z",
            foreground: 0,
            background: 0,
            modifier: 0,
            skip: false,
            hyperlink: nil
        )
        let diff = String(bytes: renderer.render(changed), encoding: .utf8) ?? ""
        #expect(diff.contains("\u{1B}[?2026h"), "diff frame opened without sync: \(diff)")
        #expect(diff.contains("\u{1B}[?2026l"), "diff frame never closed sync: \(diff)")
    }

    /// `render_ansi.rs:1772` `encoder_size_change_repaints_without_clearing`.
    ///
    /// A resize repaints everything but must **not** send `2J`: the terminal
    /// already owns scrollback from before the resize, and clearing it throws
    /// away output the user was reading. Upstream only clears on the very first
    /// frame of a pane.
    ///
    /// RED AS PORTED: `render` treats "grid changed" as `full` and sends `2J`
    /// with it, so every window resize wipes the pane's scrollback.
    @Test("a size change repaints without clearing the screen")
    func sizeChangeDoesNotClear() {
        var renderer = SurfaceANSIRenderer()
        _ = renderer.render(FrameData(
            cells: Array(repeating: .blank, count: 4),
            width: 2,
            height: 2,
            cursor: nil,
            hyperlinks: [],
            graphics: Data()
        ))
        let resized = String(bytes: renderer.render(FrameData(
            cells: Array(repeating: .blank, count: 6),
            width: 3,
            height: 2,
            cursor: nil,
            hyperlinks: [],
            graphics: Data()
        )), encoding: .utf8) ?? ""
        #expect(!resized.contains("\u{1B}[2J"), "resize cleared the scrollback: \(resized)")
    }

    /// `render_ansi.rs:1618` `blit_frame_emits_osc8_for_linked_cells`.
    ///
    /// Cells carry an index into `frame.hyperlinks`; the daemon wraps them in
    /// OSC 8 so the terminal makes them clickable. RED AS PORTED: the renderer
    /// decodes the indices and then never emits them, so links in a pane are
    /// plain text.
    @Test("a linked cell emits OSC 8")
    func osc8() {
        let ansi = render(frame(
            cursor: nil,
            hyperlinks: ["https://example.com"],
            linkIndex: 0
        ))
        #expect(ansi.contains("\u{1B}]8;;https://example.com\u{1B}\\"))
    }

    /// `render_ansi.rs:1640` `blit_frame_sanitizes_hyperlink_uris`.
    ///
    /// A URI is daemon-controlled text being pasted into an escape sequence: an
    /// embedded `ESC` or `BEL` would terminate or corrupt the OSC and whatever
    /// follows it becomes terminal input. Security-relevant, so it fails loudly.
    @Test("control characters are stripped from hyperlink URIs")
    func hyperlinkSanitized() {
        let ansi = render(frame(
            cursor: nil,
            hyperlinks: ["https://ok.example/\u{1B}]0;pwned\u{07}"],
            linkIndex: 0
        ))
        #expect(!ansi.contains("\u{1B}]0;"), "URI control bytes reached the terminal")
    }

    /// `render_ansi.rs:1508` — cursor *shape* (DECSCUSR) travels before
    /// visibility so a bar cursor is already the right shape when it appears.
    @Test("cursor shape is emitted with DECSCUSR")
    func cursorShape() {
        let ansi = render(frame(
            cursor: CursorState(column: 0, row: 0, visible: true, shape: 5)
        ))
        #expect(ansi.contains("\u{1B}[5 q") || ansi.contains("\u{1B}[5 q"), "got \(ansi)")
    }

    /// `render_ansi.rs:2105` `blit_frame_no_cursor_hides_cursor`: a frame with no
    /// cursor at all must still hide the host cursor. Without it the cursor sits
    /// wherever the previous program left it — measured on the first frame of a
    /// pane that has not printed yet.
    @Test("a missing cursor hides the host cursor")
    func missingCursorHides() {
        let ansi = render(frame(cursor: nil))
        #expect(ansi.contains("\u{1B}[?25l"), "got \(ansi)")
    }

    /// `render_ansi.rs:2218` — a hidden cursor is parked at its last visible
    /// position rather than left at a stale one, so IME candidate windows appear
    /// next to the text instead of in a corner.
    @Test("a hidden cursor is parked, not abandoned")
    func hiddenCursorParked() {
        var renderer = SurfaceANSIRenderer()
        _ = renderer.render(frame(
            cursor: CursorState(column: 0, row: 0, visible: true, shape: 0)
        ))
        let hidden = String(
            bytes: renderer.render(frame(
                cursor: CursorState(column: 0, row: 0, visible: false, shape: 0)
            )),
            encoding: .utf8
        ) ?? ""
        #expect(hidden.contains("\u{1B}[?25l"))
        // Parking means the CUP is still emitted; a bare `?25l` leaves the
        // anchor wherever the application last moved it.
        #expect(hidden.contains("H"), "no CUP before hiding: \(hidden)")
    }
}
