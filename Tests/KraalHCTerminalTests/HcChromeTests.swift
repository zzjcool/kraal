// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import KraalHCTerminal

// MARK: - Helpers

/// The color SwiftUI will actually draw, read back through AppKit.
private func sRGB(_ color: Color) -> NSColor? {
    NSColor(color).usingColorSpace(.sRGB)
}

private func alpha(_ color: Color) -> Double? {
    sRGB(color).map { Double($0.alphaComponent) }
}

/// `#rrggbbaa`, rounded back to bytes, so 6- and 8-digit hex entries compare equal.
private func hexString(_ color: Color) -> String {
    guard let value = sRGB(color) else { return "unresolved" }
    func byte(_ channel: CGFloat) -> Int { Int((Double(channel) * 255).rounded()) }
    return String(
        format: "#%02x%02x%02x%02x",
        byte(value.redComponent),
        byte(value.greenComponent),
        byte(value.blueComponent),
        byte(value.alphaComponent)
    )
}

// MARK: - Metrics

@Suite("Chrome metrics")
struct HcChromeMetricsTests {
    @Test("window defaults and minimum")
    func window() {
        #expect(HcChromeMetrics.windowDefaultWidth == 1280)
        #expect(HcChromeMetrics.windowDefaultHeight == 820)
        #expect(HcChromeMetrics.windowMinWidth == 720)
        #expect(HcChromeMetrics.windowMinHeight == 420)
    }

    @Test("titlebar, sidebar, panes, status bar")
    func chrome() {
        #expect(HcChromeMetrics.titlebarHeight == 40)
        #expect(HcChromeMetrics.sidebarWidth == 268)
        #expect(HcChromeMetrics.paneHeaderHeight == 34)
        #expect(HcChromeMetrics.statusBarHeight == 26)
        #expect(HcChromeMetrics.paneRadius == 10)
    }

    @Test("tabs")
    func tabs() {
        #expect(HcChromeMetrics.tabHeight == 29)
        #expect(HcChromeMetrics.tabRadius == 7)
        #expect(HcChromeMetrics.tabSpacing == 3)
        #expect(HcChromeMetrics.tabContentInset == 10)
    }

    @Test("sidebar rows, split gap and insets")
    func spacing() {
        #expect(HcChromeMetrics.sidebarHeaderHeight == 31)
        #expect(HcChromeMetrics.sidebarRowHeight == 30)
        #expect(HcChromeMetrics.sidebarRowInset == 8)
        #expect(HcChromeMetrics.sidebarFooterHeight == 112)
        #expect(HcChromeMetrics.paneGap == 8)
        #expect(HcChromeMetrics.workInset == 8)
        #expect(HcChromeMetrics.terminalInsetX == 14)
        #expect(HcChromeMetrics.terminalInsetY == 12)
        #expect(HcChromeMetrics.spaceAvatarSize == 18)
        #expect(HcChromeMetrics.spaceAvatarRadius == 5)
    }
}

// MARK: - Hex tables

@Suite("Chrome hex")
struct HcChromeHexTests {
    @Test("light table")
    func light() {
        #expect(HcChromeHex.light.chrome == "#f1f1ee")
        #expect(HcChromeHex.light.canvas == "#fafaf9")
        #expect(HcChromeHex.light.surface == "#ffffff")
        #expect(HcChromeHex.light.accent == "#1f62d0")
        #expect(HcChromeHex.light == HcChromeHex(
            chrome: "#f1f1ee",
            canvas: "#fafaf9",
            surface: "#ffffff",
            raised: "#f6f6f6",
            hover: "#0000000c",
            selected: "#00000012",
            border: "#00000017",
            foreground: "#1b1b1e",
            muted: "#69696b",
            dim: "#969698",
            accent: "#1f62d0",
            working: "#9a6700",
            blocked: "#c93c2c",
            done: "#2f6fe4",
            idle: "#a8a8aa"
        ))
    }

    @Test("dark table")
    func dark() {
        #expect(HcChromeHex.dark.chrome == "#0a0b0d")
        #expect(HcChromeHex.dark.canvas == "#0c0e10")
        #expect(HcChromeHex.dark.surface == "#0f1013")
        #expect(HcChromeHex.dark.accent == "#96b2d7")
        #expect(HcChromeHex.dark == HcChromeHex(
            chrome: "#0a0b0d",
            canvas: "#0c0e10",
            surface: "#0f1013",
            raised: "#1d1e21",
            hover: "#ffffff0e",
            selected: "#ffffff17",
            border: "#ffffff18",
            foreground: "#eeeeef",
            muted: "#959596",
            dim: "#646466",
            accent: "#96b2d7",
            working: "#e5c07b",
            blocked: "#f0705f",
            done: "#76a8ff",
            idle: "#646466"
        ))
    }
}

// MARK: - Colors

@Suite("Chrome colors")
struct HcChromeColorsTests {
    @Test("light scheme resolves every token")
    func light() {
        let colors = HcChromeColors.forScheme(.light)
        #expect(hexString(colors.chrome) == "#f1f1eeff")
        #expect(hexString(colors.canvas) == "#fafaf9ff")
        #expect(hexString(colors.surface) == "#ffffffff")
        #expect(hexString(colors.raised) == "#f6f6f6ff")
        #expect(hexString(colors.hover) == "#0000000c")
        #expect(hexString(colors.selected) == "#00000012")
        #expect(hexString(colors.border) == "#00000017")
        #expect(hexString(colors.foreground) == "#1b1b1eff")
        #expect(hexString(colors.muted) == "#69696bff")
        #expect(hexString(colors.dim) == "#969698ff")
        #expect(hexString(colors.accent) == "#1f62d0ff")
        #expect(hexString(colors.working) == "#9a6700ff")
        #expect(hexString(colors.blocked) == "#c93c2cff")
        #expect(hexString(colors.done) == "#2f6fe4ff")
        #expect(hexString(colors.idle) == "#a8a8aaff")
    }

    @Test("dark scheme resolves every token")
    func dark() {
        let colors = HcChromeColors.forScheme(.dark)
        #expect(hexString(colors.chrome) == "#0a0b0dff")
        #expect(hexString(colors.canvas) == "#0c0e10ff")
        #expect(hexString(colors.surface) == "#0f1013ff")
        #expect(hexString(colors.raised) == "#1d1e21ff")
        #expect(hexString(colors.hover) == "#ffffff0e")
        #expect(hexString(colors.selected) == "#ffffff17")
        #expect(hexString(colors.border) == "#ffffff18")
        #expect(hexString(colors.foreground) == "#eeeeefff")
        #expect(hexString(colors.muted) == "#959596ff")
        #expect(hexString(colors.dim) == "#646466ff")
        #expect(hexString(colors.accent) == "#96b2d7ff")
        #expect(hexString(colors.working) == "#e5c07bff")
        #expect(hexString(colors.blocked) == "#f0705fff")
        #expect(hexString(colors.done) == "#76a8ffff")
        #expect(hexString(colors.idle) == "#646466ff")
    }

    @Test("an 8-digit hex carries its alpha")
    func alphaChannel() {
        let light = HcChromeColors(hex: .light)
        #expect(abs((alpha(light.border) ?? -1) - 23.0 / 255.0) < 0.005)
        let dark = HcChromeColors(hex: .dark)
        #expect(abs((alpha(dark.hover) ?? -1) - 14.0 / 255.0) < 0.005)
        #expect(alpha(dark.chrome) == 1)
    }

    @Test("a malformed hex does not trap and resolves to clear")
    func malformed() {
        let broken = HcChromeHex(
            chrome: "nope",
            canvas: "#12345",
            surface: "",
            raised: "#ffffff0e",
            hover: "#0000000c",
            selected: "#00000012",
            border: "#00000017",
            foreground: "#1b1b1e",
            muted: "#69696b",
            dim: "#969698",
            accent: "#1f62d0",
            working: "#9a6700",
            blocked: "#c93c2c",
            done: "#2f6fe4",
            idle: "#a8a8aa"
        )
        let colors = HcChromeColors(hex: broken)
        #expect(alpha(colors.chrome) ?? 0 == 0)
        #expect(alpha(colors.canvas) ?? 0 == 0)
        #expect(alpha(colors.surface) ?? 0 == 0)
        #expect(hexString(colors.raised) == "#ffffff0e")
    }
}

// MARK: - Formatting

@Suite("Chrome format")
struct HcChromeFormatTests {
    private let now: UInt64 = 1_700_000_000_000

    @Test("relative time boundaries")
    func relativeTime() {
        #expect(HcChromeFormat.relativeTime(sinceMilliseconds: 0, now: 0) == "<1m")
        #expect(HcChromeFormat.relativeTime(sinceMilliseconds: now, now: now) == "<1m")
        #expect(HcChromeFormat.relativeTime(sinceMilliseconds: now - 30_000, now: now) == "<1m")
        #expect(HcChromeFormat.relativeTime(sinceMilliseconds: now - 59_999, now: now) == "<1m")
        #expect(HcChromeFormat.relativeTime(sinceMilliseconds: now - 60_000, now: now) == "1m")
        #expect(HcChromeFormat.relativeTime(sinceMilliseconds: now - 29 * 60_000, now: now) == "29m")
        #expect(HcChromeFormat.relativeTime(sinceMilliseconds: now - 59 * 60_000, now: now) == "59m")
        #expect(HcChromeFormat.relativeTime(sinceMilliseconds: now - 60 * 60_000, now: now) == "1h")
        #expect(HcChromeFormat.relativeTime(sinceMilliseconds: now - 2 * 3_600_000, now: now) == "2h")
        #expect(HcChromeFormat.relativeTime(sinceMilliseconds: now - 23 * 3_600_000, now: now) == "23h")
        #expect(HcChromeFormat.relativeTime(sinceMilliseconds: now - 24 * 3_600_000, now: now) == "1d")
        #expect(HcChromeFormat.relativeTime(sinceMilliseconds: now - 3 * 86_400_000, now: now) == "3d")
    }

    @Test("a clock that went backwards still reads <1m")
    func relativeTimeBackwards() {
        #expect(HcChromeFormat.relativeTime(sinceMilliseconds: now, now: now - 5_000) == "<1m")
    }

    @Test("agent counts")
    func counts() {
        #expect(HcChromeFormat.agentsLabel(0) == "0 agents")
        #expect(HcChromeFormat.agentsLabel(1) == "1 agents")
        #expect(HcChromeFormat.agentsLabel(3) == "3 agents")
        #expect(HcChromeFormat.needsYouLabel(0) == "0 needs you")
        #expect(HcChromeFormat.needsYouLabel(1) == "1 needs you")
        #expect(HcChromeFormat.needsYouLabel(2) == "2 needs you")
    }

    @Test("folder abbreviation")
    func folder() {
        let home = "/Users/kraal"
        #expect(HcChromeFormat.folder("", home: home) == "")
        #expect(HcChromeFormat.folder(home, home: home) == "~")
        #expect(HcChromeFormat.folder(home + "/sub", home: home) == "~/sub")
        #expect(HcChromeFormat.folder(home + "/sub/deep", home: home) == "~/sub/deep")
        #expect(HcChromeFormat.folder("/opt", home: home) == "/opt")
        #expect(HcChromeFormat.folder("/Users/kraaler", home: home) == "/Users/kraaler")
        #expect(HcChromeFormat.folder(home + "/sub", home: home + "/") == "~/sub")
    }

    @Test("hints")
    func hints() {
        #expect(HcChromeFormat.commandsHint == "⌘P commands")
        #expect(HcChromeFormat.searchHint == "Search")
    }
}

// MARK: - Palette

@Suite("Space palette")
struct HcSpacePaletteTests {
    @Test("six official MARK colors, in order")
    func colors() {
        #expect(HcSpacePalette.hex == ["#22a99a", "#3fae6a", "#e3814f", "#5b8def", "#8b7cf6", "#d9649a"])
        #expect(Set(HcSpacePalette.hex).count == 6)
    }

    @Test("the index is a stable FNV-1a fold of the id")
    func index() {
        // Pinned so a refactor cannot silently reshuffle every space's color.
        #expect((0..<6).map { HcSpacePalette.index(for: "space-\($0)") } == [4, 5, 0, 1, 2, 3])
        #expect(HcSpacePalette.index(for: "space-0") == HcSpacePalette.index(for: "space-0"))
        #expect(HcSpacePalette.hex(for: "space-2") == "#22a99a")
        #expect(HcSpacePalette.hex(for: "") == HcSpacePalette.hex(for: ""))
    }

    @Test("ids spread across all six colors")
    func distinct() {
        let picked = (0..<6).map { HcSpacePalette.hex(for: "space-\($0)") }
        #expect(Set(picked).count == 6)
        for id in ["", "sp1", "UI Audit", "~", "space-42"] {
            #expect(HcSpacePalette.hex.contains(HcSpacePalette.hex(for: id)))
        }
    }
}

// MARK: - Agent icons

@Suite("Agent app icon")
struct HcAgentAppIconTests {
    @Test("known OSC 7501 apps")
    func known() {
        #expect(HcAgentAppIcon.symbol(for: "claude") == "cpu")
        #expect(HcAgentAppIcon.symbol(for: "codex") == "chevron.left.forwardslash.chevron.right")
        #expect(HcAgentAppIcon.symbol(for: "cursor") == "cursorarrow.rays")
        #expect(HcAgentAppIcon.symbol(for: "aider") == "wand.and.stars")
        #expect(HcAgentAppIcon.symbol(for: "gemini") == "diamond")
        #expect(HcAgentAppIcon.displayName(for: "claude") == "Claude Code")
        #expect(HcAgentAppIcon.displayName(for: "codex") == "Codex")
    }

    @Test("unknown apps get a chip, missing apps the terminal")
    func fallback() {
        #expect(HcAgentAppIcon.symbol(for: "vim") == "cpu")
        #expect(HcAgentAppIcon.symbol(for: "Claude") == "cpu")
        #expect(HcAgentAppIcon.symbol(for: nil) == "terminal")
        #expect(HcAgentAppIcon.symbol(for: "") == "terminal")
        #expect(HcAgentAppIcon.symbol(for: "   ") == "terminal")
    }
}

// MARK: - Sections

@Suite("Agent sections")
struct HcAgentSectioningTests {
    /// `HcAgent`'s memberwise init is internal; `@testable` makes it visible.
    private func agent(
        _ address: String,
        status: HcAgentStatus,
        parent: String? = nil,
        depth: Int = 0,
        pinned: Bool = false
    ) -> HcAgent {
        HcAgent(
            address: address,
            pane: "pane-\(address)",
            name: address,
            detail: "t1",
            spaceID: "sp",
            spaceName: "Space",
            tabName: "tab",
            machine: nil,
            word: "idle",
            app: "claude",
            status: status,
            turn: 1,
            seenTurn: nil,
            pinned: pinned,
            parent: parent,
            depth: depth,
            since: 0
        )
    }

    @Test("spec order is Needs you, Working, Finished, Idle")
    func specs() {
        #expect(HcAgentSectionSpec.all.map(\.id) == ["blocked", "working", "done", "idle"])
        #expect(HcAgentSectionSpec.all.map(\.title) == ["Needs you", "Working", "Finished", "Idle"])
        #expect(HcAgentSectionSpec.all.map(\.status) == [.blocked, .working, .done, .idle])
    }

    @Test("each root's descendants stay in its section")
    func grouping() {
        let sections = HcAgentSectioning.sections([
            agent("blocked-root", status: .blocked),
            agent("blocked-child", status: .idle, parent: "blocked-root", depth: 1),
            agent("working-root", status: .working),
            agent("working-child", status: .working, parent: "working-root", depth: 1),
            agent("done-root", status: .done),
            agent("idle-root", status: .idle),
        ])
        #expect(sections.map(\.id) == ["blocked", "working", "done", "idle"])
        #expect(sections.map(\.title) == ["Needs you", "Working", "Finished", "Idle"])
        #expect(sections.map { $0.agents.map(\.address) } == [
            ["blocked-root", "blocked-child"],
            ["working-root", "working-child"],
            ["done-root"],
            ["idle-root"],
        ])
        // A quieter child still belongs to the blocked root above it.
        #expect(sections[0].agents[1].status == .idle)
        #expect(sections[0].agents[1].parent == "blocked-root")
    }

    @Test("empty sections are omitted")
    func omitted() {
        let sections = HcAgentSectioning.sections([
            agent("w", status: .working),
            agent("i", status: .idle),
        ])
        #expect(sections.map(\.title) == ["Working", "Idle"])
        #expect(HcAgentSectioning.sections([]).isEmpty)
    }

    @Test("pinned roots get their own section above the status sections")
    func pinned() {
        let sections = HcAgentSectioning.sections([
            agent("pinned-root", status: .idle, pinned: true),
            agent("pinned-child", status: .blocked, parent: "pinned-root", depth: 1),
            agent("blocked-root", status: .blocked),
        ])
        #expect(sections.map(\.id) == ["pinned", "blocked"])
        #expect(sections[0].title == "Pinned")
        #expect(sections[0].agents.map(\.address) == ["pinned-root", "pinned-child"])
        #expect(sections[1].agents.map(\.address) == ["blocked-root"])
    }

    @Test("a section mirrors its spec")
    func mirrors() {
        let sections = HcAgentSectioning.sections([agent("b", status: .blocked)])
        #expect(sections.count == 1)
        #expect(sections[0].id == "blocked")
        #expect(sections[0].title == "Needs you")
        #expect(sections[0].spec.status == .blocked)
    }
}
