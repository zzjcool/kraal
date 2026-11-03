// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The palette list is data, not a view: which rows exist, in what order, how a
// query ranks them, and which key each row climbs onto. Everything here runs
// without a window and without reading keys.json.

import KraalActions
import Testing

@testable import KraalHCTerminal

@Suite("HcPaletteTests")
struct HcPaletteTests {
    /// Every row the palette would show if the window implemented everything.
    private let entries = HcPaletteCatalog.entries(canPerform: { _ in true })

    @Test("an empty query lists every group in upstream order")
    func groupOrder() {
        let groups = HcPaletteSearch.groups(query: "", entries: entries)
        #expect(groups.map(\.title) == ["Tab", "Pane", "Space", "Terminal", "Agent", "Window", "App"])
        let tabTitles = groups.first?.entries.map(\.title) ?? []
        #expect(Array(tabTitles.prefix(2)) == ["New tab", "Go to space or tab…"])
    }

    @Test("a query matches the command name")
    func commandName() {
        let names = HcPaletteSearch.groups(query: "pane.close", entries: entries)
            .flatMap(\.entries)
            .map(\.name)
        #expect(names == ["pane.close"])
    }

    @Test("a query matches the description keywords")
    func keywords() {
        let clipboard = HcPaletteSearch.groups(query: "clipboard", entries: entries)
            .flatMap(\.entries)
            .map(\.name)
        #expect(clipboard.count == 2)
        #expect(Set(clipboard) == ["terminal.copy", "terminal.paste"])
        let preferences = HcPaletteSearch.groups(query: "preferences", entries: entries)
            .flatMap(\.entries)
            .map(\.name)
        #expect(preferences == ["app.settings"])
        let prefix = HcPaletteSearch.groups(query: "pref", entries: entries)
            .flatMap(\.entries)
            .map(\.name)
        #expect(prefix.contains("app.settings"))
    }

    @Test("split surfaces both split rows first")
    func splitRows() {
        let ids = HcPaletteSearch.groups(query: "split", entries: entries).flatMap(\.entries).map(\.id)
        #expect(Set(ids.prefix(2)) == ["pane.split:right", "pane.split:down"])
    }

    @Test("a word-start match ranks above a mid-word one")
    func wordStartWins() throws {
        let wordStart = try #require(HcPaletteSearch.score("tab", entry: named("tab.new", "New tab")))
        let midWord = try #require(HcPaletteSearch.score("tab", entry: named("app.stable", "Stable")))
        #expect(wordStart > midWord)
    }

    @Test("actions Kraal does not implement never appear")
    func unsupportedAbsent() {
        let names = Set(entries.map(\.name))
        #expect(!names.contains("layout.switch"))
        #expect(!names.contains("mod.clone"))
        #expect(!names.contains("app.welcome"))
        #expect(!names.contains("terminal.paste_image"))
    }

    @Test("only what the window can run is listed")
    func canPerformFilter() {
        // The place picker is not an action: it opens ⌘P's overlay, so it stays
        // even when the window can run nothing at all.
        let names = HcPaletteCatalog.entries(canPerform: { _ in false }).map(\.name)
        #expect(names == ["mod.open"])
    }

    @Test("rows take their keycaps from the shipped keys")
    func keycaps() throws {
        let bindings = try KraalKeymap.parse(KraalKeymap.defaultMacOS)
        let palette = try #require(entries.first { $0.name == "app.palette" })
        #expect(HcPaletteKeycaps.keys(for: palette, bindings: bindings) == "cmd-shift-p")
        let settings = try #require(entries.first { $0.name == "app.settings" })
        #expect(HcPaletteKeycaps.keys(for: settings, bindings: bindings) == "cmd-,")
    }

    @Test("the two split rows get their own direction's key")
    func splitKeycaps() throws {
        let bindings = try KraalKeymap.parse(KraalKeymap.defaultMacOS)
        let splits = entries.filter { $0.name == "pane.split" }
        let keys = splits.map { HcPaletteKeycaps.keys(for: $0, bindings: bindings) ?? "" }
        #expect(keys == ["cmd-d", "cmd-shift-d"])
    }

    private func named(_ name: String, _ title: String, group: String = "App") -> HcPaletteEntry {
        HcPaletteEntry(name: name, title: title, group: group)
    }
}
