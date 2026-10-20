// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Token resolution: turns a snapshot plus a sidebar spec into the strings and
// styles a view draws.
//
// Kept out of the views so it is testable without SwiftUI, and so the same
// resolution can later drive a menu bar extra or a tab bar.

import Foundation
import KraalProtocol

/// What a sidebar row is describing. The same `SidebarTokenKind` means different
/// things in a workspace row and an agent row, so the context carries both.
public struct SidebarRowContext: Sendable {
    public var workspace: ClientShellWorkspace?
    public var agent: ClientShellAgent?
    public var tab: ClientShellTab?
    public var pane: ClientShellPane?
    public var machineName: String
    public var tokens: [String: String]

    public init(
        workspace: ClientShellWorkspace? = nil,
        agent: ClientShellAgent? = nil,
        tab: ClientShellTab? = nil,
        pane: ClientShellPane? = nil,
        machineName: String = "local",
        tokens: [String: String] = [:]
    ) {
        self.workspace = workspace
        self.agent = agent
        self.tab = tab
        self.pane = pane
        self.machineName = machineName
        self.tokens = tokens
    }
}

public struct ResolvedToken: Equatable, Sendable {
    public var text: String
    public var style: TokenStyle
    public var kind: SidebarTokenKind

    public init(text: String, style: TokenStyle, kind: SidebarTokenKind) {
        self.text = text
        self.style = style
        self.kind = kind
    }

    public var isEmpty: Bool { text.isEmpty }
}

public struct ResolvedRow: Equatable, Sendable {
    public var tokens: [ResolvedToken]

    public init(tokens: [ResolvedToken]) {
        self.tokens = tokens
    }

    /// Tokens left after dropping empties, optionally separated by a space.
    public func joined(separator: String = " ") -> String {
        tokens.filter { !$0.isEmpty }.map(\.text).joined(separator: separator)
    }
}

public enum SidebarTokenResolver {
    /// Resolves one row spec against one context, dropping tokens that resolve to
    /// nothing (the desktop client does not render empty separators either).
    public static func resolve(
        row: SidebarRowSpec,
        context: SidebarRowContext
    ) -> ResolvedRow {
        var resolved: [ResolvedToken] = []
        resolved.reserveCapacity(row.tokens.count)
        for token in row.tokens {
            let text = text(for: token.kind, context: context)
            guard !text.isEmpty else { continue }
            resolved.append(ResolvedToken(
                text: text,
                style: token.resolvedStyle(for: text),
                kind: token.kind
            ))
        }
        return ResolvedRow(tokens: resolved)
    }

    public static func text(
        for kind: SidebarTokenKind,
        context: SidebarRowContext
    ) -> String {
        let status = context.agent?.agentStatus
            ?? context.workspace?.agentStatus
            ?? .unknown

        switch kind {
        case .stateIcon:
            return glyph(for: status)
        case .stateText:
            return statusWord(for: status)
        case .machine:
            return context.machineName
        case .workspace:
            guard let workspace = context.workspace else { return "" }
            return workspace.label.isEmpty ? "w\(workspace.number)" : workspace.label
        case .tab:
            guard let tab = context.tab else { return "" }
            return tab.label.isEmpty ? "#\(tab.number)" : tab.label
        case .pane:
            guard let pane = context.pane else { return "" }
            return pane.label ?? pane.paneId
        case .agent:
            guard let agent = context.agent else { return "" }
            return agent.label
        case .terminalTitle:
            return context.agent?.terminalTitle ?? context.agent?.title ?? ""
        case .terminalTitleStripped:
            return context.agent?.bestTitle ?? ""
        case .branch:
            return context.workspace?.branch ?? ""
        case .gitStatus:
            guard let divergence = context.workspace?.aheadBehind else { return "" }
            var parts: [String] = []
            if divergence.ahead > 0 { parts.append("↑\(divergence.ahead)") }
            if divergence.behind > 0 { parts.append("↓\(divergence.behind)") }
            return parts.joined()
        case let .custom(key):
            return context.tokens[key] ?? ""
        }
    }

    /// A single-width glyph per state, so rows do not shift as an agent changes
    /// state. Text labels are available separately via `state_text`.
    public static func glyph(for status: AgentStatus) -> String {
        switch status {
        case .idle: "○"
        case .working: "◐"
        case .blocked: "●"
        case .done: "✓"
        case .unknown: "·"
        }
    }

    public static func statusWord(for status: AgentStatus) -> String {
        switch status {
        case .idle: "idle"
        case .working: "working"
        case .blocked: "blocked"
        case .done: "done"
        case .unknown: "unknown"
        }
    }
}
