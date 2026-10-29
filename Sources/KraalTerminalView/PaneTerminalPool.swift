// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import GhosttyTerminal
import KraalProtocol
import SwiftUI

/// Hosts the pane models for one window and keeps them in sync with the store.
///
/// Keys are `(machine, paneId)`, not `paneId` alone. Pane ids are scoped to one
/// daemon — upstream says so outright: "Workspace, tab, pane IDs, and agent names
/// are scoped to one server. Two machines may both contain `w1:p1`"
/// (`docs/next/website/src/content/docs/connecting-machines.mdx:118`). Keying on
/// the pane id alone made two machines' `w1:p1` share one model, and with it one
/// Ghostty `InMemoryTerminalSession`: the scrollback, the alternate-screen state
/// and the cursor of the machine you just left were still inside the surface that
/// went on to render the new one. A full-screen program like btop lives entirely
/// in the alternate screen, so that leak showed up as its picture surviving into
/// the other machine's pane.
@MainActor
@Observable
public final class PaneTerminalPool {
    private var models: [Key: PaneTerminalModel] = [:]
    private let onInput: @Sendable (String, Data) -> Void

    /// Which machine a model belongs to, plus the pane inside it.
    private struct Key: Hashable {
        let machine: String
        let paneId: String
        /// `paneId` for a pane, the popup's terminal id for a popup.
        ///
        /// A separate field rather than a `"popup:"` prefix on `paneId`: `prune`
        /// compares `paneId` against the live pane set, and a prefixed id never
        /// matches, so every popup's Ghostty surface would be leaked forever.
        let isPopup: Bool
    }

    /// The machine whose panes the pool currently holds.
    ///
    /// A switch drops every model: their surfaces belong to another daemon's
    /// session, so there is nothing in them worth carrying across, and keeping
    /// them alive is how the previous machine's screen state leaked into the next.
    private var machine: String?

    /// The theme's terminal background, as `RRGGBB`, applied to every terminal this
    /// pool builds.
    ///
    /// Setting it retires the existing models: the colour is a construction-time
    /// configuration command in libghostty, so a theme change has to rebuild the
    /// surfaces rather than mutate them. Themes change rarely (a config reload or a
    /// light/dark switch) and a rebuild is what `selectMachine` already does on the
    /// same scale.
    public var background: String? {
        didSet {
            guard background != oldValue else { return }
            models.removeAll()
        }
    }

    /// The theme's selection highlight, as `RRGGBB`, applied to every terminal this pool
    /// builds. Same construction-time rule as ``background``: changing it retires the
    /// models.
    public var selectionBackground: String? {
        didSet {
            guard selectionBackground != oldValue else { return }
            models.removeAll()
        }
    }

    public init(
        onInput: @escaping @Sendable (String, Data) -> Void,
        background: String? = nil,
        selectionBackground: String? = nil
    ) {
        self.onInput = onInput
        self.background = background
        self.selectionBackground = selectionBackground
    }

    /// Points the pool at the machine whose panes it is about to be asked for.
    ///
    /// Called before any model is handed out for a new machine. A switch retires
    /// every model unconditionally: they are bound to the other daemon's session,
    /// and the whole reason `w1:p1` on two machines must not share a surface is
    /// that the Ghostty state inside it belongs to exactly one of them.
    ///
    /// Staying on the same machine is a no-op, which is the normal case —
    /// switching workspaces never reaches this.
    public func selectMachine(_ identifier: String) {
        guard machine != identifier else { return }
        machine = identifier
        models.removeAll()
    }

    /// The model for a pane, or for a popup when `isPopup` is set.
    ///
    /// The two live in separate key spaces because their graphics scopes differ and
    /// a popup's `terminalId` can coincide with a pane id: sharing one model would
    /// let a popup and a pane fight over the same image ids in one terminal.
    public func model(for paneId: String, isPopup: Bool = false) -> PaneTerminalModel {
        let key = Key(machine: machine ?? "", paneId: paneId, isPopup: isPopup)
        if let existing = models[key] {
            return existing
        }
        let model = PaneTerminalModel(
            paneId: paneId,
            machine: key.machine,
            isPopup: isPopup,
            background: background,
            selectionBackground: selectionBackground
        ) { [weak self] data in
            self?.onInput(paneId, data)
        }
        models[key] = model
        return model
    }

    /// Drops terminals for panes that no longer exist, releasing their surfaces.
    public func prune(keeping paneIds: Set<String>) {
        // Popups are excluded on purpose: `paneIds` is the set of *panes*, a popup
        // is not one, and its lifetime is the popup's — it closes when the surface
        // stops carrying one (`applyPopup` is not called, and the view goes away with
        // the model). Pruning by `paneId` would drop a popup's terminal every time
        // the pane set changed, throwing away its image cache mid-display.
        for key in models.keys where !key.isPopup && !paneIds.contains(key.paneId) {
            models.removeValue(forKey: key)
        }
    }

    /// Drops popup terminals for popups the surface no longer carries.
    ///
    /// Called from the same place as `prune(keeping:)` — when the store's surface
    /// changes — but keyed on the popup instead of the pane set. A popup is not in
    /// `paneIds`, so folding the two together would either leak every popup's
    /// Ghostty surface (what a `"popup:"`-prefixed `paneId` did) or delete live
    /// panes.
    public func prunePopups(keeping terminalIds: Set<String>) {
        for key in models.keys
        where key.isPopup && !terminalIds.contains(key.paneId) {
            models.removeValue(forKey: key)
        }
    }

    public func reset() {
        for model in models.values {
            model.reset()
        }
    }
}
