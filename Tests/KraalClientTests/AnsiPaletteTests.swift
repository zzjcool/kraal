// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import KraalProtocol
import Testing
@testable import KraalUI

/// Wire colours → sRGB, for the painter path.
///
/// The rules pinned here are the ones a renderer gets wrong silently: `.named(16)` is
/// "default foreground" rather than a 17th colour, the 6×6×6 cube's levels are not
/// multiples of 51, and a theme with no opinion falls back to `defaultDark` rather than
/// to black. Each expectation is computed from the rule, not copied from a run.
@Suite("ANSI palette")
struct AnsiPaletteTests {
    /// A table whose 16 entries are all distinct, so a slot mix-up shows up as a failure
    /// instead of coincidentally matching its neighbour.
    private static func fixture() -> AnsiPalette {
        AnsiPalette(
            foreground: 0xF0F0F0,
            background: 0x101010,
            cursor: 0x00FF00,
            named: (0 ..< 16).map { UInt32(0x11_0000) + UInt32($0) }
        )
    }

    @Test("named 1...16 are the table's own entries, in SGR order")
    func namedUsesTheTable() {
        let palette = Self.fixture()
        for slot in 0 ..< 16 {
            #expect(palette.rgb(.named(UInt8(slot) + 1)) == UInt32(0x11_0000) + UInt32(slot))
        }
    }

    @Test("named 0 is the default foreground, and a 17th colour does not exist")
    func namedZeroIsForeground() {
        let palette = Self.fixture()
        #expect(palette.rgb(.named(0)) == palette.foreground)
        // 16 is reachable from the wire and is bright white (`97`), not a default tag:
        // `TerminalColor(raw:)` maps 0...16 to `.named`, and SGR numbering is 1-based.
        #expect(palette.rgb(TerminalColor(raw: 16)) == palette.named[15])
        // Past the table is a fallback, never a crash: a hand-built table may be short.
        #expect(palette.rgb(.named(200)) == palette.foreground)
    }

    @Test("indexed 0...15 alias the named colours")
    func indexedAliasesNamed() {
        let palette = Self.fixture()
        for slot in 0 ..< 16 {
            #expect(palette.rgb(.indexed(UInt8(slot))) == palette.named[slot])
        }
    }

    @Test("the 6x6x6 cube steps by 95, not by 51")
    func indexedCube() {
        let palette = Self.fixture()
        #expect(palette.rgb(.indexed(16)) == 0x000000)
        // One blue step: level[1] is 95, where a 51-based ramp would say 0x33.
        #expect(palette.rgb(.indexed(17)) == 0x00005F)
        // 16 + 36*1 + 6*2 + 3 → red 95, green 135, blue 175.
        #expect(palette.rgb(.indexed(67)) == 0x5F87AF)
        // 196 is 16 + 36*5: red at full, green and blue at zero.
        #expect(palette.rgb(.indexed(196)) == 0xFF0000)
        #expect(palette.rgb(.indexed(231)) == 0xFFFFFF)
    }

    @Test("indexed 232...255 are 24 greys, ten apart, starting at 8")
    func indexedGreys() {
        let palette = Self.fixture()
        #expect(palette.rgb(.indexed(232)) == 0x080808)
        #expect(palette.rgb(.indexed(244)) == 0x808080)
        #expect(palette.rgb(.indexed(255)) == 0xEEEEEE)
    }

    @Test("direct rgb is passed through unchanged")
    func directRGBPassesThrough() {
        let palette = Self.fixture()
        #expect(palette.rgb(.rgb(red: 1, green: 2, blue: 3)) == 0x010203)
        #expect(palette.rgb(.rgb(red: 0, green: 0, blue: 0)) == 0x000000)
        #expect(palette.rgb(.rgb(red: 255, green: 255, blue: 255)) == 0xFFFFFF)
        // The same colour from the wire encoding, which is `0x02RRGGBB`.
        #expect(palette.rgb(TerminalColor(raw: 0x0201_0203)) == 0x010203)
    }

    @Test("defaultDark is a full table of plain 0xRRGGBB values")
    func defaultDarkShape() {
        let palette = AnsiPalette.defaultDark
        #expect(palette.named.count == 16)
        #expect(palette.foreground != palette.background)
        // No tag byte or alpha leaked into a channel.
        #expect(palette.named.allSatisfy { $0 <= 0xFFFFFF })
        #expect(palette.foreground <= 0xFFFFFF)
        #expect(palette.background <= 0xFFFFFF)
    }

    @Test("a theme with no opinion resolves to defaultDark, not to black")
    func emptyThemeFallsBack() {
        // `Palette()` carries every field as `nil`, the "let the terminal decide" case.
        #expect(AnsiPalette.from(Palette()) == AnsiPalette.defaultDark)
    }

    @Test("a theme's tokens are adopted for the roles they name")
    func themeTokensWin() {
        let palette = AnsiPalette.from(
            Palette(
                accent: 0xFD971F,
                terminalBackground: 0x272822,
                text: 0xF8F8F2,
                red: 0xF92672
            )
        )
        #expect(palette.foreground == 0xF8F8F2)
        #expect(palette.background == 0x272822)
        #expect(palette.cursor == 0xFD971F)
        // `red` fills the normal slot and its bright counterpart. These are SGR numbers:
        // `named(2)` is `31` (red), and the table slot behind it is 1.
        #expect(palette.rgb(.named(2)) == 0xF92672)
        #expect(palette.rgb(.named(10)) == 0xF92672)
        // Anything the theme did not name did not move. Slot 2 (green) is `named(3)`.
        #expect(palette.rgb(.named(3)) == AnsiPalette.defaultDark.named[2])
    }

    @Test("one missing token does not take the whole table down")
    func partialTheme() {
        let palette = AnsiPalette.from(Palette(green: 0xA6E22E))
        #expect(palette.rgb(.named(3)) == 0xA6E22E)
        #expect(palette.foreground == AnsiPalette.defaultDark.foreground)
        #expect(palette.background == AnsiPalette.defaultDark.background)
        // The failure mode this guards: `nil` -> 0x000000 would read as "black terminal".
        #expect(palette.background != 0x000000)
    }
}
