// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The SwiftUI view for one attached pane. It is the Ghostty surface and nothing
// else: no geometry reader, no cell canvas, no repaint loop. Sizing is the
// engine's job — `TerminalView` fits the grid in `layout()`, and the session
// forwards the resulting grid to the core as RESIZE.

import GhosttyTerminal
import SwiftUI

public struct HcTerminalPaneView: View {
    private let session: HcTerminalSession
    private let isFocused: Bool
    @FocusState private var focused: Bool

    public init(session: HcTerminalSession, isFocused: Bool = false) {
        self.session = session
        self.isFocused = isFocused
    }

    public var body: some View {
        TerminalSurfaceView(context: session.state)
            .terminalFocused($focused)
            .background(Color.clear)
            .onAppear { focused = isFocused }
            .onChange(of: isFocused) { _, value in focused = value }
    }
}
