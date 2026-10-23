// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The reachability pill in the machines panel — issue #73.
//
// Its own file because it is a second, independent signal about the same row, and
// because the claim it makes is easy to get wrong in a way no compiler catches:
// `herdr machine status` says whether the *machine* is there, while
// `EndpointStatus` in the sidebar says whether *Kraal's connection* to it is
// alive. Those disagree all the time — a saved machine that has been stopped for
// weeks still gets a green dot if the app's connection to it happens to be up.

import KraalTransport
import SwiftUI

/// What `herdr machine status` said about one row.
///
/// Deliberately a **word**, not a coloured dot. `EndpointStatus.badge` in the
/// sidebar already uses `●` (green/amber/red) for Kraal's own connection to a
/// machine; a second dot here would put two different facts in one visual
/// language, which is how a reader concludes "it says green, so the machine is
/// fine". A pill is a separate channel, and it is addressable by `AXValue` in the
/// GUI gate, which is the only channel SwiftUI `Text` offers (issue #71).
///
/// The CLI's own word is shown for every state, including ones this build does
/// not know: a newer herdr adding a fifth status must render as itself rather
/// than as a blank cell.
struct ReachabilityBadge: View {
    let status: MachineStatus

    var body: some View {
        Text(label)
            .font(KraalTheme.Font.micro)
            .foregroundStyle(colour)
            .lineLimit(1)
            .help(help)
    }

    /// The word shown. `error` becomes "unreachable" because `error` next to
    /// `disabled` reads like a severity rather than a state; the CLI's own word
    /// stays in the tooltip and in the log line.
    var label: String {
        switch status.reachability {
        case .reachable: "reachable"
        case .unreachable: "unreachable"
        case .authRequired: "auth required"
        case .disabled: "disabled"
        case let .other(raw): raw.isEmpty ? "unknown" : raw
        }
    }

    var colour: Color {
        switch status.reachability {
        case .reachable: .green
        case .unreachable: .red
        case .authRequired: .orange
        case .disabled: .secondary
        case .other: .secondary
        }
    }

    /// `true` when this row is in a state the user should look at.
    ///
    /// A property rather than something read off `colour`, so a test can assert the
    /// distinction without importing SwiftUI colours. The claim being pinned is
    /// "a dead server and a rejected key are both worth attention, and a reachable
    /// machine is not".
    var isWarning: Bool { status.reachability.needsAttention }

    private var help: String {
        if let error = status.error, !error.isEmpty { return error }
        return "herdr machine status: \(status.status)"
    }
}
