// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  GhosttyPopupView.swift
//  Kraal
//
//  The popup's terminal surface.
//
//  Deliberately thinner than `GhosttyPaneView`: a popup has no scrollbar lane, no
//  split handles, no focus outline of its own (the chrome draws its border), and no
//  per-pane geometry to report. What it does have is its own input stream, which has
//  to go to the popup's terminal id rather than to whichever pane is focused — that
//  is the whole point of a modal popup.
//

import GhosttyTerminal
import KraalUI
import SwiftUI

public struct GhosttyPopupView: View {
    let model: PaneTerminalModel
    let terminalId: String

    public init(model: PaneTerminalModel, terminalId: String) {
        self.model = model
        self.terminalId = terminalId
    }

    public var body: some View {
        TerminalSurfaceView(context: model.state)
            // A freshly mounted terminal view has an empty screen, so the model's
            // memory of what it already drew is a lie. Forgetting it lets the next
            // apply paint the whole frame — without this, a popup opened after
            // another one closed showed the closed one's cells.
            .onAppear { model.prepareForNewTerminalView() }
            .onChange(of: model.state.surfaceSize) { _, new in
                // Ghostty attaches asynchronously; a frame that arrived before the
                // grid existed is parked, and the grid appearing is the signal that
                // it can finally be laid out.
                if new != nil { model.flushPendingFrame() }
            }
    }
}
