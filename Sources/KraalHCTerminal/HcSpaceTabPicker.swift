// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// ⌘P: go to a space or a tab. Places, not commands — that is the palette (⇧⌘P).
//
// The rows are the official `app/defaults/mods/picker/main.js` list minus what
// Kraal has no data for (agent grouping, "new space on <machine>"): space
// headers in model order, their tabs, then the two ways to make more. Sizes,
// radii, colors and keys are upstream's (head 29, tab 32, new 36/32, ⇧/Esc/⏎).

import AppKit
import KraalHC
import KraalModel
import SwiftUI

// MARK: - Rows

/// One line of the picker. A header is a place you can click but not land on
/// with ↑/↓, which is why `isActionable` exists.
enum HcPickerRow: Identifiable, Equatable {
    case space(KraalSpace, current: Bool)
    case tab(KraalTab, current: Bool)
    case newTab
    case newSpace

    var id: String {
        switch self {
        case let .space(space, _): "space-\(space.id)"
        case let .tab(tab, _): "tab-\(tab.id)"
        case .newTab: "new-tab"
        case .newSpace: "new-space"
        }
    }

    /// Tabs and the two `new` rows: what ↑/↓ may select and ⏎ may run.
    var isActionable: Bool {
        if case .space = self { return false }
        return true
    }
}

enum HcPickerRows {
    /// Headers, their tabs, then `new tab` / `new space`. A query matches a
    /// space name (all of its tabs stay) or a tab name (its header stays), so
    /// the list never loses the context of what is left.
    static func rows(for workspace: KraalModel, query: String) -> [HcPickerRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let activeSpace = workspace.activeSpace?.id
        var rows: [HcPickerRow] = []
        for space in workspace.spaces {
            let spaceMatches = needle.isEmpty || space.displayName.lowercased().contains(needle)
            let tabs = spaceMatches
                ? space.tabs
                : space.tabs.filter { $0.displayName.lowercased().contains(needle) }
            guard spaceMatches || !tabs.isEmpty else { continue }
            rows.append(.space(space, current: space.id == activeSpace))
            for tab in tabs {
                let current = space.id == activeSpace && tab.id == space.active?.id
                rows.append(.tab(tab, current: current))
            }
        }
        rows.append(.newTab)
        rows.append(.newSpace)
        return rows
    }
}

// MARK: - State

@MainActor
final class HcPickerModel: ObservableObject {
    @Published var query = "" {
        // A new filter is a new list: the official picker restarts at the top.
        didSet { selection = 0 }
    }

    @Published var selection = 0

    private let workspace: HcWorkspaceModel
    private var monitor: Any?

    init(workspace: HcWorkspaceModel) {
        self.workspace = workspace
    }

    /// Every row the picker draws, headers included, in display order.
    var rows: [HcPickerRow] {
        HcPickerRows.rows(for: workspace.workspace, query: query)
    }

    var actionable: [HcPickerRow] { rows.filter(\.isActionable) }

    var selectedRow: HcPickerRow? {
        actionable.indices.contains(selection) ? actionable[selection] : nil
    }

    /// The search row owns the keyboard while the picker is up, so the arrows
    /// have to be caught before AppKit hands them to the text field.
    func attach() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.workspace.pickerVisible else { return event }
            return self.handle(event) ? nil : event
        }
    }

    func detach() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Opens on where the window already is: the focused tab's row.
    func selectCurrentPlace() {
        let focused = workspace.workspace.activeSpace?.active?.id
        selection = actionable.firstIndex { row in
            if case let .tab(tab, _) = row { return tab.id == focused }
            return false
        } ?? 0
    }

    /// Wraps, like the official picker: from the first place, ↑ is the last.
    func move(by delta: Int) {
        let count = actionable.count
        guard count > 0 else {
            selection = 0
            return
        }
        let base = min(max(selection, 0), count - 1)
        selection = ((base + delta) % count + count) % count
    }

    func runSelected() {
        guard let row = selectedRow else { return }
        run(row)
    }

    /// Closes first, then acts: an action may open a sheet or replace the layout,
    /// and a picker left on top would have to be dismissed twice.
    func run(_ row: HcPickerRow) {
        workspace.pickerVisible = false
        switch row {
        case let .space(space, _):
            perform("space.select", ["id": .string(space.id)])
        case let .tab(tab, _):
            perform("tab.select", ["id": .string(tab.id)])
        case .newTab:
            perform("tab.new", nil)
        case .newSpace:
            perform("space.new", nil)
        }
    }

    /// What a native row shows on the right: its panes' programs, else how many
    /// panes it holds (Kraal has no agent list in this overlay).
    func detail(for tab: KraalTab) -> String {
        let programs = tab.terminals
            .compactMap { address in workspace.terminals.first { $0.address == address }?.agent }
            .filter { !$0.isEmpty }
        if !programs.isEmpty { return programs.joined(separator: " · ") }
        switch tab.terminals.count {
        case 0: return ""
        case 1: return "1 pane"
        case let count: return "\(count) panes"
        }
    }

    private func perform(_ name: String, _ values: [String: JSONValue]?) {
        let arguments = values.map(JSONValue.object)
        Task { @MainActor in
            let outcome = await workspace.performAction(name, arguments: arguments)
            if let error = outcome.error {
                workspace.showToast(title: name, detail: error, level: .error)
            }
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 126: // up
            move(by: -1)
            return true
        case 125: // down
            move(by: 1)
            return true
        case 36, 76: // return / enter
            runSelected()
            return true
        case 53: // escape
            workspace.pickerVisible = false
            return true
        default:
            return false
        }
    }
}

// MARK: - View

struct HcSpaceTabPicker: View {
    @ObservedObject var model: HcWorkspaceModel
    @StateObject private var picker: HcPickerModel
    @FocusState private var searchFocused: Bool

    init(model: HcWorkspaceModel) {
        self.model = model
        _picker = StateObject(wrappedValue: HcPickerModel(workspace: model))
    }

    /// The window's tokens. Read from the model, not `@Environment`: the
    /// presenter applies `.hcTheme` above this view, and a view cannot see an
    /// environment value it injects on its own body.
    private var theme: HcTheme { model.resolvedTheme }

    var body: some View {
        VStack(spacing: 0) {
            card
                .padding(.top, 60)
            // The presenter is a centred ZStack. The empty part carries no
            // content, so clicks fall through to the dimmed backdrop and its
            // dismiss gesture keeps working.
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Injected again for the shared pieces (`HcDialogCard`) and the rows,
        // which read `@Environment(\.hcTheme)`.
        .hcTheme(theme)
        .onAppear {
            picker.attach()
            picker.selectCurrentPlace()
        }
        .task {
            // Same race the palette documents: the field exists before AppKit
            // gives the window a first responder, so one late set wins.
            try? await Task.sleep(for: .milliseconds(50))
            searchFocused = true
        }
        .onDisappear { picker.detach() }
    }

    private var card: some View {
        HcDialogCard {
            VStack(spacing: 10) {
                searchRow
                list
            }
            .padding(18)
            .frame(width: 640, height: 420)
        }
    }

    /// Not `HcField`: that field keeps its `@FocusState` private, so no caller
    /// can put the caret in it, and the picker must open ready to type. The
    /// tokens below are `HcField`'s with the height this overlay uses.
    private var searchRow: some View {
        HStack(spacing: 8) {
            TextField(
                "",
                text: $picker.query,
                prompt: Text("Go to a space or tab…").foregroundColor(theme.dim.color)
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12.8))
            .foregroundStyle(theme.foreground.color)
            .focused($searchFocused)
            Spacer(minLength: 8)
            Text("Esc")
                .font(.system(size: 11))
                .foregroundStyle(theme.dim.color)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(theme.background.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            // Upstream keeps the accent ring on the search row, focused or not.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(theme.accent.color, lineWidth: 1)
        }
    }

    private var list: some View {
        let rows = picker.rows
        let selected = picker.selectedRow?.id
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        rowView(row, selected: row.id == selected)
                            .id(row.id)
                    }
                }
                .padding(.bottom, 4)
            }
            .onChange(of: picker.selection) { _, _ in
                guard let id = picker.selectedRow?.id else { return }
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: HcPickerRow, selected: Bool) -> some View {
        switch row {
        case let .space(space, current):
            HcPickerSpaceRow(name: space.displayName, current: current) { picker.run(row) }
        case let .tab(tab, current):
            HcPickerTabRow(
                name: tab.displayName,
                detail: picker.detail(for: tab),
                current: current,
                selected: selected
            ) { picker.run(row) }
        case .newTab:
            // 32 + 4 of air above, so the two `new` rows read as one group.
            HcPickerCommandRow(title: "New tab", selected: selected, topPadding: 4) { picker.run(row) }
        case .newSpace:
            HcPickerCommandRow(title: "New space", selected: selected, topPadding: 0) { picker.run(row) }
        }
    }
}

// MARK: - Row views

/// A space: 11pt semibold dim name, an accent dot when it is the one on screen.
private struct HcPickerSpaceRow: View {
    @Environment(\.hcTheme) private var theme
    let name: String
    let current: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(current ? theme.accent.color : Color.clear)
                    .frame(width: 5, height: 5)
                Text(name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.dim.color)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 29)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }
}

/// A tab: the place the picker exists for.
private struct HcPickerTabRow: View {
    @Environment(\.hcTheme) private var theme
    let name: String
    let detail: String
    let current: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(name)
                    .font(.system(size: 12.8))
                    .foregroundStyle(current ? theme.foreground.color : theme.muted.color)
                    .lineLimit(1)
                Spacer(minLength: 12)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.dim.color)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }

    private var fill: Color {
        selected ? theme.selected.color : .clear
    }
}

/// `+ new tab` / `+ new space`.
private struct HcPickerCommandRow: View {
    @Environment(\.hcTheme) private var theme
    let title: String
    let selected: Bool
    let topPadding: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text("+")
                    .frame(width: 12)
                Text(title)
                    .font(.system(size: 12.8))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(theme.muted.color)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .padding(.top, topPadding)
    }

    private var fill: Color {
        selected ? theme.selected.color : .clear
    }
}
