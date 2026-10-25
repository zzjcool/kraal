// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  Palette+Builtin.swift
//  KraalUI
//
//  The 18 built-in themes, copied value for value from upstream's
//  `src/app/state.rs:78-527`. Kept in an extension so neither file trips
//  swiftlint's `type_body_length`.
//
//  Copied rather than imported because there is nothing to import: the palette never
//  crosses the wire (the daemon's `ClientShellSnapshot` carries no colours), so a
//  remote machine's theme could not reach this client even in principle. Reading the
//  same names from the same config file is what keeps the two agreeing.
//
//  Do not "improve" a colour here. These are transcribed so that `theme.name =
//  "nord"` in a config looks the same whether the daemon or this client drew it; a
//  hand-tuned value would be a silent divergence.
//

import Foundation

public extension Palette {
    /// The palette for a canonical theme name.
    static func builtin(_ canonical: String) -> Palette? {
        switch canonical {
        case "catppuccin": catppuccin
        case "catppuccin-latte": catppuccinLatte
        case "terminal": terminal
        case "tokyo-night": tokyoNight
        case "tokyo-night-day": tokyoNightDay
        case "dracula": dracula
        case "nord": nord
        case "gruvbox": gruvbox
        case "gruvbox-light": gruvboxLight
        case "one-dark": oneDark
        case "one-light": oneLight
        case "solarized": solarized
        case "solarized-light": solarizedLight
        case "kanagawa": kanagawa
        case "kanagawa-lotus": kanagawaLotus
        case "rose-pine": rosePine
        case "rose-pine-dawn": rosePineDawn
        case "vesper": vesper
        default: nil
        }
    }

        /// `catppuccin`
        public static let catppuccin = Palette(
            accent: 0x89B4FA,
            panelBackground: 0x181825,
            sidebarBackground: nil,
            activeRowBackground: 0x1E1E2E,
            selectionBackground: 0x313244,
            surface0: 0x313244,
            surface1: 0x45475A,
            surfaceDim: 0x1E1E2E,
            overlay0: 0x6C7086,
            overlay1: 0x7F849C,
            text: 0xCDD6F4,
            subtext0: 0xA6ADC8,
            mauve: 0xCBA6F7,
            green: 0xA6E3A1,
            yellow: 0xF9E2AF,
            red: 0xF38BA8,
            blue: 0x89B4FA,
            teal: 0x94E2D5,
            peach: 0xFAB387,
        )

        /// `catppuccin-latte`
        public static let catppuccinLatte = Palette(
            accent: 0x1E66F5,
            panelBackground: 0xEFF1F5,
            sidebarBackground: nil,
            activeRowBackground: 0xE6E9EF,
            selectionBackground: 0xBDD0F5,
            surface0: 0xCCD0DA,
            surface1: 0xBCC0CC,
            surfaceDim: 0xE6E9EF,
            overlay0: 0x9CA0B0,
            overlay1: 0x8C8FA1,
            text: 0x4C4F69,
            subtext0: 0x6C6F85,
            mauve: 0x8839EF,
            green: 0x40A02B,
            yellow: 0xDF8E1D,
            red: 0xD20F39,
            blue: 0x1E66F5,
            teal: 0x179299,
            peach: 0xFE640B,
        )

        /// `terminal`
        public static let terminal = Palette(
            accent: 0x5B9BD5,
            panelBackground: nil,
            sidebarBackground: nil,
            activeRowBackground: 0x444444,
            selectionBackground: nil,
            surface0: nil,
            surface1: 0x444444,
            surfaceDim: 0x444444,
            overlay0: 0x808080,
            overlay1: 0xFFFFFF,
            text: nil,
            subtext0: 0x808080,
            mauve: 0x808080,
            green: nil,
            yellow: nil,
            red: nil,
            blue: 0x5B9BD5,
            teal: nil,
            peach: nil,
        )

        /// `tokyo-night`
        public static let tokyoNight = Palette(
            accent: 0x7AA2F7,
            panelBackground: 0x1A1B26,
            sidebarBackground: nil,
            activeRowBackground: 0x232636,
            selectionBackground: 0x2D3650,
            surface0: 0x24283B,
            surface1: 0x414868,
            surfaceDim: 0x1A1B26,
            overlay0: 0x565F89,
            overlay1: 0x697196,
            text: 0xC0CAF5,
            subtext0: 0xA9B1D6,
            mauve: 0xBB9AF7,
            green: 0x9ECE6A,
            yellow: 0xE0AF68,
            red: 0xF7768E,
            blue: 0x7AA2F7,
            teal: 0x7DCFFF,
            peach: 0xFF9E64,
        )

        /// `tokyo-night-day`
        public static let tokyoNightDay = Palette(
            accent: 0x2E7DE9,
            panelBackground: 0xE1E2E7,
            sidebarBackground: nil,
            activeRowBackground: 0xD2D3DA,
            selectionBackground: 0xB6CAE7,
            surface0: 0xC4C8DA,
            surface1: 0xA8AECB,
            surfaceDim: 0xD2D3DA,
            overlay0: 0x8990B3,
            overlay1: 0x68709A,
            text: 0x3760BF,
            subtext0: 0x6172B0,
            mauve: 0x7847BD,
            green: 0x587539,
            yellow: 0x8C6C3E,
            red: 0xF52A65,
            blue: 0x2E7DE9,
            teal: 0x118C74,
            peach: 0xB15C00,
        )

        /// `dracula`
        public static let dracula = Palette(
            accent: 0xBD93F9,
            panelBackground: 0x282A36,
            sidebarBackground: nil,
            activeRowBackground: 0x373C52,
            selectionBackground: 0x463F5D,
            surface0: 0x44475A,
            surface1: 0x6272A4,
            surfaceDim: 0x282A36,
            overlay0: 0x6272A4,
            overlay1: 0x828CB4,
            text: 0xF8F8F2,
            subtext0: 0xD2D2DC,
            mauve: 0xFF79C6,
            green: 0x50FA7B,
            yellow: 0xF1FA8C,
            red: 0xFF5555,
            blue: 0x8BE9FD,
            teal: 0x8BE9FD,
            peach: 0xFFB86C,
        )

        /// `nord`
        public static let nord = Palette(
            accent: 0x88C0D0,
            panelBackground: 0x2E3440,
            sidebarBackground: nil,
            activeRowBackground: 0x434C5E,
            selectionBackground: 0x40505D,
            surface0: 0x3B4252,
            surface1: 0x434C5E,
            surfaceDim: 0x2E3440,
            overlay0: 0x4C566A,
            overlay1: 0x646E82,
            text: 0xECEFF4,
            subtext0: 0xD8DEE9,
            mauve: 0xB48EAD,
            green: 0xA3BE8C,
            yellow: 0xEBCB8B,
            red: 0xBF616A,
            blue: 0x81A1C1,
            teal: 0x8FBCBB,
            peach: 0xD08770,
        )

        /// `gruvbox`
        public static let gruvbox = Palette(
            accent: 0xD79921,
            panelBackground: 0x282828,
            sidebarBackground: nil,
            activeRowBackground: 0x323130,
            selectionBackground: 0x4B3F27,
            surface0: 0x3C3836,
            surface1: 0x504945,
            surfaceDim: 0x282828,
            overlay0: 0x928374,
            overlay1: 0xA89984,
            text: 0xEBDBB2,
            subtext0: 0xD5C4A1,
            mauve: 0xD3869B,
            green: 0xB8BB26,
            yellow: 0xFABD2F,
            red: 0xFB4934,
            blue: 0x83A598,
            teal: 0x8EC07C,
            peach: 0xFE8019,
        )

        /// `gruvbox-light`
        public static let gruvboxLight = Palette(
            accent: 0x076678,
            panelBackground: 0xFBF1C7,
            sidebarBackground: nil,
            activeRowBackground: 0xF2E5BC,
            selectionBackground: 0xEBDBB2,
            surface0: 0xEBDBB2,
            surface1: 0xD5C4A1,
            surfaceDim: 0xF2E5BC,
            overlay0: 0x928374,
            overlay1: 0x7C6F64,
            text: 0x3C3836,
            subtext0: 0x504945,
            mauve: 0x8F3F71,
            green: 0x79740E,
            yellow: 0xB57614,
            red: 0x9D0006,
            blue: 0x076678,
            teal: 0x427B58,
            peach: 0xAF3A03,
        )

        /// `one-dark`
        public static let oneDark = Palette(
            accent: 0x61AFEF,
            panelBackground: 0x282C34,
            sidebarBackground: nil,
            activeRowBackground: 0x313640,
            selectionBackground: 0x334659,
            surface0: 0x2C313A,
            surface1: 0x3E4451,
            surfaceDim: 0x282C34,
            overlay0: 0x5C6370,
            overlay1: 0x737A87,
            text: 0xABB2BF,
            subtext0: 0x969CA8,
            mauve: 0xC678DD,
            green: 0x98C379,
            yellow: 0xE5C07B,
            red: 0xE06C75,
            blue: 0x61AFEF,
            teal: 0x56B6C2,
            peach: 0xD19A66,
        )

        /// `one-light`
        public static let oneLight = Palette(
            accent: 0x4078F2,
            panelBackground: 0xFAFAFA,
            sidebarBackground: nil,
            activeRowBackground: 0xD8DBE2,
            selectionBackground: 0xCDDBF8,
            surface0: 0xF0F0F1,
            surface1: 0xE5E5E6,
            surfaceDim: 0xF5F5F6,
            overlay0: 0xA0A1A7,
            overlay1: 0x686B77,
            text: 0x383A42,
            subtext0: 0x686B77,
            mauve: 0xA626A4,
            green: 0x50A14F,
            yellow: 0xC18401,
            red: 0xE45649,
            blue: 0x4078F2,
            teal: 0x0184BC,
            peach: 0x986801,
        )

        /// `solarized`
        public static let solarized = Palette(
            accent: 0x268BD2,
            panelBackground: 0x002B36,
            sidebarBackground: nil,
            activeRowBackground: 0x164B57,
            selectionBackground: 0x083E55,
            surface0: 0x073642,
            surface1: 0x586E75,
            surfaceDim: 0x002B36,
            overlay0: 0x586E75,
            overlay1: 0x657B83,
            text: 0x93A1A1,
            subtext0: 0x839496,
            mauve: 0xD33682,
            green: 0x859900,
            yellow: 0xB58900,
            red: 0xDC322F,
            blue: 0x268BD2,
            teal: 0x2AA198,
            peach: 0xCB4B16,
        )

        /// `solarized-light`
        public static let solarizedLight = Palette(
            accent: 0x268BD2,
            panelBackground: 0xFDF6E3,
            sidebarBackground: nil,
            activeRowBackground: 0xEEE8D5,
            selectionBackground: 0xC9DCDF,
            surface0: 0xEEE8D5,
            surface1: 0x93A1A1,
            surfaceDim: 0xEEE8D5,
            overlay0: 0x93A1A1,
            overlay1: 0x586E75,
            text: 0x657B83,
            subtext0: 0x839496,
            mauve: 0xD33682,
            green: 0x859900,
            yellow: 0xB58900,
            red: 0xDC322F,
            blue: 0x268BD2,
            teal: 0x2AA198,
            peach: 0xCB4B16,
        )

        /// `kanagawa`
        public static let kanagawa = Palette(
            accent: 0x7E9CD8,
            panelBackground: 0x1F1F28,
            sidebarBackground: nil,
            activeRowBackground: 0x363646,
            selectionBackground: 0x32384B,
            surface0: 0x2A2A37,
            surface1: 0x363646,
            surfaceDim: 0x1F1F28,
            overlay0: 0x727169,
            overlay1: 0x87867D,
            text: 0xDCD7BA,
            subtext0: 0xC8C3AA,
            mauve: 0x957FB8,
            green: 0x76946A,
            yellow: 0xC0A36E,
            red: 0xC34043,
            blue: 0x7E9CD8,
            teal: 0x7FB4CA,
            peach: 0xFFA066,
        )

        /// `kanagawa-lotus`
        public static let kanagawaLotus = Palette(
            accent: 0x4D699B,
            panelBackground: 0xF2ECBC,
            sidebarBackground: nil,
            activeRowBackground: 0xD5CEA3,
            selectionBackground: 0xDCD5AC,
            surface0: 0xDCD5AC,
            surface1: 0xC9CBD1,
            surfaceDim: 0xD5CEA3,
            overlay0: 0xA09CAC,
            overlay1: 0x8A8980,
            text: 0x545464,
            subtext0: 0x43436C,
            mauve: 0x624C83,
            green: 0x6F894E,
            yellow: 0x77713F,
            red: 0xC84053,
            blue: 0x4D699B,
            teal: 0x4E8CA2,
            peach: 0xCC6D00,
        )

        /// `rose-pine`
        public static let rosePine = Palette(
            accent: 0xC4A7E7,
            panelBackground: 0x191724,
            sidebarBackground: nil,
            activeRowBackground: 0x26233A,
            selectionBackground: 0x3B344B,
            surface0: 0x1F1D2E,
            surface1: 0x26233A,
            surfaceDim: 0x26233A,
            overlay0: 0x6E6A86,
            overlay1: 0x908CAA,
            text: 0xE0DEF4,
            subtext0: 0xC8C5DC,
            mauve: 0xC4A7E7,
            green: 0x31748F,
            yellow: 0xF6C177,
            red: 0xEB6F92,
            blue: 0x31748F,
            teal: 0x9CCFD8,
            peach: 0xEA9A97,
        )

        /// `rose-pine-dawn`
        public static let rosePineDawn = Palette(
            accent: 0x907AA9,
            panelBackground: 0xFAF4ED,
            sidebarBackground: nil,
            activeRowBackground: 0xE3D9CF,
            selectionBackground: 0xF2E9E1,
            surface0: 0xF2E9E1,
            surface1: 0xFFFAF3,
            surfaceDim: 0xF2E9E1,
            overlay0: 0x9893A5,
            overlay1: 0x797593,
            text: 0x464261,
            subtext0: 0x797593,
            mauve: 0x907AA9,
            green: 0x286983,
            yellow: 0xEA9D34,
            red: 0xB4637A,
            blue: 0x286983,
            teal: 0x56949F,
            peach: 0xD7827E,
        )

        /// `vesper`
        public static let vesper = Palette(
            accent: 0xFFC799,
            panelBackground: 0x1A1A1A,
            sidebarBackground: nil,
            activeRowBackground: 0x101010,
            selectionBackground: 0x232323,
            surface0: 0x232323,
            surface1: 0x282828,
            surfaceDim: 0x101010,
            overlay0: 0x5C5C5C,
            overlay1: 0x7E7E7E,
            text: 0xFFFFFF,
            subtext0: 0xA0A0A0,
            mauve: 0xFFD1A8,
            green: 0x99FFE4,
            yellow: 0xFFC799,
            red: 0xFF8080,
            blue: 0xB0B0B0,
            teal: 0x66DDCC,
            peach: 0xFFC799,
        )
}
