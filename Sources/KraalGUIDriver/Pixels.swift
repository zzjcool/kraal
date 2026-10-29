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
/// `--rect X Y W H` is **top-left** anchored: y counts down from the image's top
/// edge, the same way the harness derives pane rectangles from the window.
///
/// That is *not* what a `CGContext` uses, and getting it backwards is silent —
/// measured: a `y=0` band on the top-white window image reported 0 white pixels
/// while `y=750` reported 11702, i.e. the image is addressed bottom-up by default.
/// The flip happens here, once, so no caller has to remember it.
///
/// The rect is in **points** and the image in **pixels**; `--scale` (defaulting to
/// the screen's backing factor) converts. `--origin "X Y"` subtracts the window
/// origin, for a rect derived in screen space against a window capture.
func commandPixels(_ args: Arguments) -> Never {
    // Only `--in`: `-i` is taken by `id` in the shared short-name table, so
    // advertising it here would send callers down a path that always fails.
    guard let path = args.string("in") else { fail(.harness, "pixels needs --in") }
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
    // `region` is top-down (y counts from the image's top). Drawing needs the
    // image's bottom-up origin offset so that the band lands in the output.
    //
    // The sign and the anchoring were **measured, not derived** — three variants
    // were run against a window capture whose image sits in the upper half
    // (`--rect "0 0 1180 380"` must find it, `--rect "0 380 1180 380"` must not):
    //
    //   `-region.minY`                 → reversed (found it in the lower band)
    //   `+region.minY`                 → blank (image drawn outside the output)
    //   `-(imageHeight - region.maxY)` → correct
    //
    // The comment that used to sit here described the second variant, which is why
    // this is written as a measurement rather than as an argument.
    let imageHeight = Double(image.height)
    let bottomUpY = -(imageHeight - region.maxY)
    context.draw(
        image,
        in: CGRect(x: -region.origin.x, y: bottomUpY,
                   width: CGFloat(image.width), height: CGFloat(image.height))
    )

    // `--match r>200,g<80,b>200` — a comma-separated list of channel comparisons.
    // Kept as a tiny predicate language rather than hardcoded thresholds: the
    // tolerances differ per case (a solid magenta image vs an antialiased one).
    let match = args.string("match") ?? "r>0"

    // Parsed once, before any pixel is read: a typo has to be an error, not a
    // predicate that silently becomes always-true. Measured failure modes of a
    // permissive parser — `r>>200` and `r>xyz` both counted every pixel (`Int(">200")
    // ?? 0`), an uppercase `R` dropped the whole channel test, and `blue>200` was
    // always false. Each of those turns "is the image on screen" into a constant.
    let clauses: [MatchClause]
    switch parseMatch(match) {
    case let .success(parsed):
        clauses = parsed
    case let .failure(error):
        fail(.harness, "cannot parse --match clause '\(error.text)';"
            + " expected e.g. r>200,g<80,b>200")
    }

    func satisfies(red: Int, green: Int, blue: Int) -> Bool {
        for clause in clauses where !clause.isSatisfied(red: red, green: green, blue: blue) {
            return false
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

/// One comparison in a `--match` predicate, e.g. `r>200`.
private struct MatchClause {
    enum Channel: Character { case red = "r", green = "g", blue = "b" }
    enum Comparison: Character { case greater = ">", less = "<", equal = "=" }

    let channel: Channel
    let comparison: Comparison
    let value: Int

    func isSatisfied(red: Int, green: Int, blue: Int) -> Bool {
        let actual: Int
        switch channel {
        case .red: actual = red
        case .green: actual = green
        case .blue: actual = blue
        }
        switch comparison {
        case .greater: return actual > value
        case .less: return actual < value
        case .equal: return actual == value
        }
    }
}

/// Parses `"r>200,g<80,b>200"`, refusing anything it does not fully understand.
///
/// Strict on purpose — see the note at the call site for the four ways a permissive
/// version turned the predicate into a constant.
private func parseMatch(_ text: String) -> Result<[MatchClause], MatchParseError> {
    var clauses: [MatchClause] = []
    for clause in text.split(separator: ",") {
        let trimmed = clause.trimmingCharacters(in: .whitespaces)
        // Both `first` calls are guarded by the length check, but written as
        // unwraps-with-guard rather than `!` so the linter's force_unwrapping rule
        // stays meaningful in this file.
        guard trimmed.count >= 3,
              let channelText = trimmed.first,
              let channel = MatchClause.Channel(rawValue: channelText),
              let comparisonText = trimmed.dropFirst().first,
              let comparison = MatchClause.Comparison(rawValue: comparisonText),
              let value = Int(trimmed.dropFirst(2))
        else {
            return .failure(MatchParseError(text: trimmed))
        }
        clauses.append(MatchClause(channel: channel, comparison: comparison, value: value))
    }
    return .success(clauses)
}

private struct MatchParseError: Error {
    let text: String
}

/// The region of the image to count, in image pixels.
///
/// Two spaces meet here and getting it wrong is silent: a `--rect` in **screen**
/// points against a **window** image clamps to the overlap, and the count then
/// describes a band nobody asked for (measured once: a 959x664 rect against a
/// 1180x760 window became 959x314, and "4032 magenta pixels" came out of it). So the
/// clamp is detected and reported instead of being measured.
func regionOfInterest(args: Arguments, image: CGImage) -> CGRect {
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
        // **The flip.** `--rect`'s y counts down from the top (that is what the
        // harness derives from the window layout); `CGContext`/`CGImage` address rows
        // from the bottom. Converting here, once, is the whole point of this
        // function owning the conversion — a caller that had to remember would get
        // it wrong, and it fails silently: measured on a window image whose top band
        // is white, `--rect "0 0 1180 10"` reported 0 white pixels and
        // `--rect "0 750 1180 10"` reported 11702.
        // The rect arrives **top-down**; keep it that way here. The conversion to
        // the drawing context's bottom-up space happens in one place, at the draw
        // call, because doing it twice cancels out silently (measured: flipping here
        // *and* subtracting the origin at the draw made `--rect y=600` — far from
        // the image — report all 4032 magenta pixels).
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
