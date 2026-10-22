// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  PopupChrome.swift
//  Kraal
//
//  The border and title around a popup's terminal.
//
//  The daemon's grid does not include any of this: `ClientShellPopupSurface.frame`
//  is the popup's *interior* cells, one cell inside the box the daemon reserved for
//  it. Upstream draws the frame with ratatui (`client/shell/composition.rs:566-582`)
//  and blits the terminal into `geometry.inner`; the same split applies here, just
//  with SwiftUI drawing the box.
//
//  Kept apart from `PaneLayoutView` so the layout file stays about layout, and so
//  the chrome can be looked at on its own.
//

import KraalProtocol
import SwiftUI

/// Draws the popup's box: a gap where the border will be, then the border.
///
/// Drawing order matters. The popup terminal occupies the box's full size in the
/// layout (it is later covered by this background), so this view paints a ring
/// rather than a filled rectangle — filling it would hide the terminal underneath.
struct PopupChrome: View {
    let popup: ClientShellPopupSurface
    let geometry: PopupGeometry
    let cellSize: CGSize

    /// One cell, in points. The border is exactly one cell wide because that is
    /// what `PopupGeometry` reserved for it: drawing it thinner would leave a
    /// sliver of terminal showing through, and thicker would cover a character.
    private var borderWidth: CGFloat {
        max(cellSize.width, 1)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The border: an inset stroke so it lands inside the popup's own box
            // rather than straddling its edge.
            Rectangle()
                .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: borderWidth)
                .allowsHitTesting(false)

            // The title, in the top border. macOS terminal emulators label a
            // floating sheet by its title; without it a popup is an unexplained
            // rectangle, and there is no way to tell a floating shell from a
            // rendering glitch.
            if !popup.title.isEmpty {
                Text(popup.title)
                    .font(.system(size: max(cellSize.height * 0.7, 8)))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                    .padding(.horizontal, borderWidth * 2)
                    .background(Color(nsColor: .textBackgroundColor))
                    .offset(x: borderWidth * 2)
            }
        }
        // The chrome is decoration: a click on the border must reach the terminal
        // underneath (which is what focuses it), not be eaten here.
        .allowsHitTesting(false)
    }
}
