// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  PaletteSearch.swift
//  KraalUI
//
//  Ranking for the command palette, in the shape Rex uses for its own: every
//  action carries keywords and a category, the query is split into words, and a
//  row has to match **all** of them — "split down" must not return every split.
//
//  Substring matching is what the palette did before, and with four built-ins it
//  was fine. With the full command table it is not: typing "max" found nothing
//  because the command is called "Toggle Pane Zoom", and "kill" found nothing
//  because the menu says "Close Tab". Keywords are what bridge that gap; the
//  scoring below decides which of several matches is first.
//
//  Kept pure and generic so it is testable without a window — the palette itself
//  cannot be asserted on without driving a sheet, and a matcher that is only
//  exercised through a sheet is a matcher nobody checks.
//
//  ## Weights
//
//  A match on the title is worth more than one on a keyword, which is worth more
//  than one on the category. Within a field, a whole word beats a prefix, which
//  beats a substring: "tab" should find "New Tab" before "Tab Bar" style
//  categories and before a word that merely contains "tab".

import Foundation

/// What the ranker needs from a row. `AppCommand` and the palette's own rows
/// both conform, so commands and "go to" targets are ranked by the same rules.
public protocol PaletteSearchable {
    /// What the row reads as.
    var paletteTitle: String { get }
    /// Extra words that should find it.
    var paletteKeywords: [String] { get }
    /// The family, shown as a hint and used as a weak last-resort match.
    var paletteCategory: String { get }
}

public enum PaletteSearch {
    /// Weight of a whole-word match in each field: title, keyword, category.
    static let titleExact = 100
    static let titlePrefix = 70
    static let titleContains = 45
    static let keywordExact = 60
    static let keywordPrefix = 40
    static let keywordContains = 25
    static let categoryPrefix = 12
    /// A subsequence match ("tzm" → "Toggle Pane Zoom") is last resort: it is
    /// what makes a fuzzy finder feel psychic, and also what makes it rank
    /// nonsense first when overused.
    static let subsequence = 8

    /// The query's words, lower-cased.
    public static func tokens(_ query: String) -> [String] {
        query.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
    }

    /// The rows matching every token, best first.
    ///
    /// Order is preserved among equal scores, so an empty query returns the
    /// caller's order — that is what lets the palette list Go To targets, then
    /// commands, without the ranker reordering them.
    public static func rank<T: PaletteSearchable>(_ rows: [T], query: String) -> [T] {
        let tokens = tokens(query)
        guard !tokens.isEmpty else { return rows }
        let scored: [(order: (score: Int, index: Int), row: T)] = rows.enumerated().compactMap { index, row in
            guard let score = score(row, tokens: tokens) else { return nil }
            // Sorted descending by score, then by the caller's order. Bundled into
            // one tuple so the comparison is a single `>` and stays stable.
            return ((score, -index), row)
        }
        return scored.sorted { $0.order > $1.order }.map(\.row)
    }

    /// The total score, or `nil` when any token matches nothing.
    public static func score(_ row: some PaletteSearchable, tokens: [String]) -> Int? {
        var total = 0
        for token in tokens {
            guard let best = bestScore(for: token, in: row) else { return nil }
            total += best
        }
        return total
    }

    static func bestScore(for token: String, in row: some PaletteSearchable) -> Int? {
        var best = field(token, in: row.paletteTitle, exact: titleExact, prefix: titlePrefix, contains: titleContains)
        for keyword in row.paletteKeywords {
            let score = field(
                token, in: keyword,
                exact: keywordExact, prefix: keywordPrefix, contains: keywordContains
            )
            best = max(best ?? 0, score ?? 0).nonZeroOrNil
        }
        let category = field(token, in: row.paletteCategory, exact: categoryPrefix, prefix: categoryPrefix, contains: 0)
        best = max(best ?? 0, category ?? 0).nonZeroOrNil
        if best == nil, let fuzzy = subsequence(token, in: row.paletteTitle) {
            best = fuzzy
        }
        return best
    }

    /// Exact word, then word prefix, then substring.
    static func field(_ token: String, in text: String, exact: Int, prefix: Int, contains: Int) -> Int? {
        let haystack = text.lowercased()
        let words = tokens(haystack)
        if words.contains(token) { return exact }
        if words.contains(where: { $0.hasPrefix(token) }) { return prefix }
        if contains > 0, haystack.contains(token) { return contains }
        return nil
    }

    /// Whether `token`'s characters appear in order in `text`, letters only.
    ///
    /// Skill ceilings matter: a two-character query would match almost everything
    /// ("tt" is in "Toggle Pane Zoom"), so it is not attempted.
    static func subsequence(_ token: String, in text: String) -> Int? {
        guard token.count >= 3 else { return nil }
        let haystack = Array(text.lowercased())
        var cursor = haystack.startIndex
        for character in token {
            guard let found = haystack[cursor...].firstIndex(of: character) else { return nil }
            cursor = haystack.index(after: found)
        }
        return subsequence
    }
}

private extension Int {
    /// `max(0, x)` folded back to "no match" — the score helpers use 0 as a
    /// sentinel because `Int?` comparison via `max` would keep the wrong side.
    var nonZeroOrNil: Int? { self == 0 ? nil : self }
}
