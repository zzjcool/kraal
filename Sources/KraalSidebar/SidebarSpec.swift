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

    /// Whether the condition compares numbers rather than text.
    ///
    /// Numeric rules reject `ignore_case` in the daemon, and their threshold is
    /// a float rather than a string, so the two families store their operand
    /// differently (``StyleRule/value`` vs ``StyleRule/threshold``).
    public var isNumeric: Bool {
        self == .greaterThan || self == .lessThan
    }
}

/// One `rules = [{...}]` entry on a styled sidebar token.
///
/// The daemon spells the condition as an inline key — `{ contains = "claude" }`,
/// not `{ when = "contains", value = "claude" }` (`src/config/sidebar/rules.rs`,
/// `RawRule` with `deny_unknown_fields`). Reading the wrong spelling silently
/// drops every rule in a hand-written config, which is what this type used to do.
public struct StyleRule: Equatable, Sendable {
    public var when: StyleRuleCondition
    /// Operand for text conditions.
    public var value: String
    /// Operand for numeric conditions. Kept apart from ``value`` so a threshold
    /// of `80` compares as a number instead of re-parsing a string per row.
    public var threshold: Double
    public var ignoreCase: Bool
    public var style: TokenStyle
    /// `hide = true` removes the matching token, and with it its separator.
    public var hide: Bool

    public init(
        when: StyleRuleCondition,
        value: String,
        ignoreCase: Bool = false,
        style: TokenStyle,
        hide: Bool = false
    ) {
        self.when = when
        self.value = value
        self.threshold = Double(value) ?? 0
        self.ignoreCase = ignoreCase
        self.style = style
        self.hide = hide
    }

    public init(
        when: StyleRuleCondition,
        threshold: Double,
        style: TokenStyle,
        hide: Bool = false
    ) {
        self.when = when
        self.value = Self.describe(threshold)
        self.threshold = threshold
        self.ignoreCase = false
        self.style = style
        self.hide = hide
    }

    /// Renders a threshold the way `config.toml` would spell it, so a resolved
    /// rule can be echoed back to the user.
    private static func describe(_ threshold: Double) -> String {
        threshold == threshold.rounded() && abs(threshold) < 1e15
            ? String(Int(threshold))
            : String(threshold)
    }

    /// Applies the rule to a token's rendered text.
    public func matches(_ text: String) -> Bool {
        switch when {
        case .equals:
            return ignoreCase ? Self.asciiEqualsIgnoringCase(text, value) : text == value
        case .contains:
            return ignoreCase ? Self.asciiContainsIgnoringCase(text, value) : text.contains(value)
        case .startsWith:
            return ignoreCase ? Self.asciiHasPrefixIgnoringCase(text, value) : text.hasPrefix(value)
        case .greaterThan, .lessThan:
            guard let number = Self.parseNumber(text) else { return false }
            return when == .greaterThan ? number > threshold : number < threshold
        }
    }

    // MARK: - ASCII-only case folding

    // `ignore_case` is ASCII-only upstream: `equals`, `starts_with`, and
    // `contains` all use `eq_ignore_ascii_case` on byte slices, so "codex" does
    // not match "CODEX" and a Turkish dotless i is its own letter. Folding whole
    // strings with `String.compare(.caseInsensitive)` would match more than the
    // daemon does, which is how a sidebar could disagree with the desktop client.

    private static func fold(_ byte: UInt8) -> UInt8 {
        (0x41 ... 0x5A).contains(byte) ? byte | 0x20 : byte
    }

    private static func asciiEqualsIgnoringCase(_ text: String, _ target: String) -> Bool {
        let lhs = Array(text.utf8)
        let rhs = Array(target.utf8)
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { fold($0) == fold($1) }
    }

    private static func asciiHasPrefixIgnoringCase(_ text: String, _ target: String) -> Bool {
        let rhs = Array(target.utf8)
        let lhs = Array(text.utf8)
        guard lhs.count >= rhs.count else { return false }
        return zip(lhs.prefix(rhs.count), rhs).allSatisfy { fold($0) == fold($1) }
    }

    private static func asciiContainsIgnoringCase(_ text: String, _ target: String) -> Bool {
        let rhs = Array(target.utf8)
        // The daemon's `contains` is vacuously true for an empty needle.
        guard !rhs.isEmpty else { return true }
        let lhs = Array(text.utf8)
        guard lhs.count >= rhs.count else { return false }
        for start in 0 ... (lhs.count - rhs.count) {
            let window = lhs[start ..< (start + rhs.count)]
            if zip(window, rhs).allSatisfy({ fold($0) == fold($1) }) {
                return true
            }
        }
        return false
    }

    /// The daemon parses the token's text as a finite float and drops the rule
    /// when it does not parse (`rules.rs`, `Condition::GreaterThan` arm).
    private static func parseNumber(_ text: String) -> Double? {
        guard let number = Double(text), number.isFinite else { return nil }
        return number
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
    /// Returns `nil` when a matching rule says `hide = true`: the daemon removes
    /// that token and its separator from the row, which is why this returns an
    /// optional instead of a style.
    ///
    /// Only the **first** matching rule applies (`rules.rs`, `matching_style`),
    /// and it overrides just the fields it sets; the rest inherit from the token.
    /// Layering every matching rule instead would diverge from the desktop
    /// client for any config that stacks rules on the same token. Numeric
    /// conditions share one parse of the token text, as upstream does.
    public func resolvedStyle(for text: String) -> TokenStyle? {
        for rule in rules where rule.matches(text) {
            if rule.hide { return nil }
            return TokenStyle(
                foreground: rule.style.foreground ?? style.foreground,
                background: rule.style.background ?? style.background,
                bold: rule.style.bold ?? style.bold,
                italic: rule.style.italic ?? style.italic,
                dim: rule.style.dim ?? style.dim,
                underlined: rule.style.underlined ?? style.underlined
            )
        }
        return style
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
    /// Rows for panes that are not running a coding agent.
    ///
    /// Not `agentsRows`: those name the agent on their second row, so with no
    /// agent the second row resolves to nothing and two panes of the same tab
    /// render as identical rows. The pane is the only thing that tells them
    /// apart, so it has to be in the row.
    public var paneRows: [SidebarRowSpec]
    /// Per-agent overrides from `ui.sidebar.agents.rows_by_agent`.
    public var agentOverrides: [String: [SidebarRowSpec]]
    public var spacesRowGap: Int
    public var agentsRowGap: Int

    public init(
        spacesRows: [SidebarRowSpec] = SidebarLayout.defaultSpacesRows,
        agentsRows: [SidebarRowSpec] = SidebarLayout.defaultAgentsRows,
        paneRows: [SidebarRowSpec] = SidebarLayout.defaultPaneRows,
        agentOverrides: [String: [SidebarRowSpec]] = [:],
        spacesRowGap: Int = 0,
        agentsRowGap: Int = 0
    ) {
        self.spacesRows = spacesRows
        self.agentsRows = agentsRows
        self.paneRows = paneRows
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

    /// The no-agent fallback: each row must identify one pane uniquely.
    public static let defaultPaneRows = [
        SidebarRowSpec(tokens: [
            SidebarTokenSpec(kind: .stateIcon),
            SidebarTokenSpec(kind: .tab),
            SidebarTokenSpec(kind: .pane),
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
