// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The theme tokens are measured, not invented: these assertions are the values
// sampled from the official app's screenshots in docs/audits/2026-11/. If a
// preset or a mix factor drifts, this fails before a VM run hides it.

import Testing

@testable import KraalHCTerminal

@Suite("Theme tokens")
struct HcThemeTests {
    @Test("light chrome and pane are the measured paper values")
    func lightMeasured() {
        let theme = HcTheme.resolve(.paper)
        #expect(theme.isLight)
        #expect(theme.chrome.hex == "#f1f1ee")
        #expect(theme.canvas.hex == "#ffffff")
        #expect(theme.paneHeader.hex == "#ffffff")
        #expect(theme.popover.hex == "#ffffff")
        #expect(theme.background.hex == "#ffffff")
        #expect(theme.terminalForeground.hex == "#25272c")
    }

    @Test("dark chrome, canvas, pane header and popover are the measured graphite values")
    func darkMeasured() {
        let theme = HcTheme.resolve(.graphite)
        #expect(!theme.isLight)
        #expect(theme.chrome.hex == "#0a0b0d")
        #expect(theme.canvas.hex == "#0f1013")
        #expect(theme.paneHeader.hex == "#0f1013")
        #expect(theme.popover.hex == "#25272b")
        #expect(theme.raised.hex == "#2c2e31")
        #expect(theme.background.hex == "#17191d")
    }

    @Test("every dark preset keeps its own terminal background")
    func darkPresets() {
        let backgrounds = HcThemeName.presets(isLight: false).map { HcTheme.resolve($0).background.hex }
        #expect(backgrounds == ["#17191d", "#111720", "#151c19", "#21252b"])
        #expect(HcThemeName.presets(isLight: true) == [.paper])
        for name in HcThemeName.allCases {
            let theme = HcTheme.resolve(name)
            #expect(theme.ansi.count == 16)
            #expect(theme.isLight == (name == .paper))
            #expect(theme.chrome != theme.canvas)
        }
    }

    @Test("appearance picks the half it names and never crosses light/dark")
    func appearance() {
        #expect(HcTheme.resolve(.light, light: .paper, dark: .graphite, systemIsDark: true).name == .paper)
        #expect(HcTheme.resolve(.dark, light: .paper, dark: .moss, systemIsDark: false).name == .moss)
        #expect(HcTheme.resolve(.system, light: .paper, dark: .moss, systemIsDark: true).name == .moss)
        #expect(HcTheme.resolve(.system, light: .paper, dark: .moss, systemIsDark: false).name == .paper)
        // A light name in the dark slot (or the other way round) falls back, so a
        // hand-edited blob cannot paint a dark window white.
        #expect(HcTheme.resolve(.dark, light: .paper, dark: .paper, systemIsDark: true).name == .graphite)
        #expect(HcTheme.resolve(.light, light: .ink, dark: .graphite, systemIsDark: false).name == .paper)
    }

    @Test("mix rounds like the Rust derivation and keeps the source alpha")
    func mixing() {
        let half = HcColor.mix(HcColor(rgb: 0x000000), HcColor(rgb: 0xFFFFFF), 0.5)
        #expect(half.hex == "#808080")
        let translucent = HcColor(rgb: 0xFFFFFF, alpha: 0x17)
        let mixed = HcColor.mix(translucent, .black, 0.5)
        #expect(mixed.alpha == 0x17)
        #expect(mixed.hex == "#808080" + "17")
    }

    @Test("a token round-trips through hex, with and without alpha")
    func hexRoundTrip() {
        #expect(HcColor(hex: "#F1F1EE")?.hex == "#f1f1ee")
        #expect(HcColor(hex: "0a0b0d")?.hex == "#0a0b0d")
        #expect(HcColor(hex: "#ffffff0e")?.hex == "#ffffff0e")
        #expect(HcColor(hex: "#ffffff0e")?.alpha == 0x0E)
        #expect(HcColor(hex: "#12345") == nil)
        #expect(HcColor(hex: "nothex") == nil)
    }

    @Test("theme names use the upstream spelling and swatch labels")
    func names() {
        #expect(HcThemeName.atomOneDark.rawValue == "atom-one-dark")
        #expect(HcThemeName.atomOneDark.displayName == "atom one dark")
        #expect(HcThemeName.graphite.displayName == "graphite")
        #expect(HcThemeName(rawValue: "paper") == .paper)
        #expect(HcThemeName(rawValue: "Graphite") == nil)
    }
}
