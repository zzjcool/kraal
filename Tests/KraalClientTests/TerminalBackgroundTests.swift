// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

@testable import KraalUI
import Testing

/// The colour the terminals are built with.
///
/// The defect this pins: Kraal never set a terminal background, so libghostty used its
/// own themes — `alabaster` `#F7F7F7` on light appearance, `afterglow` `#212121` on
/// dark. Measured on a gruvbox client: a `(247,247,247)` band appeared between two
/// `(17,20,25)` panes wherever a terminal painted its own background. The theme never
/// crosses the wire, so this token is the only thing that can fix it.
@Suite("Terminal background")
struct TerminalBackgroundTests {
    @Test("a theme's own terminal background wins")
    func explicitTokenWins() {
        let palette = Palette(terminalBackground: 0xAB12CD, surfaceDim: 0x111111)
        #expect(palette.terminalBackgroundHex == "AB12CD")
    }

    @Test("gruvbox resolves to its own #282828, not a libghostty default")
    func gruvboxResolves() {
        // #282828 is gruvbox's `background`; it also happens to be its `surface_dim`.
        #expect(Palette.gruvbox.terminalBackgroundHex == "282828")
    }

    @Test("a theme without either token leaves the terminal alone")
    func noTokenNoOverride() {
        // `nil` means "keep libghostty's own default", which is the pre-existing
        // behaviour and must stay reachable for a hand-built palette.
        #expect(Palette().terminalBackgroundHex == nil)
    }

    @Test("surface_dim is the fallback, because every built-in theme names it")
    func surfaceDimFallback() {
        let palette = Palette(surfaceDim: 0x1E1E2E)
        #expect(palette.terminalBackgroundHex == "1E1E2E")
    }

    @Test("the hex is zero-padded, so a dark colour cannot lose its digits")
    func zeroPadding() {
        #expect(Palette(terminalBackground: 0x000102).terminalBackgroundHex == "000102")
    }
}
