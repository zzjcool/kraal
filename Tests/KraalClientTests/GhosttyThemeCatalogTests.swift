// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  GhosttyThemeCatalogTests.swift
//  KraalClientTests
//
//  The bundled catalogue, and the palette derived from it.
//
//  These tests are the gate on the theme *files*: a truncated copy, a bad colour
//  or a duplicate name shows up here rather than as a theme that silently paints
//  nothing. That matters more than usual because the files are vendored — nobody
//  reads 51 copies in review.
//

import Foundation
import KraalProtocol
import Testing
@testable import KraalUI

@MainActor
struct GhosttyThemeCatalogTests {
    /// Pinned: adding or losing a theme file is a deliberate change, and a test
    /// that only said "more than 40" would let a broken copy slip through while
    /// another theme was added.
    static let expectedCount = 51

    @Test func everyBundledFileParses() {
        #expect(GhosttyThemeCatalog.all.count == Self.expectedCount)
        #expect(GhosttyThemeCatalog.all.allSatisfy { $0.ansi.count == 16 })
    }

    @Test func idsAreUnique() {
        let ids = GhosttyThemeCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func darkThemesComeFirst() {
        let flags = GhosttyThemeCatalog.all.map(\.isDark)
        // All the darks, then all the lights: the picker groups them and the order
        // is what makes that grouping free.
        #expect(flags == flags.sorted(by: { $0 && !$1 }))
    }

    @Test func namesAreMatchedHoweverTheyAreSpelled() {
        for spelling in ["Gruvbox Dark", "gruvbox dark", "gruvbox_dark", "GRUVBOX-DARK"] {
            #expect(GhosttyThemeCatalog.named(spelling)?.name == "Gruvbox Dark", "\(spelling) resolves")
        }
        #expect(GhosttyThemeCatalog.named("no such theme") == nil)
    }

    @Test func theKnownThemesAreThere() {
        for name in ["Catppuccin Mocha", "Catppuccin Latte", "Gruvbox Dark", "Nord", "Dracula"] {
            #expect(GhosttyThemeCatalog.named(name) != nil, "\(name) is bundled")
        }
        #expect(GhosttyThemeCatalog.named("Catppuccin Mocha")?.isDark == true)
        #expect(GhosttyThemeCatalog.named("Catppuccin Latte")?.isDark == false)
    }

    @Test func theDerivedPaletteIsTheThemesOwnColours() throws {
        let theme = try #require(GhosttyThemeCatalog.named("Gruvbox Dark"))
        let palette = Palette.derived(from: theme)
        #expect(palette.terminalBackground == 0x282828)
        #expect(palette.text == 0xEBDBB2)
        // The status roles are the ANSI colours, so "blocked" is the red the
        // terminal would have drawn.
        #expect(palette.red == 0xCC241D)
        #expect(palette.green == 0x98971A)
        #expect(palette.blue == 0x458588)
        #expect(palette.mauve == 0xB16286)
        // The sidebar stays transparent: the window material is the user's choice.
        #expect(palette.sidebarBackground == nil)
    }

    @Test func surfacesStepFromBackgroundTowardText() throws {
        let theme = try #require(GhosttyThemeCatalog.named("Catppuccin Mocha"))
        let palette = Palette.derived(from: theme)
        let background = GhosttyTheme.luminance(theme.background)
        let text = GhosttyTheme.luminance(theme.foreground)
        let dim = try #require(palette.surfaceDim)
        let surface0 = try #require(palette.surface0)
        let surface1 = try #require(palette.surface1)
        let dimL = luminance(dim)
        let surface0L = luminance(surface0)
        let surface1L = luminance(surface1)
        // Monotone and inside the pair: a surface brighter than the text or darker
        // than the background is a surface nobody can read on.
        #expect(background < dimL && dimL < surface0L && surface0L < surface1L && surface1L < text)
    }

    @Test func everyThemeIsReadable() {
        // Foreground against background, for all 51: a theme with no contrast is a
        // theme that renders as a blank rectangle.
        for theme in GhosttyThemeCatalog.all {
            let delta = abs(GhosttyTheme.luminance(theme.foreground) - GhosttyTheme.luminance(theme.background))
            #expect(delta > 0.25, "\(theme.name) has fg/bg luminance delta \(delta)")
        }
    }

    @Test func aPickedThemeWinsOverTheConfig() throws {
        let config = ThemeConfig(name: "nord", autoSwitch: false, darkName: nil, lightName: nil)
        let store = ThemeStore(
            config: config,
            appearance: .dark,
            environment: ["KRAAL_THEME": "gruvbox dark"]
        )
        #expect(store.themeName == "Gruvbox Dark")
        #expect(store.ghostty?.name == "Gruvbox Dark")
        #expect(store.palette.terminalBackground == 0x282828)

        let following = ThemeStore(config: config, appearance: .dark, environment: [:])
        #expect(following.ghostty == nil)
        #expect(following.themeName == "nord")
    }

    @Test func anUnknownPickFallsBackToTheConfig() {
        let config = ThemeConfig(name: "nord", autoSwitch: false, darkName: nil, lightName: nil)
        let store = ThemeStore(
            config: config,
            appearance: .dark,
            environment: ["KRAAL_THEME": "no such theme"]
        )
        #expect(store.themeName == "nord")
        #expect(store.ghostty == nil)
    }

    private func luminance(_ value: UInt32) -> Double {
        let hex = String(format: "%06x", value)
        return GhosttyTheme.luminance(hex)
    }
}
