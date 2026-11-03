// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import KraalActions
import SwiftUI

/// A plain reference generated from the same catalog the palette uses, so it
/// cannot drift into documenting commands that do not exist.
public struct HcHelpView: View {
    @ObservedObject var workspace: HcWorkspaceModel
    @Environment(\.dismiss) private var dismiss

    public init(workspace: HcWorkspaceModel) {
        self.workspace = workspace
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

    private func about(_ action: KraalAction) -> String {
        if case let .unsupported(reason) = action.support {
            return "\(action.about) — \(reason)"
        }
        return action.about
    }
}
