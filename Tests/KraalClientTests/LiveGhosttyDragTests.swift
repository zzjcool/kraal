// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import AppKit
import Foundation
import GhosttyTerminal
@testable import KraalProtocol
@testable import KraalTerminalView
import SwiftUI
import Testing

// Drives the real `GhosttyPaneView` — real SwiftUI, a real `PaneSurfaceHostView`, a real
// Ghostty engine — through resizes, and reads back what the *engine* shows.
//
// Every other test in this target substitutes `gridOverride` for Ghostty, so hundreds of
// them can pass while the screen is wrong. That substitution is exactly what hid the band:
// Ghostty adopts a new size on its IO thread, behind a 25 ms coalescing timer, and when it
// does it rearranges what is already on screen — pushing rows into scrollback on a shrink,
// pulling them back on a grow. A frame written before that moment is parsed against the
// old screen, and a renderer that believes its baseline is still on screen writes nothing to
// repair it.
//
// Two rules keep these tests honest, and both were learned by getting it wrong:
//
//  * Content is `alphabet[(row + generation) % 26]`, so a stale, displaced or clamped
//    screen cannot look right by accident.
//  * `controlNoDrag` must stay green. The first version of this rig drew nothing at all
//    (its run loop never let the main queue publish `surfaceSize`), every drag "failed",
//    and the failures meant nothing.

/// What a test changes between frames.
@MainActor
final class DragDriver: ObservableObject {
    /// The rows and columns the view has: what a divider drag changes first.
    @Published var rows: Int
    @Published var columns: Int
    /// The size of the frame the daemon last sent. Equal to the view's unless a test makes
    /// the daemon late, which it always is in the app: it re-renders only after being told.
    @Published var frameRows: Int
    @Published var frameColumns: Int
    @Published var generation = 0

    init(rows: Int, columns: Int = LiveFixture.columns) {
        self.rows = rows
        self.columns = columns
        frameRows = rows
        frameColumns = columns
    }

    /// The daemon has caught up with the view.
    func catchUp() {
        frameRows = rows
        frameColumns = columns
        generation += 1
    }
}

/// One pane, as the daemon describes it.
enum LiveFixture {
    static let columns = 100
    static let cellHeight: CGFloat = 18.5
    static let cellWidth: CGFloat = 8.5
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")

    static func letter(row: Int, generation: Int) -> Character {
        alphabet[(row + generation) % alphabet.count]
    }

    static func surface(columns: Int, rows: Int, generation: Int) -> PaneSurfaceFrame {
        var cells: [CellData] = []
        for row in 0 ..< rows {
            let symbol = String(letter(row: row, generation: generation))
            for _ in 0 ..< columns {
                cells.append(CellData(
                    symbol: symbol, foreground: 1, background: 2, modifier: 0,
                    skip: false, hyperlink: nil
                ))
            }
        }
        let frame = FrameData(
            cells: cells, width: UInt16(columns), height: UInt16(rows),
            cursor: nil, hyperlinks: [], graphics: Data()
        )
        let rect = SurfaceRect(
            originX: 0, originY: 0, width: UInt16(columns), height: UInt16(rows)
        )
        return PaneSurfaceFrame(
            bootId: "boot", projectionRevision: 1, surfaceRevision: UInt64(generation + 1),
            frame: frame,
            panes: [PaneSurfacePane(
                paneId: "w1:p1", contentRevision: UInt64(generation + 1),
                rect: rect, innerRect: rect, scrollbarRect: nil, scroll: nil,
                focused: true, mouseReporting: false, sgrPixelMouse: false,
                alternateScreenActive: false, pixelWidth: 0, pixelHeight: 0
            )],
            splits: [], popup: nil, graphics: SurfaceGraphicsScene()
        )
    }
}

struct DragRoot: View {
    @ObservedObject var driver: DragDriver
    let model: PaneTerminalModel

    var body: some View {
        let surface = LiveFixture.surface(
            columns: driver.frameColumns, rows: driver.frameRows, generation: driver.generation
        )
        VStack(spacing: 0) {
            // The view is exactly the size the cells need, as `PaneLayoutView` lays it out.
            GhosttyPaneView(
                model: model, surface: surface, geometry: surface.panes[0], onFocus: {}
            )
            .frame(
                width: CGFloat(driver.columns) * LiveFixture.cellWidth,
                height: CGFloat(driver.rows) * LiveFixture.cellHeight
            )
            Spacer(minLength: 0)
        }
        .frame(width: 900, height: 820, alignment: .topLeading)
    }
}

/// SplitMix64: a drag that failed can be replayed with the same steps.
struct StepGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

/// Bytes the engine sent towards the daemon, collected from its IO thread.
final class InputSink: @unchecked Sendable {
    private let lock = NSLock()
    private var collected = Data()

    func add(_ data: Data) {
        lock.lock()
        collected.append(data)
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(bytes: collected, encoding: .utf8) ?? ""
    }
}

/// These tests need a window server: a real engine renders into a real layer. Without a
/// login session (an SSH shell, a bare CI runner) `NSApplication` cannot even start, so they
/// are skipped there rather than aborting the whole run. `KRAAL_SKIP_LIVE=1` opts out by hand.
private let liveEngineAvailable: Bool = {
    if ProcessInfo.processInfo.environment["KRAAL_SKIP_LIVE"] == "1" { return false }
    return CGSessionCopyCurrentDictionary() != nil
}()

@Suite(
    "Live Ghostty drag",
    .serialized,
    .enabled(if: liveEngineAvailable, "needs a window server session")
)
@MainActor
struct LiveGhosttyDragTests {
    /// Lets the main queue run. `TerminalViewState` publishes `surfaceSize` through
    /// `DispatchQueue.main.async`, and a main-queue block cannot run while the test body is
    /// itself a main-queue block spinning a nested run loop, so this must *suspend*.
    ///
    /// Between suspensions it does what a live display cycle would: an `NSHostingView` in
    /// a window nobody is looking at otherwise never lays out.
    private func pump(_ seconds: Double) async {
        let end = ContinuousClock.now + .seconds(seconds)
        repeat {
            for window in NSApp.windows {
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
            CATransaction.flush()
            try? await Task.sleep(for: .milliseconds(8))
        } while ContinuousClock.now < end
    }

    private struct Rig {
        let model: PaneTerminalModel
        let driver: DragDriver
        let window: NSWindow
        let input: InputSink
    }

    private func makeRig(rows: Int, columns: Int = LiveFixture.columns) -> Rig {
        _ = NSApplication.shared
        let input = InputSink()
        let model = PaneTerminalModel(paneId: "w1:p1") { input.add($0) }
        let driver = DragDriver(rows: rows, columns: columns)
        let host = NSHostingView(rootView: DragRoot(driver: driver, model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 820),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        // Invisible and click-through: the engine still lays out and parses, but a test run
        // must not put a window on the desktop of whoever is working there.
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        return Rig(model: model, driver: driver, window: window, input: input)
    }

    /// The engine's lines, as `ghostty_surface_size` sees them.
    private func lines(_ model: PaneTerminalModel) -> [String]? {
        model.session.readViewportText()?.components(separatedBy: "\n")
    }

    /// One first-character mark per row; `.` is an empty row.
    private func marks(_ model: PaneTerminalModel) -> String {
        guard let lines = lines(model) else { return "<read failed>" }
        return lines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? "." : String(trimmed.prefix(1))
        }.joined()
    }

    private func expectedMarks(rows: Int, generation: Int) -> String {
        (0 ..< rows).map { String(LiveFixture.letter(row: $0, generation: generation)) }.joined()
    }

    /// Whether every row is as wide as the frame, i.e. nothing is left of an old wrap.
    private func rowsAreFullWidth(_ model: PaneTerminalModel, columns: Int) -> Bool {
        lines(model)?.allSatisfy { $0.trimmingCharacters(in: .whitespaces).count == columns } ?? false
    }

    /// Waits for the surface to exist and the first paint to land.
    private func settle(_ rig: Rig) async {
        for _ in 0 ..< 80 {
            await pump(0.05)
            if rig.model.state.surfaceSize != nil, marks(rig.model).contains("A") { break }
        }
        await pump(0.3)
    }

    /// What a finished drag must show.
    private func verdict(_ rig: Rig, label: String) -> String? {
        let want = expectedMarks(rows: rig.driver.rows, generation: rig.driver.generation)
        let got = marks(rig.model)
        guard got == want, rowsAreFullWidth(rig.model, columns: rig.driver.columns) else {
            return "\(label) rows=\(rig.driver.rows) columns=\(rig.driver.columns)"
                + " want \(want) got \(got)"
        }
        return nil
    }

    // MARK: - Drags

    /// One step of a random walk of the pane's size.
    private struct Walk {
        var rows: ClosedRange<Int> = 8 ... 38
        var columns: ClosedRange<Int>?
        var stride: ClosedRange<Int>
        var gap: ClosedRange<Double>
        /// Seconds the daemon's frame trails the view; `nil` means it arrives with it.
        var lag: ClosedRange<Double>?
    }

    private func step(_ value: Int, within range: ClosedRange<Int>,
                      stride: ClosedRange<Int>, using rng: inout StepGenerator) -> Int {
        let delta = Int.random(in: stride, using: &rng) * (Bool.random(using: &rng) ? 1 : -1)
        return min(max(value + delta, range.lowerBound), range.upperBound)
    }

    /// Walks the pane's size, one daemon update per step.
    ///
    /// **Nothing is sent after the last step.** An earlier version finished with one more
    /// `catchUp()`, and that single extra frame — arriving after the engine had adopted the
    /// final size — repaired the screen by itself: the drags passed against the unfixed
    /// code. A still screen, such as a TUI waiting for input, gets no such frame.
    private func drag(_ rig: Rig, steps: Int, walk: Walk, seed: UInt64) async {
        var rng = StepGenerator(seed: seed)
        var inFlight: [Task<Void, Never>] = []
        var lastArrival = ContinuousClock.now
        for _ in 0 ..< steps {
            rig.driver.rows = step(rig.driver.rows, within: walk.rows, stride: walk.stride, using: &rng)
            if let columns = walk.columns {
                rig.driver.columns = step(
                    rig.driver.columns, within: columns, stride: walk.stride, using: &rng
                )
            }
            if let lag = walk.lag {
                let (rows, columns) = (rig.driver.rows, rig.driver.columns)
                // In order, as the daemon's replies are: a later reply never overtakes an
                // earlier one, and the last to arrive is the last step's.
                let wanted = ContinuousClock.now
                    + .milliseconds(Int(Double.random(in: lag, using: &rng) * 1000))
                let due = max(wanted, lastArrival + .milliseconds(1))
                lastArrival = due
                let driver = rig.driver
                inFlight.append(Task { @MainActor in
                    try? await Task.sleep(until: due, clock: .continuous)
                    driver.frameRows = rows
                    driver.frameColumns = columns
                    driver.generation += 1
                })
            } else {
                rig.driver.catchUp()
            }
            await pump(Double.random(in: walk.gap, using: &rng))
        }
        for task in inFlight { await task.value }
    }

    private func failures(
        label: String, trials: Int, steps: Int, walk: Walk, startColumns: Int = LiveFixture.columns
    ) async -> [String] {
        var bad: [String] = []
        for trial in 0 ..< trials {
            let rig = makeRig(rows: 20, columns: startColumns)
            await settle(rig)
            await drag(rig, steps: steps, walk: walk, seed: UInt64(trial))
            await pump(1.0) // quiescence: every coalescing timer has long fired
            if let problem = verdict(rig, label: "\(label) seed \(trial)") { bad.append(problem) }
            rig.window.orderOut(nil)
        }
        return bad
    }

    // MARK: - Tests

    /// If this is wrong the rig is wrong, and nothing else here can be trusted.
    @Test("control: with no drag the engine shows exactly the first frame")
    func controlNoDrag() async {
        let rig = makeRig(rows: 20)
        await settle(rig)
        await pump(1.0)
        #expect(verdict(rig, label: "control") == nil)
        rig.window.orderOut(nil)
    }

    /// The pane grows and the matching frame arrives in the same update — the best case
    /// there is, nothing late, nothing out of order. The frame is still written about 25 ms
    /// before the engine's IO thread adopts the new size, and used to end up with its last
    /// rows clamped onto one line and empty rows below.
    @Test("grow: a frame written with the bigger view still ends up on every row")
    func growWithMatchingFrame() async {
        var wrong: [String] = []
        for target in [24, 27, 33] {
            let rig = makeRig(rows: 20)
            await settle(rig)
            rig.driver.rows = target
            rig.driver.catchUp()
            await pump(0.6)
            if let problem = verdict(rig, label: "20 -> \(target)") { wrong.append(problem) }
            rig.window.orderOut(nil)
        }
        #expect(wrong.isEmpty, "\(wrong)")
    }

    /// A tab switch tears the view down and mounts a new one on the same model, with a new
    /// engine behind it. The request for reports has to reach *that* engine: one sent to the
    /// dying surface is lost with it, and a pane that stopped being told its screen moved
    /// would silently go back to the band.
    @Test("a rebuilt view is still told when its engine's screen moves")
    func remountedViewStillRepaints() async {
        var wrong: [String] = []
        for target in [26, 15] {
            let rig = makeRig(rows: 20)
            await settle(rig)
            rig.window.contentView = NSHostingView(
                rootView: DragRoot(driver: rig.driver, model: rig.model)
            )
            await settle(rig)
            rig.driver.rows = target
            rig.driver.catchUp()
            await pump(0.6)
            if let problem = verdict(rig, label: "remounted, 20 -> \(target)") { wrong.append(problem) }
            rig.window.orderOut(nil)
        }
        #expect(wrong.isEmpty, "\(wrong)")
    }

    @Test("shrink: a frame written with the smaller view still ends up on every row")
    func shrinkWithMatchingFrame() async {
        var wrong: [String] = []
        for target in [16, 12, 9] {
            let rig = makeRig(rows: 20)
            await settle(rig)
            rig.driver.rows = target
            rig.driver.catchUp()
            await pump(0.6)
            if let problem = verdict(rig, label: "20 -> \(target)") { wrong.append(problem) }
            rig.window.orderOut(nil)
        }
        #expect(wrong.isEmpty, "\(wrong)")
    }

    @Test("a fast drag ends with every row of the final frame on the engine's screen")
    func fastDragEndsCorrect() async {
        let walk = Walk(stride: 1 ... 6, gap: 0.0 ... 0.03)
        let bad = await failures(label: "fast", trials: 6, steps: 36, walk: walk)
        #expect(bad.isEmpty, "\(bad.count) of 6 fast drags left the screen wrong: \(bad)")
    }

    @Test("a slow drag ends with every row of the final frame on the engine's screen")
    func slowDragEndsCorrect() async {
        let walk = Walk(stride: 1 ... 3, gap: 0.06 ... 0.12)
        let bad = await failures(label: "slow", trials: 4, steps: 12, walk: walk)
        #expect(bad.isEmpty, "\(bad.count) of 4 slow drags left the screen wrong: \(bad)")
    }

    /// The daemon answers late, as it does in the app: it re-renders only after being told
    /// the new size. Frames of one height are painted into views of another.
    ///
    /// **A guard, not a discriminator**: with replies 20-150 ms late the engine has already
    /// adopted the size by the time the frame is written, so this passes without the fix.
    @Test("a slow daemon: every row of the final frame ends up on the engine's screen")
    func slowDaemonEndsCorrect() async {
        let walk = Walk(stride: 1 ... 6, gap: 0.0 ... 0.04, lag: 0.02 ... 0.15)
        let bad = await failures(label: "slow daemon", trials: 4, steps: 26, walk: walk)
        #expect(bad.isEmpty, "\(bad.count) of 4 slow-daemon drags left the screen wrong: \(bad)")
    }

    /// A local daemon answers inside the engine's 25 ms coalescing window, so its frame
    /// is written while the engine still has the previous size. That is the case the fix is for.
    @Test("a quick daemon: every row of the final frame ends up on the engine's screen")
    func quickDaemonEndsCorrect() async {
        let walk = Walk(stride: 1 ... 6, gap: 0.0 ... 0.04, lag: 0.0 ... 0.04)
        let bad = await failures(label: "quick daemon", trials: 6, steps: 30, walk: walk)
        #expect(bad.isEmpty, "\(bad.count) of 6 quick-daemon drags left the screen wrong: \(bad)")
    }

    /// Width changes reflow every row. A guard against the repaint trigger misbehaving on
    /// them (it passes without the fix: a width change parks the frame until the grid fits).
    @Test("rows and columns together: the final frame is on the engine's screen, full width")
    func mixedDragEndsCorrect() async {
        let walk = Walk(columns: 60 ... 104, stride: 1 ... 5, gap: 0.0 ... 0.05, lag: 0.0 ... 0.1)
        let bad = await failures(label: "mixed", trials: 4, steps: 26, walk: walk, startColumns: 90)
        #expect(bad.isEmpty, "\(bad.count) of 4 mixed drags left the screen wrong: \(bad)")
    }

    /// The assumption the fix stands on: after every resize the engine reports exactly the
    /// screen it has, and none of those reports is passed on to the daemon as keystrokes.
    @Test("the engine's size reports match its real screen, and never reach the daemon")
    func engineAnnouncesItsRealScreen() async {
        let rig = makeRig(rows: 20)
        await settle(rig)
        var mismatches: [String] = []
        for (rows, columns) in [(26, 100), (14, 100), (14, 80), (31, 92), (9, 70)] {
            rig.driver.rows = rows
            rig.driver.columns = columns
            rig.driver.catchUp()
            await pump(0.5)
            let actual = lines(rig.model)
            let announced = rig.model.engineScreen
            if announced?.rows != actual?.count
                || announced?.rows != rows || announced?.columns != columns {
                mismatches.append("\(rows)x\(columns): announced \(String(describing: announced))"
                    + " engine rows=\(String(describing: actual?.count))")
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches)")
        #expect(!rig.input.text.contains("[48;"), "a size report was sent to the daemon as input")
        rig.window.orderOut(nil)
    }
}
