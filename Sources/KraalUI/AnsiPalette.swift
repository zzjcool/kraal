// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The ANSI colour table behind the self-painting pane.
//
// Why it exists: `PaneCellCanvas` draws the daemon's cells itself, so the terminal
// engine's own palette is out of reach. A cell carries a tag and a payload
// (`TerminalColor`), not a resolved sRGB value, so every colour the wire can name has
// to become `0xRRGGBB` somewhere. This is that somewhere: a pure value type with no
// view in it, so the resolution rules can be tested without a window.
//
// ## Three things that are easy to get wrong
//
// `named(16)` is not a 17th colour. On the wire 16 is the "default foreground" tag, so
// it has to resolve to `foreground` — reading it as a table slot at best paints plain
// text in the wrong colour and at worst reads past the end of the array.
//
// `indexed` is not one ramp. 0...15 alias the named colours, 16...231 are a 6×6×6 cube
// whose levels are *not* evenly spaced (`0, 95, 135, 175, 215, 255` — the first step is
// 95), and 232...255 are 24 greys ten apart starting at 8. Reading the cube as
// `level * 51` gets the two ends right by accident and every step between them wrong:
// colour 17 is blue 95 (`#00005F`), not blue 51 (`#000033`).
//
// A theme token that is `nil` means "no opinion" (see `Palette`), never black. Falling
// back to `0x000000` would paint black backgrounds over a light terminal, which is the
// exact defect the `nil` encoding was introduced to avoid.

import KraalProtocol

/// The 16 named colours plus the three roles a cell can resolve to, as `0xRRGGBB`.
public struct AnsiPalette: Equatable, Sendable {
    /// The default foreground. Also what `.named(16)` and any unanswerable slot resolve to.
    public var foreground: UInt32
    /// The colour behind the cells.
    public var background: UInt32
    /// Fill of the cursor block.
    public var cursor: UInt32
    /// The 16 named colours, index 0...15.
    ///
    /// An array rather than a tuple so a caller can build it from whatever a theme
    /// names. ``rgb(_:)`` tolerates a short or long table instead of trapping.
    public var named: [UInt32]

    public init(foreground: UInt32, background: UInt32, cursor: UInt32, named: [UInt32]) {
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.named = named
    }

    /// The xterm cube's component values. The 95 first step is what makes this table
    /// necessary — the range is a terminal convention, not an even split of 0...255.
    private static let cubeLevels: [UInt32] = [0, 95, 135, 175, 215, 255]

    /// Any wire colour as `0xRRGGBB`. Unknown tags never reach here:
    /// `TerminalColor(raw:)` has already normalised them to `.named(0)`.
    public func rgb(_ color: TerminalColor) -> UInt32 {
        switch color {
        case let .named(index):
            return namedColor(index)
        case let .indexed(index):
            return indexedColor(index)
        case let .rgb(red, green, blue):
            return (UInt32(red) << 16) | (UInt32(green) << 8) | UInt32(blue)
        }
    }

    /// `.named`'s payload: 0...15 index the table, 16 is "default foreground".
    /// `.named`'s payload, in SGR numbering: 1 is black (`30`), 8 is white (`37`),
    /// 9 is bright black (`90`), 16 is bright white (`97`) — `SurfaceANSIRenderer`'s
    /// `colorParameter` is the table of record. **0 is "default", not black**: the renderer
    /// writes `39`/`49` for it, so resolving it as entry 0 paints an ordinary terminal's text
    /// black on black. Measured on the first real launch: the panes came out as blank
    /// rectangles with only the cursor visible.
    private func namedColor(_ index: UInt8) -> UInt32 {
        guard index != 0 else { return foreground }
        return entry(Int(index) - 1)
    }

    /// One of the sixteen, by table position (0 is the terminal's black, 15 its bright white).
    private func entry(_ slot: Int) -> UInt32 {
        guard slot >= 0, slot < named.count else { return foreground }
        return named[slot]
    }

    /// `.indexed`'s payload: three ranges, three rules.
    private func indexedColor(_ index: UInt8) -> UInt32 {
        let slot = Int(index)
        if slot < 16 {
            // Not a separate table: 256-colour entries 0...15 are the very colours the
            // theme named, in table order rather than SGR order.
            return entry(Int(index))
        }
        if slot < 232 {
            let offset = slot - 16
            let red = Self.cubeLevels[offset / 36]
            let green = Self.cubeLevels[(offset / 6) % 6]
            let blue = Self.cubeLevels[offset % 6]
            return (red << 16) | (green << 8) | blue
        }
        // 232...255: 8, 18, ... 238, the same on all three channels.
        let grey = UInt32(8 + (slot - 232) * 10)
        return (grey << 16) | (grey << 8) | grey
    }

    // MARK: - From a theme

    /// A theme's opinion, with ``defaultDark`` filling in whatever it does not name.
    ///
    /// Which token lands on which slot — `Palette` has seven colour roles and no
    /// concept of "bright", so this is a mapping, not a transcription:
    ///
    /// | slot | colour | token |
    /// | --- | --- | --- |
    /// | 0, 7, 8, 15 | black, white, bright black, bright white | none — `defaultDark` |
    /// | 1, 9 | red, bright red | `red` |
    /// | 2, 10 | green, bright green | `green` |
    /// | 3 | yellow | `yellow` |
    /// | 4, 12 | blue, bright blue | `blue` |
    /// | 5, 13 | magenta, bright magenta | `mauve` |
    /// | 6, 14 | cyan, bright cyan | `teal` |
    /// | 11 | bright yellow | `peach` |
    ///
    /// Bright slots reuse their normal counterpart because the theme names one step per
    /// hue; inventing a lightened variant would be a colour the theme never chose.
    /// `peach` takes 11 rather than a normal slot because ANSI bright yellow is what
    /// programs use for warnings, and `peach` is this palette's warning colour. The
    /// achromatic slots stay on `defaultDark` because `Palette` has no token for them.
    ///
    /// Every `nil` falls back. Nothing here can produce black for a missing token: a
    /// light theme that names only `text` must not end up with a black terminal.
    public static func from(_ palette: Palette) -> AnsiPalette {
        var colors = defaultDark.named
        apply(palette.red, to: [1, 9], into: &colors)
        apply(palette.green, to: [2, 10], into: &colors)
        apply(palette.yellow, to: [3], into: &colors)
        apply(palette.blue, to: [4, 12], into: &colors)
        apply(palette.mauve, to: [5, 13], into: &colors)
        apply(palette.teal, to: [6, 14], into: &colors)
        apply(palette.peach, to: [11], into: &colors)
        return AnsiPalette(
            foreground: palette.text ?? defaultDark.foreground,
            background: palette.terminalBackground ?? defaultDark.background,
            cursor: palette.accent ?? defaultDark.cursor,
            named: colors
        )
    }

    /// Writes `token` into `slots`, leaving the default in place when the theme has no
    /// opinion — a `nil` that turned into black would be a colour the theme never chose.
    private static func apply(_ token: UInt32?, to slots: [Int], into colors: inout [UInt32]) {
        guard let token else { return }
        for slot in slots where slot < colors.count {
            colors[slot] = token
        }
    }

    // MARK: - Baseline

    /// The baseline when a theme names nothing.
    ///
    /// These are libghostty's own default dark theme — `.afterglow` in
    /// `libghostty-spm/Sources/GhosttyTerminal/Configuration/TerminalTheme+Defaults.swift`
    /// (`#212121` on `#D0D0D0`, which is also what the engine paints when no terminal
    /// background is set). It is copied rather than invented so the painter draws what
    /// the engine would have drawn for a cell a theme has no opinion about; two paths
    /// that disagree on the default are two paths that flicker when they swap.
    ///
    /// Being a copy, it is a snapshot: libghostty changing its default would not move
    /// these numbers, and that is deliberate — a fallback that shifts under an upgrade
    /// would change how existing terminals look without anyone asking.
    public static let defaultDark = AnsiPalette(
        foreground: 0xD0D0D0,
        background: 0x212121,
        cursor: 0xD0D0D0,
        named: [
            0x151515, // 0 black
            0xAC4142, // 1 red
            0x7E8E50, // 2 green
            0xE4B567, // 3 yellow
            0x6C99BB, // 4 blue
            0x9F4E86, // 5 magenta
            0x7DD5CF, // 6 cyan
            0xD0D0D0, // 7 white
            0x505050, // 8 bright black
            0xAC4142, // 9 bright red
            0x7E8E50, // 10 bright green
            0xE4B567, // 11 bright yellow
            0x6C99BB, // 12 bright blue
            0x9F4E86, // 13 bright magenta
            0x7DD5CF, // 14 bright cyan
            0xF5F5F5 // 15 bright white
        ]
    )
}
