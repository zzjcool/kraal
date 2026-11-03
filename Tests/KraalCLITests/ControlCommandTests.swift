// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import KraalHC
import Testing
@testable import KraalCLI

@Suite("kraal control commands")
struct ControlCommandTests {
    @Test("commands --help is help, not a JSON list")
    func commandsHelp() {
        #expect(ControlCommand.parse(["commands", "--help"]) == .commands(showHelp: true))
        #expect(ControlCommand.parse(["commands"]) == .commands(showHelp: false))
    }

    @Test("do keeps --flag values as strings")
    func doArguments() throws {
        let command = try #require(ControlCommand.parse([
            "do", "pane.split", "--direction", "right", "--pane", "p1",
        ]))
        guard case let .doAction(name, arguments) = command else {
            Issue.record("expected doAction")
            return
        }
        #expect(name == "pane.split")
        #expect(arguments["direction"]?.stringValue == "right")
        #expect(arguments["pane"]?.stringValue == "p1")
    }

    @Test("do coerces booleans and indices but keeps ids as strings")
    func typedArguments() throws {
        let command = try #require(ControlCommand.parse([
            "do", "space.close", "--confirmed", "true", "--index", "2", "--id", "2",
        ]))
        guard case let .doAction(_, arguments) = command else {
            Issue.record("expected doAction")
            return
        }
        #expect(arguments["confirmed"]?.boolValue == true)
        #expect(arguments["index"]?.intValue == 2)
        #expect(arguments["id"]?.stringValue == "2")
    }

    @Test("do accepts one raw JSON object")
    func doJSON() throws {
        let command = try #require(ControlCommand.parse([
            "do", "tab.new", #"{"space":"sp1","name":"qa"}"#,
        ]))
        guard case let .doAction(name, arguments) = command else {
            Issue.record("expected doAction")
            return
        }
        #expect(name == "tab.new")
        #expect(arguments["space"]?.stringValue == "sp1")
        #expect(arguments["name"]?.stringValue == "qa")
    }

    @Test("shot defaults and ls/status parse")
    func simpleCommands() {
        #expect(ControlCommand.parse(["ls"]) == .list)
        #expect(ControlCommand.parse(["status"]) == .status)
        #expect(ControlCommand.parse(["shot"]) == .shot(path: "kraal-shot.png"))
        #expect(ControlCommand.parse(["shot", "/tmp/a.png"]) == .shot(path: "/tmp/a.png"))
    }
}
