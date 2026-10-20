// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Tab bar and status bar.
//
// The tab bar is data-driven from the snapshot so it stays correct when tabs are
// created on another machine. The right side of the status bar shows
// `tab_bar_right`, which is where Herdr puts its own status segments (update
// notices, integration warnings) — reproducing it means the user sees the same
// signals the desktop client shows.

import KraalProtocol
import SwiftUI
import KraalSidebar
import KraalTransport

struct TabBarView: View {
    @Environment(AppStore.self) private var store
    @State private var prompt: CommandPrompt?

    var body: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(store.visibleTabs) { tab in
                        tabButton(tab)
                    }
                }
            }
            Button {
                store.createTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("New tab")
        }
        .padding(.horizontal, KraalTheme.Space.snug)
        .frame(height: KraalTheme.tabBarHeight)
        .glassChrome(.bar, rim: false)
        .renamePrompt($prompt)
    }

    private func tabButton(_ tab: ClientShellTab) -> some View {
        Button {
            store.focus(tabId: tab.tabId)
        } label: {
            HStack(spacing: 4) {
                StatusDot(status: tab.agentStatus, size: 6)
                Text(tab.label.isEmpty ? "#\(tab.number)" : tab.label)
                    .font(tab.focused ? KraalTheme.Font.barLabel : KraalTheme.Font.rowTitle)
                    .lineLimit(1)
                if tab.zoomed {
                    Image(systemName: "rectangle.expand.vertical")
                        .font(KraalTheme.Font.micro)
                }
            }
            .padding(.horizontal, KraalTheme.Space.base)
            .padding(.vertical, KraalTheme.Space.tight)
            .background {
                // The focused tab reads as a lit pill on the bar's glass. A plain
                // accent fill at 25% looked muddy over the material, so the pill
                // is a raised surface with an accent hairline instead.
                RoundedRectangle(cornerRadius: KraalTheme.Radius.control, style: .continuous)
                    .fill(tab.focused
                        ? AnyShapeStyle(.selection)
                        : AnyShapeStyle(Color.clear))
                    .overlay {
                        if tab.focused {
                            RoundedRectangle(
                                cornerRadius: KraalTheme.Radius.control,
                                style: .continuous
                            )
                            .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
                        }
                    }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            TabContextMenu(prompt: $prompt, tab: tab)
        }
    }
}

struct StatusBarView: View {
    @Environment(AppStore.self) private var store
    var onShowCommands: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let workspace = store.focusedWorkspace {
                Label {
                    Text(workspace.label.isEmpty ? "w\(workspace.number)" : workspace.label)
                } icon: {
                    StatusDot(status: workspace.agentStatus, size: 6)
                }
                .font(.system(size: 10))
                .labelStyle(.titleAndIcon)
            }

            if let pane = store.visiblePanes.first, let geometry = store.paneGeometry(for: pane.paneId) {
                Text("\(geometry.innerRect.width)×\(geometry.innerRect.height)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if let error = store.lastError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(sidebarColor("yellow"))
                    .help(error)
            }

            Spacer()

            if let snapshot = store.snapshot, !snapshot.tabBarRight.isEmpty {
                let separator = snapshot.tabBarRightSeparator.isEmpty
                    ? " "
                    : snapshot.tabBarRightSeparator
                HStack(spacing: 4) {
                    ForEach(Array(snapshot.tabBarRight.enumerated()), id: \.offset) { index, segment in
                        if index > 0 {
                            Text(separator).foregroundStyle(.tertiary)
                        }
                        Text(segment.text)
                            .foregroundStyle(
                                segment.accent
                                    ? sidebarColor("yellow")
                                    : Color.secondary
                            )
                    }
                }
                .font(.system(size: 10))
            }

            Button(action: onShowCommands) {
                Image(systemName: "command")
                    .font(.system(size: 9))
            }
            .buttonStyle(.borderless)
            .help("Command palette (⌘K)")
        }
        .padding(.horizontal, KraalTheme.Space.base)
        .frame(height: KraalTheme.statusBarHeight)
        .glassChrome(.bar, rim: false)
    }
}
