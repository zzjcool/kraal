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

    var body: some View {
        VStack(spacing: 0) {
            TextField("Run a command…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(10)
                .onSubmit { run(items[safe: highlighted] ?? items.first) }

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        Button {
                            run(item)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: item.symbol)
                                    .frame(width: 14)
                                    .foregroundStyle(.secondary)
                                Text(item.title)
                                    .font(.system(size: 12))
                                Spacer()
                                if let hint = item.hint {
                                    Text(hint)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                            .background {
                                if index == highlighted {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.accentColor.opacity(0.22))
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
        .background(.regularMaterial)
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    private struct Item: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let hint: String?
        let action: () -> Void
    }

    private var items: [Item] {
        var all: [Item] = []

        for command in store.commands {
            let title = command.description ?? command.commandId
            all.append(Item(
                id: command.commandId,
                title: title,
                symbol: "terminal",
                hint: command.bindingLabel.isEmpty ? nil : command.bindingLabel,
                action: { store.invoke(commandId: command.commandId) }
            ))
        }

        if let paneId = store.visiblePanes.first?.paneId {
            all.append(Item(
                id: "builtin.split",
                title: "Split Pane",
                symbol: "rectangle.split.2x1",
                hint: nil,
                action: { store.splitPane(paneId: paneId) }
            ))
            all.append(Item(
                id: "builtin.zoom",
                title: "Toggle Zoom",
                symbol: "rectangle.expand.vertical",
                hint: nil,
                action: { store.toggleZoom(paneId: paneId) }
            ))
        }

        all.append(Item(
            id: "builtin.newTab",
            title: "New Tab",
            symbol: "plus.rectangle",
            hint: nil,
            action: { store.createTab() }
        ))
        all.append(Item(
            id: "builtin.newWorkspace",
            title: "New Workspace",
            symbol: "plus.square.on.square",
            hint: nil,
            action: { store.createWorkspace() }
        ))

        let needle = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return all }
        return all.filter { $0.title.lowercased().contains(needle) }
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
