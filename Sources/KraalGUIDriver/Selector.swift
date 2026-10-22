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
/// Hence `desc` and `title` are first-class and `id` is not the default path.
struct Selector {
    var id: String?
    var desc: String?
    var title: String?
    var role: String?
    var index: Int = 0

    /// True when nothing narrows the search; refusing is better than pressing a
    /// random element.
    var isEmpty: Bool {
        id == nil && desc == nil && title == nil && role == nil
    }

    func matches(_ element: AXUIElement) -> Bool {
        if let id, element.string("AXIdentifier") != id { return false }
        if let desc, element.string(kAXDescriptionAttribute) != desc { return false }
        if let title, element.string(kAXTitleAttribute) != title { return false }
        if let role, element.string(kAXRoleAttribute) != role { return false }
        return true
    }

    var humanReadable: String {
        var parts: [String] = []
        if let id { parts.append("id=\(id)") }
        if let desc { parts.append("desc=\(desc)") }
        if let title { parts.append("title=\(title)") }
        if let role { parts.append("role=\(role)") }
        if index != 0 { parts.append("index=\(index)") }
        return parts.isEmpty ? "<empty selector>" : parts.joined(separator: " ")
    }
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
}

// MARK: - App targeting

/// Everything the driver needs to know about the app under test.
struct TargetApp {
    let application: NSRunningApplication
    let element: AXUIElement

    var pid: pid_t { application.processIdentifier }
    var name: String { application.localizedName ?? "?" }

    static func find(name: String) -> TargetApp? {
        // `.accessory` matters: KRAAL_DEV_BACKGROUND=1 sets exactly that policy so
        // the app stays out of the Dock, and filtering on `.regular` alone made
        // the driver report "no running app" for an app that was running fine.
        // Accessibility reaches both policies equally.
        let candidates = NSWorkspace.shared.runningApplications.filter {
            ($0.activationPolicy == .regular || $0.activationPolicy == .accessory)
                && ($0.localizedName ?? "").localizedCaseInsensitiveContains(name)
        }
        guard let app = candidates.first else { return nil }
        return TargetApp(
            application: app,
            element: AXUIElementCreateApplication(app.processIdentifier)
        )
    }

    func windows() -> [AXUIElement] {
        (element.copy(kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    /// Depth-first search for the `n`th element matching `selector`.
    func find(_ selector: Selector, maxDepth: Int = 16) -> AXUIElement? {
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
        walk(element, 0)
        return found
    }
}
