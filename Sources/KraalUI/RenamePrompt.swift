// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// A rename prompt shared by every context menu.
//
// Herdr puts "Rename workspace" / "Rename Tab" / "Rename Pane" in its context
// menus. Kraal has the same entries, and they all need one small text field; the
// modal alert in the AppKit menu path cannot be reused from SwiftUI, so the two
// paths share `CommandPrompt` and each renders it in its own idiom.

import SwiftUI

extension View {
    /// Presents the rename sheet for `prompt`, if one is set.
    func renamePrompt(_ prompt: Binding<CommandPrompt?>) -> some View {
        modifier(RenamePromptModifier(prompt: prompt))
    }
}

private struct RenamePromptModifier: ViewModifier {
    @Binding var prompt: CommandPrompt?
    @Environment(AppStore.self) private var store

    func body(content: Content) -> some View {
        content.sheet(item: $prompt) { prompt in
            RenameSheet(prompt: prompt) { newName in
                switch prompt {
                case .renameTab(let tabId, _):
                    store.rename(tabId: tabId, to: newName)
                case .renameWorkspace(let workspaceId, _):
                    store.rename(workspaceId: workspaceId, to: newName)
                case .renamePane(let paneId, _):
                    store.rename(paneId: paneId, to: newName)
                }
                self.prompt = nil
            } onCancel: {
                self.prompt = nil
            }
        }
    }
}

private struct RenameSheet: View {
    let prompt: CommandPrompt
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String
    @FocusState private var focused: Bool

    init(
        prompt: CommandPrompt,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.prompt = prompt
        self.onCommit = onCommit
        self.onCancel = onCancel
        _text = State(initialValue: prompt.currentValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(prompt.title)
                .font(.headline)
            TextField("Name", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(KraalTheme.Space.loose)
        .frame(width: 320)
        .glassChrome(.sheet, rim: false)
        .onAppear { focused = true }
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
    }
}
