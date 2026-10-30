// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation

/// Turns the ANSI snapshot that `herdr pane read --format ansi` prints into HTML.
///
/// This is the one capture format Rex has that herdr does not (`rex capture
/// --format=html`), and the reason it is worth having: a plain-text capture loses
/// exactly the information a bug report needs — which row is highlighted, which
/// word is red. Kraal does not need its renderer for this: herdr already resolves
/// the theme into truecolor SGR (`ESC[38;2;126;136;142m`), so the capture stream is
/// the truth and this is a pure text transform.
///
/// Deliberately *not* a terminal emulator. `pane read` prints one line per row with
/// `\r\n`; cursor moves, erases and scroll regions do not appear. Anything outside
/// SGR is dropped rather than emulated, because a half-emulator that silently gets
/// an escape sequence wrong is worse than one that ignores it.
public enum ANSIToHTML {
    /// xterm's default basic palette. `pane read` emits truecolor for the theme, so
    /// these only matter for a capture that used the 30–37 / 40–47 / 90–107 forms.
    static let palette: [String] = [
        "#000000", "#800000", "#008000", "#808000",
        "#000080", "#800080", "#008080", "#c0c0c0",
        "#808080", "#ff0000", "#00ff00", "#ffff00",
        "#0000ff", "#ff00ff", "#00ffff", "#ffffff",
    ]

    /// The 256-color palette: 16 basic, a 6×6×6 cube, then 24 grays.
    public static func color(index: Int) -> String? {
        switch index {
        case 0 ..< 16:
            return palette[index]
        case 16 ..< 232:
            let steps: [UInt8] = [0, 95, 135, 175, 215, 255]
            let offset = index - 16
            return hex(steps[offset / 36], steps[(offset / 6) % 6], steps[offset % 6])
        case 232 ..< 256:
            let level = UInt8(8 + (index - 232) * 10)
            return hex(level, level, level)
        default:
            return nil
        }
    }

    static func hex(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> String {
        String(format: "#%02x%02x%02x", red, green, blue)
    }

    /// One SGR state: what the following characters look like.
    struct Style: Equatable {
        var foreground: String?
        var background: String?
        var bold = false
        var dim = false
        var italic = false
        var underline = false
        var strikethrough = false
        var reversed = false

        var isEmpty: Bool {
            foreground == nil && background == nil && !bold && !dim && !italic
                && !underline && !strikethrough && !reversed
        }

        /// CSS for the run, with reverse video applied as the swap it is.
        var css: String {
            var parts: [String] = []
            let front = reversed ? background : foreground
            let back = reversed ? foreground : background
            if let front { parts.append("color:\(front)") }
            if let back { parts.append("background-color:\(back)") }
            if bold { parts.append("font-weight:700") }
            if italic { parts.append("font-style:italic") }
            var decoration: [String] = []
            if underline { decoration.append("underline") }
            if strikethrough { decoration.append("line-through") }
            if !decoration.isEmpty { parts.append("text-decoration:\(decoration.joined(separator: " "))") }
            if dim { parts.append("opacity:.6") }
            return parts.joined(separator: ";")
        }
    }

    /// Renders a capture stream as an HTML fragment: one `<span>` per styled run.
    public static func render(
        _ input: String,
        background: String = "#282828",
        foreground: String = "#ebdbb2",
        padding: Int = 12
    ) -> String {
        var body = ""
        var style = Style()
        var run = ""

        func flush() {
            guard !run.isEmpty else { return }
            let escaped = escape(run)
            body += style.isEmpty ? escaped : "<span style=\"\(style.css)\">\(escaped)</span>"
            run = ""
        }

        // Scalars, not Characters: Swift folds a CRLF pair into ONE Character, so
        // `character == "\r"` never matches in `pane read` output and the first
        // version shipped `^M` into the HTML. This is where that was measured.
        var index = input.unicodeScalars.startIndex
        let scalars = input.unicodeScalars
        while index < scalars.endIndex {
            let scalar = scalars[index]
            guard scalar == "\u{1B}" else {
                if scalar != "\r" {
                    run.unicodeScalars.append(scalar)
                }
                index = scalars.index(after: index)
                continue
            }

            flush()
            index = scalars.index(after: index)
            guard index < scalars.endIndex else { break }
            switch scalars[index] {
            case "[":
                index = consumeCSI(scalars, from: index, style: &style)
            case "]":
                index = consumeOSC(scalars, from: index)
            default:
                index = scalars.index(after: index)
            }
        }
        flush()

        let css = "margin:0;padding:\(padding)px;background:\(background);color:\(foreground);"
            + "font:12px/1.35 ui-monospace,SFMono-Regular,Menlo,monospace;white-space:pre-wrap"
        return """
        <!doctype html>
        <meta charset="utf-8">
        <title>kraal capture</title>
        <pre style="\(css)">\(body)</pre>
        """
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Consumes `ESC [ … <final>`, applying SGR and dropping everything else.
    private static func consumeCSI(
        _ scalars: String.UnicodeScalarView, from start: String.UnicodeScalarView.Index, style: inout Style
    ) -> String.UnicodeScalarView.Index {
        var index = scalars.index(after: start)   // skip '['
        var parameters = ""
        while index < scalars.endIndex {
            let scalar = scalars[index]
            index = scalars.index(after: index)
            if scalar.value >= 0x40, scalar.value <= 0x7E {
                if scalar == "m" {
                    applySGR(parameters, style: &style)
                }
                return index
            }
            // Intermediate bytes (0x20–0x2F) are not expected in SGR; keep them out
            // of the parameter string so a stray one cannot corrupt the numbers.
            if scalar.value < 0x40 {
                parameters.unicodeScalars.append(scalar)
            }
        }
        return index
    }

    /// Consumes `ESC ] … BEL` or `ESC ] … ESC \` (window title, hyperlinks).
    private static func consumeOSC(
        _ scalars: String.UnicodeScalarView, from start: String.UnicodeScalarView.Index
    ) -> String.UnicodeScalarView.Index {
        var index = scalars.index(after: start)   // skip ']'
        while index < scalars.endIndex {
            let scalar = scalars[index]
            index = scalars.index(after: index)
            if scalar == "\u{07}" { return index }
            if scalar == "\u{1B}", index < scalars.endIndex, scalars[index] == "\\" {
                return scalars.index(after: index)
            }
        }
        return index
    }

    static func applySGR(_ parameters: String, style: inout Style) {
        let numbers = parameters.split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
        var position = 0
        while position < numbers.count {
            let code = numbers[position]
            position += 1
            if code == 38 || code == 48 {
                guard let (color, used) = extendedColor(numbers, from: position) else { continue }
                position = used
                if code == 38 { style.foreground = color } else { style.background = color }
                continue
            }
            applySimple(code, style: &style)
        }
    }

    /// The one-number SGR codes. Anything unrecognised is ignored, not guessed at.
    private static func applySimple(_ code: Int, style: inout Style) {
        switch code {
        case 0: style = Style()
        case 1: style.bold = true
        case 2: style.dim = true
        case 3: style.italic = true
        case 4: style.underline = true
        case 7: style.reversed = true
        case 9: style.strikethrough = true
        case 22: style.bold = false; style.dim = false
        case 23: style.italic = false
        case 24: style.underline = false
        case 27: style.reversed = false
        case 29: style.strikethrough = false
        case 30 ... 37: style.foreground = color(index: code - 30)
        case 39: style.foreground = nil
        case 40 ... 47: style.background = color(index: code - 40)
        case 49: style.background = nil
        case 90 ... 97: style.foreground = color(index: code - 90 + 8)
        case 100 ... 107: style.background = color(index: code - 100 + 8)
        default: break
        }
    }

    /// `38;5;n` / `38;2;r;g;b`. Returns the colour and the cursor past its fields.
    private static func extendedColor(
        _ numbers: [Int], from position: Int
    ) -> (String?, Int)? {
        guard position < numbers.count else { return nil }
        switch numbers[position] {
        case 5:
            guard position + 1 < numbers.count else { return nil }
            return (color(index: numbers[position + 1]), position + 2)
        case 2:
            guard position + 3 < numbers.count else { return nil }
            let red = UInt8(clamping: numbers[position + 1])
            let green = UInt8(clamping: numbers[position + 2])
            let blue = UInt8(clamping: numbers[position + 3])
            return (hex(red, green, blue), position + 4)
        default:
            return nil
        }
    }
}
