// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Terminal geometry and input.
//
// The surface is negotiated with the daemon by cell count, and keystrokes are
// translated into semantic events here. Both are transport concerns rather than
// snapshot reduction, so they sit away from the state machine in `AppStore`.

import Foundation
import KraalProtocol
import KraalSidebar
import KraalTransport

extension AppStore {
    /// Records the renderer's measured cell size and re-negotiates if it changed
    /// enough to alter the grid.
    /// Records the renderer's measured cell size.
    ///
    /// `hasMeasuredCellSize` exists because the startup sequence used to negotiate
    /// the whole surface against `fallbackCellSize`, then again against the real
    /// font, and once more after the window settled — three grids in 240 ms, with
    /// the middle one wider than the window:
    ///
    ///     19:41:43.131  geometry: 120x40 -> 137x54      (fallback 7.8x17)
    ///     19:41:43.217  layout: grid=137x54  rect=1164pt  (container is 1071)
    ///     19:41:43.268  layout: grid=126x50  rect=1071pt  (real 8.5x18.5)
    ///
    /// 137 columns at 8.5 pt is 1164.5 pt: 93.5 pt of pane outside the window. Each
    /// transition is a new projection, so each wiped and repainted both panes before
    /// the user had touched anything.
    public func updateCellMetrics(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let changed = abs(size.width - terminalCellSize.width) > 0.5
            || abs(size.height - terminalCellSize.height) > 0.5
        // The first real measurement always counts, even if it happens to land within
        // the threshold: `hasMeasuredCellSize` is what lets the negotiator stop
        // waiting, and a guess that was accidentally close enough would otherwise
        // leave the whole startup sequence blocked.
        guard changed || !hasMeasuredCellSize else { return }
        kraalLog("cell metrics: \(terminalCellSize) -> \(size)"
            + (hasMeasuredCellSize ? "" : " (first measurement)"))
        terminalCellSize = size
        hasMeasuredCellSize = true
        // The daemon divides pane pixel rects by the cell size, and the handshake could
        // only carry a guess: connections are built before any surface exists, so they
        // announced the `(10, 20)` default while the real font measures `17x37`. Nothing
        // corrected it afterwards, because `EndpointConnection.cellSize` was a `let`.
        // `size` is already in device pixels — `reportCellMetrics` passes
        // `surfaceSize.cellWidthPixels` — so it goes on the wire unchanged.
        let pixels = (width: UInt32(size.width.rounded()), height: UInt32(size.height.rounded()))
        for endpoint in endpoints {
            guard let connection = endpoint.connection else { continue }
            Task { await connection.updateCellSize(width: pixels.width, height: pixels.height) }
        }
        needsGeometryReeval = true
    }

    /// Negotiates a new surface grid with the daemon.
    ///
    /// This is the whole of "the window was resized": the pane area measured
    /// itself, converted to cells, and asks the daemon to re-render at that grid.
    /// The resize travels on the live connection as a `client_shell_resize`, so
    /// the panes follow the window on the very next frame instead of after a
    /// reconnect.
    public func resizeSurface(cols: UInt16, rows: UInt16) {
        // The daemon's own limits, not just non-zero: a bogus cell metric can
        // produce a huge grid, and sending it means a silent refusal.
        guard SurfaceGeometry.isAcceptableGrid(cols: Int(cols), rows: Int(rows)) else {
            return
        }
        let clamped = ClientSurfaceSize(cols: cols, rows: rows)
        guard clamped != surfaceSize else { return }
        kraalLog("geometry: \(surfaceSize.cols)x\(surfaceSize.rows) -> \(cols)x\(rows)")
        surfaceSize = clamped
        pushSurfaceSize()
    }

    /// Sends the current grid to the daemon without tearing the connection down.
    ///
    /// Before the welcome there is nothing to resize — the hello already carries
    /// this size — and a daemon that has closed the connection would just drop
    /// the message, so both cases are no-ops rather than errors.
    ///
    /// Concurrent drags collapse: a run already in flight re-reads `surfaceSize`
    /// after its send, so the newest grid wins instead of every intermediate one
    /// queueing up behind the socket. A window drag produces a resize per frame,
    /// and unsynchronised sends would let the daemon render a size the window has
    /// already left.
    func pushSurfaceSize() {
        guard connection != nil, phase.isLive else { return }
        // Raise the flag *before* deciding whether to start a task. If a send is
        // already in flight this records that another size is waiting, so the
        // running task cannot finish without seeing it — otherwise the request
        // would be dropped exactly when the connection had just been replaced.
        resizePending = true
        guard resizeTask == nil else { return }
        resizeTask = Task { [weak self] in
            defer { self?.resizeTask = nil }
            while let self, self.resizePending {
                self.resizePending = false
                let size = self.surfaceSize
                // Re-read the connection each pass: a reconnect during a drag
                // replaces it, and the new one needs the current grid.
                guard let connection = self.connection, self.phase.isLive else { return }
                do {
                    try await connection.sendResize(to: size)
                } catch {
                    kraalLog("resize: failed to send \(size.cols)x\(size.rows): \(error)")
                    return
                }
            }
        }
    }

    /// Sends keystrokes to a pane.
    ///
    /// Ghostty returns encoded bytes; they are translated into semantic events
    /// here so they can travel on the endpoint connection. The decoder holds
    /// partial escape sequences between calls, hence one per pane — and one per
    /// *machine*, because pane ids repeat across daemons.
    public func sendInput(_ data: Data, to paneId: String?) {
        guard let paneId else { return }
        let key = decoderKey(for: paneId)
        var decoder = inputDecoders[key] ?? TerminalInputDecoder()
        // Fresh each call: the program can toggle report-all at any moment, and a
        // decoder captured once would keep answering with the old mode.
        decoder.reportsAllKeys = keyboardReportAll
        var events = decoder.decode(data)
        // Always, not only when the chunk produced nothing: a chunk can end
        // `"ab<ESC>"`, which yields `text("ab")` *and* a stranded ESC. Waiting for an
        // empty result left that ESC in the buffer, where it turned the next keystroke
        // into Alt+key (issue #110 review, M1).
        events.append(contentsOf: decoder.flushEscape())
        inputDecoders[key] = decoder
        guard !events.isEmpty else { return }

        Task {
            do {
                try await connection?.sendPaneInput(paneId, events: events)
            } catch {
                lastError = "\(error)"
            }
        }
    }

    /// Which decoder a terminal's bytes belong to.
    ///
    /// The machine half is the daemon's `boot_id`, taken from the surface the
    /// terminal is drawn from. Before the first snapshot there is no boot id; the
    /// empty string is then a single "unknown machine" bucket, which is the same
    /// behaviour as the old pane-id-only key for that one startup moment.
    private func decoderKey(for terminal: String) -> InputDecoderKey {
        InputDecoderKey(machine: surface?.bootId ?? "", terminal: terminal)
    }

    /// Sends pasted text to a pane as a paste, not as keystrokes.
    ///
    /// Why it matters: bytes sent as input are indistinguishable from typing, so
    /// a program with `bracketed-paste` disabled on its side still sees every
    /// newline as Enter — pasting three shell commands ran all three. The wire has
    /// a separate `paste` event (`Encoder.swift`, tag 3) that carries the text as
    /// one unit, which is what lets a shell offer "paste N lines?" instead of
    /// executing them.
    ///
    /// Encodes keystroke bytes for a popup and sends them to that terminal.
    ///
    /// The decoder table is shared with the panes, keyed by `(machine, terminal)`.
    /// Pane ids and popup terminal ids are different namespaces (`w1:p1` vs a
    /// terminal id), so one dictionary is enough — and it has to be one, because
    /// the decoder holds half-parsed escape sequences between calls and a popup
    /// that typed part of an escape sequence must not have it completed against a
    /// pane's state.
    public func sendPopupInput(_ data: Data, terminalId: String) {
        let key = decoderKey(for: terminalId)
        var decoder = inputDecoders[key] ?? TerminalInputDecoder()
        decoder.reportsAllKeys = keyboardReportAll
        var events = decoder.decode(data)
        events.append(contentsOf: decoder.flushEscape())
        inputDecoders[key] = decoder
        guard !events.isEmpty else { return }

        Task {
            do {
                try await connection?.sendPopupInput(terminalId, events: events)
            } catch {
                lastError = "\(error)"
            }
        }
    }

    /// No `TerminalInputDecoder` on this path: the text is not a key sequence, and
    /// decoding it would turn a literal `ESC` in the pasted text into an arrow key.
    public func sendPaste(_ text: String, to paneId: String?) {
        guard let paneId, !text.isEmpty else { return }
        kraalLog("paste: \(text.count) chars to \(paneId)")
        Task {
            do {
                try await connection?.sendPaneInput(paneId, events: [.paste(text)])
            } catch {
                lastError = "paste: \(error)"
            }
        }
    }

    /// Whether the program inside a pane asked for mouse reporting.
    ///
    /// Ghostty cannot know this (it renders from the cell grid, which carries no
    /// mouse mode), so the daemon's per-pane flag is the authority. When it is
    /// false the click belongs to the app, not the program.
    public func mouseReportingEnabled(forPane paneId: String) -> Bool {
        paneGeometry(for: paneId)?.mouseReporting ?? false
    }

    public func mousePrecision(forPane paneId: String) -> Bool {
        paneGeometry(for: paneId)?.sgrPixelMouse ?? false
    }

    /// Sends one mouse event to a pane, when that pane accepts mouse input.
    public func sendMouse(
        _ kind: ClientMouseKind,
        at point: CGPoint,
        in viewSize: CGSize,
        paneId: String,
        modifiers: UInt8 = 0,
        lines: UInt16 = 0
    ) {
        guard let geometry = paneGeometry(for: paneId),
              geometry.mouseReporting
        else { return }

        let surface = self.surface?.frame
        let mapper = MouseCoordinateMapper(
            innerRect: geometry.innerRect,
            viewSize: viewSize,
            gridWidth: surface?.width ?? 0,
            gridHeight: surface?.height ?? 0
        )
        let position = PaneMouse.position(
            for: point,
            mapper: mapper,
            precision: geometry.sgrPixelMouse
        )
        let event = ClientPaneInputEvent.mouse(
            kind: kind,
            position: position,
            geometry: ClientMouseGeometry(
                cols: geometry.innerRect.width,
                rows: geometry.innerRect.height,
                widthPx: geometry.pixelWidth,
                heightPx: geometry.pixelHeight
            ),
            modifiers: modifiers,
            lines: lines
        )
        Task {
            do {
                try await connection?.sendPaneInput(paneId, events: [event])
            } catch {
                lastError = "\(error)"
            }
        }
    }

    public func send(text: String, to paneId: String?) {
        guard let paneId else { return }
        Task {
            do {
                try await connection?.sendPaneInput(paneId, events: [.textCommit(text)])
            } catch {
                lastError = "\(error)"
            }
        }
    }

    public func loadSidebarConfig(contents: String, source: String) {
        do {
            sidebarLayout = try SidebarConfigResolver.layout(fromTOML: contents)
            sidebarConfigSource = source
            lastError = nil
        } catch {
            lastError = "Sidebar config: \(error)"
        }
    }

    public func loadSidebarConfig(fileURL: URL) {
        do {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            loadSidebarConfig(contents: text, source: fileURL.lastPathComponent)
        } catch {
            lastError = "Could not read \(fileURL.lastPathComponent): \(error)"
        }
    }

    /// Loads `~/.config/herdr/config.toml` if it exists.
    public func loadDefaultSidebarConfig() {
        let path = (HerdrDiscovery.configDirectory() as NSString)
            .appendingPathComponent("config.toml")
        guard FileManager.default.fileExists(atPath: path) else { return }
        loadSidebarConfig(fileURL: URL(fileURLWithPath: path))
    }

    /// Asks the daemon to stream the focused tab's projection to us.
    ///
    /// `client_shell.surface.set` is an upstream API, not a protocol message:
    /// until it is called the daemon keeps projecting whichever tab held focus at
    /// handshake time, so switching tabs in another client would leave this
    /// window rendering a tab that is no longer visible.
}
