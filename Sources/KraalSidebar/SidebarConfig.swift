// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Resolves a `config.toml` tree into a `SidebarLayout`.
//
// The mapping is deliberately permissive the way the daemon is: unknown token
// names are dropped rather than failing the import, because a single unsupported
// token in a hand-written config should not blank the sidebar. Structural limits,
// however, are enforced — the daemon rejects an oversized layout, and silently
// truncating one here would produce a sidebar that looks fine but differs from
// the desktop client.

import Foundation

public enum SidebarConfigError: Error, CustomStringConvertible, Equatable {
    case tooManyRows(kind: String, count: Int, limit: Int)
    case tooManyTokens(row: Int, count: Int, limit: Int)
    case tooManyRules(token: String, count: Int, limit: Int)
    case invalidValue(String)

    public var description: String {
        switch self {
        case let .tooManyRows(kind, count, limit):
            "ui.sidebar.\(kind).rows has \(count) rows; the limit is \(limit)"
        case let .tooManyTokens(row, count, limit):
            "sidebar row \(row) has \(count) tokens; the limit is \(limit)"
        case let .tooManyRules(token, count, limit):
            "token \"\(token)\" has \(count) rules; the limit is \(limit)"
        case let .invalidValue(detail):
            detail
        }
    }
}

public enum SidebarConfigResolver {
    /// Builds a layout from a parsed `config.toml`. Missing sections fall back to
    /// Herdr's shipped defaults, so a partial config still yields a usable
    /// sidebar.
    public static func layout(
        from tree: [String: TOMLValue],
        base: SidebarLayout = SidebarLayout()
    ) throws -> SidebarLayout {
        guard
            let uiTable = tree["ui"]?.table,
            let sidebar = uiTable["sidebar"]?.table
        else {
            return base
        }

        var layout = base

        if let spaces = sidebar["spaces"]?.table {
            if let rows = spaces["rows"]?.array {
                layout.spacesRows = try parseRows(rows, kind: "spaces")
            }
            if let gap = spaces["row_gap"]?.integer {
                layout.spacesRowGap = clampRowsGap(gap)
            }
        }

        if let agents = sidebar["agents"]?.table {
            if let rows = agents["rows"]?.array {
                layout.agentsRows = try parseRows(rows, kind: "agents")
            }
            if let gap = agents["row_gap"]?.integer {
                layout.agentsRowGap = clampRowsGap(gap)
            }
            if let overrides = agents["rows_by_agent"]?.table {
                var parsed: [String: [SidebarRowSpec]] = [:]
                for (agent, value) in overrides {
                    guard let rows = value.array else { continue }
                    parsed[agent] = try parseRows(rows, kind: "agents.rows_by_agent.\(agent)")
                }
                layout.agentOverrides = parsed
            }
        }

        return layout
    }

    public static func layout(fromTOML text: String) throws -> SidebarLayout {
        let tree = try TOMLParser.parse(text)
        return try layout(from: tree)
    }

    private static func clampRowsGap(_ value: Int) -> Int {
        min(max(value, 0), SidebarLimits.maxRowGap)
    }

    private static func parseRows(
        _ rows: [TOMLValue],
        kind: String
    ) throws -> [SidebarRowSpec] {
        guard rows.count <= SidebarLimits.maxRows else {
            throw SidebarConfigError.tooManyRows(
                kind: kind,
                count: rows.count,
                limit: SidebarLimits.maxRows
            )
        }
        var result: [SidebarRowSpec] = []
        for (index, row) in rows.enumerated() {
            guard let cells = row.array else {
                throw SidebarConfigError.invalidValue(
                    "\(kind) row \(index) is not an array of tokens"
                )
            }
            guard cells.count <= SidebarLimits.maxTokensPerRow else {
                throw SidebarConfigError.tooManyTokens(
                    row: index,
                    count: cells.count,
                    limit: SidebarLimits.maxTokensPerRow
                )
            }
            var tokens: [SidebarTokenSpec] = []
            for cell in cells {
                // A row entry is either a bare token name or a table with
                // `token = "..."` plus style/rule overrides.
                if let name = cell.string, let token = try parseToken(name: name, table: nil) {
                    tokens.append(token)
                    continue
                }
                if let table = cell.table {
                    guard let name = table["token"]?.string else { continue }
                    if let token = try parseToken(name: name, table: table) {
                        tokens.append(token)
                    }
                }
            }
            result.append(SidebarRowSpec(tokens: tokens))
        }
        return result
    }

    private static func parseToken(
        name: String,
        table: [String: TOMLValue]?
    ) throws -> SidebarTokenSpec? {
        guard let kind = SidebarTokenKind(name: name) else {
            // Unknown token: the daemon would reject it, but blanking a whole
            // sidebar over one key is a worse failure than skipping it.
            return nil
        }
        guard let table else {
            return SidebarTokenSpec(kind: kind)
        }

        let style = parseStyle(table)
        var rules: [StyleRule] = []
        if let rawRules = table["rules"]?.array {
            guard rawRules.count <= SidebarLimits.maxRulesPerToken else {
                throw SidebarConfigError.tooManyRules(
                    token: name,
                    count: rawRules.count,
                    limit: SidebarLimits.maxRulesPerToken
                )
            }
            for raw in rawRules {
                guard let ruleTable = raw.table else { continue }
                // One malformed rule drops only that rule. The daemon rejects
                // the whole `ui.sidebar` section instead, but resetting a
                // user's sidebar over a single bad line is the worse failure.
                if let rule = parseRule(ruleTable) {
                    rules.append(rule)
                }
            }
        }
        return SidebarTokenSpec(kind: kind, style: style, rules: rules)
    }

    /// Expands one `rules = [{...}]` table.
    ///
    /// The condition is an **inline** key — `{ equals = "Local" }`,
    /// `{ gt = 80 }` — and `RawRule` is `deny_unknown_fields`, so the
    /// `{ when = ..., value = ... }` spelling this parser used to read matched
    /// nothing and silently dropped every rule in a hand-written config.
    ///
    /// Upstream also requires exactly one condition per rule and rejects
    /// `ignore_case` on a numeric one (`src/config/sidebar/rules.rs`).
    /// Both checks are reproduced here so a config written against the docs
    /// behaves the same way in Kraal as in the terminal client.
    static func parseRule(_ table: [String: TOMLValue]) -> StyleRule? {
        var found: [RuleCondition] = []
        for condition in [
            StyleRuleCondition.equals,
            .contains,
            .startsWith,
            .greaterThan,
            .lessThan,
        ] {
            let raw = table[condition.rawValue]
            if let string = raw?.string {
                found.append(.text(condition, string))
            } else if condition.isNumeric, let number = numericValue(raw) {
                found.append(.number(condition, number))
            }
        }

        // "sidebar rule requires exactly one of equals, contains, starts_with,
        // gt, lt"
        guard found.count == 1, let only = found.first else { return nil }

        let hide = table["hide"]?.boolean ?? false
        switch only {
        case let .text(condition, text):
            return StyleRule(
                when: condition,
                value: text,
                ignoreCase: table["ignore_case"]?.boolean ?? false,
                style: parseStyle(table),
                hide: hide
            )
        case let .number(condition, threshold):
            // "ignore_case applies only to sidebar text conditions"
            guard table["ignore_case"] == nil else { return nil }
            return StyleRule(
                when: condition,
                threshold: threshold,
                style: parseStyle(table),
                hide: hide
            )
        }
    }

    /// One condition as written in `config.toml`, before it becomes a rule.
    ///
    /// A named enum rather than a tuple: the two arms carry different operands,
    /// and naming them keeps the "exactly one condition" check readable.
    private enum RuleCondition {
        case text(StyleRuleCondition, String)
        case number(StyleRuleCondition, Double)
    }

    /// Reads a numeric threshold, rejecting non-finite values the way the daemon
    /// does (`"sidebar numeric rule threshold must be finite"`).
    private static func numericValue(_ value: TOMLValue?) -> Double? {
        let number: Double
        switch value {
        case let .integer(integer):
            number = Double(integer)
        case let .double(double):
            number = double
        case let .string(string):
            number = Double(string) ?? .nan
        default:
            return nil
        }
        return number.isFinite ? number : nil
    }

    private static func parseStyle(_ table: [String: TOMLValue]) -> TokenStyle {
        TokenStyle(
            foreground: table["fg"]?.string,
            background: table["bg"]?.string,
            bold: table["bold"]?.boolean,
            italic: table["italic"]?.boolean,
            dim: table["dim"]?.boolean,
            underlined: table["underlined"]?.boolean
        )
    }
}
