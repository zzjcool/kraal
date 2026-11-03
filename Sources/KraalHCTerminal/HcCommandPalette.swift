// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The command palette: herdr-app's `frame/palette` mod, ported. The naming table
// below (titles, groups, keywords) is presentation only — every row still runs
// through `HcWorkspaceModel.performAction`, and the filter is upstream's fuzzy
// scorer, so ⌘⇧P answers the same question the official app answers: "which
// command am I looking for, and what key is it on?"
//
// The numbers are the measured ones (`docs/audits/2026-11/official-palette.png`,
// `frame/palette/main.js`): popup 620×370, `p(18).gap(10)`, search row 36,
// `ROW_H = 32`, `HEAD_H = 26`. Colors come from `HcTheme`; nothing here hardcodes
// a hex value, and there is no result count — upstream has none either.

import AppKit
import KraalActions
import KraalHC
import SwiftUI

// MARK: - The list

/// One row: what to draw, what to run, and the key that runs it.
struct HcPaletteEntry: Identifiable, Equatable {
    /// The catalog action. The place picker rides on `mod.open` so its keycap
    /// lookup finds `mod.open:picker` in keys.json, like upstream's row does.
    let name: String
    let title: String
    /// One of `HcPaletteCatalog.groupOrder`, spelled the way upstream spells it.
    let group: String
    /// Words the filter matches and the row never draws (`clipboard`, `pref`).
    let keywords: String
    let arguments: [String: String]
    /// "Go to space or tab…" opens ⌘P's picker instead of running an action.
    let opensPlacePicker: Bool

    init(
        name: String,
        title: String,
        group: String,
        keywords: String = "",
        arguments: [String: String] = [:],
        opensPlacePicker: Bool = false
    ) {
        self.name = name
        self.title = title
        self.group = group
        self.keywords = keywords
        self.arguments = arguments
        self.opensPlacePicker = opensPlacePicker
    }

    /// `pane.split:right`: the two split rows share an action name, and the id
    /// is also what the keycap lookup and the scroll anchor key off.
    var id: String {
        guard let argument = arguments.keys.sorted().first, let value = arguments[argument] else {
            return name
        }
        return "\(name):\(value)"
    }
}

struct HcPaletteGroup: Identifiable, Equatable {
    /// Empty while the query ranks a flat list: then no head is drawn and each
    /// row carries its group name instead.
    let title: String
    let entries: [HcPaletteEntry]

    var id: String { title.isEmpty ? "ranked" : title }
}

// MARK: - The catalog

enum HcPaletteCatalog {
    /// Upstream `GROUPS`, in upstream order, minus `Recent`: Kraal records no
    /// recent commands, so the list always starts at the first group.
    static let groupOrder = ["Tab", "Pane", "Space", "Layout", "Terminal", "Agent", "Window", "App"]

    /// The rows the palette shows right now: the named table filtered down to
    /// what this window can actually run, plus a fallback row for anything
    /// runnable the table does not name yet (a new catalog action shows up
    /// immediately instead of waiting for a title).
    static func entries(canPerform: (String) -> Bool) -> [HcPaletteEntry] {
        var rows = named.filter { $0.opensPlacePicker || canPerform($0.name) }
        let captioned = Set(named.map(\.name))
        for action in KraalActions.all where !captioned.contains(action.name) {
            guard action.isNative, canPerform(action.name), !hidden.contains(action.name) else { continue }
            // A command that needs an argument cannot be run from a list; it is
            // reachable through `kraal do` and through its key binding.
            guard action.requiredArguments.isEmpty else { continue }
            rows.append(fallback(for: action))
        }
        return rows
    }

    /// Upstream `HIDDEN`: commands that act on something you have to point at
    /// (an id, a terminal) or that live in the menu bar. Only fallback rows
    /// consult this — a row the table above names is never filtered. `app.palette`
    /// is kept out of the set on purpose, so ⇧⌘P is discoverable from the palette.
    private static let hidden: Set<String> = [
        "space.move", "tab.move", "space.select", "tab.select", "pane.focus",
        "terminal.keep", "terminal.park", "terminal.kill", "terminal.show",
        "agent.focus", "tab.settle", "tab.unsettle",
        "layout.toggle", "layout.set", "layout.show", "layout.hide", "layout.resize",
        "layout.select", "mod.open", "overlay.close",
        "app.hide", "app.hide_others", "app.show_all", "app.settings", "app.theme",
    ]

    /// The ported `NAMED` table, in upstream order. Titles, groups and keywords
    /// are upstream's; `Herdr` became `Kraal`, and the upstream `layout.*` /
    /// `mod.clone` rows are dropped because Kraal has neither layouts nor mods.
    private static func buildNamed() -> [HcPaletteEntry] {
        var rows = tabRows() + paneRows() + spaceRows()
        rows += [
            row("terminal.open", "Terminal", "New terminal", "shell"),
            row("terminal.copy", "Terminal", "Copy", "clipboard"),
            row("terminal.paste", "Terminal", "Paste", "clipboard"),
            row("agent.next", "Agent", "Next agent"),
            row("agent.prev", "Agent", "Previous agent"),
            row("window.minimize", "Window", "Minimize window"),
            row("window.maximize", "Window", "Maximize window", "restore"),
            row("window.close", "Window", "Close window", "quit"),
        ]
        rows += appRows()
        // One row per preset, so a new theme is listed without touching this file.
        for theme in HcThemeName.allCases {
            rows.append(row(
                "app.theme", "App", "Theme: \(theme.displayName)", "colors look",
                ["name": theme.rawValue]
            ))
        }
        return rows
    }

    private static func tabRows() -> [HcPaletteEntry] {
        [
            row("tab.new", "Tab", "New tab", "tab agent new task"),
            // ⌘P's picker is not a command: this row calls `showPlacePicker()`,
            // and Kraal has no `mod.open` action to run.
            HcPaletteEntry(
                name: "mod.open", title: "Go to space or tab…", group: "Tab",
                keywords: "switch jump find", arguments: ["name": "picker"],
                opensPlacePicker: true
            ),
            row("tab.rename", "Tab", "Rename tab", "tab"),
            row("tab.close", "Tab", "Close tab", "tab kill"),
            row("tab.next", "Tab", "Next tab", "tab"),
            row("tab.prev", "Tab", "Previous tab", "tab"),
        ]
    }

    private static func paneRows() -> [HcPaletteEntry] {
        var rows = [
            row("pane.split", "Pane", "Split right", "vertical", ["direction": "right"]),
            row("pane.split", "Pane", "Split down", "horizontal", ["direction": "down"]),
            row("pane.close", "Pane", "Close pane", "kill"),
            row("pane.zoom", "Pane", "Zoom pane", "maximize fullscreen"),
        ]
        for direction in ["left", "right", "up", "down"] {
            rows.append(row("pane.go", "Pane", "Focus pane \(direction)", "move go", ["direction": direction]))
        }
        for direction in ["left", "right", "up", "down"] {
            rows.append(row("pane.swap", "Pane", "Swap pane \(direction)", "move", ["direction": direction]))
        }
        return rows
    }

    private static func spaceRows() -> [HcPaletteEntry] {
        [
            row("space.new", "Space", "New space", "workspace"),
            row("space.rename", "Space", "Rename space", "workspace"),
            row("space.close", "Space", "Close space", "workspace kill"),
            row("space.next", "Space", "Next space", "workspace"),
            row("space.prev", "Space", "Previous space", "workspace"),
        ]
    }

    private static func appRows() -> [HcPaletteEntry] {
        [
            row("app.settings", "App", "Settings", "preferences options config look font theme sound"),
            row("app.help", "App", "Keys", "keybindings shortcuts help"),
            row("app.zoom_in", "App", "Zoom in", "bigger font size"),
            row("app.zoom_out", "App", "Zoom out", "smaller font size"),
            row("app.zoom_reset", "App", "Reset zoom", "font size"),
            row("app.quit", "App", "Quit Kraal", "exit"),
        ]
    }

    /// Upstream `titleOf`: `pane.split` → Pane / "Split pane". Only reached for
    /// actions the table above has no better name for.
    private static func fallback(for action: KraalAction) -> HcPaletteEntry {
        let parts = action.name.split(separator: ".", maxSplits: 1).map(String.init)
        let noun = parts.first ?? action.name
        let words = parts.count > 1 ? parts[1] : action.name
        return HcPaletteEntry(
            name: action.name,
            title: "\(capitalised(words.replacingOccurrences(of: "_", with: " "))) \(noun)",
            group: capitalised(noun),
            keywords: action.about
        )
    }

    private static func capitalised(_ text: String) -> String {
        guard let head = text.first else { return text }
        return head.uppercased() + String(text.dropFirst())
    }

    private static func row(
        _ name: String,
        _ group: String,
        _ title: String,
        _ keywords: String = "",
        _ arguments: [String: String] = [:]
    ) -> HcPaletteEntry {
        HcPaletteEntry(name: name, title: title, group: group, keywords: keywords, arguments: arguments)
    }

    private static let named: [HcPaletteEntry] = buildNamed()
}

// MARK: - Filtering

/// Upstream `rows()`: grouped while nothing is typed, one ranked list while
/// something is. The score is upstream's `fuzzy`; a hit in the title beats a hit
/// in the group/name/keyword haystack by 4, so "split" keeps both split rows up.
enum HcPaletteSearch {
    /// One hit, with where it came from: equal scores keep catalog order, like
    /// upstream's stable sort does.
    private struct Ranked {
        let rank: Int
        let score: Double
        let entry: HcPaletteEntry
    }

    static func groups(query: String, entries: [HcPaletteEntry]) -> [HcPaletteGroup] {
        let needle = characters(query)
        guard !needle.isEmpty else { return sections(entries) }
        let ranked = entries.enumerated()
            .compactMap { rank, entry -> Ranked? in
                guard let score = score(needle, entry: entry) else { return nil }
                return Ranked(rank: rank, score: score, entry: entry)
            }
            .sorted { left, right in
                left.score == right.score ? left.rank < right.rank : left.score > right.score
            }
            .map(\.entry)
        return ranked.isEmpty ? [] : [HcPaletteGroup(title: "", entries: ranked)]
    }

    /// Empty query: every group in `groupOrder`, empties dropped.
    private static func sections(_ entries: [HcPaletteEntry]) -> [HcPaletteGroup] {
        var groups = HcPaletteCatalog.groupOrder.compactMap { title -> HcPaletteGroup? in
            let members = entries.filter { $0.group == title }
            return members.isEmpty ? nil : HcPaletteGroup(title: title, entries: members)
        }
        // A group the order list has never heard of still shows; it lands last.
        let others = entries.filter { !HcPaletteCatalog.groupOrder.contains($0.group) }
        if !others.isEmpty { groups.append(HcPaletteGroup(title: "", entries: others)) }
        return groups
    }

    /// Upstream lowercases and drops every space, so "pane close" is one needle.
    static func characters(_ query: String) -> [Character] {
        Array(query.lowercased().filter { !$0.isWhitespace })
    }

    static func score(_ query: String, entry: HcPaletteEntry) -> Double? {
        score(characters(query), entry: entry)
    }

    static func score(_ needle: [Character], entry: HcPaletteEntry) -> Double? {
        guard !needle.isEmpty else { return 0 }
        if let title = fuzzy(needle, in: entry.title) { return title }
        let haystack = "\(entry.group) \(entry.title) \(entry.name) \(entry.keywords)"
        guard let hit = fuzzy(needle, in: haystack) else { return nil }
        return hit - 4
    }

    /// Upstream `fuzzy`: every needle character in order, +6 when it starts a
    /// word, +3 per consecutive character, -0.3 per character skipped (capped at
    /// 6), and -0.02 per character of text so a shorter match wins a tie.
    private static func fuzzy(_ needle: [Character], in text: String) -> Double? {
        let haystack = Array(text.lowercased())
        var total = 0.0
        var cursor = 0
        var streak = 0
        var matched = 0
        for character in needle {
            guard let found = first(character, in: haystack, from: cursor) else { return nil }
            let startsWord = found == 0 || wordBreaks.contains(haystack[found - 1])
            streak = found == cursor && matched > 0 ? streak + 1 : 0
            total += 1 + (startsWord ? 6 : 0) + Double(streak) * 3 - Double(min(found - cursor, 6)) * 0.3
            matched += 1
            cursor = found + 1
        }
        return total - Double(haystack.count) * 0.02
    }

    private static func first(_ character: Character, in haystack: [Character], from index: Int) -> Int? {
        for position in max(index, 0) ..< haystack.count where haystack[position] == character {
            return position
        }
        return nil
    }

    private static let wordBreaks: Set<Character> = [" ", ":", ".", "-", "_", "/"]
}

// MARK: - Keycaps

enum HcPaletteKeycaps {
    /// Upstream `keyOf`: the binding is for `name` or `name:value`, so one action
    /// name carries both ⇧⌘D and ⌘D depending on the row's direction. Nil means
    /// no key: the row draws no chips at all.
    static func keys(for entry: HcPaletteEntry, bindings: [KraalKeyBinding]) -> String? {
        let action = firstValue(of: entry).map { "\(entry.name):\($0)" } ?? entry.name
        return bindings.first { $0.section == "global" && $0.action == action }?.keys
    }

    private static func firstValue(of entry: HcPaletteEntry) -> String? {
        entry.arguments.keys.sorted().first.flatMap { entry.arguments[$0] }
    }
}

// MARK: - Model

@MainActor
final class HcPaletteModel: ObservableObject {
    /// Page Up/Down move by a screenful; upstream shows ten rows at a time.
    static let page = 10

    @Published var query = "" {
        didSet { refresh() }
    }
    @Published private(set) var selection = 0
    @Published private(set) var groups: [HcPaletteGroup] = []

    let workspace: HcWorkspaceModel
    private let bindings: [KraalKeyBinding]
    /// Built once: what the window can run cannot change while the palette is up,
    /// and the filter runs on every keystroke.
    private let rows: [HcPaletteEntry]
    private var monitor: Any?

    init(workspace: HcWorkspaceModel) {
        self.workspace = workspace
        // keys.json is read once per palette so a keycap cannot disagree with
        // what the keyboard will do the moment the palette closes.
        bindings = (try? KraalKeymap.load(path: HcKeymapController.defaultPath)) ?? []
        rows = HcPaletteCatalog.entries { workspace.canPerformAction($0) }
        refresh()
    }

    var entries: [HcPaletteEntry] { groups.flatMap(\.entries) }

    var selectedEntry: HcPaletteEntry? {
        entries.indices.contains(selection) ? entries[selection] : nil
    }

    /// Typed something: group heads give way to a ranked list, and each row
    /// shows its own group name instead.
    var isFiltering: Bool { !characters.isEmpty }

    private var characters: [Character] { HcPaletteSearch.characters(query) }

    func keys(for entry: HcPaletteEntry) -> String? {
        HcPaletteKeycaps.keys(for: entry, bindings: bindings)
    }

    func select(_ entry: HcPaletteEntry) {
        selection = entries.firstIndex(of: entry) ?? 0
    }

    func move(_ delta: Int) {
        selection = min(max(selection + delta, 0), max(entries.count - 1, 0))
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
        guard let entry = selectedEntry else { return }
        run(entry)
    }

    func run(_ entry: HcPaletteEntry) {
        workspace.showPalette = false
        // The place picker is the other overlay, not a command: `performAction`
        // would only report that Kraal has no `mod.open`.
        if entry.opensPlacePicker {
            workspace.showPlacePicker()
            return
        }
        let arguments = entry.arguments.isEmpty
            ? nil
            : JSONValue.object(entry.arguments.mapValues { .string($0) })
        Task { @MainActor in
            let outcome = await self.workspace.performAction(entry.name, arguments: arguments)
            if let error = outcome.error {
                self.workspace.showToast(title: entry.name, detail: error, level: .error)
            }
        }
    }

    private func refresh() {
        groups = HcPaletteSearch.groups(query: query, entries: rows)
        selection = min(max(selection, 0), max(entries.count - 1, 0))
    }

    private func handle(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 126: // up
            move(-1)
        case 125: // down
            move(1)
        case 116: // page up
            move(-Self.page)
        case 121: // page down
            move(Self.page)
        case 36, 76: // return, enter
            runSelected()
        case 53: // escape
            workspace.showPalette = false
        default:
            return false
        }
        return true
    }
}

// MARK: - View

public struct HcCommandPalette: View {
    @ObservedObject public var workspace: HcWorkspaceModel
    @StateObject private var model: HcPaletteModel
    @FocusState private var queryFocused: Bool

    public init(workspace: HcWorkspaceModel) {
        self.workspace = workspace
        _model = StateObject(wrappedValue: HcPaletteModel(workspace: workspace))
    }

    /// The window's tokens. Read from the model, not `@Environment`: the
    /// presenter applies `.hcTheme` above this view, and a view cannot see an
    /// environment value it injects on its own body.
    private var theme: HcTheme { workspace.resolvedTheme }

    public var body: some View {
        // The presenter centres this over its scrim, so the card hangs 21pt below
        // the top of the workspace (y=61 with the 40pt titlebar). The empty area
        // below the card must not catch clicks (no background, no contentShape)
        // or the scrim's tap-to-close would stop working everywhere but on the
        // card itself.
        VStack(spacing: 0) {
            card.padding(.top, 32)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Injected again for the rows and keycaps, which read
        // `@Environment(\.hcTheme)`.
        .hcTheme(theme)
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

    private var card: some View {
        VStack(spacing: 10) {
            searchRow
            results
        }
        .padding(18)
        .frame(width: 616, height: 412)
        .background(theme.popover.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.border.color, lineWidth: 1)
        }
        .shadow(color: .black.opacity(theme.isLight ? 0.16 : 0.42), radius: 24, y: 10)
    }

    private var searchRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "command")
                .font(.system(size: 16))
                .foregroundStyle(theme.dim.color)
            TextField(
                "",
                text: $model.query,
                prompt: Text("Type a command…").foregroundColor(theme.dim.color)
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12.8))
            .foregroundStyle(theme.foreground.color)
            .focused($queryFocused)
            Text("Esc")
                .font(.system(size: 11))
                .foregroundStyle(theme.dim.color)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(theme.background.color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(theme.accent.color, lineWidth: 1)
        }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if model.entries.isEmpty {
                    // Upstream's empty state; places are the picker's job.
                    Text("Nothing matches “\(model.query)”. Places are in the picker.")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.dim.color)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.groups) { group in
                            if !group.title.isEmpty { head(group.title) }
                            ForEach(group.entries) { entry in
                                HcPaletteRow(
                                    entry: entry,
                                    keys: model.keys(for: entry),
                                    selected: entry == model.selectedEntry,
                                    showsGroup: model.isFiltering
                                ) {
                                    model.select(entry)
                                    model.run(entry)
                                }
                                .id(entry.id)
                            }
                        }
                    }
                    .padding(.bottom, 6)
                }
            }
            .scrollIndicators(.hidden)
            .onChange(of: model.selection) { _, _ in
                scroll(proxy, to: model.selectedEntry, anchor: .center)
            }
            .onChange(of: model.query) { _, _ in
                scroll(proxy, to: model.entries.first, anchor: .top)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func head(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.dim.color)
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26, alignment: .bottomLeading)
    }

    private func scroll(_ proxy: ScrollViewProxy, to entry: HcPaletteEntry?, anchor: UnitPoint) {
        guard let entry else { return }
        withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(entry.id, anchor: anchor) }
    }
}

/// Rows keep one height and one gap while you move: 32pt, 6pt from the card's
/// edge, 10pt of inner padding, radius 7. The selected row fills `selected`, the
/// one under the pointer `hover` — never an accent tint.
private struct HcPaletteRow: View {
    @Environment(\.hcTheme) private var theme
    let entry: HcPaletteEntry
    let keys: String?
    let selected: Bool
    let showsGroup: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(entry.title)
                    .font(.system(size: 12.8))
                    .foregroundStyle(selected ? theme.foreground.color : theme.muted.color)
                    .lineLimit(1)
                if showsGroup {
                    Text(entry.group)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.dim.color)
                }
                Spacer(minLength: 0)
                if let keys, !keys.isEmpty { HcKeyCaps(keys) }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
            .background(fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
    }

    private var fill: Color {
        if selected { return theme.selected.color }
        return hovering ? theme.hover.color : .clear
    }
}
