// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import AppKit
import ApplicationServices
import Foundation

// Client actions, borrowed from Rex's shape (`rex actions`, `rex -C CLIENT do ACTION`).
//
// The catalog is the app's own menu bar, read through the Accessibility API. That
// is not a shortcut: this driver deliberately shares no code with the app (see the
// note at the top of `main.swift`), so a command list hardcoded here would be a
// second source of truth that drifts the moment a menu item is renamed. Reading the
// menu bar means `actions` can only report what a human could press, and `do` can
// only do what a human could do — the same honesty rule the rest of the driver
// follows. It also means an action Kraal *cannot* do is discoverable by its absence
// rather than by a lie.

enum ActionFailure: Error {
    case harness(String)
    case assertion(String)

    var exit: Exit {
        switch self {
        case .harness: Exit.harness
        case .assertion: Exit.assertion
        }
    }

    var message: String {
        switch self {
        case let .harness(text), let .assertion(text): text
        }
    }
}

/// One pressable menu item: what `actions` lists and `do` acts on.
struct MenuAction {
    let menu: String
    let title: String
    let enabled: Bool

    /// `Menu > Item`. Rex prints `NAME` and a separate `ARGS` column; a menu path is
    /// the same information in one string, and it is what `do --path` takes.
    var path: String { "\(menu) > \(title)" }
}

/// `AXEnabled` is absent on items that are always enabled (Kraal's Split Right), and
/// a missing attribute must not read as "disabled".
func isEnabled(_ element: AXUIElement) -> Bool {
    (element.copy(kAXEnabledAttribute) as? Bool) ?? true
}

/// Reads one menu's items, opening it first.
///
/// Measured on Kraal 2026-10-30: an `AXMenuBarItem`'s children are empty until the
/// menu is opened, so a "just walk the tree" implementation reports an empty
/// catalog. Each menu is therefore pressed, read, and cancelled — the same path
/// `menu` already uses.
func readMenu(_ barItem: AXUIElement, timeout: Double) -> [AXUIElement] {
    AXUIElementPerformAction(barItem, kAXPressAction as CFString)
    defer { AXUIElementPerformAction(barItem, kAXCancelAction as CFString) }

    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let menu = barItem.children.first { ($0.string(kAXRoleAttribute) ?? "") == (kAXMenuRole as String) }
        let items = (menu?.children ?? []).filter { !($0.string(kAXTitleAttribute) ?? "").isEmpty }
        if !items.isEmpty { return items }
        usleep(60_000)
    }
    return []
}

func menuActions(_ app: TargetApp, timeout: Double) -> [MenuAction] {
    app.findAll(Selector(role: kAXMenuBarItemRole as String))
        .filter { !($0.string(kAXTitleAttribute) ?? "").isEmpty }
        .flatMap { barItem -> [MenuAction] in
            let menuName = barItem.string(kAXTitleAttribute) ?? "?"
            return readMenu(barItem, timeout: timeout).map {
                MenuAction(
                    menu: menuName,
                    title: $0.string(kAXTitleAttribute) ?? "",
                    enabled: isEnabled($0)
                )
            }
        }
}

func actionApp(_ args: Arguments) -> TargetApp {
    let name = args.string("app") ?? "Kraal"
    guard let app = TargetApp.find(name: name) else {
        fail(.harness, "no running app matching '\(name)'")
    }
    return app
}

/// `kraal-gui actions [--json]`
func commandActions(_ args: Arguments) -> Never {
    let app = actionApp(args)
    let catalog = menuActions(app, timeout: args.double("timeout") ?? 5)
    guard !catalog.isEmpty else {
        fail(.harness, "the menu bar of '\(app.name)' reported no items")
    }

    if args.has("json") {
        let rows = catalog.map {
            ["path": $0.path, "menu": $0.menu, "title": $0.title, "enabled": $0.enabled] as [String: Any]
        }
        let payload: [String: Any] = ["app": app.name, "count": catalog.count, "actions": rows]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { fail(.harness, "cannot serialise the action catalog") }
        print(json)
        exit(Exit.success.rawValue)
    }

    let width = catalog.map(\.title.count).max() ?? 0
    for action in catalog {
        let pad = String(repeating: " ", count: max(width - action.title.count, 0))
        print("\(action.enabled ? " " : "-") \(action.menu)\t\(action.title)\(pad)")
    }
    print("\(catalog.count) actions")
    exit(Exit.success.rawValue)
}

/// Resolves `--path "Menu > Item"` / `--item "Item"` against the live catalog.
func resolveAction(_ catalog: [MenuAction], args: Arguments) throws -> MenuAction {
    let wanted: [MenuAction]
    if let path = args.string("path") {
        let parts = path.split(separator: ">")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        wanted = catalog.filter { action in
            let full = [action.menu, action.title]
            guard parts.count == full.count else { return false }
            return zip(parts, full).allSatisfy { $0.caseInsensitiveCompare($1) == .orderedSame }
        }
    } else if let item = args.string("item") {
        wanted = catalog.filter { $0.title.caseInsensitiveCompare(item) == .orderedSame }
    } else {
        throw ActionFailure.harness("do needs --path \"Menu > Item\" or --item \"Item\"")
    }

    switch wanted.count {
    case 1:
        guard let found = wanted.first else { throw ActionFailure.harness("unreachable") }
        return found
    case 0:
        let menus = Set(catalog.map(\.menu)).sorted().joined(separator: ", ")
        throw ActionFailure.harness("no such action; menus are: \(menus)")
    default:
        let paths = wanted.map(\.path).joined(separator: ", ")
        throw ActionFailure.harness("ambiguous action, it matches: \(paths)")
    }
}

/// Opens `menu`, presses `item`, and leaves no menu tracking behind.
func pressMenuItem(_ app: TargetApp, menu: String, item: String, timeout: Double) throws {
    var barSelector = Selector(role: kAXMenuBarItemRole as String)
    barSelector.title = menu
    guard let opener = app.find(barSelector) else {
        throw ActionFailure.harness("no menu bar item '\(menu)'")
    }
    guard opener.actionNames.contains(kAXPressAction) else {
        throw ActionFailure.harness("menu bar item '\(menu)' cannot be pressed")
    }
    let openError = AXUIElementPerformAction(opener, kAXPressAction as CFString)
    if openError != .success {
        throw ActionFailure.harness("opening menu '\(menu)' failed with AXError \(openError.rawValue)")
    }

    // The menu's contents appear asynchronously once tracking starts.
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let menuElement = opener.children.first { ($0.string(kAXRoleAttribute) ?? "") == (kAXMenuRole as String) }
        if let target = menuElement?.children.first(where: {
            ($0.string(kAXTitleAttribute) ?? "").caseInsensitiveCompare(item) == .orderedSame
        }) {
            guard isEnabled(target) else {
                AXUIElementPerformAction(opener, kAXCancelAction as CFString)
                throw ActionFailure.assertion("'\(menu) > \(item)' is disabled")
            }
            let error = AXUIElementPerformAction(target, kAXPressAction as CFString)
            if error != .success {
                throw ActionFailure.harness("pressing '\(menu) > \(item)' failed with AXError \(error.rawValue)")
            }
            return
        }
        usleep(120_000)
    }
    // Leave no menu tracking behind on failure: a stuck open menu makes the next
    // command's synthetic events go nowhere.
    AXUIElementPerformAction(opener, kAXCancelAction as CFString)
    throw ActionFailure.harness("menu '\(menu)' has no item '\(item)'")
}

/// `kraal-gui do --path "View > Split Right" | --item "Split Right" [--json]`
///
/// Actions that open a sheet (`Rename Pane…`) are pressed like any other; the prompt
/// then has to be answered with `type` + `key --name return`, because the driver
/// cannot know what to type.
func commandDo(_ args: Arguments) -> Never {
    let app = actionApp(args)
    let timeout = args.double("timeout") ?? 5
    let catalog = menuActions(app, timeout: timeout)

    do {
        let action = try resolveAction(catalog, args: args)
        try pressMenuItem(app, menu: action.menu, item: action.title, timeout: timeout)
        requireAlive(app, context: "pressing '\(action.path)'")

        if args.has("json") {
            let payload: [String: Any] = ["path": action.path, "pressed": true, "menu": action.menu]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8)
            else { fail(.harness, "cannot serialise the result") }
            print(json)
        } else {
            print("pressed \"\(action.path)\"")
        }
        exit(Exit.success.rawValue)
    } catch let failure as ActionFailure {
        fail(failure.exit, failure.message)
    } catch {
        fail(.harness, "unexpected error: \(error)")
    }
}
