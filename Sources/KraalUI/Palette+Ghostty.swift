// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  Palette+Ghostty.swift
//  KraalUI
//
//  Turning a terminal theme into the interface's palette.
//
//  ## Why derive instead of shipping a second table
//
//  A theme file carries 6 + 16 colours; the interface needs 19 roles. Rex solves
//  this by computing its 70 semantic roles from the same source colours
//  (`docs/REX-UI.md` §2), and that is the right shape: one file per theme, and the
//  chrome cannot drift away from the terminal it frames.
//
//  ## The rule, in one line
//
//  Surfaces are the background mixed a little toward the foreground; muted text is
//  the foreground mixed a little toward the background; the status roles are the
//  ANSI colours, so "blocked" is the red the terminal would have drawn.
//
//  Mixing in sRGB, not in linear light: these are *interface* steps of 5–15%, and
//  linear-light mixing on a near-black background produces steps that look equal
//  to the eye but that nobody would pick by hand. Ghostty's own files were picked
//  by hand; this is trying to stay out of the way.
//

import Foundation
import KraalProtocol

public extension Palette {
    /// The palette a Ghostty theme implies.
    ///
    /// `nil` tokens are avoided on purpose: a theme file is a complete statement
    /// about its own colours, so every role can be filled. (`sidebarBackground` is
    /// the exception — Kraal leaves the sidebar to the window material, and painting
    /// it would remove the glass the user chose.)
    static func derived(from theme: GhosttyTheme) -> Palette {
        let background = GhosttyTheme.value(theme.background) ?? 0x000000
        let foreground = GhosttyTheme.value(theme.foreground) ?? 0xFFFFFF
        let ansi = theme.ansi.map { GhosttyTheme.value($0) ?? foreground }
        let accent = ansi[4]
        let selection = theme.selectionBackground.flatMap(GhosttyTheme.value)
            ?? mix(background, foreground, 0.30)

        return Palette(
            accent: accent,
            panelBackground: mix(background, foreground, 0.06),
            terminalBackground: background,
            sidebarBackground: nil,
            activeRowBackground: mix(background, accent, 0.20),
            selectionBackground: selection,
            surface0: mix(background, foreground, 0.09),
            surface1: mix(background, foreground, 0.14),
            surfaceDim: mix(background, foreground, 0.05),
            overlay0: mix(background, foreground, 0.50),
            overlay1: mix(background, foreground, 0.62),
            text: foreground,
            subtext0: mix(background, foreground, 0.78),
            mauve: ansi[5],
            green: ansi[2],
            yellow: ansi[3],
            red: ansi[1],
            blue: ansi[4],
            teal: ansi[6],
            peach: ansi[9]
        )
    }

    /// `from` moved `amount` (0…1) of the way to `target`, per channel.
    static func mix(_ from: UInt32, _ target: UInt32, _ amount: Double) -> UInt32 {
        let clamped = min(max(amount, 0), 1)
        func channel(_ shift: UInt32) -> UInt32 {
            let left = Double((from >> shift) & 0xFF)
            let right = Double((target >> shift) & 0xFF)
            return UInt32((left + (right - left) * clamped).rounded())
        }
        return channel(16) << 16 | channel(8) << 8 | channel(0)
    }
}
