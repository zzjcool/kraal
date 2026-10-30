// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  GhosttyThemeTests.swift
//  KraalProtocolTests
//
//  The theme file format, and what "a file that cannot be rendered" means.
//

import Foundation
import Testing
@testable import KraalProtocol

struct GhosttyThemeTests {
    private static let gruvbox = """
    palette = 0=#282828
    palette = 1=#cc241d
    palette = 2=#98971a
    palette = 3=#d79921
    palette = 4=#458588
    palette = 5=#b16286
    palette = 6=#689d6a
    palette = 7=#a89984
    palette = 8=#928374
    palette = 9=#fb4934
    palette = 10=#b8bb26
    palette = 11=#fabd2f
    palette = 12=#83a598
    palette = 13=#d3869b
    palette = 14=#8ec07c
    palette = 15=#ebdbb2
    background = #282828
    foreground = #ebdbb2
    cursor-color = #ebdbb2
    cursor-text = #282828
    selection-background = #665c54
    """

    @Test func aCompleteFileParsesEveryField() throws {
        let theme = try #require(GhosttyTheme.parse(id: "gruvbox", name: "Gruvbox", text: Self.gruvbox))
        #expect(theme.background == "282828")
        #expect(theme.foreground == "ebdbb2")
        #expect(theme.cursor == "ebdbb2")
        #expect(theme.cursorText == "282828")
        #expect(theme.selectionBackground == "665c54")
        #expect(theme.ansi.count == 16)
        #expect(theme.ansi[1] == "cc241d")
        #expect(theme.ansi[15] == "ebdbb2")
        #expect(theme.isDark)
    }

    @Test func optionalColoursMayBeAbsent() throws {
        let text = Self.gruvbox
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("cursor") && !$0.hasPrefix("selection") }
            .joined(separator: "\n")
        let theme = try #require(GhosttyTheme.parse(id: "x", name: "X", text: text))
        #expect(theme.cursor == nil)
        #expect(theme.selectionBackground == nil)
        // `nil` is "the file did not say", not black: a black cursor-text is invisible.
        #expect(theme.ansi.count == 16)
    }

    @Test func aMissingPaletteEntryIsRefusedRatherThanHalfApplied() {
        let text = Self.gruvbox.replacingOccurrences(of: "palette = 15=#ebdbb2\n", with: "")
        #expect(GhosttyTheme.parse(id: "x", name: "X", text: text) == nil)
    }

    @Test func aMissingBackgroundIsRefused() {
        let text = Self.gruvbox.replacingOccurrences(of: "background = #282828\n", with: "")
        #expect(GhosttyTheme.parse(id: "x", name: "X", text: text) == nil)
    }

    @Test func commentsAndBlankLinesAreIgnored() throws {
        let text = "# a comment\n\n" + Self.gruvbox + "\n# trailing\n"
        let theme = try #require(GhosttyTheme.parse(id: "x", name: "X", text: text))
        #expect(theme.ansi.count == 16)
    }

    @Test func shortHexIsExpanded() throws {
        let text = Self.gruvbox.replacingOccurrences(of: "background = #282828", with: "background = #fff")
        let theme = try #require(GhosttyTheme.parse(id: "x", name: "X", text: text))
        #expect(theme.background == "ffffff")
        #expect(!theme.isDark)
    }

    @Test func luminanceAnswersWhichWayIsUp() {
        #expect(GhosttyTheme.luminance("000000") < 0.01)
        #expect(GhosttyTheme.luminance("ffffff") > 0.99)
        #expect(GhosttyTheme.luminance("nonsense") == 0.5)
    }

    @Test func valueRoundTrips() {
        #expect(GhosttyTheme.value("ebdbb2") == 0xEBDBB2)
        #expect(GhosttyTheme.value("#EBDBB2") == 0xEBDBB2)
        #expect(GhosttyTheme.value("xyz") == nil)
    }
}
