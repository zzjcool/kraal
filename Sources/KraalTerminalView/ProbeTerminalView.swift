// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import AppKit
import GhosttyTerminal

/// A terminal view that refuses to have an intrinsic size.
///
/// `NSView` reports `noIntrinsicMetric` by default, and SwiftUI honours that by
/// proposing the size the *container* offers. When the offer never changes — a
/// settled split — the view keeps whatever rectangle it was last given, even after
/// the pane above or below it grew. Measured on a settled drag, both panes one row
/// out in opposite directions with the totals conserved:
///
///     p16 allocated=592.0pt view=573.5pt gap=+18.5pt
///     p14 allocated=314.5pt view=333.0pt gap=-18.5pt
///
/// `NSView`'s default already says "no intrinsic size"; this class exists so the value
/// is stated explicitly and can be changed in one place if the default is not what
/// SwiftUI is honouring.
final class ProbeTerminalView: AppTerminalView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}
