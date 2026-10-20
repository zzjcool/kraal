// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The keyboard shortcut reference, opened from the app menu.
//
// Herdr ships the same panel (its binary carries a `keybindings` action and the
// heading strings `WORKSPACES & PANES` / `NAVIGATION` / `APPLICATION`). Showing
// the bindings the app actually honours — rather than a hand-written list that
// drifts — is why the rows are derived from `AppCommand` and the same shortcut
// table the menu bar uses.

import AppKit
import SwiftUI

struct ShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    private struct Section: Identifiable {
        var id: String { title }
        var title: String
        var rows: [(String, String)]
    }

    private var sections: [Section] {
        [
            Section(title: "Workspaces & Panes", rows: [
                ("New Workspace", "⌘N"),
                ("New Tab", "⌘T"),
                ("Split Right", "⌘D"),
                ("Split Down", "⇧⌘D"),
                ("Close Pane", "⇧⌘W"),
                ("Close Tab", "⌘W"),
                ("Toggle Pane Zoom", "⇧⌘↵"),
                ("Clear Pane", "—"),
            ]),
            Section(title: "Navigation", rows: [
                ("Next / Previous Tab", "⇧⌘] / ⇧⌘["),
                ("Next / Previous Workspace", "⌘] / ⌘["),
                ("Next / Previous Pane", "⌥⌘] / ⌥⌘["),
                ("Focus Pane by Direction", "⌥⌘←↑↓→"),
                ("Move Tab Left / Right", "⇧⌘, / ⇧⌘."),
                ("Focus Tab 1…9", "⌘1 … ⌘9"),
                ("Focus Workspace 1…9", "⌃⌘1 … ⌃⌘9"),
            ]),
            Section(title: "Application", rows: [
                ("Command Palette", "⌘K"),
                ("Toggle Sidebar", "⌘B"),
                ("Toggle Status Bar", "⇧⌘B"),
                ("Keyboard Shortcuts", "⌘/"),
                ("Reconnect", "⌘R"),
                ("Quit", "⌘Q"),
            ]),
            Section(title: "Terminal", rows: [
                ("Paste into terminal", "⌘V"),
                ("Copy selection", "⌘C"),
                ("Select All", "⌘A"),
            ]),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(KraalTheme.Space.loose)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: KraalTheme.Space.snug) {
                            Text(section.title.uppercased())
                                .font(KraalTheme.Font.sectionHeader)
                                .foregroundStyle(.secondary)
                            ForEach(section.rows, id: \.0) { row in
                                HStack {
                                    Text(row.0)
                                    Spacer(minLength: 24)
                                    Text(row.1)
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                .font(KraalTheme.Font.rowTitle)
                            }
                        }
                    }
                }
                .padding(KraalTheme.Space.loose)
            }
        }
        .frame(width: 460, height: 520)
        .glassChrome(.sheet, rim: false)
    }
}
