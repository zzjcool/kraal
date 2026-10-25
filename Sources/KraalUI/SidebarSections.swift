// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  SidebarSections.swift
//  KraalUI
//
//  How the sidebar's two panes divide the height.
//
//  The sidebar shows spaces above and agents below, both at once. Upstream draws
//  the same thing in `src/ui/sidebar.rs:30-66`; this is that rule, in points rather
//  than terminal rows.
//

import Foundation

/// The vertical split between the sidebar's spaces pane and its agents pane.
///
/// Upstream's rule, kept deliberately close so the two clients look the same:
///
/// - The ratio is clamped to `0.1 ... 0.9`, so neither pane can be squeezed away.
/// - Both panes always get at least `minSection` points.
/// - Below `compactThreshold` the split becomes an even halving and the minimums
///   stop applying: at that point there is no height to distribute, and honouring a
///   minimum would push the second pane off the bottom.
public enum SidebarSections {
    /// Upstream's `split_ratio.clamp(0.1, 0.9)`.
    public static let minRatio: CGFloat = 0.1
    public static let maxRatio: CGFloat = 0.9
    public static let defaultRatio: CGFloat = 0.5

    /// Below this the split is a plain halving.
    ///
    /// Upstream's threshold is `6` terminal rows (`ui/sidebar.rs:34`). A sidebar row
    /// there is one row; here the narrowest useful row is the 10 pt caption plus its
    /// vertical padding, which `SidebarView` already draws. Six rows of that is
    /// ~84 pt; this uses 120 pt so that the transition happens while both panes can
    /// still show a heading and one row each.
    public static let compactThreshold: CGFloat = 120

    /// The minimum either pane may receive once the ratio applies.
    ///
    /// Upstream's `3` rows (`ui/sidebar.rs:43`): enough for a heading and two
    /// entries. At ~14 pt per row plus a heading, 56 pt is the smallest that still
    /// reads as a list rather than a sliver.
    public static let minSection: CGFloat = 56

    /// Height of the spaces pane and the agents pane, in that order.
    ///
    /// The two always sum to `totalHeight`: the divider is drawn *between* them and
    /// takes no height of its own, so a caller that positions the divider at the
    /// first value gets a layout with no gap and no overlap.
    public static func heights(
        totalHeight: CGFloat,
        ratio: CGFloat = defaultRatio
    ) -> (spaces: CGFloat, agents: CGFloat) {
        guard totalHeight > 0 else { return (0, 0) }
        // A non-finite ratio would propagate into the layout and collapse a pane to
        // NaN, which SwiftUI renders as nothing at all.
        let clamped = ratio.isFinite ? min(max(ratio, minRatio), maxRatio) : defaultRatio

        if totalHeight < compactThreshold {
            let spaces = (totalHeight / 2).rounded(.up)
            return (spaces, totalHeight - spaces)
        }

        let raw = (totalHeight * clamped).rounded()
        let lower = min(minSection, totalHeight)
        let upper = max(totalHeight - minSection, lower)
        let spaces = min(max(raw, lower), upper)
        return (spaces, totalHeight - spaces)
    }

    /// The ratio a divider dragged to `offsetFromTop` implies.
    ///
    /// Clamped the same way `heights` clamps, so a drag that runs past an edge stops
    /// there instead of producing a ratio the layout would silently rewrite.
    public static func ratio(draggedTo offsetFromTop: CGFloat, totalHeight: CGFloat) -> CGFloat {
        guard totalHeight > 0 else { return defaultRatio }
        let raw = offsetFromTop / totalHeight
        guard raw.isFinite else { return defaultRatio }
        return min(max(raw, minRatio), maxRatio)
    }
}
