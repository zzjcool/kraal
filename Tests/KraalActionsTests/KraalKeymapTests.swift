// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import Testing

@testable import KraalActions

@Suite("Keys")
struct KraalKeymapTests {
    @Test("shipped macOS defaults parse and keep sections apart")
    func defaults() throws {
        let bindings = try KraalKeymap.parse(KraalKeymap.defaultMacOS)
        #expect(bindings.contains { $0.section == "global" && $0.action == "tab.new" })
        #expect(bindings.contains { $0.section == "terminal" && $0.action == "send:\u{1b}b" })
        #expect(bindings.contains { $0.keys == "cmd-shift-]" && $0.action == "tab.next" })
    }

    @Test("shipped defaults are herdr-app's keys.macos.json, picker entries included")
    func upstreamDefaults() throws {
        let bindings = try KraalKeymap.parse(KraalKeymap.defaultMacOS)
        let global = bindings.filter { $0.section == "global" }
        func bound(_ keys: String) -> String? {
            global.first { $0.keys == keys }?.action
        }
        #expect(bound("cmd-p") == "mod.open:picker")
        #expect(bound("cmd-,") == "app.settings")
        #expect(bound("cmd-shift-p") == "app.palette")
        #expect(bound("cmd-b") == "layout.toggle:sidebar")
        #expect(bound("cmd-shift-l") == "layout.switch")
        // herdr-app 0.1.12 `app/defaults/keys.macos.json`: 57 global, 9 terminal.
        // The counts are the guard against silently dropping an entry.
        #expect(global.count == 57)
        #expect(bindings.filter { $0.section == "terminal" }.count == 9)
    }

    @Test("every shipped global binding is a real action or a namespaced skip")
    func shippedActions() throws {
        let global = try KraalKeymap.parse(KraalKeymap.defaultMacOS).filter { $0.section == "global" }
        #expect(!global.isEmpty)
        for binding in global {
            let name = binding.action.split(separator: ":", maxSplits: 1).first.map(String.init)
                ?? binding.action
            // `mod.`/`layout.` are herdr-app mod commands. `HcKeymapController`
            // must skip them rather than fail the keyboard, so an unknown one is
            // allowed here — an unknown name outside those namespaces is not.
            let namespaced = name.hasPrefix("mod.") || name.hasPrefix("layout.")
            #expect(
                KraalActions.find(name) != nil || namespaced,
                "\(binding.keys) -> \(binding.action) is neither a known action nor namespaced"
            )
        }
    }

    @Test("the picker entry survives the 0.1.x migration unchanged")
    func pickerEntry() {
        #expect(KraalKeymap.current("mod.open:picker") == "mod.open:picker")
    }

    @Test("the escape hatch stays reserved and unbound")
    func escapeHatch() throws {
        let bindings = try KraalKeymap.parse(KraalKeymap.defaultMacOS)
        #expect(!bindings.contains { $0.keys == KraalKeymap.escapeHatch })
        #expect(!bindings.contains { $0.action == KraalKeymap.escapeHatch })
        #expect(throws: KraalKeymapError.self) {
            try KraalKeymap.parse(#"{"global": {"cmd-x": "ctrl-alt-shift-escape"}}"#)
        }
    }

    @Test("modifiers and shifted punctuation normalize to the physical key")
    func combos() throws {
        let plus = try KraalKeyCombo("cmd-+")
        #expect(plus.key == "=")
        #expect(plus.modifiers == [.command, .shift])
        let bracket = try KraalKeyCombo("cmd-shift-]")
        #expect(bracket.key == "]")
        #expect(bracket.matches(modifiers: [.command, .shift], key: "]"))
        #expect(bracket.matches(modifiers: [.command, .shift], key: "}"))
        let minus = try KraalKeyCombo("cmd--")
        #expect(minus.key == "-")
        #expect(!minus.matches(modifiers: [.command], key: "="))
    }

    @Test("a bad section rejects the whole file")
    func sections() {
        #expect(throws: KraalKeymapError.self) {
            try KraalKeymap.parse(#"{"nope": {"cmd-x": "tab.new"}}"#)
        }
        #expect(throws: KraalKeymapError.self) {
            try KraalKeymap.parse(#"{"layout:": {"cmd-x": "tab.new"}}"#)
        }
        #expect((try? KraalKeymap.parse(#"{"layout:terminals": {"cmd-x": "tab.new"}}"#)) != nil)
    }

    @Test("unknown action and the escape hatch are rejected")
    func actions() {
        #expect(throws: KraalKeymapError.self) {
            try KraalKeymap.parse(#"{"global": {"cmd-x": "nosuch"}}"#)
        }
        #expect(throws: KraalKeymapError.self) {
            try KraalKeymap.parse(#"{"global": {"ctrl-alt-shift-escape": "tab.new"}}"#)
        }
        #expect((try? KraalKeymap.parse(#"{"global": {"cmd-x": "send:\u001b"}}"#)) != nil)
        #expect((try? KraalKeymap.parse(#"{"global": {"cmd-x": "editor.save"}}"#)) != nil)
    }

    @Test("old project/context names migrate only when the new name exists")
    func migration() {
        #expect(KraalKeymap.current("project.select:2") == "space.select:2")
        #expect(KraalKeymap.current("context.new") == "tab.new")
        #expect(KraalKeymap.current("mod.open:start") == "tab.new")
        #expect(KraalKeymap.current("pane.zoom") == "pane.zoom")
    }

    @Test("JSON errors surface as one readable error")
    func malformed() {
        #expect(throws: KraalKeymapError.self) {
            try KraalKeymap.parse(#"{"global": {"cmd-x": 3}}"#)
        }
        #expect(throws: KraalKeymapError.self) {
            try KraalKeymap.parse("[]")
        }
    }
}
