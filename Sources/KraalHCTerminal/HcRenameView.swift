// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import SwiftUI

public struct HcRenameView: View {
    @ObservedObject var model: HcWorkspaceModel
    let request: HcRenameRequest
    @State private var name: String
    @Environment(\.dismiss) private var dismiss

    public init(model: HcWorkspaceModel, request: HcRenameRequest) {
        self.model = model
        self.request = request
        _name = State(initialValue: request.current)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commit() }
            HStack {
                Text("Empty restores the automatic name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { commit() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 360)
    }

    private var title: String {
        switch request.kind {
        case .space: "Rename space"
        case .tab: "Rename tab"
        }
    }

    private func commit() {
        let value = name
        dismiss()
        Task { @MainActor in
            await model.commitRename(request, name: value)
        }
    }
}
