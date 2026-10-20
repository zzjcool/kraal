// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The sidebar layout engine: `config.toml` semantics reduced to a data model the
// views consume.
//
// Herdr describes its sidebar as a 2-D grid of *tokens*
// (`ui.sidebar.agents.rows = [["state_icon", "machine"], ["agent"]]`), with
// per-token style overrides and conditional rules. Rather than reimplementing
// ratatui, Kraal resolves that same description into `SidebarRowSpec` values and
// lets SwiftUI draw them — so a user's `config.toml` changes the native layout.
//
// Adapted from `herdr:src/config/sidebar.rs` (Apache-2.0).

import Foundation
import KraalProtocol

// MARK: - Tokens

public enum SidebarTokenKind: Equatable, Sendable {
    // Agent list tokens.
    case stateIcon
    case stateText
    case machine
    case workspace
    case tab
    case pane
    case agent
    case terminalTitle
    case terminalTitleStripped

    // Space (workspace) list tokens.
    case branch
    case gitStatus

    /// `$metadata_key`: a value published by `pane.report-metadata`.
    case custom(String)

    public init?(name: String) {
        switch name {
        case "state_icon": self = .stateIcon
        case "state_text": self = .stateText
        case "machine": self = .machine
        case "workspace": self = .workspace
        case "tab": self = .tab
        case "pane": self = .pane
        case "agent": self = .agent
        case "terminal_title": self = .terminalTitle
        case "terminal_title_stripped": self = .terminalTitleStripped
        case "branch": self = .branch
        case "git_status": self = .gitStatus
        default:
            if name.hasPrefix("$"), name.count > 1 {
                self = .custom(String(name.dropFirst()))
            } else {
                return nil
            }
        }
    }

    /// The wire spelling, used when echoing a resolved layout back to the user.
    public var name: String {
        switch self {
        case .stateIcon: "state_icon"
        case .stateText: "state_text"
        case .machine: "machine"
        case .workspace: "workspace"
        case .tab: "tab"
        case .pane: "pane"
        case .agent: "agent"
        case .terminalTitle: "terminal_title"
        case .terminalTitleStripped: "terminal_title_stripped"
        case .branch: "branch"
        case .gitStatus: "git_status"
        case let .custom(key): "$\(key)"
        }
    }
}

public enum StyleRuleCondition: String, Sendable {
    case equals
    case contains
    case startsWith = "starts_with"
    case greaterThan = "gt"
    case lessThan = "lt"
}

public struct StyleRule: Equatable, Sendable {
    public var when: StyleRuleCondition
    public var value: String
    public var ignoreCase: Bool
    public var style: TokenStyle

    public init(
        when: StyleRuleCondition,
        value: String,
        ignoreCase: Bool = false,
        style: TokenStyle
    ) {
        self.when = when
        self.value = value
        self.ignoreCase = ignoreCase
        self.style = style
    }

    /// Applies the rule to a token's rendered text.
    public func matches(_ text: String) -> Bool {
        let subject = ignoreCase ? text.lowercased() : text
        let target = ignoreCase ? value.lowercased() : value
        switch when {
        case .equals:
            return subject == target
        case .contains:
            return subject.contains(target)
        case .startsWith:
            return subject.hasPrefix(target)
        case .greaterThan:
            guard let lhs = Double(subject), let rhs = Double(target) else { return false }
            return lhs > rhs
        case .lessThan:
            guard let lhs = Double(subject), let rhs = Double(target) else { return false }
            return lhs < rhs
        }
    }
}

/// The style fields a `config.toml` token can override.
public struct TokenStyle: Equatable, Sendable {
    public var foreground: String?
    public var background: String?
    public var bold: Bool?
    public var italic: Bool?
    public var dim: Bool?
    public var underlined: Bool?

    public init(
        foreground: String? = nil,
        background: String? = nil,
        bold: Bool? = nil,
        italic: Bool? = nil,
        dim: Bool? = nil,
        underlined: Bool? = nil
    ) {
        self.foreground = foreground
        self.background = background
        self.bold = bold
        self.italic = italic
        self.dim = dim
        self.underlined = underlined
    }

    public static let none = TokenStyle()

    public var isEmpty: Bool { self == .none }

    /// Layered application: `other` wins where it sets a field.
    public func merging(_ other: TokenStyle) -> TokenStyle {
        TokenStyle(
            foreground: other.foreground ?? foreground,
            background: other.background ?? background,
            bold: other.bold ?? bold,
            italic: other.italic ?? italic,
            dim: other.dim ?? dim,
            underlined: other.underlined ?? underlined
        )
    }
}

public struct SidebarTokenSpec: Equatable, Sendable {
    public var kind: SidebarTokenKind
    public var style: TokenStyle
    public var rules: [StyleRule]

    public init(kind: SidebarTokenKind, style: TokenStyle = .none, rules: [StyleRule] = []) {
        self.kind = kind
        self.style = style
        self.rules = rules
    }

    /// The effective style for a token whose text resolved to `text`.
    ///
    /// Rules are applied in declaration order, later rules winning field by
    /// field, which is how the daemon layers them.
    public func resolvedStyle(for text: String) -> TokenStyle {
        var result = style
        for rule in rules where rule.matches(text) {
            result = result.merging(rule.style)
        }
        return result
    }
}

public struct SidebarRowSpec: Equatable, Sendable {
    public var tokens: [SidebarTokenSpec]

    public init(tokens: [SidebarTokenSpec]) {
        self.tokens = tokens
    }
}

public enum SidebarKind: Sendable {
    case spaces
    case agents
}

public struct SidebarLayout: Equatable, Sendable {
    public var spacesRows: [SidebarRowSpec]
    public var agentsRows: [SidebarRowSpec]
    /// Per-agent overrides from `ui.sidebar.agents.rows_by_agent`.
    public var agentOverrides: [String: [SidebarRowSpec]]
    public var spacesRowGap: Int
    public var agentsRowGap: Int

    public init(
        spacesRows: [SidebarRowSpec] = SidebarLayout.defaultSpacesRows,
        agentsRows: [SidebarRowSpec] = SidebarLayout.defaultAgentsRows,
        agentOverrides: [String: [SidebarRowSpec]] = [:],
        spacesRowGap: Int = 0,
        agentsRowGap: Int = 0
    ) {
        self.spacesRows = spacesRows
        self.agentsRows = agentsRows
        self.agentOverrides = agentOverrides
        self.spacesRowGap = spacesRowGap
        self.agentsRowGap = agentsRowGap
    }

    /// Herdr's shipped defaults, mirrored so a host with no `config.toml` looks
    /// the same as the desktop client.
    public static let defaultSpacesRows = [
        SidebarRowSpec(tokens: [
            SidebarTokenSpec(kind: .stateIcon),
            SidebarTokenSpec(kind: .workspace),
        ]),
        SidebarRowSpec(tokens: [
            SidebarTokenSpec(kind: .branch),
            SidebarTokenSpec(kind: .gitStatus),
        ]),
    ]

    public static let defaultAgentsRows = [
        SidebarRowSpec(tokens: [
            SidebarTokenSpec(kind: .stateIcon),
            SidebarTokenSpec(kind: .machine),
            SidebarTokenSpec(kind: .workspace),
            SidebarTokenSpec(kind: .tab),
        ]),
        SidebarRowSpec(tokens: [
            SidebarTokenSpec(kind: .agent),
        ]),
    ]

    public func rows(for agentKind: String?) -> [SidebarRowSpec] {
        guard let agentKind, let override = agentOverrides[agentKind] else {
            return agentsRows
        }
        return override
    }
}

public enum SidebarLimits {
    /// The daemon refuses layouts larger than this; matching it means a config
    /// that works there works here, and vice versa.
    public static let maxRows = 16
    public static let maxTokensPerRow = 16
    public static let maxRulesPerToken = 16
    public static let maxRowGap = 4
}
