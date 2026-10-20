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
                guard let ruleTable = raw.table,
                      let whenText = ruleTable["when"]?.string,
                      let condition = StyleRuleCondition(rawValue: whenText),
                      let value = ruleTable["value"]?.string
                else {
                    continue
                }
                rules.append(StyleRule(
                    when: condition,
                    value: value,
                    ignoreCase: ruleTable["ignore_case"]?.boolean ?? false,
                    style: parseStyle(ruleTable)
                ))
            }
        }
        return SidebarTokenSpec(kind: kind, style: style, rules: rules)
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
