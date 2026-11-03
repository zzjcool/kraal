// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The palette is a thin view over `KraalActions`; it never owns a second list
// of commands. Recent items are added when the action runner starts recording
// them, not by copying names into this file.

import AppKit
import KraalActions
import SwiftUI

struct HcPaletteEntry: Identifiable, Equatable {
    let name: String
    let about: String
    let group: String

    var id: String { name }
}

struct HcPaletteGroup: Identifiable, Equatable {
    let title: String
    let entries: [HcPaletteEntry]
    var id: String { title }
}

enum HcPaletteSearch {
    static func groups(query: String, canPerform: (String) -> Bool) -> [HcPaletteGroup] {
        let entries = KraalActions.all
            .filter { canPerform($0.name) }
            .map { entry(for: $0) }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matched: [HcPaletteEntry]
        if needle.isEmpty {
            matched = entries
        } else {
            let words = needle.split(whereSeparator: \.isWhitespace).map(String.init)
            matched = entries
                .compactMap { entry -> (HcPaletteEntry, Int)? in
                    let name = entry.name.lowercased()
                    let about = entry.about.lowercased()
                    let haystack = name + " " + about
                    guard words.allSatisfy({ haystack.contains($0) }) else { return nil }
                    let score = words.reduce(0) { total, word in
                        if name.hasPrefix(word) { return total }
                        if name.contains(word) { return total + 1 }
                        return total + 2
                    }
                    return (entry, score)
                }
                .sorted { lhs, rhs in
                    lhs.1 == rhs.1 ? lhs.0.name < rhs.0.name : lhs.1 < rhs.1
                }
                .map(\.0)
        }
        let order = ["Spaces", "Tabs", "Panes", "Terminals", "Agents", "Application", "Window"]
        return order.compactMap { title in
            let members = matched.filter { $0.group == title }
            return members.isEmpty ? nil : HcPaletteGroup(title: title, entries: members)
        }
    }

    private static func entry(for action: KraalAction) -> HcPaletteEntry {
        let prefix = action.name.split(separator: ".").first.map(String.init) ?? "Application"
        let group: String
        switch prefix {
        case "space": group = "Spaces"
        case "tab": group = "Tabs"
        case "pane": group = "Panes"
        case "terminal": group = "Terminals"
        case "agent": group = "Agents"
        case "window": group = "Window"
        default: group = "Application"
        }
        return HcPaletteEntry(name: action.name, about: action.about, group: group)
    }
}

@MainActor
final class HcPaletteModel: ObservableObject {
    @Published var query = "" {
        didSet { refresh() }
    }
    @Published var selection = 0
    @Published private(set) var groups: [HcPaletteGroup] = []

    let workspace: HcWorkspaceModel
    private var monitor: Any?

    init(workspace: HcWorkspaceModel) {
        self.workspace = workspace
        refresh()
    }

    var entries: [HcPaletteEntry] {
        groups.flatMap(\.entries)
    }

    func attach() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.workspace.showPalette else { return event }
            return self.handle(event) ? nil : event
        }
    }

    func detach() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    func runSelected() {
        let all = entries
        guard all.indices.contains(selection) else { return }
        run(all[selection])
    }

    func run(_ entry: HcPaletteEntry) {
        workspace.showPalette = false
        Task { @MainActor in
            let outcome = await workspace.performAction(entry.name)
            if let error = outcome.error {
                workspace.showToast(title: entry.name, detail: error, level: .error)
            }
        }
    }

    private func refresh() {
        let groups = HcPaletteSearch.groups(query: query) { workspace.canPerformAction($0) }
        self.groups = groups
        selection = min(max(selection, 0), max(entries.count - 1, 0))
    }

    private func handle(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 126: // up
            selection = max(0, selection - 1)
            return true
        case 125: // down
            selection = min(max(entries.count - 1, 0), selection + 1)
            return true
        case 36, 76: // return / enter
            runSelected()
            return true
        case 53: // escape
            workspace.showPalette = false
            return true
        default:
            return false
        }
    }
}

public struct HcCommandPalette: View {
    @ObservedObject public var workspace: HcWorkspaceModel
    @StateObject private var model: HcPaletteModel
    @FocusState private var queryFocused: Bool

    public init(workspace: HcWorkspaceModel) {
        self.workspace = workspace
        _model = StateObject(wrappedValue: HcPaletteModel(workspace: workspace))
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Type a command", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($queryFocused)
                Text("\(model.entries.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                        ForEach(model.groups) { group in
                            Section {
                                ForEach(group.entries) { entry in
                                    HcPaletteRow(
                                        entry: entry,
                                        selected: entry.name == model.entries[safe: model.selection]?.name
                                    ) {
                                        model.selection = model.entries.firstIndex(of: entry) ?? 0
                                        model.run(entry)
                                    }
                                    .id(entry.name)
                                }
                            } header: {
                                Text(group.title.uppercased())
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 16)
                                    .padding(.top, 8)
                                    .padding(.bottom, 2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.regularMaterial)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .onChange(of: model.selection) { _, newValue in
                    if let entry = model.entries[safe: newValue] {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(entry.name, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(width: 560, height: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.separator, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
        .onAppear {
            model.attach()
            queryFocused = true
        }
        .task {
            // The overlay and its TextField exist before AppKit gives the window
            // a first responder. Setting the FocusState inside onAppear alone
            // loses that race: ⌘K opened the palette but the terminal kept the
            // keyboard, so typing filtered nothing (caught in the Tart VM).
            try? await Task.sleep(for: .milliseconds(50))
            queryFocused = true
        }
        .onDisappear { model.detach() }
    }
}

private struct HcPaletteRow: View {
    let entry: HcPaletteEntry
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(entry.name)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                Spacer(minLength: 12)
                Text(entry.about)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
