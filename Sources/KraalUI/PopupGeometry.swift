// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  PopupGeometry.swift
//  Kraal
//
//  Where a popup goes and how big it is.
//
//  ## The daemon decides the popup; this decides its box
//
//  A popup is not a floating decoration. The daemon spawns a whole separate
//  terminal for it — `app/popup.rs` calls `TerminalRuntime::spawn_shell_command` —
//  and pushes its finished cell grid in `PaneSurfaceFrame.popup`, complete with its
//  own `FrameData`, title and mouse-reporting flags. The client's job is to draw
//  that grid somewhere sensible and route keys to it.
//
//  The box comes from the daemon too, but only as a *request*: `width` and `height`
//  are either a cell count or a percentage of the available area, and either can be
//  absent. Resolving them is arithmetic, so it lives here as a pure function with
//  tests rather than inside a view.
//
//  The arithmetic is a direct port of upstream's `resolve_popup_geometry`
//  (`popup_size.rs:50-100`), including the clamps. They are not decorative: a popup
//  narrower than its border (6 cells) has no interior at all, and the reservation of
//  one column for the scrollbar gutter is what keeps the daemon's rendered rows from
//  being reflowed by Ghostty.
//

import Foundation
import KraalProtocol

/// A popup's requested size, as it arrives on the wire.
///
/// `ClientShellPopupSize` is already this shape; the alias exists so the geometry
/// code can talk about "a size" without repeating the protocol's type name, and so
/// a future second source of sizes (a settings window, say) has somewhere to land.
public typealias PopupSize = ClientShellPopupSize

/// A resolved popup box, in surface cells.
public struct PopupGeometry: Equatable, Sendable {
    /// The whole popup, border included. This is what gets a background and a
    /// border drawn on it.
    public var outer: SurfaceRect
    /// The terminal grid inside the border. This is what `popup.frame` is drawn
    /// into, and it is one column narrower than the border's interior whenever
    /// there is room — the difference is the daemon's scrollbar gutter.
    public var inner: SurfaceRect

    public init(outer: SurfaceRect, inner: SurfaceRect) {
        self.outer = outer
        self.inner = inner
    }
}

public extension AppStore {
    /// The popup the daemon is currently showing, if any.
    ///
    /// A popup is not a client feature with server state: the daemon pushes the
    /// whole thing — its title, its requested size, and its finished cell grid — as
    /// part of every surface frame. So "is a popup open" is answered by the last
    /// frame, and nothing here needs to be remembered.
    var activePopup: ClientShellPopupSurface? {
        surface?.popup
    }

    /// Where the popup's box goes on this surface, or `nil` when there is no popup
    /// or no room for one.
    var popupGeometry: PopupGeometry? {
        guard let popup = activePopup, let frame = surface?.frame else { return nil }
        return PopupGeometryResolver.resolve(
            width: popup.width,
            height: popup.height,
            area: SurfaceRect(
                originX: 0,
                originY: 0,
                width: frame.width,
                height: frame.height
            )
        )
    }

    /// Whether the daemon renders a popup right now.
    var hasPopup: Bool { activePopup != nil }
}

public enum PopupGeometryResolver {
    /// Smallest box that can hold a border and something inside it.
    ///
    /// Upstream's numbers: a 6-cell-wide box is a 4-cell interior, and 4 rows is one
    /// row of text plus a border top and bottom. Anything smaller is refused rather
    /// than drawn degenerate.
    public static let minimumWidth: UInt16 = 6
    public static let minimumHeight: UInt16 = 4

    /// Resolves a popup box inside `area`, or `nil` when the area cannot hold one.
    ///
    /// - Parameters:
    ///   - width: the requested width, or `nil` for half the area.
    ///   - height: the requested height, or `nil` for half the area.
    ///   - area: the space available, in cells — normally the whole surface.
    public static func resolve(
        width: PopupSize?,
        height: PopupSize?,
        area: SurfaceRect
    ) -> PopupGeometry? {
        // Half the area is the default, with the minimums as a floor: a popup that
        // takes half of a 20-row terminal is 10 rows, which is fine; half of a
        // 6-row one is 3, which is not a box.
        let defaultWidth = max(area.width / 2, minimumWidth)
        let defaultHeight = max(area.height / 2, minimumHeight)

        let outerWidth = min(
            max(width.map { resolve($0, available: area.width) } ?? defaultWidth, minimumWidth),
            area.width
        )
        let outerHeight = min(
            max(height.map { resolve($0, available: area.height) } ?? defaultHeight, minimumHeight),
            area.height
        )
        // After the `min` above, an area smaller than the minimum cannot be served.
        guard outerWidth >= minimumWidth, outerHeight >= minimumHeight else { return nil }

        // Centred. The division truncates, which biases the box one cell towards
        // the top-left on odd remainders — the same as upstream, and invisible.
        let outerX = area.originX + (area.width - outerWidth) / 2
        let outerY = area.originY + (area.height - outerHeight) / 2

        let interiorWidth = outerWidth - 2
        let interiorHeight = outerHeight - 2
        // One column goes to the scrollbar gutter when there is room for it. On a
        // 4-cell interior the gutter is skipped rather than eating half the text.
        let terminalColumns = interiorWidth <= 4 ? interiorWidth : interiorWidth - 1

        return PopupGeometry(
            outer: SurfaceRect(
                originX: outerX,
                originY: outerY,
                width: outerWidth,
                height: outerHeight
            ),
            inner: SurfaceRect(
                originX: outerX + 1,
                originY: outerY + 1,
                width: terminalColumns,
                height: interiorHeight
            )
        )
    }

    /// Resolves one dimension: cells are cells, percentages are of the available
    /// space.
    static func resolve(_ size: PopupSize, available: UInt16) -> UInt16 {
        switch size {
        case let .cells(cells):
            return cells
        case let .percent(percent):
            // 32-bit intermediate: the product reaches 65535 * 255 = 16_711_425 for
            // the extremes of both types, which overflows `UInt16` (a surface wider
            // than 655 is reachable on a very wide monitor) but fits `UInt32`
            // comfortably.
            //
            // A percentage above 100 is not rejected here: it is clamped by the
            // caller's `min(..., area)` like any other oversized request, so a
            // daemon that sends 150% gets a full-size popup rather than none.
            return UInt16((UInt32(available) * UInt32(percent)) / 100)
        }
    }
}
