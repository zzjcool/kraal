// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import Testing

@testable import KraalProtocol

/// `kraal capture --format html`. The capture stream is `herdr pane read --format
/// ansi`; these cases are cut from a real capture (truecolor SGR, `\r\n` rows,
/// themed colours) rather than invented, because the bugs worth catching are the
/// ones that only show up on real output.
@Suite("ANSI capture to HTML")
struct ANSIToHTMLTests {
    private func body(_ input: String) -> String {
        ANSIToHTML.render(input, background: "#000000", foreground: "#ffffff")
    }

    @Test("plain text is escaped, not interpreted")
    func escapesMarkup() {
        let html = body("if a < b && c > d\n")
        #expect(html.contains("if a &lt; b &amp;&amp; c &gt; d"))
        #expect(!html.contains("<b"))
    }

    @Test("a truecolor run becomes a span with that colour")
    func truecolorRun() {
        // Cut from a real capture: `ESC[0mESC[38;2;126;136;142m  /ls-branchESC[0m`.
        let html = body("\u{1B}[0m\u{1B}[38;2;126;136;142m  /ls-branch\u{1B}[0m\n")
        #expect(html.contains("<span style=\"color:#7e888e\">  /ls-branch</span>"))
        #expect(!html.contains("\u{1B}"))
    }

    @Test("carriage returns are dropped, newlines kept")
    func dropsCarriageReturns() {
        // `pane read` ends every row with `\r\n`; a stray CR renders as a control
        // character in the browser, which is how the first version shipped `^M`
        // into the HTML.
        let html = body("one\r\ntwo\r\n")
        #expect(html.contains("one\ntwo\n"))
        #expect(!html.contains("\r"))
    }

    @Test("the 16 basic colours use the xterm palette")
    func basicPalette() {
        #expect(ANSIToHTML.color(index: 1) == "#800000")
        #expect(ANSIToHTML.color(index: 9) == "#ff0000")
        #expect(ANSIToHTML.color(index: 15) == "#ffffff")
    }

    @Test("the 256-colour cube and grayscale ramp are computed, not guessed")
    func indexedPalette() {
        #expect(ANSIToHTML.color(index: 196) == "#ff0000")   // cube corner
        #expect(ANSIToHTML.color(index: 232) == "#080808")   // first gray
        #expect(ANSIToHTML.color(index: 255) == "#eeeeee")   // last gray
        #expect(ANSIToHTML.color(index: 300) == nil)
    }

    @Test("256-colour and reverse video survive the round trip")
    func indexedAndReversed() {
        let html = body("\u{1B}[38;5;196;48;2;10;20;30;7mX\u{1B}[0m")
        // Reverse video swaps the two: the background becomes the text colour.
        #expect(html.contains("color:#0a141e"))
        #expect(html.contains("background-color:#ff0000"))
    }

    @Test("SGR state accumulates across sequences")
    func accumulatingStyle() {
        let html = body("\u{1B}[1m\u{1B}[31mbold red\u{1B}[0m plain")
        #expect(html.contains("color:#800000;font-weight:700"))
        #expect(html.contains(" plain"))
    }

    @Test("resets turn the style back off")
    func resets() {
        let html = body("\u{1B}[1;3;4;9mX\u{1B}[22;23;24;29mY")
        #expect(html.contains("font-weight:700"))
        #expect(html.contains("text-decoration:underline line-through"))
        #expect(html.contains("X</span>Y"), "a reset must leave the next run unwrapped")
    }

    @Test("non-SGR escapes are dropped without eating the text")
    func dropsOtherEscapes() {
        // Cursor moves and an OSC title: `pane read` should not emit them, but a
        // capture taken with `--format ansi` from a stranger's terminal might.
        let html = body("a\u{1B}[2Kb\u{1B}]0;window-name\u{07}c")
        #expect(html.contains("abc"))
        #expect(!html.contains("window-name"))
    }

    @Test("an unterminated escape cannot swallow the rest of the capture")
    func unterminatedEscape() {
        let html = body("keep\u{1B}")
        #expect(html.contains("keep"))
    }

    @Test("the document carries the theme it was asked for")
    func documentChrome() {
        let html = body("x")
        #expect(html.hasPrefix("<!doctype html>"))
        #expect(html.contains("background:#000000"))
        #expect(html.contains("color:#ffffff"))
        #expect(html.contains("<pre style="))
    }
}
