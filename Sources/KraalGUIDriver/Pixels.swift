// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  Pixels.swift
//  kraal-gui
//
//  Counts pixels that match a colour predicate inside a screenshot region.
//
//  This exists for one reason: a kitty graphics image had every layer unit-tested,
//  every byte accounted for, and never appeared on the screen. "Bytes were written"
//  and "a picture is visible" are different claims, and only a screenshot settles
//  the second (issue #103).
//

import AppKit
import CoreGraphics
import Foundation

/// Counts pixels inside a region that match an RGB predicate.
///
/// Exists so a GUI case can assert *what is on the screen*, not just what was sent
/// to the terminal. The kitty graphics path had every layer unit-tested and every
/// byte accounted for while the picture never appeared, so "the encoder produced
/// bytes" and "the renderer wrote them" are not enough — only a screenshot is
/// (#103).
///
/// `--rect X Y W H` is **screen** coordinates, the same space `driver click
/// --at-screen` and `screencapture` use. The image is in pixels and a Retina screen
/// has more of them than points, so the rect is scaled by the image's own size
/// relative to the display, not assumed 1:1.
func commandPixels(_ args: Arguments) -> Never {
    guard let path = args.string("in") else { fail(.harness, "pixels needs -i/--in") }
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { fail(.harness, "cannot read \(path) as an image") }

    let region = regionOfInterest(args: args, image: image)
    // Redraw into a known layout (8 bits per channel, RGBA) so the predicate does
    // not have to cope with whatever the screenshot's native format was.
    let width = Int(region.width)
    let height = Int(region.height)
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fail(.harness, "cannot create a drawing context") }
    context.draw(
        image,
        in: CGRect(x: -region.origin.x, y: -region.origin.y,
                   width: CGFloat(image.width), height: CGFloat(image.height))
    )

    // `--match r>200,g<80,b>200` — a comma-separated list of channel comparisons.
    // Kept as a tiny predicate language rather than hardcoded thresholds: the
    // tolerances differ per case (a solid magenta image vs an antialiased one).
    let match = args.string("match") ?? "r>0"

    func satisfies(red: Int, green: Int, blue: Int) -> Bool {
        for clause in match.split(separator: ",") {
            let text = clause.trimmingCharacters(in: .whitespaces)
            guard text.count >= 2 else { continue }
            // `text.first` can never be nil here (the guard above), but writing it as
            // an unwrap would make the linter's job impossible in a file whose whole
            // purpose is parsing a user-supplied predicate.
            guard let channel = text.first else { continue }
            let rest = text.dropFirst()
            let value = Int(rest.dropFirst()) ?? 0
            let actual: Int
            switch channel {
            case "r": actual = red
            case "g": actual = green
            case "b": actual = blue
            default: continue
            }
            let passes: Bool
            switch rest.first {
            case ">": passes = actual > value
            case "<": passes = actual < value
            case "=": passes = actual == value
            default: passes = false
            }
            if !passes { return false }
        }
        return true
    }

    var matched = 0
    var sampled = 0
    for index in stride(from: 0, to: pixels.count, by: 4) {
        let red = Int(pixels[index])
        let green = Int(pixels[index + 1])
        let blue = Int(pixels[index + 2])
        sampled += 1
        if satisfies(red: red, green: green, blue: blue) { matched += 1 }
    }
    print("pixels matched=\(matched) sampled=\(sampled) region=\(width)x\(height)")
    exit(Exit.success.rawValue)
}

/// The region of the image to count, in image pixels.
///
/// Two spaces meet here and getting it wrong is silent: a `--rect` in **screen**
/// points against a **window** image clamps to the overlap, and the count then
/// describes a band nobody asked for (measured once: a 959x664 rect against a
/// 1180x760 window became 959x314, and "4032 magenta pixels" came out of it). So the
/// clamp is detected and reported instead of being measured.
private func regionOfInterest(args: Arguments, image: CGImage) -> CGRect {
    // Region of interest in *image* pixels.
    var region = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    if let rect = args.string("rect") {
        let parts = rect.split(separator: " ").compactMap { Double($0) }
        guard parts.count == 4 else { fail(.harness, "pixels --rect wants \"X Y W H\"") }
        let (originX, originY, regionW, regionH) = (parts[0], parts[1], parts[2], parts[3])
        // The rect is in screen **points**; the image is in **pixels**. A Retina
        // capture has more pixels than points, so the rect has to be scaled — but
        // only by the screencapture-vs-screen ratio, and only when the image really
        // is a whole-screen capture. Deriving the factor from the image's own width
        // silently mis-scales any other image (a 100pt test bitmap was read as 200
        // pixels wide and a 50pt rect came out 7x7).
        //
        // `NSScreen` reports the backing factor directly, which is what
        // `screencapture` obeys.
        //
        // The space the rect is in must match the space the image is in, and there
        // are two possibilities that look alike: `screencapture -l` produces a
        // *window* image whose origin is the window's top-left, while a full-screen
        // capture's origin is the screen's. A screen-space rect intersected with a
        // window image silently clamps: a rect of `221 446 959 664` against a
        // 1180x760 window became `959x314`, and the count was taken from whatever
        // happened to land in that band. `--origin X Y` names the offset to subtract;
        // `--scale` overrides the backing factor (a window capture of a 2x screen is
        // already in pixels).
        let scale = args.double("scale") ?? Double(NSScreen.main?.backingScaleFactor ?? 1)
        var localX = originX
        var localY = originY
        if let origin = args.string("origin") {
            let parts2 = origin.split(separator: " ").compactMap { Double($0) }
            guard parts2.count == 2 else { fail(.harness, "pixels --origin wants \"X Y\"") }
            localX -= parts2[0]
            localY -= parts2[1]
        }
        region = CGRect(
            x: localX * scale, y: localY * scale,
            width: regionW * scale, height: regionH * scale
        )
            .integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        if region.isEmpty {
            fail(.harness, "pixels --rect \(rect) is outside \(image.width)x\(image.height)"
                + " (after --origin/--scale); the rect and the image are in different spaces")
        }
        // A clamped region is the failure mode above, and it is silent: the count is
        // simply taken from a smaller band than asked for. Say so rather than
        // quietly measuring the wrong thing.
        let wanted = (regionW * scale, regionH * scale)
        if abs(region.width - wanted.0) > 2 || abs(region.height - wanted.1) > 2 {
            fail(.harness, "pixels region clamped from \(Int(wanted.0))x\(Int(wanted.1))"
                + " to \(Int(region.width))x\(Int(region.height)) — the rect and the image"
                + " are in different coordinate spaces (pass --origin and/or --scale)")
        }
    }

    return region
}
