// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The herdr-core launch path, kept out of `KraalMacMain.swift` (that file is at
// swiftlint's length limit and this is a self-contained mode).

import AppKit
import KraalHC
import KraalHCTerminal
import KraalUI
import SwiftUI

extension KraalAppDelegate {
    /// The socket this launch should use for herdr-core, if it asked for hc mode.
    static func hcSocketPath() -> String? {
        let environment = ProcessInfo.processInfo.environment
        let explicit = environment["KRAAL_HC_SOCKET"] ?? ""
        guard environment["KRAAL_HC"] == "1" || !explicit.isEmpty else { return nil }
        if !explicit.isEmpty { return explicit }
        do {
            return try HcPaths.resolve().socket
        } catch {
            kraalLog("launch: hc path resolution failed: \(error)")
            return nil
        }
    }

    /// Builds the M0 window: a flat terminal list and one attached pane.
    func presentHcWindow(path: String) {
        let model = HcWorkspaceModel(path: path)
        model.log = { kraalLog($0) }
        hcWorkspace = model
        window = makeWindow(root: HcRootView(model: model))
        model.start()
    }
}
