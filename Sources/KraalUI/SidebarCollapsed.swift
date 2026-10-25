// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  SidebarCollapsed.swift
//  KraalUI
//
//  The narrow sidebar: one indexed row per workspace, one per agent.
//
//  Upstream's collapsed sidebar is a 4-column strip (`config.rs:403-408`,
//  `SidebarCollapsedModeConfig::Compact => 4`) showing `"<n> <status glyph>"` for the
//  first half of its height as workspaces and the second half as agents
//  (`sidebar.rs:47-175`). The point is that both lists stay reachable while the
//  sidebar is out of the way, not that they become readable — at 4 columns the names
//  are gone on purpose.
//

import Foundation
import KraalProtocol

public enum SidebarCollapsed {
    /// Width of the narrow strip, in points.
    ///
    /// Upstream counts 4 *terminal columns*; this is a SwiftUI sidebar measured in
    /// points, so the number is chosen to fit the same content — a two-digit index
    /// plus a glyph — rather than copied literally. Kept in one place so the strip
    /// and any future test agree.
    public static let width: CGFloat = 34

    /// Below this the strip shows one list instead of two.
    ///
    /// Upstream's `content.height < 7` (`sidebar.rs:34-36`): with fewer than 7 rows
    /// there is no room for a divider and a row on each side, so it renders the
    /// workspaces alone and leaves the detail area empty.
    public static let splitThreshold: CGFloat = 7

    /// Height of one collapsed row.
    ///
    /// `counts(rows:)` counts rows, so the view divides its height by this to find
    /// out how many fit. It lives here rather than in `KraalTheme` because it is the
    /// unit of the collapsed strip specifically — the expanded rows are taller.
    public static let rowHeight: CGFloat = 14

    /// How many workspaces and agents fit at a given height.
    ///
    /// `div_ceil(2)` per upstream (`sidebar.rs:37`), which gives the extra row to the
    /// top half. Both counts are `0` when there is no height left.
    public static func counts(rows: Int) -> (workspaces: Int, agents: Int) {
        guard rows > 0 else { return (0, 0) }
        if rows < Int(splitThreshold) {
            return (rows, 0)
        }
        let workspaces = (rows + 1) / 2
        // Minus one for the divider between the halves.
        return (workspaces, max(0, rows - workspaces - 1))
    }

    /// The label a collapsed row shows: a 1-based index, two columns wide.
    ///
    /// Two columns so a single-digit index lines up with a two-digit one; upstream
    /// formats with `"{:<2}"` (`sidebar.rs:96`) for the same reason.
    public static func label(index: Int) -> String {
        String(format: "%-2d", index + 1)
    }

    /// A single character standing in for an agent's state.
    ///
    /// Upstream draws a glyph per `AgentStatus` (`status_icon`, `shell.rs:190-201`)
    /// and colours it. The glyphs differ per `status_indicators` style there; this
    /// client has one style, so one mapping.
    public static func glyph(for status: AgentStatus) -> String {
        switch status {
        case .blocked: "■"
        case .done: "✓"
        case .working: "◐"
        case .idle: "·"
        case .unknown: "?"
        }
    }
}
