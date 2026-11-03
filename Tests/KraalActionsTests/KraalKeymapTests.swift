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
