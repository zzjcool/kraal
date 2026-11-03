// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import KraalActions
import SwiftUI

/// A plain reference generated from the same catalog the palette uses, so it
/// cannot drift into documenting commands that do not exist.
public struct HcHelpView: View {
    @ObservedObject var workspace: HcWorkspaceModel
    let keyBindings: [KraalKeyBinding]
    @Environment(\.dismiss) private var dismiss

    public init(workspace: HcWorkspaceModel, keyBindings: [KraalKeyBinding] = []) {
        self.workspace = workspace
        self.keyBindings = keyBindings
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Commands").font(.headline)
                    Text("Everything the palette and menus can run in this window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if !runnableKeys.isEmpty {
                        Text("KEYS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(runnableKeys, id: \.keys) { binding in
                            HStack(spacing: 12) {
                                Text(binding.keys)
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 170, alignment: .leading)
                                Text(binding.action)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                            }
                        }
                        Text("COMMANDS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                    ForEach(KraalActions.all, id: \.name) { action in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(action.name)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .frame(width: 170, alignment: .leading)
                            Text(about(action))
                                .font(.system(size: 12))
                                .foregroundStyle(action.support.isNative ? .primary : .secondary)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 640, height: 560)
        .onAppear { workspace.showHelp = true }
    }

    private var runnableKeys: [KraalKeyBinding] {
        keyBindings.filter { binding in
            if binding.action.hasPrefix("send:") { return true }
            let name = binding.action.split(separator: ":", maxSplits: 1).first.map(String.init) ?? binding.action
            return workspace.canPerformAction(name)
        }
    }

    private func about(_ action: KraalAction) -> String {
        if case let .unsupported(reason) = action.support {
            return "\(action.about) — \(reason)"
        }
        return action.about
    }
}
