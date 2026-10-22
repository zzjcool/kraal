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
    @Environment(AppStore.self) private var store

    private struct Section: Identifiable {
        var id: String { title }
        var title: String
        var rows: [(String, String)]
    }

    /// The daemon's own keybinding profile, when it sent one.
    ///
    /// Read from the snapshot (the field `server_keybindings_toml` that used to be
    /// decoded and dropped). Non-nil means the daemon has an opinion about the
    /// bindings and the panel should show *its* answer.
    private var profile: String? {
        SnapshotNotices.serverKeybindings(in: store.snapshot)
    }

    /// The binding the daemon reports for `name`, falling back to `builtIn`.
    ///
    /// Overlay rather than replace: the built-in table covers actions the daemon's
    /// profile may not mention (this client's own menu commands), and a missing
    /// entry must not blank a row. When the daemon does mention an action, its
    /// answer wins — that is the entire point, because a user who remapped
    /// `new_tab` in `[keys]` is looking at this panel to confirm what they got.
    private func binding(_ builtIn: String, _ name: String) -> String {
        KeybindingProfile.binding(for: name, in: profile) ?? builtIn
    }

    private var sections: [Section] {
        [
            Section(title: "Workspaces & Panes", rows: [
                ("New Workspace", binding("⌘N", "new_workspace")),
                ("New Tab", binding("⌘T", "new_tab")),
                ("Split Right", binding("⌘D", "split_vertical")),
                ("Split Down", binding("⇧⌘D", "split_horizontal")),
                ("Close Pane", binding("⇧⌘W", "close_pane")),
                ("Close Tab", binding("⌘W", "close_tab")),
                ("Toggle Pane Zoom", binding("⇧⌘↵", "toggle_zoom")),
                ("Clear Pane", "—"),
            ]),
            Section(title: "Navigation", rows: [
                ("Go To Pane…", binding("⌘K", "goto")),
                ("Next / Previous Tab", "\(binding("⇧⌘]", "next_tab")) / \(binding("⇧⌘[", "previous_tab"))"),
                ("Next / Previous Workspace",
                 "\(binding("⌘]", "next_workspace")) / \(binding("⌘[", "previous_workspace"))"),
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
                ("Keyboard Shortcuts", binding("⌘/", "help")),
                ("Reconnect", "⌘R"),
                ("Quit", "⌘Q"),
            ]),
            Section(title: "Terminal", rows: [
                ("Paste into terminal", "⌘V"),
                ("Copy selection", "⌘C"),
                ("Copy mode (reach history)", "⌘F"),
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

            Divider()

            // Say where the numbers came from. Without this the panel looks
            // identical whether it is showing this client's menu shortcuts or the
            // daemon's remapped `[keys]`, and a user who edited the config has no
            // way to tell whether it took effect.
            HStack(spacing: KraalTheme.Space.snug) {
                Image(systemName: profile == nil ? "menubar.rectangle" : "checkmark.seal")
                    .font(.system(size: 9))
                Text(profile == nil
                    ? "Menu shortcuts (the daemon sent no keybinding profile)"
                    : "Bindings from the daemon's [keys] config")
                    .font(.system(size: 10))
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, KraalTheme.Space.loose)
            .padding(.vertical, KraalTheme.Space.snug)
        }
        .frame(width: 460, height: 520)
        .glassChrome(.sheet, rim: false)
    }
}
