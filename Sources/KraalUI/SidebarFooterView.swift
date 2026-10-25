// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  SidebarFooterView.swift
//  KraalUI
//
//  The sidebar's bottom row: `+ new` on the left, `● menu` on the right.
//
//  Extracted from `SidebarView` to keep that file inside `type_body_length`, and
//  because the footer is a self-contained unit — it is the one row that is always
//  present, whatever the two lists are doing.
//

import SwiftUI

struct SidebarFooterView: View {
    let store: AppStore
    let attention: String?
    /// Where the row layout came from, surfaced in the menu's tooltip.
    let layoutSource: String?

    @Environment(WindowActions.self) private var windowActions

    var body: some View {
        HStack(spacing: 6) {
            Button {
                store.createWorkspace()
            } label: {
                Label("new", systemImage: "plus")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("New workspace")
            .accessibilityIdentifier("sidebar.footer.new")

            Spacer(minLength: 4)

            // No settings/collapse icons here any more. `menu` already opens
            // settings, and the collapse control moved to the header — `footer` is
            // `" new"` and `"menu"` upstream (`sidebar.rs:379-431`) and nothing more.
            // `sidebarConfigSource` still surfaces through the menu's tooltip.
            menu
        }
        .padding(.horizontal, KraalTheme.Space.base)
        .padding(.vertical, KraalTheme.Space.tight)
        // No identifier on the row itself: `accessibilityIdentifier` on a container
        // *overrides its children's*, so tagging the HStack turned `new` and the
        // collapse button into two more elements called "sidebar.footer" and the
        // footer case could not press either. The children identify themselves.
    }

    /// The `● menu` launcher.
    ///
    /// Upstream's global menu holds `settings`, `keybinds`, `reload config`,
    /// `update ready` and `detach` (`global_menu.rs:22-48`). Kraal's equivalents are
    /// spread across the system menu bar and the sheets, so this collects the ones
    /// that exist — the point of a footer entry is that they are reachable *from the
    /// sidebar*, which they were not.
    ///
    /// `detach` is deliberately absent: this client has no detach, and a row that
    /// does nothing is worse than a missing one. `update ready` appears only when
    /// the daemon reports a version, and it states the fact rather than installing:
    /// there is no in-app installer.
    private var menu: some View {
        Menu {
            Button("Settings…") { windowActions.showSettings() }
            Button("Keyboard Shortcuts…") { windowActions.showShortcuts() }
            Button("Reload Config") { store.reloadServerConfig() }
            if let attention {
                Divider()
                Text(attention)
            }
        } label: {
            // A dot before the word, the way upstream draws it: `"● "` then `"menu"`
            // (`sidebar.rs:409-416`).
            HStack(spacing: 2) {
                if attention != nil {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 4, height: 4)
                        .accessibilityIdentifier("sidebar.footer.attention")
                        .onAppear {
                            if let attention {
                                kraalLog("sidebar footer attention: \(attention)")
                            }
                        }
                }
                Text("menu")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(attention ?? layoutSource.map { "Layout from \($0)" }
            ?? "Settings, shortcuts, reload")
        .accessibilityIdentifier("sidebar.footer.menu")
    }
}
