// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The window's top bar: the Kraal mark and the two chrome buttons over the
// sidebar's width, then one card per tab of the active space. The strip lives
// *inside* the titlebar on purpose — the official app has no second toolbar
// row, so a tab is a 29pt card and not a capsule on a bar of its own.

import KraalModel
import SwiftUI

struct HcTitlebarView: View {
    @ObservedObject var model: HcWorkspaceModel
    @Environment(\.colorScheme) private var colorScheme

    private var colors: HcChromeColors { .forScheme(colorScheme) }
    private var tabs: [KraalTab] { model.workspace.activeSpace?.tabs ?? [] }
    private var activeTabID: String? { model.workspace.activeSpace?.activeTab }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                brand
                tabStrip
            }
            .frame(height: HcChromeMetrics.titlebarHeight)
            Rectangle()
                .fill(colors.border)
                .frame(height: 1)
        }
        .background(colors.chrome)
    }

    // MARK: - Brand (over the sidebar's width)

    private var brand: some View {
        HStack(spacing: 8) {
            Image(systemName: "app.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .foregroundStyle(colors.accent)
            Text("Kraal")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(colors.foreground)
                .lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                HcTitlebarIconButton(symbol: "magnifyingglass", size: 15, help: HcChromeFormat.searchHint) {
                    model.showPalette = true
                }
                HcTitlebarIconButton(symbol: "sidebar.leading", size: 15, help: "Toggle sidebar") {
                    model.sidebarVisible.toggle()
                }
            }
        }
        // The traffic lights are drawn by AppKit over this view; 78pt is where
        // the official window starts its own content.
        .padding(.leading, 78)
        .padding(.trailing, 10)
        .frame(width: HcChromeMetrics.sidebarWidth)
    }

    // MARK: - Tab strip

    private var tabStrip: some View {
        HStack(spacing: HcChromeMetrics.tabSpacing) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HcChromeMetrics.tabSpacing) {
                    ForEach(tabs) { tab in
                        HcTitlebarTab(model: model, tab: tab, active: tab.id == activeTabID)
                    }
                }
                .frame(height: HcChromeMetrics.titlebarHeight)
            }
            HcTitlebarIconButton(symbol: "plus", size: 13, help: "New tab") {
                Task { await model.newTab() }
            }
        }
        .padding(.leading, HcChromeMetrics.tabContentInset)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - One tab

private struct HcTitlebarTab: View {
    @ObservedObject var model: HcWorkspaceModel
    let tab: KraalTab
    let active: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    private var colors: HcChromeColors { .forScheme(colorScheme) }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: HcChromeMetrics.tabRadius) }

    /// The first agent whose pane is inside this tab. Its `app` word picks the
    /// glyph and its status is the tab's status dot; a plain shell has neither,
    /// and `HcAgentAppIcon` already falls back to the terminal glyph for that.
    private var agent: HcAgent? {
        let panes = Set(tab.panes.map(\.id))
        return model.agents.first { agent in
            guard let pane = agent.pane else { return false }
            return panes.contains(pane)
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: HcAgentAppIcon.symbol(for: agent?.app))
                .font(.system(size: 14))
                .foregroundStyle(colors.muted)
            Text(tab.displayName)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 170, alignment: .leading)
            status
            if active {
                close
            }
        }
        .font(.system(size: 12.8))
        .foregroundStyle(active ? colors.foreground : colors.muted)
        .padding(.horizontal, HcChromeMetrics.tabContentInset)
        .frame(height: HcChromeMetrics.tabHeight)
        .background(shape.fill(cardColor))
        .overlay(shape.strokeBorder(active ? colors.border : colors.chrome, lineWidth: 1))
        .contentShape(shape)
        .help(tab.name.isEmpty ? "Tab \(tab.displayName)" : tab.name)
        .onHover { hovering = $0 }
        .focusable(false)
        .onTapGesture(count: 2) { model.requestRename(tab: tab.id) }
        .onTapGesture { model.selectTab(tab.id) }
        .contextMenu { menu }
        .draggable(tab.id)
        .dropDestination(for: String.self) { items, _ in accept(items) }
    }

    /// The raised card is what makes the active tab readable at a glance; an
    /// inactive tab is chrome-coloured on a chrome bar, so it has no visible
    /// card until the pointer is over it.
    private var cardColor: Color {
        if active { return colors.raised }
        return hovering ? colors.hover : colors.chrome
    }

    @ViewBuilder
    private var status: some View {
        switch agent?.status ?? .idle {
        case .working:
            ProgressView()
                .controlSize(.mini)
                .tint(colors.working)
                .frame(width: 12, height: 12)
        case .blocked:
            dot(colors.blocked)
        case .done:
            dot(colors.done)
        case .idle:
            EmptyView()
        }
    }

    private func dot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
    }

    private var close: some View {
        Button {
            Task { await model.closeTab(tab.id) }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12))
                .foregroundStyle(colors.muted)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Close tab")
    }

    @ViewBuilder
    private var menu: some View {
        Button("Rename Tab…") { model.requestRename(tab: tab.id) }
        Button("Close Tab") { Task { await model.closeTab(tab.id) } }
    }

    /// A tab dropped onto another tab lands just after it, which is the order
    /// the strip shows (`tab.move` takes a 1-based index).
    private func accept(_ items: [String]) -> Bool {
        guard let source = items.first, source != tab.id else { return false }
        let strip = model.workspace.activeSpace?.tabs ?? []
        let destination = (strip.firstIndex { $0.id == tab.id } ?? 0) + 1
        Task { await model.moveTab(source, index: destination) }
        return true
    }
}

// MARK: - Chrome button

/// The 26pt square the bars use for icon buttons: dim glyph, hover background,
/// plain style so it never picks up the system bezel.
private struct HcTitlebarIconButton: View {
    let symbol: String
    let size: CGFloat
    let help: String
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    private var colors: HcChromeColors { .forScheme(colorScheme) }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: 26, height: 26)
                .foregroundStyle(hovering ? colors.foreground : colors.muted)
                .background(shape.fill(hovering ? colors.hover : Color.clear))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .help(help)
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 6) }
}
