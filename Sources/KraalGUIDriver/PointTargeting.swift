// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import AppKit
import CoreGraphics
import Foundation

// Pointer commands and the coordinate space each one takes.
//
// This file exists because of issue #72: `click --at` was window-relative while
// `ax --json` frames are screen coordinates, and the two were silently mixed.
// Keeping both spaces named in one place is the fix; keeping them in `main.swift`
// also pushed that file past SwiftLint's length limit, which is the smaller reason.

/// Which space a coordinate pair is expressed in.
///
/// An `ax --json` frame is a **screen** coordinate — that is what `AXPosition`
/// returns — while `--at` takes a **window-relative** offset. Mixing the two shifted
/// every click in the VM by the window origin (measured: 350pt, because the window
/// sits at y=350) and nothing said so. Now each form names its space, and a point
/// that misses the window is refused instead of clamped onto the nearest edge.
enum PointSpace {
    case windowRelative
    case screen
}

/// Converts a point to screen coordinates inside `window`, or refuses.
///
/// Refusing is the point of this function. The previous version clamped, so a point
/// computed in the wrong space landed on the window's edge, the click "succeeded",
/// and the case failed later with a message that read like a product bug (issue
/// #72). Both refusals quote the window frame *and* the screen point the driver
/// would have used, because "off by the window origin" is the mistake people
/// actually make.
///
/// The window's whole frame is in bounds, titlebar included, rather than just its
/// content area. AX reports the window element at the full frame, so a caller who
/// targets something the app drew into the titlebar is legitimate; narrowing this to
/// the content area would reject those points on no evidence. A click on the
/// titlebar that does nothing is a case's problem, not a coordinate-space problem.
func resolvePoint(
    _ raw: (Double, Double), space: PointSpace, in window: WindowInfo, caller: String
) -> CGPoint {
    let origin = window.frame.origin
    let width = window.frame.width
    let height = window.frame.height
    let (pointX, pointY) = raw
    let frameText = "window frame x=\(Int(origin.x)) y=\(Int(origin.y)) "
        + "w=\(Int(width)) h=\(Int(height))"
    switch space {
    case .windowRelative:
        guard pointX >= 0, pointY >= 0, pointX < width, pointY < height else {
            fail(.harness, "\(caller): window-relative point "
                + "(\(Int(pointX)),\(Int(pointY))) is outside the window — \(frameText), so an "
                + "offset must be inside [0,\(Int(width))) x [0,\(Int(height))). As given it "
                + "would land at screen (\(Int(origin.x + pointX)),\(Int(origin.y + pointY))). "
                + "An AX frame is a screen point, not an offset: either subtract the window "
                + "origin, or use the screen form (`click --at-screen`).")
        }
        return CGPoint(x: origin.x + pointX, y: origin.y + pointY)
    case .screen:
        let inside = pointX >= origin.x && pointY >= origin.y
            && pointX < origin.x + width && pointY < origin.y + height
        guard inside else {
            fail(.harness, "\(caller): screen point (\(Int(pointX)),\(Int(pointY))) is outside "
                + "the window — \(frameText) covers x in "
                + "[\(Int(origin.x)),\(Int(origin.x + width))) and y in "
                + "[\(Int(origin.y)),\(Int(origin.y + height))). If this number is a window "
                + "offset rather than an AX frame, pass it to `click --at` instead.")
        }
        return CGPoint(x: pointX, y: pointY)
    }
}

/// The same screen point written as an offset from the window's top-left corner.
func windowOffset(_ point: CGPoint, in window: WindowInfo) -> String {
    "\(Int(point.x - window.frame.origin.x)),\(Int(point.y - window.frame.origin.y))"
}

/// Reads one `X,Y` argument pair.
func requirePoint(_ args: Arguments, prefix: String = "at") -> (Double, Double) {
    let raw: String?
    if prefix == "at" {
        raw = args.string("at")
    } else {
        raw = args.string(prefix)
    }
    guard let raw else { fail(.harness, "missing --\(prefix) X,Y") }
    let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    guard parts.count == 2, let pointX = Double(parts[0]), let pointY = Double(parts[1]) else {
        fail(.harness, "--\(prefix) must be X,Y — got '\(raw)'")
    }
    return (pointX, pointY)
}

/// Clicks at a point, in whichever space the caller has it in.
///
/// `--at X,Y` is relative to the app's window — it survives the window moving, and
/// every coordinate bug so far came from hard-coding a position instead of deriving
/// it from the window. `--at-screen X,Y` is absolute screen coordinates, which is the
/// space AX frames are already in, so an AX measurement can be passed through
/// unchanged instead of being offset by hand (issue #72). Exactly one of the two is
/// required, and the point must land inside the window.
///
/// Activates the app first. Unlike `AXPress`, a synthetic click goes wherever the
/// pointer is, so without activation it lands on whatever is frontmost — that is the
/// failure mode that made a VM probe click TextEdit instead of the target.
func commandClick(_ args: Arguments) -> Never {
    guard let app = TargetApp.find(name: args.string("app") ?? "Kraal") else {
        fail(.harness, "no running app matching '\(args.string("app") ?? "Kraal")'")
    }
    let relative = args.string("at")
    let absolute = args.string("at-screen")
    if relative != nil, absolute != nil {
        fail(.harness, "click takes --at X,Y (window-relative) or --at-screen X,Y (screen), "
            + "not both — which space did you mean?")
    }
    guard relative != nil || absolute != nil else {
        fail(.harness, "click needs --at X,Y (window-relative) or --at-screen X,Y "
            + "(screen coordinates, as printed by `ax --json`)")
    }
    guard let window = primaryWindow(for: app.pid, title: args.string("title")) else {
        fail(.harness, "app '\(app.name)' has no window")
    }
    // Resolve and refuse *before* activating: a point that misses the window is a
    // caller mistake, and reporting it must not take the pointer away first.
    let point: CGPoint
    let described: String
    if absolute != nil {
        point = resolvePoint(
            requirePoint(args, prefix: "at-screen"), space: .screen,
            in: window, caller: "click --at-screen"
        )
        described = "screen(\(Int(point.x)),\(Int(point.y))) = "
            + "window+(\(windowOffset(point, in: window)))"
    } else {
        point = resolvePoint(
            requirePoint(args, prefix: "at"), space: .windowRelative,
            in: window, caller: "click --at"
        )
        described = "window+(\(windowOffset(point, in: window))) -> "
            + "screen(\(Int(point.x)),\(Int(point.y)))"
    }

    let stealsFocus = !args.has("no-activate")
    if stealsFocus && !activateAndConfirm(app) {
        fail(.harness, explanation(for: app))
    }
    let button: CGMouseButton = args.has("right") ? .right : .left
    SyntheticInput.click(at: point, clicks: args.int("clicks") ?? 1, button: button)
    print("clicked \(described) button=\(button == .right ? "right" : "left") "
        + "activated=\(stealsFocus)")
    requireAlive(app, context: "click")
    exit(Exit.success.rawValue)
}

/// Scrolls the wheel at a point, in whichever space the caller has it in.
///
/// Same two spaces as `click` (issue #72), same refusal rules. Exists because the
/// pane under the pointer is decided by the app from the event's own position, so
/// this is the only way to test that decision — `pane.scroll` names its target and
/// would pass even if the routing were inverted.
func commandScroll(_ args: Arguments) -> Never {
    guard let app = TargetApp.find(name: args.string("app") ?? "Kraal") else {
        fail(.harness, "no running app matching '\(args.string("app") ?? "Kraal")'")
    }
    let relative = args.string("at")
    let absolute = args.string("at-screen")
    if relative != nil, absolute != nil {
        fail(.harness, "scroll takes --at X,Y or --at-screen X,Y, not both")
    }
    guard relative != nil || absolute != nil else {
        fail(.harness, "scroll needs --at X,Y (window-relative) or --at-screen X,Y (screen)")
    }
    guard let window = primaryWindow(for: app.pid, title: args.string("title")) else {
        fail(.harness, "app '\(app.name)' has no window")
    }
    let point: CGPoint
    if absolute != nil {
        point = resolvePoint(
            requirePoint(args, prefix: "at-screen"), space: .screen,
            in: window, caller: "scroll --at-screen"
        )
    } else {
        point = resolvePoint(
            requirePoint(args, prefix: "at"), space: .windowRelative,
            in: window, caller: "scroll --at"
        )
    }
    guard let lines = Int32(args.string("lines") ?? "3") else {
        fail(.harness, "--lines must be an integer, got '\(args.string("lines") ?? "")'")
    }
    guard activateAndConfirm(app) else {
        fail(.harness, explanation(for: app))
    }
    SyntheticInput.scroll(at: point, lines: lines)
    print("scrolled screen(\(Int(point.x)),\(Int(point.y))) lines=\(lines) "
        + "window+(\(windowOffset(point, in: window)))")
    requireAlive(app, context: "scroll")
    exit(Exit.success.rawValue)
}

/// Drags between two window-relative points.
///
/// Only the window-relative form exists. No case needs a screen-space drag, and a
/// flag kept "for symmetry" is one more thing to get wrong — the case that drags
/// (the split divider) derives its points from the daemon's own geometry plus the
/// window origin, which is the form that survives the window moving. The points are
/// still validated, so a coordinate computed in screen space fails here quoting the
/// window frame, instead of dragging from 350pt below the divider.
func commandDrag(_ args: Arguments) -> Never {
    guard let app = TargetApp.find(name: args.string("app") ?? "Kraal") else {
        fail(.harness, "no running app matching '\(args.string("app") ?? "Kraal")'")
    }
    guard let window = primaryWindow(for: app.pid, title: args.string("title")) else {
        fail(.harness, "app '\(app.name)' has no window")
    }
    let start = resolvePoint(
        requirePoint(args, prefix: "from"), space: .windowRelative,
        in: window, caller: "drag --from"
    )
    let end = resolvePoint(
        requirePoint(args, prefix: "to"), space: .windowRelative,
        in: window, caller: "drag --to"
    )

    guard activateAndConfirm(app) else {
        fail(.harness, "could not bring '\(app.name)' to the front for a drag")
    }
    SyntheticInput.drag(from: start, to: end, steps: args.int("steps") ?? 1)
    print("dragged window+(\(windowOffset(start, in: window))) -> "
        + "(\(windowOffset(end, in: window))) screen "
        + "(\(Int(start.x)),\(Int(start.y))) -> (\(Int(end.x)),\(Int(end.y)))")
    requireAlive(app, context: "drag")
    exit(Exit.success.rawValue)
}
