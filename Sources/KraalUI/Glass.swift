// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Real macOS materials for the app chrome.
//
// Why this file exists: SwiftUI's `Material` views sample what is behind them *in
// the view tree*. Inside an opaque `NSWindow` that is the window's own background
// colour, so `.thinMaterial` on the sidebar renders a flat grey — translucent in
// name only. Measured on this machine before the change: every chrome pixel came
// back as one of two constant greys regardless of what the window covered.
//
// `NSVisualEffectView` with `blendingMode = .behindWindow` is what actually reaches
// the desktop, and it is also what gives Kraal the system behaviours for free:
// dark/light adaptation, "Reduce transparency" and "Increase contrast" in
// Accessibility, and `state = .followsWindowActiveState` (an inactive window dims
// its chrome the way every other Mac app does).
//
// The terminal deliberately does not use any of this. See `PaneLayoutView`, which
// keeps an opaque background under the Ghostty surface: washed-out glyphs on a
// blurred backdrop are the one thing a terminal client must never ship.

import SwiftUI

#if os(macOS)
import AppKit
#endif

/// A chrome surface in the app, named by role rather than by blur radius.
///
/// Mapping roles to AppKit materials (instead of picking an opacity per view) is
/// what keeps the chrome consistent: AppKit's `.sidebar`, `.headerView`,
/// `.underWindowBackground` and `.hudWindow` are the same materials Finder, Mail
/// and Spotlight use, and they stay correct across OS releases.
public enum GlassLayer {
    /// The workspace/agent sidebar. AppKit's canonical sidebar material.
    case sidebar
    /// Bars that sit against the window chrome: tab bar and status bar.
    case bar
    /// A modal sheet or panel (Machines, Shortcuts, Connection, Rename).
    case sheet
    /// A floating keyboard-driven overlay: the command palette.
    case hud

    #if os(macOS)
    var material: NSVisualEffectView.Material {
        switch self {
        case .sidebar: return .sidebar
        case .bar: return .headerView
        case .sheet: return .underWindowBackground
        case .hud: return .hudWindow
        }
    }
    #endif

    /// How strongly the window background is washed back over the material.
    ///
    /// Apple tints its own sidebars the same way. A pure material over a bright
    /// photo can drop body text below a readable contrast ratio; this wash buys
    /// contrast back while keeping the blur visible.
    var tint: Double {
        switch self {
        case .sidebar: return 0.28
        case .bar: return 0.34
        case .sheet: return 0.30
        case .hud: return 0.38
        }
    }
}

#if os(macOS)
/// Bridges `NSVisualEffectView` into SwiftUI.
private struct VisualEffectBackground: NSViewRepresentable {
    let layer: GlassLayer

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = layer.material
        // `.behindWindow` rather than `.withinWindow`: within-window blending only
        // samples sibling views, which is exactly the effect `Material` already
        // gives and the reason the chrome looked flat before.
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.isEmphasized = false
        view.autoresizingMask = [.width, .height]
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        if view.material != layer.material {
            view.material = layer.material
        }
    }
}
#endif

/// The material, its contrast wash, and the specular rim that reads as glass.
struct GlassBackground: View {
    let layer: GlassLayer
    var showsRim = true

    @Environment(\.colorScheme) private var scheme
    /// Replaces the wash when the active theme names this surface's colour.
    var paletteTint: Color?

    var body: some View {
        ZStack {
            materialBase
            // A palette colour, when the theme names this surface's colour, *replaces*
            // the contrast wash entirely rather than being stacked over it.
            //
            // Stacking it above `wash` did not work and looked like it did: `wash` is a
            // translucent `windowBackgroundColor` over an `NSVisualEffectView` with
            // `.behindWindow` blending, so a second translucent layer on top just mixed
            // with it and the measured pixels did not change between two themes with
            // opposite panel colours (7981 both times). Upstream paints `panel_bg` flat
            // there instead of over a material (`src/client/shell.rs` reads every colour
            // from `config.palette`), so flat is also the faithful answer.
            if let paletteTint {
                Rectangle().fill(paletteTint)
            } else {
                wash
            }
            if showsRim { rim }
        }
    }

    @ViewBuilder
    private var materialBase: some View {
        #if os(macOS)
        VisualEffectBackground(layer: layer)
        #else
        // iOS has no NSVisualEffectView; SwiftUI's material is the system one there.
        Rectangle().fill(.ultraThinMaterial)
        #endif
    }

    private var wash: some View {
        Rectangle()
            .fill(backdrop.opacity(layer.tint))
    }

    private var backdrop: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(.systemBackground)
        #endif
    }

    /// A hairline that is brighter along the top edge, the way a real glass pane
    /// catches light. Kept to one pixel: this is a hint of an edge, not a border.
    private var rim: some View {
        Rectangle()
            .strokeBorder(
                LinearGradient(
                    colors: scheme == .dark
                        ? [.white.opacity(0.14), .white.opacity(0.03), .black.opacity(0.28)]
                        : [.white.opacity(0.55), .black.opacity(0.05), .black.opacity(0.14)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
    }
}

public extension View {
    /// Draws this view on a real system material.
    ///
    /// Use for chrome only — sidebars, bars, sheets, overlays. Never for the
    /// terminal surface, which must stay opaque to keep glyph contrast.
    /// The glass chrome, optionally tinted by the active palette.
    ///
    /// `tint` is what makes a theme visible on the chrome. A `.background` applied on
    /// top of `glassChrome` from the outside did not work: the glass already draws an
    /// opaque `windowBackgroundColor` wash, so the extra layer sat behind something the
    /// screenshot showed as unchanged. Tinting the wash itself is the layer that is
    /// actually on screen.
    func glassChrome(
        _ layer: GlassLayer,
        rim: Bool = true,
        tint: Color? = nil
    ) -> some View {
        background { GlassBackground(layer: layer, showsRim: rim, paletteTint: tint) }
    }

    /// A rounded glass panel, for overlays that should read as a floating pane of
    /// glass rather than a full-bleed sheet.
    func glassPanel(_ layer: GlassLayer, radius: CGFloat, rim: Bool = true) -> some View {
        background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(.clear)
                .background {
                    GlassBackground(layer: layer, showsRim: false)
                        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                }
                .overlay {
                    if rim {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                    }
                }
        }
    }
}
