// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import AppKit
import ApplicationServices
import Foundation

/// A selector picks exactly one accessibility element inside a running app.
///
/// The repo hand-writes **zero** `accessibilityIdentifier`s, so `id` is only a
/// hint. What actually distinguishes Kraal's controls:
///
/// - toolbar buttons carry only `AXDescription` (`Refresh`, `Split View Horizontally`)
/// - menu items carry only `AXTitle` (`Split Right`) and a shared
///   `AXIdentifier` of `runCommand:` — 5 menu items use that same value, so it
///   cannot identify anything on its own
///
/// `AXTitle` is an AppKit-only channel in this app, measured (issue #71): a bare
/// `NSButton` reports the title it was given, while twenty spellings of SwiftUI
/// `Button` all reported `title=''` and put their text in `AXDescription` —
/// including plain `Button("X"){}`, `.bordered`, `.help`, `Label` and
/// `.accessibilityLabel`. So a control whose text was added with
/// `.accessibilityLabel` is found by `--desc`, never by `--title`. The machines
/// panel relies on that: its row buttons are `desc="Rename <machine>"` so one row
/// is addressable without `--index`.
///
/// Hence `desc` and `title` are first-class and `id` is not the default path.
struct Selector {
    var id: String?
    var desc: String?
    var title: String?
    /// `AXValue` — the text SwiftUI `Text` puts its string in.
    ///
    /// Needed because this repo writes no `accessibilityIdentifier`s and SwiftUI
    /// leaves `AXTitle`/`AXDescription` empty for `Text`: every sidebar row, every
    /// machine name and every footer label is only reachable through `AXValue`.
    /// Without it, "click the machine called alpha-b" can only be expressed as
    /// "click (60,181)", which breaks the moment a workspace row is added above it.
    var value: String?
    var role: String?
    var index: Int = 0
    /// Restricts the search to the subtree under the first element matching this
    /// selector.
    ///
    /// Necessary because titles are not unique across the app: `Copy` exists in
    /// both the Edit menu and the pane context menu, and `Split Right` exists in
    /// both the View menu and the context menu. Without a scope, a press aimed at
    /// one of them can silently hit the other — and the two do different things
    /// (the menu-bar copy targets the focused pane; the context-menu copy targets
    /// the pane the menu was raised on).
    ///
    /// Boxed because a struct cannot contain itself; the scope is only ever one
    /// level deep, so a class box is enough.
    var within: ScopeBox?

    /// True when nothing narrows the search; refusing is better than pressing a
    /// random element.
    var isEmpty: Bool {
        id == nil && desc == nil && title == nil && value == nil && role == nil && within == nil
    }

    func matches(_ element: AXUIElement) -> Bool {
        if let id, element.string("AXIdentifier") != id { return false }
        if let desc, element.string(kAXDescriptionAttribute) != desc { return false }
        if let title, element.string(kAXTitleAttribute) != title { return false }
        if let value, element.string(kAXValueAttribute) != value { return false }
        if let role, element.string(kAXRoleAttribute) != role { return false }
        return true
    }

    var humanReadable: String {
        var parts: [String] = []
        if let id { parts.append("id=\(id)") }
        if let desc { parts.append("desc=\(desc)") }
        if let title { parts.append("title=\(title)") }
        if let value { parts.append("value=\(value)") }
        if let role { parts.append("role=\(role)") }
        if let within { parts.append("within[\(within.selector.humanReadable)]") }
        if index != 0 { parts.append("index=\(index)") }
        return parts.isEmpty ? "<empty selector>" : parts.joined(separator: " ")
    }
}

/// Boxes a nested `Selector` so `Selector` can stay a value type.
final class ScopeBox {
    let selector: Selector
    init(_ selector: Selector) { self.selector = selector }
}

// MARK: - AX helpers

extension AXUIElement {
    func copy(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    func string(_ attribute: String) -> String? {
        copy(attribute) as? String
    }

    var children: [AXUIElement] {
        (copy(kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    var actionNames: [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(self, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    /// `kAXPositionAttribute` + `kAXSizeAttribute` as one rect, in screen points
    /// with the origin at the top-left (the space `CGEvent` speaks).
    var frame: CGRect? {
        guard let origin = point(kAXPositionAttribute), let size = size(kAXSizeAttribute) else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    /// Reads an `AXValue` of type `.cgPoint`. The type-ID check is the real
    /// guard: `AXValue` is a CF type, so `as?` here is dead code the compiler
    /// rejects, and a plain `as!` is what swiftlint forbids.
    private func point(_ attribute: String) -> CGPoint? {
        guard let raw = copy(attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var value = CGPoint.zero
        guard AXValueGetValue(unsafeDowncast(raw, to: AXValue.self), .cgPoint, &value) else {
            return nil
        }
        return value
    }

    private func size(_ attribute: String) -> CGSize? {
        guard let raw = copy(attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var value = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(raw, to: AXValue.self), .cgSize, &value) else {
            return nil
        }
        return value
    }
    /// the context menu's `Copy`) resolves to whichever the DFS reaches first.
    func find(_ selector: Selector, maxDepth: Int = 16) -> AXUIElement? {
        let root: AXUIElement
        if let scope = selector.within {
            guard let scoped = find(scope.selector, maxDepth: maxDepth) else { return nil }
            root = scoped
        } else {
            root = self
        }
        var seen = 0
        var found: AXUIElement?
        func walk(_ node: AXUIElement, _ depth: Int) {
            guard found == nil, depth <= maxDepth else { return }
            if selector.matches(node) {
                if seen == selector.index { found = node; return }
                seen += 1
            }
            for child in node.children {
                walk(child, depth + 1)
            }
        }
        walk(root, 0)
        return found
    }

    /// Every element matching the selector, honouring `within`. `press` uses this
    /// to report an ambiguous match instead of quietly picking the first one.
    func findAll(_ selector: Selector, maxDepth: Int = 16) -> [AXUIElement] {
        let root: AXUIElement
        if let scope = selector.within {
            guard let scoped = find(scope.selector, maxDepth: maxDepth) else { return [] }
            root = scoped
        } else {
            root = self
        }
        var matches: [AXUIElement] = []
        var visited = Set<CFHashCode>()
        func walk(_ node: AXUIElement, _ depth: Int) {
            guard depth <= maxDepth else { return }
            guard visited.insert(CFHash(node)).inserted else { return }
            if selector.matches(node) { matches.append(node) }
            for child in node.children {
                walk(child, depth + 1)
            }
        }
        walk(root, 0)
        return matches
    }

}

// MARK: - App targeting

/// Everything the driver needs to know about the app under test.
struct TargetApp {
    let application: NSRunningApplication
    let element: AXUIElement

    var pid: pid_t { application.processIdentifier }
    var name: String { application.localizedName ?? "?" }

    /// Finds the *live* app under test, preferring one that actually has a window.
    ///
    /// Two filters, both learned from real failures:
    ///
    /// - `.accessory` is allowed: `KRAAL_DEV_BACKGROUND=1` sets exactly that policy
    ///   so the app stays out of the Dock. Filtering on `.regular` alone made the
    ///   driver report "no running app" for an app that was running fine.
    /// - terminated entries are rejected. `NSWorkspace.runningApplications`
    ///   sometimes still lists processes that have exited (`activationPolicy`
    ///   comes back as `.prohibited`), and picking one of those produced
    ///   "could not bring Kraal to the front" while the real instance was sitting
    ///   right there. Ranking by "has a window" makes an ambiguous host — three
    ///   Kraal processes during a debugging session — resolve to the right one.
    static func find(name: String) -> TargetApp? {
        let candidates = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated
                && ($0.activationPolicy == .regular || $0.activationPolicy == .accessory)
                && ($0.localizedName ?? "").localizedCaseInsensitiveContains(name)
        }
        guard !candidates.isEmpty else { return nil }
        let ranked = candidates
            .map { (app: $0, windows: KraalGUIDriver.windows(of: $0.processIdentifier).count) }
            .sorted { $0.windows > $1.windows }
        guard let best = ranked.first else { return nil }
        return TargetApp(
            application: best.app,
            element: AXUIElementCreateApplication(best.app.processIdentifier)
        )
    }

    func windows() -> [AXUIElement] {
        (element.copy(kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    /// Search rooted at the application element.
    func find(_ selector: Selector, maxDepth: Int = 16) -> AXUIElement? {
        element.find(selector, maxDepth: maxDepth)
    }

    func findAll(_ selector: Selector, maxDepth: Int = 16) -> [AXUIElement] {
        element.findAll(selector, maxDepth: maxDepth)
    }
    /// Depth-first search for the `n`th element matching `selector`.
    ///
    /// `selector.within` narrows the search to one subtree; it is resolved first
    /// and the outer selector is then matched only against that subtree's root and
    /// descendants. Without that, a title that appears twice (Edit's `Copy` and
}
