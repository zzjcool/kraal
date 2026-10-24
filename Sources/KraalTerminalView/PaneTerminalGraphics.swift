// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  PaneTerminalGraphics.swift
//  Kraal
//
//  The graphics half of a pane's terminal: turning the daemon's scene into kitty
//  bytes, keeping pane/popup image-id spaces apart, and the log lines that are the
//  only evidence any of it reached the terminal.
//
//  Split out of `PaneTerminal.swift` to keep that file under the linted length.
//  It is one concern, not a grab bag: everything here is "a scene becomes bytes and
//  we can prove what came out", and none of it touches the cell/diff path.
//

import Foundation

import KraalProtocol
import KraalUI

extension PaneTerminalModel {
    /// The popup counterpart of `logGraphics`, plus the line that proves a popup's
    /// cells actually reached its terminal.
    ///
    /// The layout log next to it (`popup:`) says where the popup was placed; this one
    /// says its cells were rendered and written. A popup that is laid out and sized
    /// correctly but never painted has exactly one of the two.
    func logPopupFrame(
        frame: FrameData,
        revision: UInt64,
        painted: Data,
        scene: SurfaceGraphicsScene
    ) {
        kraalLog("popup frame: terminal=\(paneId) rev=\(revision) "
            + "cells=\(frame.width)x\(frame.height) painted=\(painted.count)")
        // Counts come from the *filtered* scene, not the whole tab's: reporting three
        // pane placements next to `encoded=0` would read as a broken encoder when it
        // is the filter doing its job.
        let scoped = scene.filtered(toPopup: paneId)
        logGraphics(encoded: frame.graphics, painted: painted,
                    assets: scoped.assets.count, placements: scoped.placements.count)
    }

    /// One line per frame that carried graphics, recording **both** the encoder's
    /// output and what the renderer actually produced.
    ///
    /// Both numbers, because they answer different questions and only the pair is
    /// evidence. `encoded` proves the client turned the daemon's scene into kitty
    /// bytes; `kitty` proves the renderer wrote sequences out. An encoder whose
    /// output the renderer drops looks identical to a working chain if only the
    /// first number is logged — `SurfaceANSIRenderer` skips graphics it believes are
    /// unchanged (`lastGraphics`), so "encoded > 0, kitty == 0" is a real state
    /// (measured while injecting that bug for the GUI gate).
    ///
    /// Narrow on purpose: a line per frame would make "an image arrived"
    /// unfalsifiable.
    func logGraphics(encoded: Data, painted: Data, assets: Int, placements: Int) {
        guard !encoded.isEmpty || !painted.isEmpty else { return }
        kraalLog("graphics: pane=\(paneId) scope=\(graphicsScope) "
            + "assets=\(assets) placements=\(placements) "
            + "encoded=\(encoded.count) painted=\(painted.count) "
            + "kitty=\(Self.kittySequenceCount(painted))")
    }

    /// How many kitty graphics sequences an output buffer contains.
    static func kittySequenceCount(_ bytes: Data) -> Int {
        let needle = Data("\u{1B}_G".utf8)
        var count = 0
        var searchStart = bytes.startIndex
        while searchStart < bytes.endIndex,
              let found = bytes.range(of: needle, in: searchStart ..< bytes.endIndex) {
            count += 1
            searchStart = found.upperBound
        }
        return count
    }

    /// Shifts a scene's placements into this pane's coordinate space, dropping the
    /// ones that fall outside it.
    ///
    /// Placements are surface-absolute (upstream `client_host_piece` adds the pane
    /// origin to get them), and this terminal is only the pane. A placement whose
    /// cells are entirely outside the pane is dropped rather than clamped: kitty
    /// would draw it over the neighbouring pane's cells, and this terminal has no
    /// way to clip it.
    func sceneInPaneSpace(
        _ scene: SurfaceGraphicsScene,
        origin: (x: Int, y: Int),
        paneSize: (width: Int, height: Int)
    ) -> SurfaceGraphicsScene {
        guard origin.x != 0 || origin.y != 0 else { return scene }
        let width = paneSize.width
        let height = paneSize.height
        var shifted = scene
        shifted.placements = scene.placements.compactMap { placement in
            // Compare in signed space: the placement's cells are unsigned on the
            // wire, so a origin shift can go negative only if the data is wrong.
            let column = Int(placement.cellX) - origin.x
            let row = Int(placement.cellY) - origin.y
            guard column >= 0, row >= 0 else { return nil }
            // A pane with no measured size yet cannot answer "is this inside", so
            // keep everything and let the next frame decide.
            if width > 0, column >= width { return nil }
            if height > 0, row >= height { return nil }
            var moved = placement
            moved.cellX = UInt16(column)
            moved.cellY = UInt16(row)
            return moved
        }
        return shifted
    }

    /// The id namespace for this pane's images.
    ///
    /// `machine + paneId`, not `paneId`: two machines both name a pane `w1:p1`, and
    /// image ids are a hash of this string. Sharing it would put both daemons'
    /// images in one namespace, where one pane's `d=I` deletes the other's picture.
    var graphicsScope: String {
        let base = machine.isEmpty ? paneId : "\(machine)/\(paneId)"
        // A popup and a pane never draw into the same terminal, but the image ids
        // they hand to Ghostty are per *terminal*, and a popup model is keyed by the
        // same string a pane can be. Tagging the kind keeps the two id spaces apart
        // even when the ids coincide, so one's `d=I` cannot delete the other's image.
        return isPopup ? "popup/\(base)" : "pane/\(base)"
    }
}
