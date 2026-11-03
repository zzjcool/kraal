// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import AppKit
import KraalActions
import Testing

@testable import KraalHCTerminal

@Suite("Key events")
struct HcKeymapControllerTests {
    private func event(
        _ characters: String,
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    @Test("shifted punctuation stays on its physical key")
    func punctuation() throws {
        let combo = try #require(HcKeymapController.combo(try event("}", keyCode: 30, flags: [.command, .shift])))
        #expect(combo.0 == [.command, .shift])
        #expect(combo.1 == "}")
        let binding = try KraalKeyCombo("cmd-shift-]")
        #expect(binding.matches(modifiers: combo.0, key: combo.1))
    }

    @Test("terminal bindings are tried before global ones")
    func precedence() throws {
        let global = KraalKeyBinding(
            section: "global", keys: "cmd-c", combo: try KraalKeyCombo("cmd-c"), action: "tab.close"
        )
        let terminal = KraalKeyBinding(
            section: "terminal", keys: "cmd-c", combo: try KraalKeyCombo("cmd-c"), action: "send:x"
        )
        #expect(HcKeymapController.candidates([global, terminal], terminal: true).map(\.section)
            == ["terminal", "global"])
        #expect(HcKeymapController.candidates([global, terminal], terminal: false).map(\.section)
            == ["global"])
    }

    @Test("special keys use names, not characters")
    func special() throws {
        #expect(HcKeymapController.combo(try event("\r", keyCode: 36))?.1 == "enter")
        #expect(HcKeymapController.combo(try event("\u{1b}", keyCode: 53))?.1 == "escape")
        #expect(HcKeymapController.combo(try event("", keyCode: 123))?.1 == "left")
        #expect(HcKeymapController.combo(try event("", keyCode: 120))?.1 == "f2")
    }
}
