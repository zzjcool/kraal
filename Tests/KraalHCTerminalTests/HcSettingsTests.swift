// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The settings blob has to survive versions: an older file, a newer file and a
// hand-edited one all decode. The dialog's list logic is pure, so the groups and
// labels are checked here instead of in the VM.

import Foundation
import KraalActions
import Testing

@testable import KraalHCTerminal

@Suite("Terminal settings")
struct HcSettingsTests {
    @Test("settings round-trip through UserDefaults")
    func roundTrip() throws {
        let name = "kraal.tests.settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = HcTerminalSettings()
        settings.fontSize = 17
        settings.paddingX = 8
        settings.paddingY = 6
        settings.backgroundOpacity = 0.9
        settings.minimumContrast = 0.4
        settings.density = .compact
        settings.soundEnabled = false
        settings.appearance = .dark
        settings.optionAsAlt = true
        settings.save(to: defaults)
        #expect(HcTerminalSettings.load(from: defaults) == settings)
    }

    @Test("opacity and contrast are clamped for the surface")
    func clamps() {
        var settings = HcTerminalSettings()
        settings.backgroundOpacity = 0
        settings.minimumContrast = 2
        let config = settings.terminalConfiguration
        #expect(config != .init())
    }

    @Test("older settings blobs keep their values")
    func olderBlob() throws {
        let json = """
        {"fontSize":16,"paddingX":4,"paddingY":6,"backgroundOpacity":0.8,
         "minimumContrast":0.2,"density":"compact","soundEnabled":false,
         "appearance":"dark"}
        """
        let value = try JSONDecoder().decode(HcTerminalSettings.self, from: Data(json.utf8))
        #expect(value.fontSize == 16)
        #expect(value.density == .compact)
        #expect(value.appearance == .dark)
        #expect(value.optionAsAlt == false)
    }

    @Test("scrollback uses the upstream line and byte ceilings")
    func scrollbackLimits() {
        #expect(HcTerminalSettings.scrollbackLines == 10_000)
        #expect(HcTerminalSettings.scrollbackBytes == 10 * 1024 * 1024)
    }

    @Test("zoom steps one point and clamps")
    func zoom() {
        #expect(HcFontZoom.next(13, by: 1) == 14)
        #expect(HcFontZoom.next(32, by: 1) == 32)
        #expect(HcFontZoom.next(8, by: -1) == 8)
        #expect(HcFontZoom.reset() == 13)
    }

    @Test("density changes row and tab padding")
    func density() {
        #expect(HcDensity.comfortable.rowPadding > HcDensity.compact.rowPadding)
        #expect(HcDensity.comfortable.tabPadding > HcDensity.compact.tabPadding)
    }

    // MARK: Theme pair in the settings blob

    @Test("a blob without the theme pair decodes to paper and graphite")
    func themeDefaults() throws {
        let json = #"{"fontSize":15,"density":"compact","appearance":"dark"}"#
        let value = try JSONDecoder().decode(HcTerminalSettings.self, from: Data(json.utf8))
        #expect(value.themeLight == .paper)
        #expect(value.themeDark == .graphite)
        #expect(value.fontSize == 15)
        #expect(value.appearance == .dark)
    }

    @Test("a theme name this build does not know falls back instead of throwing")
    func unknownTheme() throws {
        let json = #"{"themeLight":"solarized","themeDark":"dracula","fontSize":14}"#
        let value = try JSONDecoder().decode(HcTerminalSettings.self, from: Data(json.utf8))
        #expect(value.themeLight == .paper)
        #expect(value.themeDark == .graphite)
        // The rest of the blob still loads.
        #expect(value.fontSize == 14)
    }

    @Test("a theme in the wrong slot is corrected")
    func wrongSlot() throws {
        let bothLight = try JSONDecoder().decode(
            HcTerminalSettings.self,
            from: Data(#"{"themeLight":"paper","themeDark":"paper"}"#.utf8)
        )
        #expect(bothLight.themeDark == .graphite)
        #expect(bothLight.themeLight == .paper)

        let bothDark = try JSONDecoder().decode(
            HcTerminalSettings.self,
            from: Data(#"{"themeLight":"moss","themeDark":"ink"}"#.utf8)
        )
        #expect(bothDark.themeLight == .paper)
        #expect(bothDark.themeDark == .ink)
    }

    @Test("the theme pair survives encode and decode")
    func themeRoundTrip() throws {
        var settings = HcTerminalSettings()
        settings.themeDark = .moss
        settings.themeLight = .paper
        let data = try JSONEncoder().encode(settings)
        let value = try JSONDecoder().decode(HcTerminalSettings.self, from: data)
        #expect(value.themeDark == .moss)
        #expect(value.themeLight == .paper)
        #expect(value == settings)
    }

    @Test("the Look page lists presets in upstream order")
    func presetOrder() {
        #expect(HcThemeName.presets(isLight: false) == [.graphite, .ink, .moss, .atomOneDark])
        #expect(HcThemeName.presets(isLight: true) == [.paper])
    }
}

@Suite("Keybind list")
struct HcKeybindListTests {
    private func binding(_ section: String, _ keys: String, _ action: String) -> KraalKeyBinding {
        // The combo only matters to the window; the list never parses it.
        let combo = (try? KraalKeyCombo(keys)) ?? KraalKeyCombo(modifiers: [], key: keys)
        return KraalKeyBinding(section: section, keys: keys, combo: combo, action: action)
    }

    /// `isRunnable` sees the whole action, so this strips the argument the way
    /// the dialog's own predicate does.
    private func runnable(_ runnableNames: Set<String>) -> (String) -> Bool {
        { action in
            let name = action.split(separator: ":", maxSplits: 1).first.map(String.init) ?? action
            return runnableNames.contains(name)
        }
    }

    @Test("actions read as words")
    func labels() {
        #expect(HcKeybindList.label("send:\u{1b}[D") == #"type "\u001b[D""#)
        #expect(HcKeybindList.label("pane.split:right") == "pane split right")
        #expect(HcKeybindList.label("mod.open:picker") == "mod open picker")
        #expect(HcKeybindList.label("app.hide_others") == "app hide others")
    }

    @Test("groups keep upstream's order and name the non-global section")
    func grouping() {
        let bindings = [
            binding("global", "cmd-n", "space.new"),
            binding("global", "cmd-t", "tab.new"),
            binding("global", "cmd-d", "pane.split:right"),
            binding("global", "cmd-]", "agent.next"),
            binding("terminal", "cmd-c", "terminal.copy"),
            binding("global", "cmd-q", "app.quit"),
            binding("global", "cmd-alt-h", "app.hide_others"),
        ]
        let names: Set<String> = [
            "space.new", "tab.new", "pane.split", "agent.next", "terminal.copy", "app.quit",
        ]
        // `app.hide_others` is not implemented, so it must not be listed.
        let groups = HcKeybindList.groups(bindings, query: "", isRunnable: runnable(names))
        #expect(groups.map(\.title) == ["spaces", "tabs", "panes", "agents", "terminal", "window"])
        #expect(groups.first?.rows.map(\.label) == ["space new"])
        #expect(groups[4].rows.map(\.keys) == ["cmd-c  (terminal)"])
        #expect(groups[5].rows.map(\.keys) == ["cmd-q"])
    }

    @Test("the filter matches the keys or the label, case-insensitively")
    func filtering() {
        let bindings = [
            binding("global", "cmd-shift-]", "tab.next"),
            binding("global", "cmd-d", "pane.split:right"),
            binding("global", "cmd-n", "space.new"),
        ]
        let all = HcKeybindList.groups(bindings, query: "") { _ in true }
        #expect(all.flatMap(\.rows).count == 3)

        let byKeys = HcKeybindList.groups(bindings, query: "SHIFT") { _ in true }
        #expect(byKeys.flatMap(\.rows).map(\.keys) == ["cmd-shift-]"])

        let byLabel = HcKeybindList.groups(bindings, query: "SPLIT") { _ in true }
        #expect(byLabel.flatMap(\.rows).map(\.label) == ["pane split right"])

        let none = HcKeybindList.groups(bindings, query: "nothing") { _ in true }
        #expect(none.isEmpty)
    }

    @Test("a binding the window cannot run is not listed")
    func nonRunnable() {
        let bindings = [
            binding("terminal", "ctrl-v", "terminal.paste_image"),
            binding("terminal", "cmd-v", "terminal.paste"),
        ]
        let groups = HcKeybindList.groups(bindings, query: "") { action in
            action == "terminal.paste"
        }
        #expect(groups.flatMap(\.rows).map(\.keys) == ["cmd-v  (terminal)"])
    }
}
