// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation

/// `fg`/`bg` encoding. Not ARGB — the top byte is a tag, not alpha.
public enum TerminalColor: Equatable, Hashable, Sendable {
    /// Palette index 0...=16 (the terminal's named ANSI colors).
    case named(UInt8)
    /// `0x0100_00XX`: 256-color palette entry `XX`.
    case indexed(UInt8)
    /// `0x02RRGGBB`: direct color.
    case rgb(red: UInt8, green: UInt8, blue: UInt8)

    public init(raw: UInt32) {
        switch raw {
        case 0 ... 16:
            self = .named(UInt8(raw))
        default:
            switch (raw >> 24) & 0xFF {
            case 0x01:
                self = .indexed(UInt8(raw & 0xFF))
            case 0x02:
                self = .rgb(
                    red: UInt8((raw >> 16) & 0xFF),
                    green: UInt8((raw >> 8) & 0xFF),
                    blue: UInt8(raw & 0xFF)
                )
            default:
                // Unknown encoding: fall back to the default foreground rather
                // than dropping the cell.
                self = .named(0)
            }
        }
    }

    public var rawValue: UInt32 {
        switch self {
        case let .named(index):
            UInt32(index)
        case let .indexed(index):
            0x0100_0000 | UInt32(index)
        case let .rgb(red, green, blue):
            0x0200_0000 | (UInt32(red) << 16) | (UInt32(green) << 8) | UInt32(blue)
        }
    }
}

/// The visible state of one cell, resolved for drawing.
public struct StyledCell: Equatable, Sendable {
    public var symbol: String
    public var foreground: TerminalColor
    public var background: TerminalColor
    public var modifier: UInt16
    public var hyperlink: String?

    public var isBold: Bool { modifier & CellModifier.bold != 0 }
    public var isDim: Bool { modifier & CellModifier.dim != 0 }
    public var isItalic: Bool { modifier & CellModifier.italic != 0 }
    public var isUnderlined: Bool { modifier & CellModifier.underline != 0 }
    public var isReversed: Bool { modifier & CellModifier.reversed != 0 }
    public var isStrikethrough: Bool { modifier & CellModifier.strikethrough != 0 }
    public var isHidden: Bool { modifier & CellModifier.hidden != 0 }
}
