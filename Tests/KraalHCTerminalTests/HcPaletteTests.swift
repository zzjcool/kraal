// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Testing

@testable import KraalHCTerminal

@Suite("Command palette")
struct HcPaletteTests {
    private let supported: Set<String> = [
        "space.new", "tab.new", "pane.split", "pane.close", "terminal.pin",
    ]

    @Test("only actions the window can run are listed")
    func filters() {
        let groups = HcPaletteSearch.groups(query: "") { supported.contains($0) }
        let names = groups.flatMap(\.entries).map(\.name)
        #expect(names == ["space.new", "tab.new", "pane.split", "pane.close", "terminal.pin"])
        #expect(groups.map(\.title) == ["Spaces", "Tabs", "Panes", "Terminals"])
    }

    @Test("a query searches the name and the explanation")
    func fuzzy() {
        let byName = HcPaletteSearch.groups(query: "split") { supported.contains($0) }
        #expect(byName.flatMap(\.entries).map(\.name) == ["pane.split"])
        let byAbout = HcPaletteSearch.groups(query: "pin") { supported.contains($0) }
        #expect(byAbout.flatMap(\.entries).map(\.name) == ["terminal.pin"])
    }

    @Test("an empty query keeps catalog order, not alphabetical order")
    func order() {
        let all = Set(["tab.close", "tab.new"])
        let names = HcPaletteSearch.groups(query: "") { all.contains($0) }
            .flatMap(\.entries).map(\.name)
        #expect(names == ["tab.new", "tab.close"])
    }

    @Test("every word must match")
    func allWords() {
        let groups = HcPaletteSearch.groups(query: "pane close") { supported.contains($0) }
        #expect(groups.flatMap(\.entries).map(\.name) == ["pane.close"])
        let none = HcPaletteSearch.groups(query: "pane pin") { supported.contains($0) }
        #expect(none.isEmpty)
    }
}
