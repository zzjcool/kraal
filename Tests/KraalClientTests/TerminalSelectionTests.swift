// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

@testable import KraalUI
import Testing

/// The colour a selection is highlighted with.
///
/// The defect this pins: the client wrote exactly three config keys to libghostty
/// (`background`, `window-padding-x/y`, `window-padding-color`), so the selection
/// highlight kept libghostty's built-in value — a neutral grey — in every theme. Measured
/// on gruvbox: the theme's own `selection_background` is `#4B3F27`, the pane highlighted
/// in `#303030` (afterglow's), i.e. a colour from a theme the client does not even use.
///
/// Only the highlight's background crosses over. `selection-foreground` is deliberately
/// left alone: unset, the engine keeps each cell's own ink, which is a better contrast
/// answer than any single colour we could pick here.
@Suite("Terminal selection colour")
struct TerminalSelectionTests {
    @Test("a theme's own selection background wins")
    func explicitTokenWins() {
        let palette = Palette(selectionBackground: 0xBDD0F5)
        #expect(palette.selectionBackgroundHex == "BDD0F5")
    }

    @Test("gruvbox resolves to its own #4B3F27")
    func gruvboxResolves() {
        #expect(Palette.gruvbox.selectionBackgroundHex == "4B3F27")
    }

    @Test("no token means no override, not a guessed colour")
    func noTokenNoOverride() {
        // A hand-built palette must stay able to say "keep the engine's default": guessing
        // here would paint a highlight nobody asked for.
        #expect(Palette().selectionBackgroundHex == nil)
    }

    @Test("it is not derived from the terminal background")
    func independentOfBackground() {
        // `terminalBackground` has a `surface_dim` fallback because a *pane* with no
        // background is visible as a band. A selection has no such failure mode, so
        // borrowing `surface_dim` here would silently highlight every theme's selection in
        // its dimmest surface colour.
        let palette = Palette(terminalBackground: 0x222222, surfaceDim: 0x111111)
        #expect(palette.selectionBackgroundHex == nil)
    }

    @Test("the hex is zero-padded")
    func zeroPadding() {
        #expect(Palette(selectionBackground: 0x000A0B).selectionBackgroundHex == "000A0B")
    }
}
