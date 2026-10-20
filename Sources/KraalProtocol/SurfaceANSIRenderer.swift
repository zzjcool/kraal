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
// (66 B measured) rather than a full repaint.

import Foundation

public struct SurfaceANSIRenderer {
    /// Cells from the previous frame, for diffing. Empty until the first render.
    private var previous: FrameData?
    private var previousCursorVisible = false

    public init() {}

    /// Resets so the next `render` emits a full frame.
    public mutating func reset() {
        previous = nil
        previousCursorVisible = false
    }

    /// Returns the ANSI bytes that bring a terminal from the previous frame to
    /// `frame`, or a full repaint when there is no previous frame.
    public mutating func render(_ frame: FrameData) -> Data {
        var output = Data()
        let full = previous == nil
            || previous?.width != frame.width
            || previous?.height != frame.height

        if full {
            // Synchronized output keeps the terminal from painting a half-built
            // screen; the daemon emits the same pair (2026h / 2026l).
            output.appendUTF8("\u{1B}[?2026h")
            output.appendUTF8("\u{1B}[2J")
        }

        var lastStyle: String?
        let rows = full ? Array(0 ..< Int(frame.height)) : changedRows(frame)
        for row in rows {
            appendRow(
                row,
                frame: frame,
                full: full,
                output: &output,
                lastStyle: &lastStyle
            )
        }

        // Cursor: only when it moved or its visibility flipped, and never while
        // a patch leaves it hidden.
        if let cursor = frame.cursor, cursor.visible {
            let moved = previous?.cursor.map {
                $0.column != cursor.column || $0.row != cursor.row
            } ?? true
            if moved || !previousCursorVisible {
                output.appendUTF8("\u{1B}[\(Int(cursor.row) + 1);\(Int(cursor.column) + 1)H")
            }
            if !previousCursorVisible {
                output.appendUTF8("\u{1B}[?25h")
            }
        } else if previousCursorVisible {
            output.appendUTF8("\u{1B}[?25l")
        }

        if full {
            output.appendUTF8("\u{1B}[?2026l")
        }
        output.appendUTF8("\u{1B}[0m")

        previous = frame
        previousCursorVisible = frame.cursor?.visible ?? false
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

        // Skip rows that are entirely the default cell: nothing to repaint, and
        // emitting them would flash cleared background on some terminals.
        let cells = frame.cells[start ..< start + width]
        if !full, cells.allSatisfy({ $0 == .blank }) {
            return
        }

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
            // Named colors are palette entries; 0...=16 map onto 0...=16 with
            // the default foreground/background at index 0.
            if index == 0 {
                return isBackground ? "49" : "39"
            }
            return "\(base);5;\(index)"
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
