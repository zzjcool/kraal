// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import SwiftUI

struct HcAgentToastView: View {
    let toast: HcAgentToast
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: toast.level == .error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(toast.level == .error ? Color.red : Color.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.callout.weight(.semibold))
                if !toast.detail.isEmpty {
                    Text(toast.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .frame(width: 280, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.12))
        )
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }
}

struct HcAgentPeekView: View {
    let address: String
    let session: HcTerminalSession
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .foregroundStyle(.secondary)
                Text(address)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close peek")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            Divider()
            HcTerminalPaneView(session: session)
        }
        .frame(width: 560, height: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.15))
        )
        .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
    }
}
