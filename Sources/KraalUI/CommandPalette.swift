// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Command palette.
//
// Two sources feed it: the user's own `config.toml` commands (delivered in the
// snapshot, invoked through `command.invoke`) and a small set of built-in
// actions. That means a user's custom keybinds show up here for free, which is
// the main reason the snapshot carries `commands` at all.

import KraalProtocol
import SwiftUI
import KraalSidebar
import KraalTransport

struct CommandPalette: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted = 0
    /// Rename prompts raised by a palette command (`Rename Tab…` and friends).
    ///
    /// They are presented from the sheet rather than from the window behind it:
    /// a sheet that dims the window and then waits for an alert on the window is a
    /// sheet the user has to dismiss to answer.
    @State private var prompt: CommandPrompt?
    /// The same closures the menu bar dispatches through, so a palette command
    /// and its menu item are one code path — not two that can disagree.
    private let env: CommandEnvironment

    init(env: CommandEnvironment = CommandEnvironment()) {
        self.env = env
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Run a command…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(KraalTheme.Space.roomy)
                .onSubmit { run(items[safe: highlighted] ?? items.first) }

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        Button {
                            run(item)
                        } label: {
                            HStack(spacing: KraalTheme.Space.base) {
                                Image(systemName: item.symbol)
                                    .frame(width: 14)
                                    .foregroundStyle(.secondary)
                                Text(item.title)
                                    .font(KraalTheme.Font.rowTitle)
                                Spacer()
                                if let hint = item.hint {
                                    Text(hint)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, KraalTheme.Space.base)
                            .padding(.vertical, KraalTheme.Space.snug)
                            .contentShape(Rectangle())
                            .background {
                                if index == highlighted {
                                    RoundedRectangle(
                                        cornerRadius: KraalTheme.Radius.control,
                                        style: .continuous
                                    )
                                    .fill(.selection)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            if hovering { highlighted = index }
                        }
                    }

                    if items.isEmpty {
                        Text("No matching commands")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 460)
        // The palette floats over the terminal, so it gets the HUD material:
        // the most legible of the system blurs, which a quick keyboard overlay
        // needs. Rounded and rimmed so it reads as a pane of glass on top of the
        // window rather than a second sheet.
        .glassPanel(.hud, radius: KraalTheme.Radius.overlay)
        .renamePrompt($prompt)
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    private struct Item: Identifiable, PaletteSearchable {
        let id: String
        let title: String
        let symbol: String
        let hint: String?
        /// The family the row belongs to, shown nowhere and matched weakly.
        var category: String = ""
        /// Synonyms and machine names: what the title does not say.
        var keywords: [String] = []
        let action: () -> Void

        var paletteTitle: String { title }
        var paletteKeywords: [String] { keywords }
        var paletteCategory: String { category }
    }

    /// Every row, ranked. See `PaletteSearch` for the weights.
    ///
    /// The palette used to hold four built-ins; the app knows 58 commands, and a
    /// palette that hides them makes the menu the only way to reach half the app.
    private var items: [Item] {
        PaletteSearch.rank(navigatorItems + commandItems, query: query)
    }

    /// One row per command, dispatched exactly as the menu dispatches it.
    private var commandItems: [Item] {
        AppCommand.allCases.map { command in
            Item(
                id: "command.\(command.rawValue)",
                title: command.title,
                symbol: command.category.symbol,
                hint: command.category.title,
                category: command.category.title,
                keywords: command.keywords,
                action: { perform(command, on: store, env: env) }
            )
        }
    }

    /// Every jumpable pane/tab/workspace across all machines, as palette rows.
    ///
    /// Built from `Navigator`, which is pure: the ordering rules (current first,
    /// active machine wins ties, panes before tabs before workspaces) are
    /// asserted in tests rather than implied by the order this loop happens to
    /// run in.
    private var navigatorItems: [Item] {
        let machines = store.endpoints.map { endpoint in
            NavigatorMachine(
                id: endpoint.id.storageKey,
                label: endpoint.label,
                snapshot: endpoint.snapshot,
                isActive: endpoint.id == store.activeEndpointID
            )
        }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let targets = Navigator.filtered(Navigator.targets(for: machines), query: query)
        // The palette is a list, not a database: 400 rows of scrollback would make
        // the commands unreachable. The navigator's own ordering decides what
        // survives the cut.
        return targets.prefix(40).map { target in
            Item(
                id: "goto.\(target.id)",
                title: target.isCurrent ? "\(target.title) (current)" : target.title,
                symbol: symbol(for: target.kind),
                hint: hint(for: target),
                category: hint(for: target),
                // The machine name is in the hint and not in the title, so
                // "scratch" has to match a pane called "npm" on the scratch box.
                keywords: [target.machineLabel, target.kind.rawValue],
                action: { store.goTo(target) }
            )
        }
    }

    private func symbol(for kind: NavigatorTarget.Kind) -> String {
        switch kind {
        case .pane: "rectangle"
        case .tab: "rectangle.on.rectangle"
        case .workspace: "square.grid.2x2"
        }
    }

    /// The kind and machine, shown on the right.
    ///
    /// The machine is never omitted: a row that only says "vim" is ambiguous the
    /// moment two machines are connected, and jumping to the wrong one is worse
    /// than not jumping at all.
    private func hint(for target: NavigatorTarget) -> String {
        let kind = switch target.kind {
        case .pane: "pane"
        case .tab: "tab"
        case .workspace: "workspace"
        }
        return "\(kind) · \(target.machineLabel)"
    }

    private func run(_ item: Item?) {
        guard let item else { return }
        item.action()
        dismiss()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
