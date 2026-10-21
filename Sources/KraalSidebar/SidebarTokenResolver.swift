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
    /// True when this row is a worktree drawn under its parent.
    ///
    /// An indented row is a sub-entry of a repository that is already on screen,
    /// so repeating its branch and ahead/behind underneath it is noise — the
    /// terminal client suppresses both (`sidebar.rs:687`).
    public var indented: Bool
    /// Whether a `machine` token resolves. False for a single-machine setup.
    public var showsMachineName: Bool

    public init(
        workspace: ClientShellWorkspace? = nil,
        agent: ClientShellAgent? = nil,
        tab: ClientShellTab? = nil,
        pane: ClientShellPane? = nil,
        machineName: String = "local",
        tokens: [String: String] = [:],
        indented: Bool = false,
        showsMachineName: Bool = true
    ) {
        self.workspace = workspace
        self.agent = agent
        self.tab = tab
        self.pane = pane
        self.machineName = machineName
        self.tokens = tokens
        self.indented = indented
        self.showsMachineName = showsMachineName
    }

    /// The word a workspace row shows for itself.
    ///
    /// A nested worktree is named by its branch, because its workspace label is
    /// the generated `worktree-<name>` slug and the branch is what the user
    /// recognises. The `worktree/` prefix is the daemon's convention for those
    /// branches, not part of the name, so it is stripped for display
    /// (`sidebar.rs:669-676`). A workspace the user renamed keeps its label.
    public var workspaceLabel: String {
        guard let workspace else { return "" }
        if indented, !workspace.customLabel, let branch = workspace.branch, !branch.isEmpty {
            let stripped = branch.hasPrefix("worktree/")
                ? String(branch.dropFirst("worktree/".count))
                : branch
            return stripped
        }
        return workspace.label.isEmpty ? "w\(workspace.number)" : workspace.label
    }
}

public struct ResolvedToken: Equatable, Sendable {
    public var text: String
    public var style: TokenStyle
    public var kind: SidebarTokenKind
    /// Per-character-run styles, when one token needs more than one colour.
    ///
    /// `git_status` is the only such token: the terminal client draws `↑ahead`
    /// green and `↓behind` red (`src/client/shell/sidebar.rs:246-267`). Modelling
    /// that as a single colour would have meant either picking one for both or
    /// splitting the token, and splitting it would have changed the separator
    /// rules the layout is defined in terms of.
    public var segments: [ResolvedSegment]

    public init(
        text: String,
        style: TokenStyle,
        kind: SidebarTokenKind,
        segments: [ResolvedSegment] = []
    ) {
        self.text = text
        self.style = style
        self.kind = kind
        self.segments = segments
    }

    public var isEmpty: Bool { text.isEmpty }
}

/// One colour run inside a token.
public struct ResolvedSegment: Equatable, Sendable {
    public enum Tint: Equatable, Sendable {
        case ahead
        case behind
        case plain
    }

    public var text: String
    public var tint: Tint

    public init(text: String, tint: Tint) {
        self.text = text
        self.tint = tint
    }
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
                kind: token.kind,
                segments: segments(for: token.kind, context: context)
            ))
        }
        return ResolvedRow(tokens: resolved)
    }

    /// Colour runs for tokens that draw more than one colour.
    public static func segments(
        for kind: SidebarTokenKind,
        context: SidebarRowContext
    ) -> [ResolvedSegment] {
        guard case .gitStatus = kind, !context.indented,
              let divergence = context.workspace?.aheadBehind else { return [] }
        var segments: [ResolvedSegment] = []
        if divergence.ahead > 0 {
            segments.append(ResolvedSegment(text: "↑\(divergence.ahead)", tint: .ahead))
        }
        if divergence.ahead > 0, divergence.behind > 0 {
            segments.append(ResolvedSegment(text: " ", tint: .plain))
        }
        if divergence.behind > 0 {
            segments.append(ResolvedSegment(text: "↓\(divergence.behind)", tint: .behind))
        }
        return segments
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
            // "machine label when the client has multiple machines; omitted for a
            // single local machine" (configuration.mdx:386). With one machine the
            // name is on every row and carries no information, so the desktop
            // client drops it rather than repeating it.
            return context.showsMachineName ? context.machineName : ""
        case .workspace:
            return context.workspaceLabel
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
            // A worktree row already shows its branch as its name.
            guard !context.indented else { return "" }
            return context.workspace?.branch ?? ""
        case .gitStatus:
            // Divergence belongs to the repository, which the parent row carries.
            guard !context.indented else { return "" }
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
