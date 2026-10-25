// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  SidebarCollapsedView.swift
//  KraalUI
//
//  The narrow sidebar: workspaces on top, agents below, both indexed.
//
//  Extracted from `SidebarView` because that view sits on `type_body_length` — and
//  because the collapsed strip shares almost nothing with the expanded one: it draws
//  numbers and glyphs, not names and rows.
//

import KraalProtocol
import SwiftUI

struct SidebarCollapsedView: View {
    let store: AppStore
    let isCollapsed: Bool
    /// Non-nil when something needs the user, which tints the chevron.
    let attention: String?
    let toggle: () -> Void

    var body: some View {
        GeometryReader { proxy in
            // Rows, not points: the two lists divide however many rows fit, so the
            // height that actually exists is what they split.
            let rows = max(0, Int(proxy.size.height / SidebarCollapsed.rowHeight) - 1)
            let counts = SidebarCollapsed.counts(rows: rows)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(store.workspaces.prefix(counts.workspaces).enumerated()),
                        id: \.element.workspaceId) { entry in
                    collapsedRow(
                        label: SidebarCollapsed.label(index: entry.offset),
                        glyph: SidebarCollapsed.glyph(for: entry.element.agentStatus),
                        highlighted: entry.element.focused
                    ) {
                        store.focus(workspaceId: entry.element.workspaceId)
                    }
                }
                if counts.agents > 0 {
                    Divider().opacity(0.4)
                    ForEach(Array(store.aggregatedAgents.prefix(counts.agents).enumerated()),
                            id: \.element.id) { entry in
                        collapsedRow(
                            label: SidebarCollapsed.label(index: entry.offset),
                            glyph: SidebarCollapsed.glyph(for: entry.element.agent.agentStatus),
                            highlighted: entry.element.agent.focused
                        ) {
                            store.focus(paneId: entry.element.agent.paneId)
                        }
                    }
                }
                Spacer(minLength: 0)
                // Where upstream puts it (`sidebar.rs:172-193`, `area.bottom() - 1`).
                collapsedToggle
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: SidebarCollapsed.width)
    }

    /// One row of the collapsed strip.
    private func collapsedRow(
        label: String,
        glyph: String,
        highlighted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 1) {
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(glyph)
                .font(.system(size: 9))
                .foregroundStyle(highlighted ? Color.accentColor : Color.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .frame(height: SidebarCollapsed.rowHeight, alignment: .leading)
        .background(highlighted ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }

    /// The collapse/expand chevron, shared by both states.
    ///
    /// Upstream tints it with the accent colour when something needs attention
    /// (`sidebar.rs:186-192`), which is how the footer dot's information survives
    /// collapsing.
    private var collapsedToggle: some View {
        Button(action: toggle) {
            Text(isCollapsed ? "\u{00BB}" : "\u{00AB}")
                .font(.system(size: 10))
                .foregroundStyle(attention == nil ? Color.secondary : Color.orange)
                .frame(maxWidth: .infinity)
                .frame(height: SidebarCollapsed.rowHeight)
        }
        .buttonStyle(.plain)
        .help(isCollapsed ? "Expand the sidebar" : "Collapse the sidebar")
        .accessibilityIdentifier("sidebar.collapse.toggle")
    }
}
