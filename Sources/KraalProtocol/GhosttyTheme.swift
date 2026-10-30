// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  GhosttyTheme.swift
//  KraalProtocol
//
//  One theme, as Ghostty writes it to a file.
//
//      palette = 0=#45475a
//      ...
//      background = #1e1e2e
//      foreground = #cdd6f4
//      cursor-color = #f5e0dc
//      cursor-text = #1e1e2e
//      selection-background = #f5e0dc
//      selection-foreground = #1e1e2e
//
//  The same format Ghostty's `theme = name` reads, so Kraal's catalogue and the
//  user's editor of choice talk about themes the same way, and adding a theme is
//  a file copy (`Sources/KraalUI/Resources/themes/ATTRIBUTION.md`).
//
//  ## Why the parser is here and not in KraalUI
//
//  It is text in, colours out — no AppKit, no SwiftUI, no bundle. Keeping it in
//  the protocol module means the terminal renderer (KraalTerminalView) can take
//  the parsed colours without importing the UI, and the tests can exercise the
//  parser on strings rather than on files.
//
//  ## `nil` means "the file did not say", not "black"
//
//  Only `background`, `foreground` and all 16 palette entries are required: those
//  are what a terminal cannot render without. The rest are optional because
//  Ghostty's own files often omit `cursor-text` and selection colours, and a
//  default of black there would draw an invisible cursor.

import Foundation

/// A theme file, parsed.
public struct GhosttyTheme: Sendable, Equatable, Identifiable {
    /// The file name, used as the stable key (a theme can be renamed upstream).
    public let id: String
    /// The display name: the file name, with Ghostty's own spelling.
    public let name: String
    /// `RRGGBB`, lower case, no `#`.
    public let background: String
    public let foreground: String
    public let cursor: String?
    public let cursorText: String?
    public let selectionBackground: String?
    public let selectionForeground: String?
    /// Sixteen colours, index 0…15.
    public let ansi: [String]

    public init(
        id: String,
        name: String,
        background: String,
        foreground: String,
        cursor: String? = nil,
        cursorText: String? = nil,
        selectionBackground: String? = nil,
        selectionForeground: String? = nil,
        ansi: [String]
    ) {
        self.id = id
        self.name = name
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.cursorText = cursorText
        self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground
        self.ansi = ansi
    }

    /// A dark theme, by the luminance of its background.
    ///
    /// Used to sort the picker (dark themes first, matching the shell's own
    /// grouping) and by the derived palette, which has to know which way "raised"
    /// and "recessed" run.
    public var isDark: Bool { Self.luminance(background) < 0.5 }

    /// `0…1` perceptual-ish luminance of a `RRGGBB` string. `nil` when unparsable.
    public static func luminance(_ hex: String) -> Double {
        guard let rgb = components(hex) else { return 0.5 }
        return 0.2126 * linear(rgb.red) + 0.7152 * linear(rgb.green) + 0.0722 * linear(rgb.blue)
    }

    /// The colour as `0xRRGGBB`, or `nil` when the string is not six hex digits.
    public static func value(_ hex: String) -> UInt32? {
        guard let rgb = components(hex) else { return nil }
        return UInt32(rgb.red * 255 + 0.5) << 16
            | UInt32(rgb.green * 255 + 0.5) << 8
            | UInt32(rgb.blue * 255 + 0.5)
    }

    /// Parses one theme file.
    ///
    /// Returns `nil` when a required key is missing or a colour is malformed. A
    /// theme that cannot be rendered is skipped rather than half-applied: a
    /// half-applied one shows as black text on a black background, which reads as
    /// a broken app rather than a broken file.
    public static func parse(id: String, name: String, text: String) -> GhosttyTheme? {
        var values: [String: String] = [:]
        var palette: [Int: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let split = line.firstIndex(of: "=") else { continue }
            let key = line[..<split].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: split)...].trimmingCharacters(in: .whitespaces)
            if key == "palette" {
                // `palette = 4=#89b4fa`: the value has a second `=`.
                guard let inner = value.firstIndex(of: "="),
                      let index = Int(value[..<inner].trimmingCharacters(in: .whitespaces)),
                      let hex = normalise(String(value[value.index(after: inner)...]))
                else { continue }
                palette[index] = hex
            } else if let hex = normalise(String(value)) {
                values[key] = hex
            }
        }
        guard let background = values["background"],
              let foreground = values["foreground"],
              palette.count >= 16,
              (0..<16).allSatisfy({ palette[$0] != nil })
        else { return nil }
        return GhosttyTheme(
            id: id,
            name: name,
            background: background,
            foreground: foreground,
            cursor: values["cursor-color"],
            cursorText: values["cursor-text"],
            selectionBackground: values["selection-background"],
            selectionForeground: values["selection-foreground"],
            ansi: (0..<16).map { palette[$0] ?? foreground }
        )
    }

    /// `#RRGGBB` / `RRGGBB` / `#RGB` → `rrggbb`, lower case. Anything else is `nil`.
    static func normalise(_ raw: String) -> String? {
        var hex = raw.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        hex = hex.lowercased()
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex
    }

    private struct Channels {
        let red: Double
        let green: Double
        let blue: Double
    }

    private static func components(_ hex: String) -> Channels? {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let int = UInt32(value, radix: 16) else { return nil }
        return Channels(
            red: Double((int >> 16) & 0xFF) / 255,
            green: Double((int >> 8) & 0xFF) / 255,
            blue: Double(int & 0xFF) / 255
        )
    }

    private static func linear(_ component: Double) -> Double {
        component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }
}
