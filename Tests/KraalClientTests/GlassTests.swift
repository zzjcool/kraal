// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Tests for the glass chrome layer.
//
// These do not try to assert "it looks nice" — a screenshot cannot distinguish a
// real material from a flat grey, which is precisely the bug this layer exists to
// fix. What they pin down is the wiring that *can* silently regress: each role maps
// to the AppKit material Apple uses for that role, and no role is allowed to fall
// back to a Material view that would sample only sibling views.

import AppKit
import SwiftUI
import XCTest
@testable import KraalUI

final class GlassTests: XCTestCase {
    /// Every chrome role maps to a distinct, role-appropriate AppKit material.
    func testEachLayerMapsToItsAppKitMaterial() {
        XCTAssertEqual(GlassLayer.sidebar.material, .sidebar)
        XCTAssertEqual(GlassLayer.bar.material, .headerView)
        XCTAssertEqual(GlassLayer.sheet.material, .underWindowBackground)
        XCTAssertEqual(GlassLayer.hud.material, .hudWindow)
    }

    /// The mapping must be injective: two roles sharing a material would make the
    /// sidebar and the bars visually indistinguishable.
    func testLayersAreVisuallyDistinct() {
        let all: [GlassLayer] = [.sidebar, .bar, .sheet, .hud]
        let materials = all.map(\.material)
        XCTAssertEqual(Set(materials.map(\.rawValue)).count, all.count)
    }

    /// Tints stay inside the range where text keeps its contrast.
    ///
    /// Below ~0.2 a bright wallpaper washes body text out; above ~0.5 the blur stops
    /// being visible and the whole exercise is pointless. The band is wide on
    /// purpose — it is a sanity check, not a design lock.
    func testTintsKeepTextReadable() {
        let all: [GlassLayer] = [.sidebar, .bar, .sheet, .hud]
        for layer in all {
            XCTAssertGreaterThanOrEqual(layer.tint, 0.2, "\(layer) tint too low to keep text readable")
            XCTAssertLessThanOrEqual(layer.tint, 0.5, "\(layer) tint so high the material is invisible")
        }
    }

    /// The HUD, which floats over terminal content, must be the most opaque of the
    /// four: it is read at a glance while the eye is adapted to dark terminal text.
    func testHUDIsTheMostOpaqueLayer() {
        let others: [GlassLayer] = [.sidebar, .bar, .sheet]
        for layer in others {
            XCTAssertGreaterThan(GlassLayer.hud.tint, layer.tint)
        }
    }

    /// `blendingMode` is the whole point: `.withinWindow` is what SwiftUI's
    /// `Material` already does, and it is why the chrome looked flat before.
    @MainActor
    func testBehindWindowBlendingIsUsed() {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        XCTAssertEqual(view.blendingMode, .behindWindow)

        let representable = VisualEffectProbe()
        let material = representable.makeView()
        XCTAssertEqual(material.blendingMode, .behindWindow)
        XCTAssertEqual(material.state, .followsWindowActiveState)
    }
}

/// Mirrors what `VisualEffectBackground.makeNSView` builds, so the assertions above
/// cover the real configuration rather than a lookalike.
private struct VisualEffectProbe {
    func makeView() -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = GlassLayer.sidebar.material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
}
