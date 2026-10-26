// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  ChromeColourTests.swift
//  KraalClientTests
//
//  The palette's role-to-Color resolution, which the views now depend on.
//
//  Before this, nine views injected `@Environment(\.palette)` and two read it: the
//  theme only ever changed sidebar *text*. Chrome (row highlight, tab pill, sidebar
//  tint) was system colour, so picking `nord` and picking `catppuccin` looked the same.
//
//  These tests pin the resolution rules, not the pixels. Two rules matter:
//
//  1. a set token must win — that is what "the theme applies" means;
//  2. an unset token must fall back to something *visible and platform-appropriate*,
//     never to black. `Color::Reset` upstream means "let the terminal decide", and a
//     black band over a light terminal is the classic transcription mistake.
//

import SwiftUI
import Testing

@testable import KraalUI

@Suite("Chrome colour resolution")
struct ChromeColourTests {
    private func palette(
        activeRow: UInt32? = nil,
        sidebar: UInt32? = nil,
        panel: UInt32? = nil,
        selection: UInt32? = nil,
        surfaceDim: UInt32? = nil,
        overlay0: UInt32? = nil,
        accent: UInt32? = nil
    ) -> Palette {
        var palette = Palette()
        palette.activeRowBackground = activeRow
        palette.sidebarBackground = sidebar
        palette.panelBackground = panel
        palette.selectionBackground = selection
        palette.surfaceDim = surfaceDim
        palette.overlay0 = overlay0
        palette.accent = accent
        return palette
    }

    /// A resolved colour's channels.
    ///
    /// `Color` has no useful equality, so colours are compared through sRGB components.
    /// A named struct rather than a tuple because four members is past the lint limit
    /// and, more to the point, `.alpha` reads better than `.3` at every call site.
    private struct Channels {
        var red: Double
        var green: Double
        var blue: Double
        var alpha: Double
    }

    private func channels(_ color: Color) -> Channels? {
        guard let resolved = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return Channels(
            red: Double(resolved.redComponent),
            green: Double(resolved.greenComponent),
            blue: Double(resolved.blueComponent),
            alpha: Double(resolved.alphaComponent)
        )
    }

    private func rgb(_ value: UInt32) -> Channels {
        Channels(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            alpha: 1
        )
    }

    private func isClose(_ color: Color, _ expected: Channels, tolerance: Double = 0.01) -> Bool {
        guard let actual = channels(color) else { return false }
        return abs(actual.red - expected.red) < tolerance
            && abs(actual.green - expected.green) < tolerance
            && abs(actual.blue - expected.blue) < tolerance
    }

    // MARK: - A set token wins

    /// The whole point of the change: `active_row_bg` from the theme reaches the row.
    @Test("a themed row highlight is the theme's colour")
    func themedRowHighlight() {
        let nord = palette(activeRow: 0x434C5E)
        #expect(isClose(nord.activeRowColor, rgb(0x434C5E)),
                "the row highlight ignored the theme")
    }

    @Test("a themed sidebar and panel colour reach the container")
    func themedContainers() {
        let themed = palette(sidebar: 0x2E3440, panel: 0x3B4252)
        #expect(isClose(themed.sidebarColor, rgb(0x2E3440)))
        #expect(isClose(themed.panelColor, rgb(0x3B4252)))
    }

    @Test("a themed selection colour reaches the tab pill")
    func themedSelection() {
        let themed = palette(selection: 0x40505D)
        #expect(isClose(themed.selectionColor, rgb(0x40505D)))
        #expect(themed.hasSelectionColor)
    }

    @Test("a themed accent reaches the focus borders")
    func themedAccent() {
        let themed = palette(accent: 0x88C0D0)
        #expect(isClose(themed.accentColor, rgb(0x88C0D0)))
    }

    // MARK: - An unset token falls back, never to black

    /// A row with no fill cannot be told from its neighbours, so the fallback has to be
    /// visible. It is the accent at low opacity rather than a literal.
    @Test("an unset row highlight is still visible")
    func unsetRowHighlightIsVisible() {
        let bare = palette()
        guard let actual = channels(bare.activeRowColor) else {
            Issue.record("could not resolve the fallback colour")
            return
        }
        #expect(actual.alpha > 0.05, "the fallback row highlight is invisible")
        #expect(actual.alpha < 1.0, "a fallback must be a tint, not an opaque block")
    }

    /// `.clear` is the right answer only where something else is already drawn behind:
    /// the sidebar and panel sit over the window's glass.
    @Test("an unset sidebar and panel colour are clear, not black")
    func unsetContainersAreClear() {
        let bare = palette()
        for (name, color) in [("sidebar", bare.sidebarColor), ("panel", bare.panelColor)] {
            guard let actual = channels(color) else {
                Issue.record("\(name) did not resolve")
                continue
            }
            #expect(actual.alpha == 0,
                    "\(name) painted over the glass instead of leaving it")
        }
    }

    /// The selection fallback is the platform's own selection colour, which is not
    /// black and not clear.
    @Test("an unset selection colour is the platform's")
    func unsetSelectionIsPlatform() {
        let bare = palette()
        #expect(!bare.hasSelectionColor)
        guard let actual = channels(bare.selectionColor) else {
            Issue.record("selection fallback did not resolve")
            return
        }
        #expect(actual.alpha > 0.05, "the selection fallback is invisible")
        let platform = NSColor.selectedContentBackgroundColor.usingColorSpace(.sRGB)
        #expect(abs(actual.red - Double(platform?.redComponent ?? -1)) < 0.01,
                "the selection fallback is not the platform colour")
    }

    /// An unset `surface_dim` must resolve to the platform's separator.
    ///
    /// The assertion is on **alpha**, not on RGB: the platform separator is black at
    /// ~10% alpha (measured: `r=0 g=0 b=0 a=0.098`), which is a correct hairline over
    /// whatever is behind it. Testing "the RGB sum is not zero" — the first version of
    /// this test — asserted the wrong property and failed on a correct fallback.
    @Test("an unset separator is a platform hairline, not an opaque line")
    func unsetSeparatorIsPlatform() {
        let bare = palette()
        guard let actual = channels(bare.separatorColor) else {
            Issue.record("separator fallback did not resolve")
            return
        }
        #expect(actual.alpha > 0.02, "the separator is invisible")
        #expect(actual.alpha < 0.5, "the separator is too heavy to be a hairline")
    }

    /// Secondary text falls back to `.secondary`, which is legible in both appearances;
    /// a literal would disappear in one of them.
    @Test("unset muted text is not black")
    func unsetMutedIsNotBlack() {
        let bare = palette()
        guard let actual = channels(bare.mutedColor) else {
            Issue.record("muted fallback did not resolve")
            return
        }
        #expect(actual.alpha > 0.05, "muted text is invisible")
    }

    // MARK: - Two themes must actually differ

    /// The report was "picking a theme does not change anything". Two themes that both
    /// name a row background must resolve to different colours, or the wiring is inert.
    @Test("two themes produce different chrome")
    func themesDiffer() throws {
        let nord = try #require(Palette.named("nord"))
        let gruvbox = try #require(Palette.named("gruvbox"))
        #expect(!isClose(nord.activeRowColor, rgb(gruvbox.activeRowBackground ?? 0)),
                "two themes resolved to the same row highlight")
    }
}
