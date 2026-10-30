// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  ThemePicker.swift
//  KraalUI
//
//  The list of themes Kraal ships, with a preview of each one's colours.
//
//  Modelled on Ghostty's own theme browser and on Rex's `client.theme.change`:
//  a search field, a list, and a swatch — picking a theme is a visual decision,
//  so the row has to show the colours, not name them. The search reuses
//  `PaletteSearch`, which is what makes "gruv" and "dark blue" work.
//
//  Selecting a theme here is a *client* decision: Kraal paints this theme's
//  chrome and hands its colours to the terminal, and `config.toml` is left alone.
//  The first row goes back to following `config.toml`, which is how a user undoes
//  a pick without editing anything.
//

import KraalProtocol
import SwiftUI

struct ThemePicker: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search themes…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(KraalTheme.Space.roomy)
                .focused($searchFocused)
                .onSubmit { pick(rows[safe: highlighted] ?? rows.first) }

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        Button {
                            pick(row)
                        } label: {
                            ThemeRow(
                                title: row.title,
                                theme: row.theme,
                                family: row.category,
                                isSelected: index == highlighted,
                                isPicked: row.id == pickedID
                            )
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            if hovering { highlighted = index }
                        }
                    }

                    if rows.isEmpty {
                        Text("No matching themes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 400)
        }
        .frame(width: 460)
        .glassPanel(.hud, radius: KraalTheme.Radius.overlay)
        .onAppear { searchFocused = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    private var pickedID: String? { store.themeStore?.ghostty?.id }

    private struct Row: Identifiable, PaletteSearchable {
        let id: String
        let title: String
        let theme: GhosttyTheme?
        var keywords: [String] = []
        var category: String = ""

        var paletteTitle: String { title }
        var paletteKeywords: [String] { keywords }
        var paletteCategory: String { category }
    }

    private var rows: [Row] {
        var all: [Row] = [
            Row(
                id: "config",
                title: "Follow config.toml",
                theme: nil,
                keywords: ["config", "daemon", "default", "automatic"],
                category: "Automatic"
            ),
        ]
        all.append(contentsOf: GhosttyThemeCatalog.all.map { theme in
            Row(
                id: theme.id,
                title: theme.name,
                theme: theme,
                keywords: theme.isDark ? ["dark"] : ["light"],
                category: theme.isDark ? "Dark" : "Light"
            )
        })
        return PaletteSearch.rank(all, query: query)
    }

    private func pick(_ row: Row?) {
        guard let row else { return }
        store.themeStore?.selectTheme(row.theme)
        dismiss()
    }
}

/// One line: the swatch, the name, and the family on the right.
private struct ThemeRow: View {
    let title: String
    let theme: GhosttyTheme?
    let family: String
    let isSelected: Bool
    let isPicked: Bool

    var body: some View {
        HStack(spacing: KraalTheme.Space.base) {
            ThemeSwatch(theme: theme)
                .frame(width: 54, height: 14)
            Text(title)
                .font(KraalTheme.Font.rowTitle)
            Spacer()
            if isPicked {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            Text(family)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, KraalTheme.Space.base)
        .padding(.vertical, KraalTheme.Space.snug)
        .contentShape(Rectangle())
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: KraalTheme.Radius.control, style: .continuous)
                    .fill(.selection)
            }
        }
    }
}

/// The theme's own colours: background, then the eight normal and eight bright.
///
/// A row that only names a theme asks the user to remember what "Kanagawa Dragon"
/// looks like; eight pixels of each colour answer it. `nil` (the config row) is
/// drawn as the current palette so the row is not a hole in the list.
private struct ThemeSwatch: View {
    let theme: GhosttyTheme?
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            if let theme {
                block(theme.background)
                ForEach(theme.ansi, id: \.self) { hex in
                    block(hex)
                }
            } else {
                ForEach(0..<4, id: \.self) { _ in
                    Rectangle().fill(palette.color(palette.overlay0, fallback: .secondary))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        }
    }

    private func block(_ hex: String) -> some View {
        Rectangle().fill(color(hex))
    }

    private func color(_ hex: String) -> Color {
        guard let value = GhosttyTheme.value(hex) else { return .clear }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
