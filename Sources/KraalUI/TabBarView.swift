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
    @Environment(\.palette) private var palette
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
    @Environment(\.palette) private var palette
    @Environment(AppStore.self) private var store
    var onShowCommands: () -> Void
    /// The copy-mode bar, when this window has one.
    var copyMode: CopyModeBanner?

    var body: some View {
        HStack(spacing: 8) {
            // Copy mode takes the left of the bar while active, because it changes
            // what every key does — it is the most important thing on screen and a
            // user who does not notice it thinks their shell is broken.
            if let copyMode {
                CopyModeBannerView(banner: copyMode)
            }

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
                    .foregroundStyle(sidebarColor("yellow", palette: palette))
                    .help(error)
            }

            // The daemon's own diagnostics (config problem, available update,
            // release notes). Previously decoded and dropped, so a broken config
            // file failed silently — the pane looked fine while every rule in it
            // was ignored. One notice only: a status bar is not a queue.
            if let notice = SnapshotNotices.statusBarNotice(in: store.snapshot) {
                Label {
                    Text(notice.summary)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: notice.kind.isIssue
                        ? "exclamationmark.triangle.fill"
                        : "info.circle.fill")
                        .font(.system(size: 9))
                }
                .font(.system(size: 10))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(notice.kind.isIssue
                    ? sidebarColor("yellow", palette: palette)
                    : Color.secondary)
                .help(notice.detail ?? notice.summary)
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
                                    ? sidebarColor("yellow", palette: palette)
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

/// The copy-mode indicator.
///
/// Its own view so it can observe the banner: `StatusBarView` reads the store from
/// the environment and would otherwise not be rebuilt when the mode's cursor moves
/// (the store does not change for a local cursor move).
struct CopyModeBannerView: View {
    @Environment(\.palette) private var palette
    @ObservedObject var banner: CopyModeBanner

    var body: some View {
        if let text = banner.text {
            Label {
                Text(text)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
            } icon: {
                Image(systemName: "text.cursor")
                    .font(.system(size: 9))
            }
            .foregroundStyle(Color.accentColor)
            .help("Copy mode: select text from this pane's history. Esc leaves.")
        }
    }
}
