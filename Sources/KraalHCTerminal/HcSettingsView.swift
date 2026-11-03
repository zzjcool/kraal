// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Settings that live in this client, not in the core's shared document. Every
// terminal field is applied to live surfaces as it changes; there is no restart.

import SwiftUI

public struct HcSettingsView: View {
    @ObservedObject var model: HcWorkspaceModel
    @Environment(\.dismiss) private var dismiss

    public init(model: HcWorkspaceModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            Form {
                Section("Appearance") {
                    Picker("App", selection: binding(\.appearance)) {
                        ForEach(HcAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Sidebar density", selection: binding(\.density)) {
                        ForEach(HcDensity.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                Section("Terminal") {
                    Stepper(value: binding(\.fontSize), in: 8 ... 32, step: 1) {
                        Text("Font size: \(Int(model.settings.fontSize)) pt")
                    }
                    Stepper(value: binding(\.paddingX), in: 0 ... 32) {
                        Text("Horizontal padding: \(model.settings.paddingX) pt")
                    }
                    Stepper(value: binding(\.paddingY), in: 0 ... 32) {
                        Text("Vertical padding: \(model.settings.paddingY) pt")
                    }
                    LabeledContent("Background opacity") {
                        Slider(value: binding(\.backgroundOpacity), in: 0.1 ... 1)
                            .frame(width: 180)
                        Text("\(Int(model.settings.backgroundOpacity * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                    LabeledContent("Minimum contrast") {
                        Slider(value: binding(\.minimumContrast), in: 0 ... 1)
                            .frame(width: 180)
                        Text(String(format: "%.2f", model.settings.minimumContrast))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
                Section("Notifications") {
                    Toggle("Play a sound for agent alerts", isOn: binding(\.soundEnabled))
                }
                Section("Files") {
                    LabeledContent("Core socket") {
                        Text(model.path)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                    LabeledContent("Keys") {
                        Text(HcKeymapController.defaultPath.path)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                }
                Section {
                    HStack {
                        Button("Reset terminal settings") {
                            model.settings = HcTerminalSettings()
                        }
                        Spacer()
                        Button("Reset keys…") {
                            // The escape hatch is the documented route; this
                            // button only tells the user where it is.
                            model.showToast(
                                title: "Keys reset",
                                detail: "Press ctrl-alt-shift-escape in the window.",
                                level: .info
                            )
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 560, height: 600)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<HcTerminalSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { model.settings[keyPath: keyPath] = $0 }
        )
    }
}
