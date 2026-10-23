// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import AppKit
import ApplicationServices
import Foundation

/// Synthetic mouse and keyboard events.
///
/// This is the fallback, not the default. `AXPress` reaches most controls without
/// touching focus (verified: the frontmost app never changed), but it cannot
/// express "click here at this point" — terminal contents are drawn by Metal and
/// expose no elements, and the sidebar's `AXUnknown` rows carry no identifiers.
/// For those, a real event at a computed point is the only option left.
///
/// Unlike `AXPress`, this **does** need the app frontmost and does move the
/// pointer, so callers must treat it as the expensive path.
enum SyntheticInput {
    /// Posts a click at a point in *screen* coordinates (origin top-left, the
    /// space `CGWindowListCopyWindowInfo` reports).
    static func click(at point: CGPoint, clicks: Int = 1, button: CGMouseButton = .left) {
        let pressType: CGEventType
        let releaseType: CGEventType
        switch button {
        case .right:
            (pressType, releaseType) = (.rightMouseDown, .rightMouseUp)
        default:
            (pressType, releaseType) = (.leftMouseDown, .leftMouseUp)
        }
        post(.mouseMoved, at: point)
        usleep(60_000)
        for _ in 0..<max(clicks, 1) {
            post(pressType, at: point, button: button)
            usleep(30_000)
            post(releaseType, at: point, button: button)
            usleep(30_000)
        }
    }

    /// Drags from one point to another with a single mouse-dragged event.
    ///
    /// Measured inside the VM (kraal-agent, Kraal 1180x760, container 959pt):
    ///
    /// | drag | ratio change | expected | ratio |
    /// | --- | --- | --- | --- |
    /// | 16 steps of 40pt | 0.39 | 0.042 | **9.4x** |
    /// | 1 step of 40pt | 0.088 | 0.042 | 2.1x |
    /// | 1 step of 20pt | 0.050 | 0.021 | 2.4x |
    /// | 1 step of 80pt | 0.127 | 0.083 | 1.5x |
    ///
    /// The factor is not constant, which rules out a units bug in this driver.
    /// What it does match is the app applying the gesture translation **twice**:
    /// `DragGesture.onChanged` and `onEnded` both call `dragSplitRatio` with the
    /// same cumulative `translation`, and the ratio formula adds that translation
    /// to a `position` that the daemon has already moved. So a 40pt drag asks for
    /// 2x40pt. The shrinking factor at larger distances is the clamp to 0.9
    /// compressing the tail, not a different cause.
    ///
    /// This driver therefore sends exactly one dragged event: the extra steps were
    /// multiplying an already-doubled input and made the divider run away from the
    /// pointer. Chasing the remaining 2x by editing this file would be papering
    /// over an app bug — see `docs/ENVIRONMENT.md` §8.8.
    static func drag(
        from start: CGPoint, to end: CGPoint, steps: Int = 1, button: CGMouseButton = .left
    ) {
        let dragType: CGEventType = button == .right ? .rightMouseDragged : .leftMouseDragged
        let total = max(steps, 1)

        // `mouseMoved` first, then press. Warping the cursor instead
        // (`CGWarpMouseCursorPosition`) looked more correct and made every drag
        // miss the divider entirely — the hit testing uses the event's own
        // position, not the cursor's.
        post(.mouseMoved, at: start)
        usleep(100_000)
        post(.leftMouseDown, at: start, button: button)
        usleep(150_000)

        for step in 1...total {
            let fraction = Double(step) / Double(total)
            let point = CGPoint(
                x: start.x + (end.x - start.x) * fraction,
                y: start.y + (end.y - start.y) * fraction
            )
            post(dragType, at: point, button: button)
            usleep(80_000)
        }

        usleep(80_000)
        post(.leftMouseUp, at: end, button: button)
    }

    /// A key with optional modifiers, e.g. `--mod cmd --char w`.
    static func key(char: String, modifiers: CGEventFlags) -> Bool {
        guard let scalar = char.lowercased().unicodeScalars.first,
              let code = virtualKey(for: scalar)
        else { return false }
        for isDown in [true, false] {
            guard let keyEvent = CGEvent(
                keyboardEventSource: nil, virtualKey: code, keyDown: isDown
            ) else { return false }
            keyEvent.flags = modifiers
            keyEvent.post(tap: .cghidEventTap)
            usleep(25_000)
        }
        return true
    }

    /// Posts a scroll-wheel event at a screen point.
    ///
    /// A wheel event carries its position, so "which pane is under the pointer"
    /// is answered by the app's own hit testing — unlike `pane.scroll`, which
    /// names its target and therefore cannot test the routing that picks one.
    static func scroll(at point: CGPoint, lines: Int32) {
        let move = CGEvent(
            mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: point, mouseButton: .left
        )
        move?.post(tap: .cghidEventTap)
        usleep(120_000)
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
            wheel1: lines, wheel2: 0, wheel3: 0
        ) else { return }
        event.location = point
        event.post(tap: .cghidEventTap)
    }

    private static func post(
        _ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left
    ) {
        CGEvent(
            mouseEventSource: nil, mouseType: type,
            mouseCursorPosition: point, mouseButton: button
        )?.post(tap: .cghidEventTap)
    }

    /// US-layout virtual key codes — the only ones a positional lookup can give.
    /// Anything not listed must go through `keyboardSetUnicodeString` instead,
    /// which is what `type` does for arbitrary text.
    private static let keyCodes: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "\r": 36,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43,
        "/": 44, "n": 45, "m": 46, ".": 47, "\t": 48, " ": 49, "`": 50,
    ]

    private static func virtualKey(for scalar: Unicode.Scalar) -> CGKeyCode? {
        guard let character = Character(String(scalar)) as Character? else { return nil }
        return keyCodes[character]
    }
}

extension CGEventFlags {
    /// Parses `--mod cmd,shift` into flags. Kept here so there is one place that
    /// decides what a modifier name means.
    static func parse(_ text: String?) -> CGEventFlags {
        guard let text, !text.isEmpty else { return [] }
        var flags: CGEventFlags = []
        for part in text.split(separator: ",") {
            switch part.trimmingCharacters(in: .whitespaces).lowercased() {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt", "option", "opt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default: break
            }
        }
        return flags
    }
}
