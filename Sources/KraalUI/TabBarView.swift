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
        .padding(.horizontal, 6)
        .frame(height: KraalTheme.tabBarHeight)
        .background(.thinMaterial)
    }

    private func tabButton(_ tab: ClientShellTab) -> some View {
        Button {
            store.focus(tabId: tab.tabId)
        } label: {
            HStack(spacing: 4) {
                StatusDot(status: tab.agentStatus, size: 6)
                Text(tab.label.isEmpty ? "#\(tab.number)" : tab.label)
                    .font(.system(size: 11, weight: tab.focused ? .semibold : .regular))
                    .lineLimit(1)
                if tab.zoomed {
                    Image(systemName: "rectangle.expand.vertical")
                        .font(.system(size: 8))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(tab.focused ? Color.accentColor.opacity(0.25) : .clear)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Close Tab", role: .destructive) { store.close(tabId: tab.tabId) }
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
        .padding(.horizontal, 8)
        .frame(height: KraalTheme.statusBarHeight)
        .background(.thinMaterial)
    }
}
