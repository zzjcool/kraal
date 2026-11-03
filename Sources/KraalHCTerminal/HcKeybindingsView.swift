// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// ⌘/ — the keybinds, grouped and filterable. The list is generated from
// keys.json, so it cannot document a binding the window does not have, and it
// hides the ones this window cannot run (a `mod.` action, a catalog entry whose
// phase has not landed).
//
// Sizes, group names and ordering are `app/defaults/mods/help/main.js`: groups
// spaces / tabs / panes / agents / terminal / window, keys in a 190pt column,
// the section appended for anything that is not `global`.

import AppKit
import Foundation
import KraalActions
import SwiftUI

// MARK: - The list

/// The pure half of the dialog: an action becomes a label, bindings become the
/// upstream groups. Kept out of the view so both can be tested without a window.
enum HcKeybindList {
    struct Row: Identifiable, Equatable {
        let keys: String
        let label: String

        var id: String { keys + "\u{1F}" + label }
    }

    struct Group: Identifiable, Equatable {
        let title: String
        let rows: [Row]

        var id: String { title }
    }

    /// Upstream's buckets, in its order. Anything the first five miss lands in
    /// `window`, which is also where `app.` actions go, exactly like upstream.
    static let buckets: [(title: String, prefixes: [String])] = [
        ("spaces", ["space."]),
        ("tabs", ["tab."]),
        ("panes", ["pane."]),
        ("agents", ["agent."]),
        ("terminal", ["terminal.", "send:"]),
    ]

    /// `send:\u{1b}[D` → `type "\u001b[D"`; `pane.split:right` → `pane split
    /// right`; `mod.open:picker` → `mod open picker`.
    static func label(_ action: String) -> String {
        if action.hasPrefix(sendPrefix) {
            return "type " + quoted(String(action.dropFirst(sendPrefix.count)))
        }
        let parts = action.split(separator: ":", maxSplits: 1).map(String.init)
        let words = (parts.first ?? action)
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        guard parts.count == 2 else { return words }
        return "\(words) \(parts[1])"
    }

    /// `isRunnable` sees the whole action (`pane.split:right`, `send:abc`), so a
    /// caller can keep the two shapes that are not catalog actions.
    static func groups(
        _ bindings: [KraalKeyBinding],
        query: String,
        isRunnable: (String) -> Bool
    ) -> [Group] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var rest = bindings
            .filter { isRunnable($0.action) }
            .filter { binding in
                guard !needle.isEmpty else { return true }
                return binding.keys.lowercased().contains(needle)
                    || label(binding.action).lowercased().contains(needle)
            }
        var groups: [Group] = []
        for bucket in buckets {
            let members = rest.filter { matches($0, bucket.prefixes) }
            rest.removeAll { matches($0, bucket.prefixes) }
            if !members.isEmpty {
                groups.append(Group(title: bucket.title, rows: members.map(row)))
            }
        }
        if !rest.isEmpty {
            groups.append(Group(title: "window", rows: rest.map(row)))
        }
        return groups
    }

    private static let sendPrefix = "send:"

    private static func matches(_ binding: KraalKeyBinding, _ prefixes: [String]) -> Bool {
        prefixes.contains { binding.action.hasPrefix($0) }
    }

    /// The section is appended for anything that is not `global`, so a key that
    /// only fires in the terminal says so.
    private static func row(_ binding: KraalKeyBinding) -> Row {
        let suffix = binding.section == "global" ? "" : "  (\(binding.section))"
        return Row(keys: binding.keys + suffix, label: label(binding.action))
    }

    /// Escaped the way upstream's `JSON.stringify` prints it: a tab or an ESC
    /// becomes `\u00XX` instead of an invisible character in the list.
    private static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

// MARK: - The dialog

public struct HcKeybindingsView: View {
    @ObservedObject var workspace: HcWorkspaceModel
    let keyBindings: [KraalKeyBinding]

    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var escapeMonitor: Any?

    public init(workspace: HcWorkspaceModel, keyBindings: [KraalKeyBinding] = []) {
        self.workspace = workspace
        self.keyBindings = keyBindings
    }

    /// From the model, not `@Environment`: this view injects `.hcTheme` on its
    /// own body and cannot read a value it injects itself.
    private var theme: HcTheme { workspace.resolvedTheme }

    private var groups: [HcKeybindList.Group] {
        HcKeybindList.groups(keyBindings, query: query, isRunnable: runnable)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title
            HcKeybindSearch(text: $query, focused: $searchFocused)
                .padding(.top, 14)
            ScrollView {
                HcKeybindGroups(groups: groups)
            }
            .padding(.top, 14)
        }
        .padding(18)
        .frame(width: 640, height: 520)
        .background(theme.popover.color)
        .hcTheme(theme)
        .onAppear { attachEscape() }
        .onDisappear { detachEscape() }
        .onExitCommand { close() }
        .task {
            // The field exists before AppKit gives the window a first
            // responder, so one late set wins — the palette's 50 ms retry.
            try? await Task.sleep(for: .milliseconds(50))
            searchFocused = true
        }
    }

    private var title: some View {
        HStack(spacing: 0) {
            Text("Keybinds")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.foreground.color)
            Spacer(minLength: 0)
            Text("Esc")
                .font(.system(size: 11))
                .foregroundStyle(theme.dim.color)
        }
        .frame(height: 22)
    }

    /// What this window can actually run: the action table's implemented set,
    /// plus the two shapes that are not actions — `send:` types into the focused
    /// terminal, and ⌘P's `mod.open:picker` opens the place picker.
    private func runnable(_ action: String) -> Bool {
        if action.hasPrefix("send:") { return true }
        if action == Self.pickerAction { return true }
        let name = action.split(separator: ":", maxSplits: 1).first.map(String.init) ?? action
        return workspace.canPerformAction(name)
    }

    /// Upstream's ⌘P entry point. `HcKeymapController` routes it to
    /// `showPlacePicker()` instead of to a mod loader, so it is listed here.
    private static let pickerAction = "mod.open:picker"

    /// Esc must work while the filter field has the keyboard, and a focused
    /// field eats the key before `onExitCommand` sees it (the palette's
    /// monitor, for the same reason).
    private func attachEscape() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, workspace.showHelp else { return event }
            close()
            return nil
        }
    }

    private func detachEscape() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    private func close() {
        workspace.showHelp = false
    }
}

/// `HcField` keeps its `@FocusState` private, so no caller can put the keyboard
/// in it; this is the same field with the focus state owned here. Upstream's
/// help dialog keeps the accent border whether or not it has focus, so this one
/// does too.
private struct HcKeybindSearch: View {
    @Environment(\.hcTheme) private var theme
    @Binding var text: String
    let focused: FocusState<Bool>.Binding

    var body: some View {
        TextField("", text: $text, prompt: Text("Type to filter…").foregroundColor(theme.dim.color))
            .textFieldStyle(.plain)
            .font(.system(size: 12.8))
            .foregroundStyle(theme.foreground.color)
            .focused(focused)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(theme.background.color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(theme.accent.color, lineWidth: 1)
            }
    }
}

private struct HcKeybindGroups: View {
    @Environment(\.hcTheme) private var theme
    let groups: [HcKeybindList.Group]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.dim.color)
                    ForEach(group.rows) { row in
                        rowView(row)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rowView(_ row: HcKeybindList.Row) -> some View {
        HStack(spacing: 0) {
            Text(row.keys)
                .foregroundStyle(theme.accent.color)
                .frame(width: 190, alignment: .leading)
            Text(row.label)
                .foregroundStyle(theme.foreground.color)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .frame(height: 32)
        .contentShape(Rectangle())
    }
}
