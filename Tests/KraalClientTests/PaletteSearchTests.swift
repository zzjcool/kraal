// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  PaletteSearchTests.swift
//  KraalClientTests
//
//  The palette's ranking, checked without a window. Each case is a query a
//  person would actually type, and the thing they would expect to find.
//

import Foundation
import Testing
@testable import KraalUI

@MainActor
struct PaletteSearchTests {
    /// A row with no `AppCommand` behind it, so a test can isolate the score.
    private struct Row: PaletteSearchable {
        let paletteTitle: String
        var paletteKeywords: [String] = []
        var paletteCategory: String = ""
    }

    private func titles(_ rows: [Row], _ query: String) -> [String] {
        PaletteSearch.rank(rows, query: query).map(\.paletteTitle)
    }

    @Test func emptyQueryKeepsTheCallerOrder() {
        let rows = [Row(paletteTitle: "Zed"), Row(paletteTitle: "Alpha")]
        #expect(titles(rows, "") == ["Zed", "Alpha"])
        #expect(titles(rows, "   ") == ["Zed", "Alpha"])
    }

    @Test func aKeywordFindsACommandWhoseTitleSaysSomethingElse() {
        // The menu says "Toggle Pane Zoom"; the user types "max".
        let found = PaletteSearch.rank(AppCommand.allCases, query: "max")
        #expect(found.first == .toggleZoom)
    }

    @Test func everyKeywordFindsItsCommand() {
        // "kill" is not in any title: it is the word someone uses for closing.
        let found = PaletteSearch.rank(AppCommand.allCases, query: "kill")
        #expect(found.contains(.closeTab))
        #expect(found.contains(.closePane))
        #expect(found.contains(.closeWorkspace))
    }

    @Test func twoWordsHaveToBothMatch() {
        let found = PaletteSearch.rank(AppCommand.allCases, query: "split down")
        #expect(found.first == .splitDown)
        #expect(!found.contains(.splitRight))
    }

    @Test func titleMatchOutranksKeywordMatch() {
        let rows = [
            Row(paletteTitle: "Something Else", paletteKeywords: ["zoom"]),
            Row(paletteTitle: "Zoom"),
        ]
        #expect(titles(rows, "zoom") == ["Zoom", "Something Else"])
    }

    @Test func theCategoryIsAWeakMatch() {
        let found = PaletteSearch.rank(AppCommand.allCases, query: "workspace")
        #expect(found.contains(.focusWorkspace3))
        #expect(found.contains(.newWorkspace))
    }

    @Test func fuzzySubsequenceIsTheLastResort() {
        // "tzm" is not a substring of anything; it is a subsequence of the title.
        let found = PaletteSearch.rank(AppCommand.allCases, query: "tzm")
        #expect(found.contains(.toggleZoom))
        // Two characters are not enough to be useful, and would rank everything.
        #expect(PaletteSearch.rank(AppCommand.allCases, query: "tz").isEmpty)
    }

    @Test func aMachineNameFindsAPaneOnThatMachine() {
        let rows = [
            Row(paletteTitle: "npm test", paletteKeywords: ["scratch"]),
            Row(paletteTitle: "npm run build", paletteKeywords: ["gateway"]),
        ]
        #expect(titles(rows, "scratch") == ["npm test"])
    }

    @Test func caseAndPunctuationDoNotMatter() {
        #expect(PaletteSearch.rank(AppCommand.allCases, query: "TOGGLE-ZOOM").first == .toggleZoom)
    }

    @Test func nothingMatchedIsEmpty() {
        #expect(PaletteSearch.rank(AppCommand.allCases, query: "qqqq").isEmpty)
    }

    @Test func everyCommandCarriesAtLeastOneKeyword() {
        // The table is what makes the palette usable; a command with no synonyms
        // is only findable by the author's wording.
        let missing = AppCommand.allCases.filter { $0.keywords.isEmpty }
        #expect(missing.isEmpty, "commands with no keywords: \(missing.map(\.rawValue))")
    }

    @Test func everyCommandIsReachableByItsIdWords() {
        let unreachable = AppCommand.allCases.filter { command in
            let words = command.rawValue.replacingOccurrences(of: "_", with: " ")
            return PaletteSearch.rank(AppCommand.allCases, query: words).first != command
        }
        #expect(unreachable.isEmpty, "not ranked first by their own id: \(unreachable.map(\.rawValue))")
    }
}
