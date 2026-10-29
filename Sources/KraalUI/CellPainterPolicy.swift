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
    /// `KRAAL_CELL_PAINTER=1` draws the daemon's cells ourselves; anything else leaves the
    /// engine as the only thing on screen.
    ///
    /// Off by default on purpose: this renderer cannot yet honour selection, links, graphics
    /// or a popup's own surface, and a flag is the difference between experimenting with that
    /// and shipping it.
    public static var enabled = false

    /// Read the environment once, at launch. Called from the app target before any pane is
    /// built, so no view ever has to ask.
    public static func apply(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let raw = environment["KRAAL_CELL_PAINTER"]?.lowercased() ?? ""
        enabled = ["1", "true", "yes"].contains(raw)
    }
}
