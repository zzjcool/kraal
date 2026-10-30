// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  GhosttyThemeCatalog.swift
//  KraalUI
//
//  The themes Kraal ships, read once from the bundle.
//
//  ## Where the files come from, and why not a generated table
//
//  They are Ghostty's own theme files, copied verbatim into
//  `Resources/themes/`. A generated Swift table would be 51 structs of 23 hex
//  literals: unreviewable, and impossible to diff against upstream. Reading the
//  files at launch costs one directory listing and 51 small reads, once — the
//  catalogue is cached for the life of the process.
//
//  ## Names
//
//  Matching is by *canonical* name: lower-cased, accents folded, spaces and
//  underscores to hyphens ("Rosé Pine" == "rose-pine" == "rose_pine"). Ghostty's
//  files are spelled the way their authors wrote them, and a person typing
//  "gruvbox dark" should not have to reproduce a capital letter.
//
//  The ids are the file names, so a rename upstream is a changed id rather than a
//  silently different theme — the saved selection then falls back instead of
//  quietly becoming something else.

import Foundation
import KraalProtocol

public enum GhosttyThemeCatalog {
    /// Every bundled theme, dark first then light, each group by name.
    public static let all: [GhosttyTheme] = load()

    /// The theme matching `raw`, however it was spelled.
    public static func named(_ raw: String) -> GhosttyTheme? {
        let wanted = canonical(raw)
        return byCanonicalName[wanted]
    }

    /// The theme a saved id refers to.
    public static func identified(by id: String) -> GhosttyTheme? {
        byID[id]
    }

    /// "Catppuccin Mocha" → "catppuccin-mocha".
    public static func canonical(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let mapped = folded.map { character -> Character in
            if character == " " || character == "_" { return "-" }
            return character
        }
        return String(mapped)
    }

    private static let byCanonicalName: [String: GhosttyTheme] = {
        var map: [String: GhosttyTheme] = [:]
        for theme in all {
            map[canonical(theme.name)] = theme
            map[canonical(theme.id)] = theme
        }
        return map
    }()

    private static let byID: [String: GhosttyTheme] = {
        var map: [String: GhosttyTheme] = [:]
        for theme in all { map[theme.id] = theme }
        return map
    }()

    private static func load() -> [GhosttyTheme] {
        guard let urls = Bundle.module.urls(forResourcesWithExtension: nil, subdirectory: "themes") else {
            kraalLog("theme: the bundled theme directory is missing")
            return []
        }
        var themes: [GhosttyTheme] = []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension.isEmpty {
            let name = url.lastPathComponent
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                kraalLog("theme: \(name) is not readable UTF-8")
                continue
            }
            if let theme = GhosttyTheme.parse(id: name, name: name, text: text) {
                themes.append(theme)
            } else {
                // Not fatal: one bad file must not cost the user their theme picker.
                // `GhosttyThemeCatalogTests` is what keeps the bundled set clean.
                kraalLog("theme: skipping \(name), not a complete theme file")
            }
        }
        let dark = themes.filter(\.isDark).sorted { $0.name < $1.name }
        let light = themes.filter { !$0.isDark }.sorted { $0.name < $1.name }
        return dark + light
    }
}
