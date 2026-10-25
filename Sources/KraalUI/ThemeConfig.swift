// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  ThemeConfig.swift
//  KraalUI
//
//  Reads the `[theme]` table out of the user's `config.toml`.
//
//  ## Why this client reads the file itself
//
//  The palette never crosses the wire: the daemon's `ClientShellSnapshot` has no
//  colour fields at all, so a remote machine's theme could not be delivered even in
//  principle. Upstream's own client shell resolves its palette locally, from the same
//  config file (`src/client/shell/config.rs:137`), which is the model followed here.
//
//  The parser is deliberately small and TOML-shaped rather than a dependency:
//  `Package.swift` has exactly one external package (libghostty) and adding a TOML
//  library to read four keys is not worth it. `KeybindingProfile` already parses the
//  daemon's keybinding TOML the same way, so this is the established pattern here.
//
//  What it does **not** do is pretend to be a TOML parser. It reads the keys it needs
//  from the `[theme]` table and ignores everything else. A syntax error elsewhere in
//  the file must not stop the theme from being read, because the daemon will report
//  the syntax error itself and a client that also refused would be useless.
//

import Foundation

/// The `[theme]` table of `config.toml`.
public struct ThemeConfig: Equatable, Sendable {
    /// Built-in theme name. Upstream default: `"catppuccin"`.
    public var name: String?
    /// Follow the host appearance and switch between `darkName` / `lightName`.
    public var autoSwitch: Bool
    public var darkName: String?
    public var lightName: String?

    /// Upstream's defaults (`src/app/mod.rs:320-345`).
    public static let `default` = ThemeConfig(
        name: nil,
        autoSwitch: false,
        darkName: nil,
        lightName: nil
    )

    public init(name: String?, autoSwitch: Bool, darkName: String?, lightName: String?) {
        self.name = name
        self.autoSwitch = autoSwitch
        self.darkName = darkName
        self.lightName = lightName
    }

    /// Parses the `[theme]` table out of a document.
    ///
    /// Keys may appear before or after other tables; only those inside `[theme]` are
    /// read, and `[theme.something]` subtables are skipped rather than mistaken for
    /// keys. Values are unquoted and whitespace-trimmed; `auto_switch` accepts the
    /// TOML booleans.
    public static func parse(_ document: String) -> ThemeConfig {
        var config = ThemeConfig.default
        var insideTheme = false
        for rawLine in document.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.split(separator: "#", maxSplits: 1).first
                .map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard !line.isEmpty else { continue }
            if line.hasPrefix("[") {
                // A table header ends the previous table. `[theme.something]` is a
                // subtable and its keys are not `[theme]`'s.
                insideTheme = line == "[theme]"
                continue
            }
            guard insideTheme, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = unquote(line[line.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces))
            switch key {
            case "name": config.name = value
            case "dark_name": config.darkName = value
            case "light_name": config.lightName = value
            case "auto_switch": config.autoSwitch = value.lowercased() == "true"
            default: continue
            }
        }
        return config
    }

    /// Strips one layer of quotes, if present.
    ///
    /// Only single- and double-quoted scalars are handled. A multi-line or literal
    /// string in `[theme]` would be a strange thing to write, and treating it as
    /// missing (rather than as a title with a stray quote in it) is the honest outcome.
    private static func unquote(_ raw: String) -> String {
        guard raw.count >= 2 else { return raw }
        if (raw.hasPrefix("\"") && raw.hasSuffix("\""))
            || (raw.hasPrefix("'") && raw.hasSuffix("'")) {
            return String(raw.dropFirst().dropLast())
        }
        return raw
    }

    /// Where `config.toml` lives for this user.
    ///
    /// `HERDR_CONFIG_DIR` wins when set — the GUI gate puts a scratch config there so
    /// a case cannot read the developer's real theme.
    public static func configURL(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> URL? {
        if let override = environment["HERDR_CONFIG_DIR"] {
            return URL(fileURLWithPath: override).appendingPathComponent("config.toml")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/herdr/config.toml")
    }

    /// Reads and parses the user's config, or `.default` when there is none.
    public static func load(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> ThemeConfig {
        guard let url = configURL(environment: environment) else { return .default }
        guard let document = try? String(contentsOf: url, encoding: .utf8) else {
            // Absent is not an error: the default theme is what upstream uses too, and
            // logging on every launch for the common case would be noise. The path is
            // logged anyway, because "my theme did nothing" is answered by *which file
            // was read* far faster than by reading the code again.
            kraalLog("theme: no config at \(url.path)")
            return .default
        }
        let config = parse(document)
        kraalLog("theme: name=\(config.name ?? "-") auto=\(config.autoSwitch)")
        return config
    }
}
