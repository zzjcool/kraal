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

    public init() {}

    /// Resets so the next `render` emits a full repaint **and clears the screen**.
    ///
    /// Both are right after a dropped or rejected frame: the terminal may be
    /// holding rows at the old width, and repainting over them without clearing
    /// leaves the tail of each row behind.
    public mutating func reset() {
        previous = nil
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

        var lastStyle: String?
        let rows = repaintAll ? Array(0 ..< Int(frame.height)) : changedRows(frame)
        for row in rows {
            appendRow(
                row,
                frame: frame,
                full: repaintAll,
                output: &output,
                lastStyle: &lastStyle
            )
        }

        // Cursor: only when it moved or its visibility flipped, and never while
        // a patch leaves it hidden. The `?25l` above is unconditional, so
        // re-showing is what has to be conditional — otherwise every frame would
        // emit a redundant `?25h`.
        if let cursor = frame.cursor, cursor.visible {
            let moved = previous?.cursor.map {
                $0.column != cursor.column || $0.row != cursor.row
            } ?? true
            if moved {
                output.appendUTF8("\u{1B}[\(Int(cursor.row) + 1);\(Int(cursor.column) + 1)H")
            }
            output.appendUTF8("\u{1B}[?25h")
        }

        // Close the synchronized-output pair opened above. Unconditional, to
        // match the unconditional open — a diff frame that opened `?2026h` and
        // never closed it would freeze the terminal's rendering.
        output.appendUTF8("\u{1B}[?2026l")
        output.appendUTF8("\u{1B}[0m")

        previous = frame
        return output
    }

    // MARK: - Row diffing

    private func changedRows(_ frame: FrameData) -> [Int] {
        guard let previous, previous.cells.count == frame.cells.count else {
            return Array(0 ..< Int(frame.height))
        }
        let width = Int(frame.width)
        var rows: [Int] = []
        for row in 0 ..< Int(frame.height) {
            let start = row * width
            let end = start + width
            if previous.cells[start ..< end] != frame.cells[start ..< end] {
                rows.append(row)
            }
        }
        return rows
    }

    private func appendRow(
        _ row: Int,
        frame: FrameData,
        full: Bool,
        output: inout Data,
        lastStyle: inout String?
    ) {
        let width = Int(frame.width)
        let start = row * width
        guard start + width <= frame.cells.count else { return }

        // Every changed row is repainted in full, including ones that became
        // blank: skipping a blank row would leave whatever was drawn there before
        // on screen, which showed up as stale bands after a pane was split.
        output.appendUTF8("\u{1B}[\(row + 1);1H")

        var column = 0
        while column < width {
            let cell = frame.cells[start + column]
            if cell.skip {
                column += 1
                continue
            }

            let style = StyleCode.encode(cell)
            if style != lastStyle {
                output.appendUTF8("\u{1B}[0")
                output.appendUTF8(style)
                output.appendUTF8("m")
                lastStyle = style
            }

            let symbol = cell.symbol.isEmpty ? " " : cell.symbol
            output.appendUTF8(symbol)
            column += SurfaceText.isWide(symbol) ? 2 : 1
        }

        // A styled row must not leak its background into the next one.
        if lastStyle != nil, lastStyle != StyleCode.encode(.blank) {
            output.appendUTF8("\u{1B}[0m")
            lastStyle = nil
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

        let reversed = cell.modifier & (CellModifier.reverse | CellModifier.reversed) != 0
        if reversed {
            swap(&foreground, &background)
        }
        if cell.modifier & CellModifier.bold != 0 { parts.append("1") }
        if cell.modifier & CellModifier.dim != 0 { parts.append("2") }
        if cell.modifier & CellModifier.italic != 0 { parts.append("3") }
        if cell.modifier & CellModifier.underline != 0 { parts.append("4") }
        if cell.modifier & CellModifier.blink != 0 { parts.append("5") }
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
