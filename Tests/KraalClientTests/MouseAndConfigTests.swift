// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  MouseAndConfigTests.swift
//  KraalClientTests
//
//  Mouse forwarding, config loading, and the reload command.
//
//  `sendMouse` is the one place where "the click belongs to the app or to the program"
//  is decided, and getting it wrong in either direction is visible: forwarding when the
//  program did not ask takes the pane's own context menu away, and not forwarding when
//  it did means clicking a TUI does nothing. The gate is the daemon's per-pane flag.
//
//  `loadSidebarConfig` has an error path that reaches the user as a banner, so it must
//  report *and* keep the previous layout rather than half-applying a broken file.
//

import Foundation
import Testing

@testable import KraalClient
@testable import KraalProtocol
@testable import KraalUI

@Suite("Mouse forwarding and config")
@MainActor
struct MouseAndConfigTests {
    private func store(
        mouseReporting: Bool = true,
        sgrPixelMouse: Bool = false
    ) -> (AppStore, DaemonConnectionRecorder) {
        let store = AppStore(target: .local)
        let endpoint = EndpointState(id: .local, label: "Local", settings: .local)
        let recorder = DaemonConnectionRecorder()
        endpoint.connection = recorder
        endpoint.status = .online
        store.endpoints = [endpoint]
        store.activeEndpointID = .local
        store.phase = .live
        store.surface = PaneSurfaceFrame(
            bootId: "boot", projectionRevision: 1, surfaceRevision: 1,
            frame: FrameData(
                cells: Array(repeating: .blank, count: 40 * 10), width: 40, height: 10,
                cursor: nil, hyperlinks: [], graphics: Data()
            ),
            panes: [PaneSurfacePane(
                paneId: "w1:p1", contentRevision: 1,
                rect: SurfaceRect(originX: 0, originY: 0, width: 40, height: 10),
                innerRect: SurfaceRect(originX: 0, originY: 0, width: 40, height: 10),
                scrollbarRect: nil, scroll: nil, focused: true,
                mouseReporting: mouseReporting, sgrPixelMouse: sgrPixelMouse,
                alternateScreenActive: false, pixelWidth: 400, pixelHeight: 200
            )],
            splits: [], popup: nil, graphics: SurfaceGraphicsScene()
        )
        return (store, recorder)
    }

    private func waitUntil(_ label: String, timeout: TimeInterval = 2, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for \(label)")
    }

    // MARK: - The gate

    /// When the program did not ask for mouse reporting, the click is the app's: it
    /// opens the pane menu and nothing is sent to the daemon.
    @Test("a click is not forwarded when the program did not ask for it")
    func clickNotForwardedWithoutReporting() async throws {
        let (store, recorder) = store(mouseReporting: false)
        store.sendMouse(
            ClientMouseKind.press(.left), at: CGPoint(x: 10, y: 10), in: CGSize(width: 400, height: 100),
            paneId: "w1:p1"
        )
        try await Task.sleep(for: .milliseconds(80))
        #expect(recorder.paneInputs.isEmpty,
                "the click was forwarded, so the pane's context menu can never open")
    }

    @Test("a click is forwarded when the program asked for it")
    func clickForwardedWithReporting() async throws {
        let (store, recorder) = store(mouseReporting: true)
        store.sendMouse(
            ClientMouseKind.press(.left), at: CGPoint(x: 10, y: 10), in: CGSize(width: 400, height: 100),
            paneId: "w1:p1"
        )
        try await waitUntil("the mouse event") { !recorder.paneInputs.isEmpty }

        let sent = try #require(recorder.paneInputs.first)
        #expect(sent.paneId == "w1:p1")
        guard case let .mouse(kind, position, geometry, modifiers, lines) = sent.events[0] else {
            Issue.record("a non-mouse event was sent for a click")
            return
        }
        #expect(kind == ClientMouseKind.press(.left))
        #expect(modifiers == 0)
        #expect(lines == 0)
        // The geometry is the pane's own cell grid and pixel size, which is what lets
        // the daemon map a cell to a pixel for the program.
        let box = try #require(geometry, "the mouse event carried no pane geometry")
        #expect(box.cols == 40)
        #expect(box.rows == 10)
        #expect(box.widthPx == 400)
        #expect(box.heightPx == 200)
        // 400x100 points onto a 40x10 grid: point (10,10) is cell (1,1). Without the
        // pixel flag the position is a plain cell.
        guard case let .cell(column, row) = position else {
            Issue.record("a non-pixel pane produced a pixel position")
            return
        }
        #expect(column == 1)
        #expect(row == 1)
    }

    /// An unknown pane is not the app's and not the program's — there is nothing to
    /// address, so nothing is sent.
    @Test("a click on an unknown pane is not forwarded")
    func clickOnUnknownPane() async throws {
        let (store, recorder) = store()
        store.sendMouse(
            ClientMouseKind.press(.left), at: CGPoint(x: 10, y: 10), in: CGSize(width: 400, height: 100),
            paneId: "w9:p9"
        )
        try await Task.sleep(for: .milliseconds(80))
        #expect(recorder.paneInputs.isEmpty)
    }

    // MARK: - Config loading

    /// A valid file is applied and clears any previous error.
    @Test("a valid sidebar config is applied")
    func validConfigApplied() {
        let store = AppStore(target: .local)
        store.endpoints = [EndpointState(id: .local, label: "Local", settings: .local)]
        store.activeEndpointID = .local

        store.loadSidebarConfig(contents: "[agents]\nrows = [[\"agent\"]]\n", source: "config.toml")
        #expect(store.lastError == nil)
        #expect(store.sidebarConfigSource == "config.toml")
    }

    /// A broken file reports the problem and keeps the layout it had. Half-applying is
    /// worse than ignoring: the sidebar would change shape and the user would not know
    /// which line did it.
    @Test("a broken sidebar config reports and keeps the previous layout")
    func brokenConfigKeepsLayout() {
        let store = AppStore(target: .local)
        store.endpoints = [EndpointState(id: .local, label: "Local", settings: .local)]
        store.activeEndpointID = .local

        store.loadSidebarConfig(contents: "[agents]\nrows = [[\"agent\"]]\n", source: "good.toml")
        let applied = store.sidebarConfigSource

        store.loadSidebarConfig(contents: "this is not toml {{{", source: "bad.toml")
        #expect(store.lastError != nil, "a broken config was accepted silently")
        #expect(store.sidebarConfigSource == applied,
                "a broken config was half-applied")
    }

    /// A missing file is reported, not crashy.
    @Test("a missing config file is reported")
    func missingFileReported() {
        let store = AppStore(target: .local)
        store.endpoints = [EndpointState(id: .local, label: "Local", settings: .local)]
        store.activeEndpointID = .local
        store.loadSidebarConfig(fileURL: URL(fileURLWithPath: "/nonexistent/config.toml"))
        #expect(store.lastError?.contains("Could not read") == true)
    }

    // MARK: - Reload

    /// Reloading asks the daemon, and does so on the connection rather than locally
    /// only: the daemon owns the config the panes were projected from.
    @Test("reloading the server config sends server.reload_config")
    func reloadSendsRequest() async throws {
        let (store, recorder) = store()
        store.reloadServerConfig()
        try await waitUntil("server.reload_config") {
            recorder.methods.contains("server.reload_config")
        }
        #expect(recorder.methods.contains("server.reload_config"))
    }
}
