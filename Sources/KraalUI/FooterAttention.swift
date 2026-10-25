// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  FooterAttention.swift
//  KraalUI
//
//  What the sidebar's footer dot is telling the user about.
//
//  Upstream marks its footer launcher when `update_available` or
//  `integration_updates_available` is set (`src/client/shell/global_menu.rs:9-11`)
//  and tints it with the accent colour (`sidebar.rs:394-412`). Kraal has no in-app
//  global menu — the same actions live in the system menu bar — so the signal is
//  mirrored without the launcher.
//

import Foundation
import KraalProtocol

public enum FooterAttention {
    /// The reason to show the dot, or `nil` when there is nothing to say.
    ///
    /// Ordered by severity, because the dot can only carry one tooltip:
    ///
    /// 1. A config diagnostic. It stops the daemon from doing what the file says, so
    ///    it outranks "there is a newer version" — upstream surfaces it as its own
    ///    notice (`SnapshotNotices.swift:85-92`), and it would otherwise be invisible
    ///    from the sidebar.
    /// 2. An update, which is upstream's first attention condition.
    /// 3. Pending integration updates, upstream's second.
    ///
    /// An annotated and a pending state at once is not a case upstream has to
    /// answer — its dot is a boolean — so the ordering above is this client's
    /// choice, recorded here rather than left implicit in a `if` chain.
    public static func reason(for snapshot: ClientShellSnapshot?) -> String? {
        guard let snapshot else { return nil }
        if let diagnostic = trimmed(snapshot.configDiagnostic) {
            return "config: \(diagnostic)"
        }
        if let version = trimmed(snapshot.updateAvailable) {
            return "herdr \(version) available"
        }
        if snapshot.integrationUpdatesAvailable {
            return "integration updates available"
        }
        return nil
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
