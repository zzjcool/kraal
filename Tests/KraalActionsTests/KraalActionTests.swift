// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import KraalActions
import KraalHC
import Testing

@Suite("Action catalog")
struct KraalActionTests {
    private let upstreamNames = [
        "space.new", "space.close", "space.rename", "space.move",
        "tab.new", "tab.close", "tab.rename", "tab.move",
        "pane.split", "pane.close",
        "terminal.open", "terminal.keep", "terminal.park", "terminal.right_click",
        "terminal.pin", "terminal.kill",
        "space.select", "space.next", "space.prev", "tab.select", "tab.settle",
        "tab.unsettle", "tab.next", "tab.prev", "pane.zoom", "pane.focus",
        "pane.go", "pane.swap", "terminal.peek", "terminal.show", "terminal.copy",
        "terminal.paste", "terminal.paste_image", "agent.focus", "agent.next", "agent.prev",
        "layout.switch", "layout.clone", "mod.clone", "layout.set", "layout.toggle",
        "layout.show", "layout.hide", "layout.resize", "layout.select", "layout.reset",
        "mod.open", "overlay.close",
        "app.help", "app.welcome", "app.whats_new", "app.feedback", "app.palette",
        "app.settings", "app.check_updates", "app.update_core", "app.reset", "app.theme",
        "app.zoom_in", "app.zoom_out", "app.zoom_reset", "app.update", "app.quit",
        "app.hide", "app.hide_others", "app.show_all",
        "window.close", "window.minimize", "window.maximize",
    ]

    private func error(_ body: () throws -> Void) -> String {
        do {
            try body()
            return "<no error>"
        } catch let error as KraalActionError {
            return error.description
        } catch {
            return String(describing: error)
        }
    }

    @Test("all 69 upstream actions are present exactly once, in source order")
    func coverage() {
        #expect(KraalActions.all.count == 69)
        #expect(KraalActions.all.map(\.name) == upstreamNames)
        #expect(Set(KraalActions.all.map(\.name)).count == 69)
        #expect(KraalActions.listing.count == 69)
        #expect(KraalActions.unsupported.count == 19)
    }

    @Test("argument names and required flags match herdr-app")
    func arguments() {
        let expected: [String: [String]] = [
            "space.new": ["name", "folder", "tab", "argv", "task", "machine"],
            "space.move": ["id", "index"],
            "tab.new": ["name", "space", "folder", "argv", "task", "mod", "props"],
            "pane.split": ["direction", "pane", "argv", "mod", "props"],
            "terminal.pin": ["terminal", "pinned"],
            "layout.resize": ["id", "px", "weight"],
            "app.settings": ["section"],
        ]
        for (name, args) in expected {
            #expect(KraalActions.find(name)?.args.map(\.name) == args)
        }
        #expect(KraalActions.find("space.move")?.requiredArguments == ["id", "index"])
        #expect(KraalActions.find("pane.split")?.requiredArguments == ["direction"])
        #expect(KraalActions.find("terminal.pin")?.requiredArguments == ["terminal", "pinned"])
        #expect(KraalActions.find("space.next")?.validArguments == "none")
    }

    @Test("unsupported actions carry a reason but keep their upstream name")
    func unsupported() {
        for action in KraalActions.unsupported {
            guard case let .unsupported(reason) = action.support else {
                Issue.record("\(action.name) is not marked unsupported")
                continue
            }
            #expect(!reason.isEmpty)
        }
        #expect(KraalActions.listing.contains { $0.name == "layout.set" })
        #expect(KraalActions.listing.contains { $0.name == "mod.open" })
        #expect(KraalActions.listing.contains { $0.name == "terminal.copy" })
        #expect(KraalActions.listing.contains { $0.name == "pane.split" })
    }

    @Test("commands JSON is the upstream array shape, with no support field")
    func listingJSON() throws {
        let data = try #require(KraalActions.listingJSON().data(using: .utf8))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(root.count == KraalActions.listing.count)
        let first = try #require(root.first { $0["name"] as? String == "pane.split" })
        #expect(Set(first.keys) == ["name", "args", "about"])
        let args = try #require(first["args"] as? [[String: Any]])
        #expect(args.allSatisfy { Set($0.keys) == ["name", "required"] })
        #expect(root.allSatisfy { Set($0.keys) == ["name", "args", "about"] })
        let text = try KraalActions.listingJSON()
        #expect(!text.contains("support"))
    }

    @Test("unknown arguments error lists the valid names")
    func unknownArgument() {
        let message = error {
            _ = try KraalActions.validate(name: "space.next", arguments: .object(["wat": .bool(true)]))
        }
        #expect(message == "space.next: unknown argument(s): wat; valid arguments: none")

        let two = error {
            _ = try KraalActions.validate(
                name: "pane.split",
                arguments: .object(["z": .bool(true), "a": .bool(false)])
            )
        }
        #expect(two == "pane.split: unknown argument(s): a, z; valid arguments: direction, pane, argv, mod, props")
    }

    @Test("target types must be strings or null")
    func targetTypes() {
        let message = error {
            _ = try KraalActions.validate(name: "pane.close", arguments: .object(["pane": .int(3)]))
        }
        #expect(message == "pane.close: argument pane must be a string (or null to omit it)")

        let nullRequired = error {
            _ = try KraalActions.validate(name: "terminal.kill", arguments: .object(["terminal": .null]))
        }
        #expect(nullRequired == "terminal.kill needs terminal")

        #expect((try? KraalActions.validate(name: "pane.close", arguments: .object(["pane": .null]))) != nil)
    }

    @Test("missing and malformed move arguments use upstream's combined message")
    func missing() {
        let one = error {
            _ = try KraalActions.validate(name: "space.move", arguments: .object(["id": .string("sp1")]))
        }
        #expect(one == "space.move needs id and index")

        let wrongType = error {
            _ = try KraalActions.validate(
                name: "tab.move",
                arguments: .object(["id": .string("tb1"), "index": .string("2")])
            )
        }
        #expect(wrongType == "tab.move needs id and index")

        let directed = error {
            _ = try KraalActions.validate(name: "pane.split", arguments: .object([:]))
        }
        #expect(directed == "pane.split needs direction")
    }

    @Test("enumerated and boolean arguments use upstream errors")
    func values() {
        #expect(error {
            _ = try KraalActions.validate(
                name: "pane.split",
                arguments: .object(["direction": .string("up")])
            )
        } == "pane.split direction is \"right\" or \"down\", not \"up\"")

        #expect(error {
            _ = try KraalActions.validate(
                name: "pane.go",
                arguments: .object(["direction": .string("sideways")])
            )
        } == "pane.go direction is left, right, up or down, not \"sideways\"")

        #expect(error {
            _ = try KraalActions.validate(
                name: "terminal.right_click",
                arguments: .object(["to": .string("both")])
            )
        } == "terminal.right_click to is \"program\" or \"menu\", not \"both\"")

        #expect(error {
            _ = try KraalActions.validate(
                name: "terminal.pin",
                arguments: .object(["terminal": .string("t1"), "pinned": .string("yes")])
            )
        } == "terminal.pin pinned is true or false")

        #expect(error {
            _ = try KraalActions.validate(
                name: "app.feedback",
                arguments: .object(["from": .string("robot")])
            )
        } == "from must be person or agent")
    }

    @Test("valid calls return their object and null arguments are empty")
    func valid() throws {
        #expect(try KraalActions.validate(name: "space.next", arguments: nil).isEmpty)
        #expect(try KraalActions.validate(name: "space.next", arguments: .null).isEmpty)

        let values = try KraalActions.validate(
            name: "pane.split",
            arguments: .object(["direction": .string("right"), "pane": .string("p1")])
        )
        #expect(values["direction"] == .string("right"))
        #expect(values["pane"] == .string("p1"))

        _ = try KraalActions.validate(
            name: "terminal.pin",
            arguments: .object(["terminal": .string("t1"), "pinned": .bool(true)])
        )
    }

    @Test("unknown action and non-object arguments are rejected")
    func shape() {
        #expect(error {
            _ = try KraalActions.validate(name: "nope", arguments: .object([:]))
        } == "unknown command \"nope\": see `kraal commands`")

        #expect(error {
            _ = try KraalActions.validate(name: "space.next", arguments: .array([]))
        } == "space.next: arguments must be an object; valid arguments: none")
    }

    @Test("listing round-trips through Codable")
    func codable() throws {
        let data = try JSONEncoder().encode(KraalActions.listing)
        let decoded = try JSONDecoder().decode([KraalActionListing].self, from: data)
        #expect(decoded == KraalActions.listing)
    }
}
