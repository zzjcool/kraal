// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The herdr-core launch path, kept out of `KraalMacMain.swift` so the app
// lifecycle and window construction stay readable.

import AppKit
import KraalHC
import KraalHCTerminal
import KraalSupport
import SwiftUI

extension KraalAppDelegate {
    /// The socket this launch uses for herdr-core.
    ///
    /// `KRAAL_HC_SOCKET` is the explicit override used by VM/scratch sessions;
    /// otherwise the same `HC_SESSION`/`HC_SOCKET`/XDG rules as `hc` apply.
    /// A resolution failure is thrown, not turned into a second window: there
    /// is only one client stack now.
    static func hcSocketPath() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        if let explicit = environment["KRAAL_HC_SOCKET"], !explicit.isEmpty {
            return explicit
        }
        return try HcPaths.resolve().socket
    }

    /// Builds the herdr-core window: machines, the layout and its panes.
    ///
    /// A second launch in the same home raises the existing window instead of
    /// opening a second one. The control socket is the witness: if a process
    /// answers `raise`, it owns the home.
    func presentHcWindow(path: String) {
        let controlPath = try? HcControlPaths.resolve()
        if let controlPath,
           (try? HcControlClient.send(.raise, path: controlPath, timeout: 0.5)) != nil {
            kraalLog("launch: existing window raised via \(controlPath)")
            NSApp.terminate(nil)
            return
        }

        let model = HcWorkspaceModel(path: path)
        presentHcWindow(model: model)
    }

    /// A window whose transport is `ssh -T <host> hc connect`, for a core that
    /// is not added as a machine (or on a platform without a local core).
    func presentHcWindow(sshHost: String, remoteCommand: String = "hc connect") {
        let model = HcWorkspaceModel(
            linkFactory: { try HcSSHLink(host: sshHost, remoteCommand: remoteCommand) },
            label: "ssh:\(sshHost)"
        )
        presentHcWindow(model: model)
    }

    private func presentHcWindow(model: HcWorkspaceModel) {
        model.log = { kraalLog($0) }
        hcWorkspace = model
        let window = makeWindow(root: HcRootView(model: model))
        self.window = window
        model.windowNumber = window.windowNumber
        HcMenuBar.install(workspace: model)

        let controlPath = try? HcControlPaths.resolve()
        if let controlPath {
            do {
                let server = HcControlServer(path: controlPath) { [weak self] request in
                    guard let self else {
                        return .object(["error": .string("Kraal is closing")])
                    }
                    return await self.respond(to: request, model: model)
                }
                try server.start()
                hcControl = server
                model.controlSocketPath = controlPath
                kraalLog("hc: control listening at \(controlPath)")
            } catch {
                model.log?("hc: control socket unavailable: \(error)")
            }
        } else {
            model.log?("hc: control socket path unavailable")
        }

        model.start()
    }

    @MainActor
    private func respond(to request: HcControlRequest, model: HcWorkspaceModel) async -> JSONValue {
        switch request {
        case let .shot(path):
            return controlShot(path)
        case .raise:
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            return .object(["ok": .bool(true)])
        case .list, .status, .doAction:
            return await model.handleControl(request)
        }
    }

    /// `screencapture -l` needs the window *number*, not the AX window. The
    /// number is stable while the window is ordered back, so this also works
    /// for the background dev session.
    @MainActor
    private func controlShot(_ path: String) -> JSONValue {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.pathExtension.lowercased() == "png" else {
            return .object(["error": .string("screenshot path must end in .png")])
        }
        guard let number = window?.windowNumber, number > 0 else {
            return .object(["error": .string("window is not available")])
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return .object(["error": .string("cannot create screenshot directory: \(error)")])
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(number), url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .object(["error": .string("cannot run screencapture: \(error)")])
        }
        guard process.terminationStatus == 0 else {
            return .object(["error": .string("screencapture exited \(process.terminationStatus)")])
        }
        return .object(["path": .string(url.path)])
    }
}
