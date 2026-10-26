// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  PaletteUpstreamTests.swift
//  KraalClientTests
//
//  Every colour in the built-in theme table, checked against upstream's own table.
//
//  `Palette+Builtin.swift` is a transcription of `src/app/state.rs:78-527`: 18 themes x
//  19 colours = 342 numbers. A transcription mistake produces no failing test on its own
//  — `nord` just looks slightly wrong, which nobody reports precisely. Before this file
//  only two of the 342 were pinned.
//
//  The reference is `Fixtures/upstream-palettes.json`, regenerated from upstream by
//  `Scripts/palette-verify.py`. Keeping it as data rather than reading the Rust source at
//  test time means the test does not depend on a checkout that only exists on one
//  machine.
//
//  Source: herdr `src/app/state.rs` (Apache-2.0).
//

import Foundation
import Testing

@testable import KraalUI

@Suite("Palette against upstream")
struct PaletteUpstreamTests {
    /// One colour, with both names: upstream's and this client's.
    ///
    /// The mapping lives here, in one table, and the test walks it. If `Palette+Builtin`
    /// and this file disagreed about which upstream field maps to which Swift property,
    /// a copy of the same mistake in both places would still compare equal — so the
    /// mapping is asserted to be total for every field the fixture carries.
    struct Field {
        var upstream: String
        var read: @Sendable (Palette) -> UInt32?
    }

    static let fields: [Field] = [
        Field(upstream: "accent") { $0.accent },
        Field(upstream: "panel_bg") { $0.panelBackground },
        Field(upstream: "sidebar_bg") { $0.sidebarBackground },
        Field(upstream: "active_row_bg") { $0.activeRowBackground },
        Field(upstream: "selection_bg") { $0.selectionBackground },
        Field(upstream: "surface0") { $0.surface0 },
        Field(upstream: "surface1") { $0.surface1 },
        Field(upstream: "surface_dim") { $0.surfaceDim },
        Field(upstream: "overlay0") { $0.overlay0 },
        Field(upstream: "overlay1") { $0.overlay1 },
        Field(upstream: "text") { $0.text },
        Field(upstream: "subtext0") { $0.subtext0 },
        Field(upstream: "mauve") { $0.mauve },
        Field(upstream: "green") { $0.green },
        Field(upstream: "yellow") { $0.yellow },
        Field(upstream: "red") { $0.red },
        Field(upstream: "blue") { $0.blue },
        Field(upstream: "teal") { $0.teal },
        Field(upstream: "peach") { $0.peach },
    ]

    struct Reference: Decodable {
        var themes: [String: [String: UInt32?]]
    }

    static func reference() throws -> Reference {
        let url = Bundle.module.url(
            forResource: "upstream-palettes",
            withExtension: "json",
            subdirectory: "Fixtures"
        )
        guard let url else {
            throw FixtureError.missing("upstream-palettes.json")
        }
        return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    }

    enum FixtureError: Error { case missing(String) }

    static var themeNames: [String] {
        (try? reference().themes.keys.sorted()) ?? []
    }

    /// Every theme upstream defines is present here, with every one of its 19 colours.
    @Test("all 18 themes match upstream colour for colour", arguments: themeNames)
    func matchesUpstream(name: String) throws {
        let expected = try Self.reference().themes[name]
        let theme = try #require(expected, "\(name) is missing from the fixture")
        let palette = try #require(Palette.named(name), "\(name) has no palette")

        for field in Self.fields {
            // `[String: UInt32?]`的 subscript 是双层可选：一层表示「键不存在」，
            // 一层表示「值就是 null(=Reset)」。`flatMap` 明确取后者，不用 `?? nil`
            // （swiftlint 会判为冗余）。
            let reference = theme[field.upstream].flatMap { $0 }
            let actual = field.read(palette)
            #expect(
                actual == reference,
                "\(name).\(field.upstream): \(Self.hex(actual)) != \(Self.hex(reference))"
            )
        }
    }

    /// The fixture covers exactly the fields this test walks.
    ///
    /// Without this, a field deleted from `Palette` would drop out of the comparison
    /// silently: the loop only asserts fields it knows about, so a shrinking field list
    /// looks like continued success.
    @Test("the fixture and the field list agree on which colours exist")
    func fixtureCoversEveryField() throws {
        let reference = try Self.reference()
        for (name, values) in reference.themes {
            let fixtureKeys = Set(values.keys)
            let walked = Set(Self.fields.map(\.upstream))
            #expect(fixtureKeys == walked, "\(name): fixture has \(fixtureKeys.sorted())")
        }
        #expect(reference.themes.count == 18, "upstream defines 18 themes")
    }

    /// `Color::Reset` is "let the terminal decide", not black.
    ///
    /// It is easy to transcribe it as `0x000000`, which paints a black band where the
    /// terminal's own background should show through — visible immediately, but only in
    /// themes that actually use Reset.
    @Test("Reset stays nil instead of becoming black")
    func resetStaysNil() throws {
        let reference = try Self.reference()
        // `terminal` is the theme built almost entirely from Reset.
        let terminal = try #require(reference.themes["terminal"])
        let resetFields = Self.fields.filter { terminal[$0.upstream].flatMap { $0 } == nil }
        #expect(!resetFields.isEmpty, "terminal should use Color::Reset somewhere")

        let palette = try #require(Palette.named("terminal"))
        for field in resetFields {
            #expect(field.read(palette) == nil,
                    "terminal.\(field.upstream) became \(Self.hex(field.read(palette)))")
        }
    }

    static func hex(_ value: UInt32?) -> String {
        guard let value else { return "nil" }
        return String(format: "#%06X", value)
    }
}
