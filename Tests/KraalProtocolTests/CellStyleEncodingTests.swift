// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The SGR side of cell -> ANSI: what `StyleCode` emits, and the style key the
// renderer uses to decide whether it has to emit anything at all.
//
// Split out of SurfaceANSIRendererTests.swift, which hit the 400-line
// `type_body_length` limit. The two halves are genuinely different questions:
// that file is about *which rows and cells* get written, this one is about
// *what bytes a style turns into*, plus the invariant that lets the renderer
// skip encoding a style the terminal already has applied (issue #49).
//
// `ANSIConformanceTests` remains the authority on the SGR *table* (which
// modifier bit maps to which code, ports of upstream `render_ansi.rs`); the
// cases here are about the renderer's use of it.

import Foundation
import Testing

@testable import KraalProtocol

@Suite("Cell style encoding")
struct CellStyleEncodingTests {
    @Test("colors use the non-ARGB encoding in SGR output")
    func colorEncoding() {
        let trueColor = CellData(
            symbol: "z",
            foreground: 0x020A_141E,
            background: 0x0100_00FF,
            modifier: 0,
            skip: false,
            hyperlink: nil
        )
        let code = StyleCode.encode(trueColor)
        #expect(code.contains("38;2;10;20;30"))
        #expect(code.contains("48;5;255"))
    }

    /// The renderer only calls `StyleCode.encode` when a cell's style *differs*
    /// from the previous one (issue #49). That is a large saving — one style
    /// across a screen is the common case — and it is only safe if the cheap key
    /// it compares can never call two different SGR strings equal. If it did, a
    /// cell would silently inherit the previous cell's colour.
    ///
    /// This is the direction of the implication that matters:
    ///
    ///     equal SGR  ⇒  equal key        (required: no dropped colour)
    ///     equal key  ⇒  equal SGR        (NOT required: a redundant SGR is fine)
    ///
    /// A sweep over every pair of colour encodings times every modifier bit
    /// checks the first line for the values a cell can carry.
    @Test("an unchanged style key always means an unchanged SGR string")
    func styleKeyNeverCollapsesDistinctStyles() {
        // One raw value per `TerminalColor` case, plus the two that go through
        // the fallback (unknown tag, and a named index above the table).
        let colors: [UInt32] = [
            0x0000_0000, 0x0000_0003, 0x0000_0010, // named: default, 3, max
            0x0000_0011, // past the 16-entry table -> falls back to default
            0x0100_00AB, // indexed
            0x020A_141E, // rgb
            0x0300_0005, // unknown tag -> falls back to default
        ]
        var modifiers: [UInt16] = [0]
        for bit in UInt16(0) ..< 9 {
            modifiers.append(1 << bit)
        }
        // Extended underline styles live in the top nibble.
        for style in UInt16(2) ... 5 {
            modifiers.append(CellModifier.underline | (style << 12))
        }

        func cell(_ foreground: UInt32, _ background: UInt32, _ modifier: UInt16) -> CellData {
            CellData(
                symbol: "x",
                foreground: foreground,
                background: background,
                modifier: modifier,
                skip: false,
                hyperlink: nil
            )
        }

        var byKey: [SurfaceANSIRenderer.CellStyleKey: String] = [:]
        for foreground in colors {
            for background in colors {
                for modifier in modifiers {
                    let sample = cell(foreground, background, modifier)
                    let key = SurfaceANSIRenderer.CellStyleKey(cell: sample)
                    let sgr = StyleCode.encode(sample)
                    if let seen = byKey[key] {
                        // The same key twice is only allowed if the bytes match too.
                        #expect(
                            seen == sgr,
                            "key \(key) encodes as both \(seen) and \(sgr)"
                        )
                    } else {
                        byKey[key] = sgr
                    }
                }
            }
        }
        #expect(byKey.count > 100, "expected a broad sweep, got \(byKey.count)")
    }

    /// A repeated style must be written once per run, not once per cell, and the
    /// row must still come out correctly styled. This pins the *behaviour* half
    /// of issue #49 without measuring time.
    @Test("a repeated style is written once per run, not once per cell")
    func repeatedStyleIsWrittenOncePerRun() {
        let width: UInt16 = 16
        let cell = CellData(
            symbol: "a",
            foreground: 0x0000_0003,
            background: 0x0100_0002,
            modifier: CellModifier.bold,
            skip: false,
            hyperlink: nil
        )
        let frame = FrameData(
            cells: Array(repeating: cell, count: Int(width)),
            width: width,
            height: 1,
            cursor: CursorState(column: 0, row: 0, visible: true, shape: 0),
            hyperlinks: [],
            graphics: Data()
        )
        var renderer = SurfaceANSIRenderer()
        let text = String(bytes: renderer.render(frame), encoding: .utf8) ?? ""

        let sgrRuns = text.components(separatedBy: "\u{1B}[0").count - 1
        // Three prefixes for the whole frame: the 16-cell run, the row-end reset,
        // and the frame's trailing reset. Encoding per cell would emit one per
        // cell (16) plus those two.
        #expect(sgrRuns <= 3, "expected one SGR run for a uniform row, got \(sgrRuns): \(text)")
        // The style itself must still be right: bold, named(3) -> 32, indexed(2).
        // The renderer writes `ESC[0` + style + `m`, so the bold `1` lands after
        // the reset byte.
        #expect(text.contains("\u{1B}[01;32;48;5;2m"), "style missing from \(text)")
        #expect(!text.contains("39"), "a styled row must not reset to default: \(text)")
    }
}
