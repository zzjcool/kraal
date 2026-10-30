// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  FontScale.swift
//  KraalUI
//
//  The terminal's font size, and the three commands that move it.
//
//  Rex has `client.font.increase / decrease / reset`; Ghostty has ⌘+ / ⌘- / ⌘0.
//  A terminal client without them makes the user edit a config file to read a
//  small font, which is the kind of gap nobody reports and everybody works around.
//
//  ## 13 is the base, and it is the engine's own default
//
//  libghostty's `font-size` defaults to 13; Kraal never set it, so every pane so
//  far has been drawn at 13. `reset` therefore sets 13 rather than clearing the
//  key — the two are the same thing today, and writing the number makes the log
//  line (`terminal font: 13`) comparable across runs.
//
//  The step is 1pt, the range 8…32: below 8 a cell is about four pixels wide and
//  the grid is unusable; above 32 a single pane of a 1180pt window fits fewer than
//  thirty columns, which is past "large" into "broken layout".
//
//  Pure, and separate from the view, so the step and the clamp are testable
//  without a window — the pool rebuild they cause is not.
//

import Foundation

public enum FontScale {
    /// The engine's default, and what `reset` restores.
    public static let base: Float = 13
    public static let minimum: Float = 8
    public static let maximum: Float = 32
    /// One point per press. Half steps sound nicer and make the log ambiguous.
    public static let step: Float = 1

    public enum Change: Sendable, Equatable {
        case increase
        case decrease
        case reset
    }

    /// The size after `change`, clamped.
    public static func next(_ current: Float, change: Change) -> Float {
        switch change {
        case .increase: clamp(current + step)
        case .decrease: clamp(current - step)
        case .reset: base
        }
    }

    public static func clamp(_ size: Float) -> Float {
        min(max(size, minimum), maximum)
    }

    /// `13` / `13.5` — no trailing `.0`, so a log line reads like a person wrote it.
    public static func label(_ size: Float) -> String {
        size == size.rounded() ? String(Int(size)) : String(format: "%.1f", size)
    }
}
