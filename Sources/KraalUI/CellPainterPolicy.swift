// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Which renderer draws a pane's cells.
//
// Process-global and set once, before the first pane exists, for the same reason
// `PaneRenderPolicy` is: a per-pane decision would make two panes in one window disagree
// about what they are, and this switch exists to compare one whole window against another.

import Foundation

public enum CellPainterPolicy {
    public enum Mode: String {
        /// Only the engine draws.
        case off
        /// Our renderer draws every pane, all the time. For comparing the two renderers.
        case always
        /// Our renderer draws *while a divider is being dragged*, and the engine owns the
        /// picture the rest of the time.
        case drag

        /// The shipped default.
        ///
        /// Jitter only happens while a divider moves: the engine's layer is resized by layout
        /// and the compositor stretches the previous frame until the engine repaints at the
        /// new size, so every drag step shows glyphs at a slightly wrong scale. Drawing the
        /// same cells at paint time has no such window. Outside a drag the engine is the
        /// better renderer — selection, links, graphics, IME preedit and search highlights are
        /// all things this renderer cannot show yet — so it gets the picture back the moment
        /// the mouse is released.
        public static let shipped: Mode = .drag
    }

    /// Read once at launch. `KRAAL_CELL_PAINTER` takes `off`/`0`, `always`/`1`/`true`/`yes`,
    /// or `drag`; anything else, including an unset variable, is the shipped default.
    public static var mode: Mode = .shipped

    public static func apply(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let raw = environment["KRAAL_CELL_PAINTER"]?.lowercased() ?? ""
        switch raw {
        case "0", "false", "no", "off", "none": mode = .off
        case "drag", "dragging": mode = .drag
        case "1", "true", "yes", "always": mode = .always
        default: mode = .shipped
        }
    }

    /// Whether our renderer should be on top right now.
    public static func shouldPaint(dragging: Bool) -> Bool {
        switch mode {
        case .off: return false
        case .always: return true
        case .drag: return dragging
        }
    }
}
