// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Tests for popup geometry.
//
// The numbers here are upstream's (`popup_size.rs:50-100`). They matter because
// every one of them produces a box that is *almost* right: a popup whose interior
// is one column too wide has its rows reflowed by Ghostty, and a box smaller than
// its border has no interior at all. Both look like rendering bugs elsewhere.
//

import Foundation
import KraalProtocol
import Testing

@testable import KraalUI

@Suite("Popup geometry")
struct PopupGeometryTests {
    private let area = SurfaceRect(originX: 0, originY: 0, width: 100, height: 40)

    // MARK: - Defaults

    /// With no request, the popup takes half the area in each direction.
    @Test("the default box is half the area")
    func defaultIsHalf() throws {
        let geometry = try #require(
            PopupGeometryResolver.resolve(width: nil, height: nil, area: area)
        )
        #expect(geometry.outer.width == 50)
        #expect(geometry.outer.height == 20)
    }

    /// ...and is centred, so it does not sit in a corner.
    @Test("the box is centred")
    func centred() throws {
        let geometry = try #require(
            PopupGeometryResolver.resolve(width: nil, height: nil, area: area)
        )
        #expect(geometry.outer.originX == 25, "(100 - 50) / 2")
        #expect(geometry.outer.originY == 10, "(40 - 20) / 2")
    }

    /// A centre offset follows the area's own origin: a popup belongs to the
    /// surface, not to the window, and the surface may start below a tab bar.
    @Test("the box is offset by the area's origin")
    func respectsAreaOrigin() throws {
        let offsetArea = SurfaceRect(originX: 10, originY: 5, width: 100, height: 40)
        let geometry = try #require(
            PopupGeometryResolver.resolve(width: nil, height: nil, area: offsetArea)
        )
        #expect(geometry.outer.originX == 35, "10 + 25")
        #expect(geometry.outer.originY == 15, "5 + 10")
    }

    // MARK: - Sizes

    /// A cell count is taken literally.
    @Test("a cell size is used as given")
    func cellsAreLiteral() throws {
        let geometry = try #require(PopupGeometryResolver.resolve(
            width: .cells(30),
            height: .cells(12),
            area: area
        ))
        #expect(geometry.outer.width == 30)
        #expect(geometry.outer.height == 12)
    }

    /// A percentage is of the available space, not of the popup.
    @Test("a percentage is of the available area")
    func percentOfArea() throws {
        let geometry = try #require(PopupGeometryResolver.resolve(
            width: .percent(80),
            height: .percent(50),
            area: area
        ))
        #expect(geometry.outer.width == 80, "80% of 100")
        #expect(geometry.outer.height == 20, "50% of 40")
    }

    /// A percentage of a wide surface must not overflow. `available * 100` exceeds
    /// `UInt16` past 655 cells, which a very wide monitor reaches.
    @Test("a wide area does not overflow the percentage")
    func percentDoesNotOverflow() {
        #expect(PopupGeometryResolver.resolve(.percent(100), available: 5000) == 5000)
        #expect(PopupGeometryResolver.resolve(.percent(50), available: 5000) == 2500)
        // UInt16.max is the widest a rect can be; 100% of it must survive.
        #expect(PopupGeometryResolver.resolve(.percent(100), available: .max) == .max)
    }

    /// A percentage above 100 is not an error: it is clamped like any other
    /// oversized request, so a daemon asking for 150% gets a full-size popup rather
    /// than nothing. Refusing it would turn a harmless over-request into "the popup
    /// never appeared", which is indistinguishable from the feature being broken.
    @Test("a percentage above 100 is clamped, not refused")
    func oversizedPercentIsClamped() throws {
        let geometry = try #require(PopupGeometryResolver.resolve(
            width: .percent(150),
            height: .percent(150),
            area: area
        ))
        #expect(geometry.outer.width == area.width)
        #expect(geometry.outer.height == area.height)
    }

    /// Larger than the area is clamped to the area rather than hanging off it.
    @Test("an oversized request is clamped to the area")
    func oversizedIsClamped() throws {
        let geometry = try #require(PopupGeometryResolver.resolve(
            width: .cells(500),
            height: .cells(500),
            area: area
        ))
        #expect(geometry.outer.width == 100)
        #expect(geometry.outer.height == 40)
        #expect(geometry.outer.originX == 0, "a full-size box has no margin")
    }

    // MARK: - Minimums

    /// A request below the minimum is raised to it: a box narrower than its border
    /// has no interior.
    @Test("a tiny request is raised to the minimum")
    func tinyRequestRaised() throws {
        let geometry = try #require(PopupGeometryResolver.resolve(
            width: .cells(1),
            height: .cells(1),
            area: area
        ))
        #expect(geometry.outer.width == PopupGeometryResolver.minimumWidth)
        #expect(geometry.outer.height == PopupGeometryResolver.minimumHeight)
    }

    /// An area that cannot hold a minimum box yields nothing at all, rather than a
    /// degenerate one. This is the case that has to be `nil`, not "0×0": drawing a
    /// 0×0 box is invisible, and invisible is indistinguishable from "popup never
    /// arrived".
    @Test("an area too small for a box yields nothing")
    func tinyAreaYieldsNothing() {
        #expect(PopupGeometryResolver.resolve(
            width: nil,
            height: nil,
            area: SurfaceRect(originX: 0, originY: 0, width: 5, height: 40)
        ) == nil)
        #expect(PopupGeometryResolver.resolve(
            width: nil,
            height: nil,
            area: SurfaceRect(originX: 0, originY: 0, width: 100, height: 3)
        ) == nil)
    }

    // MARK: - Interior

    /// The interior is inset by one cell on every side, leaving room for the border.
    @Test("the interior is inset by the border")
    func interiorIsInset() throws {
        let geometry = try #require(PopupGeometryResolver.resolve(
            width: .cells(40),
            height: .cells(20),
            area: area
        ))
        #expect(geometry.inner.originX == geometry.outer.originX + 1)
        #expect(geometry.inner.originY == geometry.outer.originY + 1)
        #expect(geometry.inner.height == 18, "20 - 2 border rows")
    }

    /// The interior loses one more column to the scrollbar gutter — but only when
    /// there is room for it.
    ///
    /// This is the one-column difference that matters most: handing Ghostty a grid
    /// one column wider than the daemon rendered makes it reflow every row, which
    /// shows up as text wrapping differently from the pane behind it.
    @Test("the interior leaves a column for the scrollbar gutter")
    func gutterColumn() throws {
        let wide = try #require(PopupGeometryResolver.resolve(
            width: .cells(40),
            height: .cells(20),
            area: area
        ))
        // 40 - 2 border = 38 interior; 38 > 4 so one column goes to the gutter.
        #expect(wide.inner.width == 37)

        // A 4-cell interior is narrow enough that the gutter is skipped: taking a
        // column would leave 3 cells of text behind a 4-cell border.
        let narrow = try #require(PopupGeometryResolver.resolve(
            width: .cells(6),
            height: .cells(20),
            area: area
        ))
        #expect(narrow.inner.width == 4, "6 - 2 border, no gutter")
    }

    /// The innermost case must not go negative. A 6-cell box is the minimum, so its
    /// interior is 4 wide; anything that produced fewer would mean an underflow.
    @Test("the minimum box still has a positive interior")
    func minimumInteriorIsPositive() throws {
        let geometry = try #require(PopupGeometryResolver.resolve(
            width: .cells(PopupGeometryResolver.minimumWidth),
            height: .cells(PopupGeometryResolver.minimumHeight),
            area: area
        ))
        #expect(geometry.inner.width > 0)
        #expect(geometry.inner.height > 0)
    }

    /// The interior must fit inside its own box. A child rect that escapes its
    /// parent is how a popup ends up drawing over the panes beside it.
    @Test("the interior stays inside the box")
    func interiorInsideOuter() throws {
        for width in [UInt16(6), 7, 20, 50, 100] {
            let geometry = try #require(PopupGeometryResolver.resolve(
                width: .cells(width),
                height: .cells(10),
                area: area
            ), "width \(width)")
            #expect(
                geometry.inner.originX >= geometry.outer.originX
                    && Int(geometry.inner.originX) + Int(geometry.inner.width)
                    <= Int(geometry.outer.originX) + Int(geometry.outer.width),
                "width \(width): \(geometry.inner) escapes \(geometry.outer)"
            )
        }
    }
}
