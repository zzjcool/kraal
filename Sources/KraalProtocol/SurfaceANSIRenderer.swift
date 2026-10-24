// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Renders an authoritative cell grid as VT/ANSI.
//
// Why this exists: the daemon hands us the *decoded* screen (a `PaneSurface`
// cell grid) but a renderer wants input, and Ghostty — the renderer we chose for
// glyph shaping, emoji, IME, selection, and kitty graphics — consumes ANSI.
//
// Converting cells to ANSI instead of opening a second `terminal attach` channel
// has three consequences, all good:
//
//   1. No second SSH channel, so no per-pane handshake and no `takeover` races
//      with the desktop client.
//   2. What we draw is the daemon's own composited screen, byte for byte —
//      measured 36/36 identical rows in research/04_ansi_vs_surface.py.
//   3. Input still flows back as semantic events on the same connection.
//
// `SurfaceANSIRenderer` emits a full frame on first use and then only the rows
// and cells that changed, which keeps the steady-state cost near the patch size
// (66 B measured) rather than a full repaint. Every frame — diff or not — is
// wrapped in synchronized output so nothing is ever visible half-painted.

import Foundation

public struct SurfaceANSIRenderer {
    /// Cells from the previous frame, for diffing. Empty until the first render.
    private var previous: FrameData?
    /// Where the cursor was last *shown*.
    ///
    /// A frame with no cursor, or with a hidden one, still has to put the host
    /// cursor somewhere: parking it at the last visible position keeps the IME
    /// candidate window near the text the user is typing instead of in a corner.
    private var lastVisibleCursor: (row: UInt16, column: UInt16)?
    /// The DECSCUSR shape currently applied, so the sequence is only re-emitted
    /// when it changes.
    private var lastShape: UInt8 = 0
    /// The kitty graphics bytes the terminal already holds.
    ///
    /// Diffed like the cells: a frame that changed one row must not resend a
    /// megabyte of image data (issue #37).
    private var lastGraphics = Data()

    public init() {}

    /// Resets so the next `render` emits a full repaint **and clears the screen**.
    ///
    /// Both are right after a dropped or rejected frame: the terminal may be
    /// holding rows at the old width, and repainting over them without clearing
    /// leaves the tail of each row behind.
    public mutating func reset() {
        previous = nil
        // The screen is being cleared, so a parked cursor position from the old
        // frame points at nothing. Forget it rather than emit a CUP into a region
        // that no longer has content.
        lastVisibleCursor = nil
        lastShape = 0
        // The screen is cleared, which takes any placed image with it. Forgetting
        // the bytes here is what makes the next frame write them again.
        lastGraphics = Data()
    }

    /// Returns the ANSI bytes that bring a terminal from the previous frame to
    /// `frame`, or a full repaint when there is no previous frame.
    public mutating func render(_ frame: FrameData) -> Data {
        var output = Data()
        // Three separate questions, deliberately kept separate. Collapsing them
        // into one flag is what made a resize clear the scrollback.
        //
        //   repaintAll — is the diff trustworthy? A different grid size means no
        //                cell's coordinates match what is on screen, so every row
        //                has to be written again.
        //   clear      — may we destroy scrollback? Only when there is nothing
        //                worth keeping: a pane's first frame, or after `reset()`
        //                threw away a frame that left bad rows behind.
        //   sync       — never a question. Every frame is wrapped.
        let firstFrame = previous == nil
        let repaintAll = firstFrame
            || previous?.width != frame.width
            || previous?.height != frame.height
        let clear = firstFrame

        // Synchronized output keeps the terminal from painting a half-built
        // screen. Every frame gets it, not just full ones: a diff writes several
        // rows in sequence and is just as visible mid-write. The daemon wraps
        // every frame too (render_ansi.rs:1284), and 16 bytes against a 66-byte
        // patch is not what made this worth skipping.
        output.appendUTF8("\u{1B}[?2026h")
        // Hide the cursor before any cell writes. The cursor is positioned with
        // CUP while painting, so a terminal that draws the hardware cursor at
        // that intermediate position shows it flicking across the pane. Upstream
        // writes this unconditionally for the same reason (render_ansi.rs:690),
        // and a diff that touches three rows has the same three intermediate
        // positions a full repaint does.
        output.appendUTF8("\u{1B}[?25l")
        if clear {
            output.appendUTF8("\u{1B}[2J")
        }

        var stream = RowStream()
        let rows = repaintAll ? Array(0 ..< Int(frame.height)) : changedRows(frame)
        for row in rows {
            appendRow(row, frame: frame, stream: &stream, output: &output)
        }

        // Cursor. Three separate requirements, all from `render_ansi.rs:778`
        // (`resolve_host_cursor_state`) and `:838` (`write_host_cursor_state`):
        //
        //   position — move it even when hidden, so a hidden cursor does not sit
        //              where the previous program left it (the IME candidate
        //              window follows the cursor, and parked in a corner it looks
        //              broken).
        //   shape    — DECSCUSR (`CSI Ps SP q`), only when it changed. Without
        //              it a bar or underline cursor is always drawn as a block.
        //   visible  — `?25h` last, so the cursor never flashes at an
        //              intermediate position.
        //
        // A frame with no cursor at all still hides the host cursor, at its last
        // visible position.
        let hostCursor = resolveHostCursor(frame)
        lastVisibleCursor = hostCursor.visible ? (hostCursor.row, hostCursor.column) : lastVisibleCursor
        output.appendUTF8("\u{1B}[\(Int(hostCursor.row) + 1);\(Int(hostCursor.column) + 1)H")
        if hostCursor.shape != lastShape {
            output.appendUTF8("\u{1B}[\(hostCursor.shape) q")
            lastShape = hostCursor.shape
        }
        output.appendUTF8(hostCursor.visible ? "\u{1B}[?25h" : "\u{1B}[?25l")

        // Kitty graphics, at the end of the block and inside it (issue #37).
        //
        // `frame.graphics` is a ready-to-write kitty byte stream the daemon
        // already encoded — not a scene to compose. A client's whole job is to put
        // it in the output, which it did not: `PaneTerminal` passed `Data()` here,
        // so an image was decoded, measured with the cell grid, and then dropped.
        //
        // Three details, all from upstream `frame_output.rs::write_composed_frame`:
        //
        //   * inside the synchronized-output pair — outside it the terminal paints
        //     cells and image in two flushes, which reads as a flicker;
        //   * after the cells — written first, the row repaint would cover it;
        //   * wrapped in DECSC/DECRC — a graphics sequence leaves the cursor where
        //     it stopped, and the next frame's CUP would start from there.
        //
        // Only when the bytes changed. A diff frame runs on every keystroke, and
        // resending a whole image then would cost more than the frame itself.
        if !frame.graphics.isEmpty, frame.graphics != lastGraphics {
            output.appendUTF8("\u{1B}7")
            output.append(frame.graphics)
            output.appendUTF8("\u{1B}8")
            lastGraphics = frame.graphics
        }

        // Close the synchronized-output pair opened above. Unconditional, to
        // match the unconditional open — a diff frame that opened `?2026h` and
        // never closed it would freeze the terminal's rendering.
        output.appendUTF8("\u{1B}[?2026l")
        output.appendUTF8("\u{1B}[0m")

        previous = frame
        return output
    }

    /// Where the host cursor goes, and whether it is shown.
    ///
    /// Mirror of the daemon's `resolve_host_cursor_state`. The only non-obvious
    /// case is "no cursor at all": park at the last place it was visible, or at
    /// the bottom-right corner when there is none, and hide it.
    private func resolveHostCursor(_ frame: FrameData) -> HostCursor {
        let maxRow = frame.height &- 1
        let maxColumn = frame.width &- 1
        func clamp(_ row: UInt16, _ column: UInt16) -> HostCursor {
            HostCursor(row: min(row, maxRow), column: min(column, maxColumn))
        }
        guard let cursor = frame.cursor else {
            var parked = lastVisibleCursor.map { clamp($0.row, $0.column) }
                ?? HostCursor(row: maxRow, column: maxColumn)
            parked.visible = false
            return parked
        }
        var resolved = clamp(cursor.row, cursor.column)
        resolved.visible = cursor.visible
        // DECSCUSR takes 0–6; anything else means "terminal default".
        resolved.shape = cursor.shape <= 6 ? cursor.shape : 0
        return resolved
    }

    private struct HostCursor {
        var row: UInt16
        var column: UInt16
        var visible = false
        var shape: UInt8 = 0
    }

    // MARK: - Row diffing

    private func changedRows(_ frame: FrameData) -> [Int] {
        guard let previous, previous.buffer.count == frame.buffer.count else {
            return Array(0 ..< Int(frame.height))
        }
        var rows: [Int] = []
        for row in 0 ..< Int(frame.height) where previous.buffer.row(row) != frame.buffer.row(row) {
            // Row-wise on purpose: rows that a patch did not touch are still the
            // same buffer, and `Array`'s `==` short-circuits on identical storage,
            // so an unchanged row costs a couple of instructions instead of a
            // scan. Comparing flat cells cannot see that (issue #50).
            rows.append(row)
        }
        return rows
    }

    /// What the terminal currently has applied, carried across rows.
    ///
    /// OSC 8 is a *state*, not a per-cell attribute: a run of linked cells is
    /// wrapped once, not once per glyph. Styles are the same. Keeping both in one
    /// value makes the "reset at end of row" rule explicit and keeps `appendRow`
    /// within the parameter limit.
    private struct RowStream {
        /// The style of the last cell written, as its **raw** fields.
        ///
        /// Deliberately not the encoded SGR string: deciding whether a style
        /// changed must not allocate. Comparing encoded strings meant running
        /// `StyleCode.encode` for every cell and throwing the result away for all
        /// but the ~1 cell per run that starts a new style (issue #49). Raw
        /// `UInt32`/`UInt16` fields compare in a few instructions.
        var lastStyle: CellStyleKey?
        var activeLink: String?
    }

    /// Everything `StyleCode.encode` reads, exactly as the cell stores it.
    ///
    /// Two cells with equal keys produce equal SGR, which is the only property
    /// the renderer needs: it decides *whether* to encode, and `encode` still
    /// does the encoding. Deriving the key from raw fields rather than from the
    /// encoded string is what makes the check free.
    ///
    /// Equality here is deliberately finer than SGR equality, never coarser.
    /// `TerminalColor.init(raw:)` folds unknown tags to `named(0)`, so two
    /// different `foreground` values can encode to the same SGR; treating those
    /// as "changed" costs one redundant SGR write, while the reverse (treating
    /// two different SGRs as equal) would drop a colour. `reversed` needs no
    /// special case: it is a modifier bit and the fg/bg swap is a function of
    /// the two fields already in the key.
    ///
    /// `internal` rather than `private` so tests can hold the one invariant that
    /// makes skipping safe: equal SGR implies equal key (see
    /// `CellStyleEncodingTests.styleKeyNeverCollapsesDistinctStyles`). That test
    /// keys a dictionary by it, so it is `Hashable` as well as `Equatable`.
    struct CellStyleKey: Hashable {
        var foreground: UInt32
        var background: UInt32
        var modifier: UInt16

        init(cell: CellData) {
            foreground = cell.foreground
            background = cell.background
            modifier = cell.modifier
        }
    }

    private func appendRow(
        _ row: Int,
        frame: FrameData,
        stream: inout RowStream,
        output: inout Data
    ) {
        let width = Int(frame.width)
        // One row, fetched once: the row diff and the patch path both leave
        // untouched rows sharing storage, so this is a retain, not a copy. Reading
        // through the flat subscript instead would re-borrow a fresh array value
        // per cell.
        let cells = frame.buffer.row(row)
        guard cells.count >= width else { return }

        // Every changed row is repainted in full, including ones that became
        // blank: skipping a blank row would leave whatever was drawn there before
        // on screen, which showed up as stale bands after a pane was split.
        output.appendUTF8("\u{1B}[\(row + 1);1H")

        var column = 0
        while column < width {
            let cell = cells[cells.startIndex + column]
            if cell.skip {
                column += 1
                continue
            }

            // Links are emitted before the style so the style applies inside the
            // link run, matching `write_cell` in the daemon.
            writeHyperlinkIfChanged(
                requested: linkURI(for: cell, in: frame),
                active: &stream.activeLink,
                output: &output
            )

            let style = CellStyleKey(cell: cell)
            if style != stream.lastStyle {
                output.appendUTF8("\u{1B}[0")
                output.appendUTF8(StyleCode.encode(cell))
                output.appendUTF8("m")
                stream.lastStyle = style
            }

            let symbol = cell.symbol.isEmpty ? " " : cell.symbol
            output.appendUTF8(symbol)
            column += SurfaceText.isWide(symbol) ? 2 : 1
        }

        // A styled row must not leak its background into the next one, and an
        // open link must not leak either — an unterminated OSC 8 would make the
        // rest of the pane clickable.
        if stream.activeLink != nil {
            output.appendUTF8("\u{1B}]8;;\u{1B}\\")
            stream.activeLink = nil
        }
        if let lastStyle = stream.lastStyle, lastStyle != CellStyleKey(cell: .blank) {
            output.appendUTF8("\u{1B}[0m")
            stream.lastStyle = nil
        }
    }

    /// The sanitized URI this cell links to, if any.
    ///
    /// A URI is daemon-controlled text placed *inside* an escape sequence, so it
    /// is untrusted input: an embedded `ESC` or `BEL` would end the OSC early and
    /// the remainder would be interpreted as terminal input. Strip every control
    /// character, and drop a link that sanitizes to nothing.
    ///
    /// `render_ansi.rs:910` `sanitized_hyperlink_uri`.
    private func linkURI(for cell: CellData, in frame: FrameData) -> String? {
        guard let index = cell.hyperlink, Int(index) < frame.hyperlinks.count else {
            return nil
        }
        let raw = frame.hyperlinks[Int(index)]
        let sanitized = String(raw.unicodeScalars.filter {
            $0 != "\u{1B}" && $0 != "\u{07}" && !CharacterSet.controlCharacters.contains($0)
        })
        return sanitized.isEmpty ? nil : sanitized
    }

    /// Opens, closes or leaves the OSC 8 state so the stream matches `requested`.
    ///
    /// Emitting the pair per cell instead would add ~40 bytes per linked glyph;
    /// emitting nothing is the bug this fixes (`render_ansi.rs:1618`
    /// `blit_frame_emits_osc8_for_linked_cells`).
    private func writeHyperlinkIfChanged(
        requested: String?,
        active: inout String?,
        output: inout Data
    ) {
        if active == requested { return }
        if active != nil {
            output.appendUTF8("\u{1B}]8;;\u{1B}\\")
        }
        active = requested
        if let requested {
            output.appendUTF8("\u{1B}]8;;")
            output.appendUTF8(requested)
            output.appendUTF8("\u{1B}\\")
        }
    }
}

/// SGR parameter generation.
enum StyleCode {
    /// 256-color / RGB palette indices for the 16 named ANSI colors.
    static let namedIndex = 0

    static func encode(_ cell: CellData) -> String {
        var parts: [String] = []
        var foreground = TerminalColor(raw: cell.foreground)
        var background = TerminalColor(raw: cell.background)

        let reversed = cell.modifier & CellModifier.reversed != 0
        if reversed {
            // The daemon swaps the two colours *and* emits `7`
            // (`render_ansi.rs:455`): the swap makes the actual colours right,
            // and `7` tells the terminal so that anything it draws itself — a
            // selection, the cursor block — inverts too.
            swap(&foreground, &background)
        }
        if cell.modifier & CellModifier.bold != 0 { parts.append("1") }
        if cell.modifier & CellModifier.dim != 0 { parts.append("2") }
        if cell.modifier & CellModifier.italic != 0 { parts.append("3") }
        if cell.modifier & CellModifier.underline != 0 {
            // The extended form carries the style: `4:2` double, `4:3` curly,
            // `4:4` dotted, `4:5` dashed (`render_ansi.rs:445`). Plain `4` means
            // "single", so an unset style keeps the short form.
            switch CellModifier.underlineStyle(cell.modifier) {
            case 2: parts.append("4:2")
            case 3: parts.append("4:3")
            case 4: parts.append("4:4")
            case 5: parts.append("4:5")
            default: parts.append("4")
            }
        }
        if cell.modifier & CellModifier.slowBlink != 0 { parts.append("5") }
        if cell.modifier & CellModifier.rapidBlink != 0 { parts.append("6") }
        if reversed { parts.append("7") }
        if cell.modifier & CellModifier.hidden != 0 { parts.append("8") }
        if cell.modifier & CellModifier.strikethrough != 0 { parts.append("9") }

        parts.append(colorParameter(foreground, isBackground: false))
        parts.append(colorParameter(background, isBackground: true))
        return parts.joined(separator: ";")
    }

    private static func colorParameter(
        _ color: TerminalColor,
        isBackground: Bool
    ) -> String {
        let base = isBackground ? 48 : 38
        switch color {
        case let .named(index):
            // The 16 named colours have their own SGR codes, and they are *not*
            // the 256-colour palette indices: `named(1)` is black and must go
            // out as `30`, not `38;5;1` — the latter is palette entry 1, which is
            // red. Straight from `render_ansi.rs:347` (`color_to_sgr_fg`), which
            // is an explicit table for exactly this reason.
            //
            // 0 is "default", 1...8 are 30...37, 9...16 are 90...97; anything
            // else falls back to the default rather than emitting a wrong colour.
            guard index != 0, index <= 16 else {
                return isBackground ? "49" : "39"
            }
            let code: UInt8
            if index <= 8 {
                code = 30 + (index - 1)
            } else {
                code = 90 + (index - 9)
            }
            return String(isBackground ? code + 10 : code)
        case let .indexed(index):
            return "\(base);5;\(index)"
        case let .rgb(red, green, blue):
            return "\(base);2;\(red);\(green);\(blue)"
        }
    }
}

extension Data {
    /// UTF-8 append shorthand; `String.UTF8View` needs a `contentsOf:` call at
    /// every site otherwise, which drowns the escape sequences in boilerplate.
    mutating func appendUTF8(_ string: String) {
        append(contentsOf: string.utf8)
    }
}
