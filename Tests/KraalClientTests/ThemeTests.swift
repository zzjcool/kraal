// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  ThemeTests.swift
//  KraalClientTests
//
//  Theme resolution: name canonicalisation, config parsing, light/dark switching.
//
//  These exist because the failure mode is silent. A config with `theme.name = "Nord"`
//  that draws Catppuccin looks like a working app with the wrong colours, not like a
//  bug — nothing errors, nothing logs, and the user cannot tell whether they typed it
//  wrong. Every alias upstream accepts is therefore pinned here.
//

import Foundation
import Testing

@testable import KraalUI

@Suite("Theme")
struct ThemeTests {
    // MARK: - Name canonicalisation

    @Test(
        "names are canonicalised the way upstream does",
        arguments: [
            // (written, canonical) — from src/config/theme.rs:25-46
            ("catppuccin", "catppuccin"),
            ("Catppuccin Mocha", "catppuccin"),
            ("catppuccin_mocha", "catppuccin"),
            ("catppuccin-latte", "catppuccin-latte"),
            ("Latte", "catppuccin-latte"),
            ("light", "catppuccin-latte"),
            ("Tokyo_Night", "tokyo-night"),
            ("tokyonight", "tokyo-night"),
            ("gruvbox-dark", "gruvbox"),
            ("One Dark", "one-dark"),
            ("rose_pine_dawn", "rose-pine-dawn"),
            ("dawn", "rose-pine-dawn"),
            ("vesper", "vesper"),
        ]
    )
    func canonicalNames(written: String, canonical: String) {
        #expect(Palette.canonicalThemeName(written) == canonical,
                "\(written) should resolve to \(canonical)")
    }

    @Test("an unknown name has no palette")
    func unknownNameIsNil() {
        #expect(Palette.canonicalThemeName("solarized-mocha-latte") == nil)
        #expect(Palette.named("solarized-mocha-latte") == nil)
    }

    /// Every canonical name upstream lists must resolve to a real palette. A missing
    /// arm in `builtin` would make that theme silently fall back to Catppuccin.
    @Test("every built-in theme resolves")
    func everyThemeResolves() {
        let names = [
            "catppuccin", "catppuccin-latte", "terminal", "tokyo-night",
            "tokyo-night-day", "dracula", "nord", "gruvbox", "gruvbox-light",
            "one-dark", "one-light", "solarized", "solarized-light", "kanagawa",
            "kanagawa-lotus", "rose-pine", "rose-pine-dawn", "vesper",
        ]
        for name in names {
            #expect(Palette.named(name) != nil, "\(name) has no palette")
        }
    }

    /// Two themes must actually differ. If a transcription error copied Catppuccin's
    /// numbers into `nord`, every "it resolved" assertion above would still pass.
    @Test("built-in themes are distinct")
    func themesAreDistinct() {
        let catppuccin = Palette.named("catppuccin")
        let nord = Palette.named("nord")
        #expect(catppuccin != nord)
        #expect(catppuccin?.panelBackground != nord?.panelBackground)
    }

    /// The values are transcribed from `src/app/state.rs`. Pinning two makes a
    /// mis-transcription visible instead of "some colours".
    @Test("transcribed colours match upstream")
    func coloursMatchUpstream() {
        let catppuccin = Palette.named("catppuccin")
        #expect(catppuccin?.accent == 0x89B4_FA)   // state.rs:80  accent: 137,180,250
        #expect(catppuccin?.text == 0xCDD6_F4)     // state.rs:88  text: 205,214,244
    }

    // MARK: - config.toml

    @Test("the [theme] table is read")
    func parsesThemeTable() {
        let config = ThemeConfig.parse("""
        [theme]
        name = "nord"
        auto_switch = true
        dark_name = "gruvbox"
        light_name = "gruvbox-light"
        """)
        #expect(config.name == "nord")
        #expect(config.autoSwitch)
        #expect(config.darkName == "gruvbox")
        #expect(config.lightName == "gruvbox-light")
    }

    @Test("keys outside [theme] are ignored")
    func ignoresOtherTables() {
        let config = ThemeConfig.parse("""
        [ui]
        name = "not-a-theme"
        accent = "red"

        [theme]
        name = "dracula"

        [keys]
        prefix = "ctrl+a"
        """)
        #expect(config.name == "dracula")
    }

    /// `[theme.custom]` is a subtable: its keys are not `[theme]`'s.
    @Test("a subtable ends the [theme] table")
    func subtableEndsTheme() {
        let config = ThemeConfig.parse("""
        [theme]
        name = "nord"

        [theme.custom]
        name = "should-not-win"
        """)
        #expect(config.name == "nord")
    }

    @Test("comments and quoting do not leak into the value")
    func stripsCommentsAndQuotes() {
        let config = ThemeConfig.parse("""
        [theme]
        name = "one-dark"   # my favourite
        auto_switch = false
        """)
        #expect(config.name == "one-dark")
        #expect(!config.autoSwitch)
    }

    @Test("an empty or missing table means defaults")
    func defaultsWhenAbsent() {
        #expect(ThemeConfig.parse("") == .default)
        #expect(ThemeConfig.parse("[ui]\naccent = \"red\"") == .default)
        #expect(ThemeConfig.default.name == nil)
        #expect(!ThemeConfig.default.autoSwitch)
    }

    // MARK: - Resolution

    @Test("without auto_switch the manual name wins")
    func manualNameWins() {
        let config = ThemeConfig(name: "nord", autoSwitch: false, darkName: "dracula", lightName: nil)
        let resolved = ThemeResolver.resolve(config, appearance: .light)
        #expect(resolved.name == "nord")
        #expect(resolved.palette == Palette.named("nord"))
    }

    @Test("auto_switch follows the appearance")
    func autoSwitchFollowsAppearance() {
        let config = ThemeConfig(name: "nord", autoSwitch: true, darkName: "dracula", lightName: "one-light")
        #expect(ThemeResolver.resolve(config, appearance: .dark).name == "dracula")
        #expect(ThemeResolver.resolve(config, appearance: .light).name == "one-light")
    }

    /// With `auto_switch` on and no names given, the sibling of the manual theme is
    /// used — otherwise turning on auto-switch would jump to Catppuccin.
    @Test("auto_switch without explicit names uses the sibling")
    func autoSwitchUsesSibling() {
        let config = ThemeConfig(name: "gruvbox", autoSwitch: true, darkName: nil, lightName: nil)
        #expect(ThemeResolver.resolve(config, appearance: .dark).name == "gruvbox")
        #expect(ThemeResolver.resolve(config, appearance: .light).name == "gruvbox-light")
    }

    @Test("sibling pairs match upstream")
    func siblingPairs() {
        #expect(ThemeResolver.siblings(of: "catppuccin").light == "catppuccin-latte")
        #expect(ThemeResolver.siblings(of: "catppuccin-latte").dark == "catppuccin")
        #expect(ThemeResolver.siblings(of: "rose-pine-dawn").dark == "rose-pine")
        // A theme with no partner stays itself, so auto-switch is a no-op for it.
        #expect(ThemeResolver.siblings(of: "vesper").light == "vesper")
    }

    /// A typo must not produce an invisible client: fall back and keep going.
    @Test("an unknown name falls back instead of drawing nothing")
    func unknownNameFallsBack() {
        let config = ThemeConfig(name: "not-a-theme", autoSwitch: false, darkName: nil, lightName: nil)
        let resolved = ThemeResolver.resolve(config, appearance: .dark)
        #expect(resolved.name == "catppuccin")
    }

    @Test("defaults to catppuccin like upstream")
    func defaultsToCatppuccin() {
        let resolved = ThemeResolver.resolve(.default, appearance: .dark)
        #expect(resolved.name == "catppuccin")
    }

    // MARK: - Rendering

    /// `nil` means "no opinion" upstream (`Color::Reset`), and must stay transparent
    /// rather than becoming black — a `terminal` theme over a light terminal would
    /// otherwise paint black behind the sidebar.
    @Test("an unset token falls back rather than turning black")
    func unsetTokenFallsBack() {
        let palette = Palette.named("terminal")
        #expect(palette?.sidebarBackground == nil)
        #expect(palette?.sidebarColor == .clear)
    }

    /// The sidebar's token resolver speaks names, so the palette has to answer for
    /// them; without this a themed client still drew the hard-coded green.
    @Test("colour names resolve through the palette")
    func namesResolveThroughPalette() {
        let nord = Palette.named("nord")
        let gruvbox = Palette.named("gruvbox")
        let nordGreen = sidebarColor("green", palette: nord)
        let gruvboxGreen = sidebarColor("green", palette: gruvbox)
        #expect(nordGreen != gruvboxGreen,
                "green is the same colour in two themes — the palette is not being read")
    }

    @Test("without a palette the fixed table is still used")
    func noPaletteKeepsLegacyTable() {
        // Call sites that have no theme (previews, tests) must not break.
        #expect(sidebarColor("red") == sidebarColor("red", palette: nil))
    }
}

// MARK: - Reload

/// Reloading `config.toml` re-resolves the palette without a relaunch.
///
/// This is covered here rather than by a GUI case because the two ways a user reaches
/// "Reload Config" — the footer menu and the app menu — are both unusable from the
/// harness: the footer menu is an `AXMenuButton` whose items are not in the AX tree
/// until it opens, and the app menu item presses without running its selector because
/// the gate launches the app as an accessory (no key menu bar to track). The *reload*
/// is what needs covering, and it is pure logic once the file is on disk.
@Suite("Theme reload")
@MainActor
struct ThemeReloadTests {
    private func scratch() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kraal-theme-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ body: String, to dir: URL) throws {
        try body.write(
            to: dir.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
    }

    @Test("a reload picks up a changed theme name")
    func reloadPicksUpChange() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = ["HERDR_CONFIG_DIR": dir.path]

        try write("[theme]\nname = \"nord\"\n", to: dir)
        let store = ThemeStore(config: nil, appearance: .dark, environment: env)
        #expect(store.themeName == "nord")

        try write("[theme]\nname = \"dracula\"\n", to: dir)
        store.reloadFromDisk(environment: env)
        #expect(store.themeName == "dracula")
        #expect(store.palette == Palette.named("dracula"))
    }

    @Test("a reload that removes the theme falls back to the default")
    func reloadWithoutThemeFallsBack() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = ["HERDR_CONFIG_DIR": dir.path]

        try write("[theme]\nname = \"vesper\"\n", to: dir)
        let store = ThemeStore(config: nil, appearance: .dark, environment: env)
        #expect(store.themeName == "vesper")

        try write("[ui]\naccent = \"red\"\n", to: dir)
        store.reloadFromDisk(environment: env)
        #expect(store.themeName == "catppuccin")
    }

    /// The store must read the file itself when no config is passed. The first version
    /// defaulted to `.default` and every caller used the default, so the file was never
    /// read — the client silently drew Catppuccin while `theme.name = "nord"` sat there.
    @Test("a store built without a config reads the file")
    func defaultInitReadsFile() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("[theme]\nname = \"gruvbox\"\n", to: dir)
        let store = ThemeStore(
            config: nil,
            appearance: .dark,
            environment: ["HERDR_CONFIG_DIR": dir.path]
        )
        #expect(store.themeName == "gruvbox")
    }

    @Test("a reload without auto_switch keeps the manual theme")
    func reloadKeepsManualTheme() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = ["HERDR_CONFIG_DIR": dir.path]
        try write("[theme]\nname = \"nord\"\n", to: dir)
        let store = ThemeStore(config: nil, appearance: .light, environment: env)
        store.reloadFromDisk(environment: env)
        // The new appearance did not change, so the manual name still wins.
        #expect(store.themeName == "nord")
    }
}
