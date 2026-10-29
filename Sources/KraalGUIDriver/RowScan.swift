// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import CoreGraphics
import Foundation
import ImageIO

/// Prints, per row of a region, the most common colour and what share of the row it
/// covers.
///
/// Written for the "did a pane leave a row unpainted" assertion, which needs a per-row
/// answer and cannot get one from `pixels`: that command counts matching pixels over a
/// whole region, so a handful of antialiased glyph pixels is indistinguishable from a
/// fully uncovered band. Here a row that is 90% one colour is unambiguous.
///
/// JSON, because the caller's assertion is in Python: `{"rows": [{"y": 12,
/// "dominant": [40,40,40], "share": 0.998}, ...]}`.
func commandRowScan(_ args: Arguments) -> Never {
    guard let path = args.string("in") else { fail(.harness, "rowscan needs --in") }
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { fail(.harness, "cannot read \(path) as an image") }

    let region = regionOfInterest(args: args, image: image)
    let width = Int(region.width)
    let height = Int(region.height)
    guard width > 0, height > 0 else {
        fail(.harness, "rowscan region is empty (\(width)x\(height))")
    }

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
    // Same anchoring as `commandPixels`, and for the same measured reason: `region` is
    // top-down, drawing is bottom-up. The three variants are written down in
    // `Pixels.swift`; this is the one that was measured correct.
    let imageHeight = Double(image.height)
    context.draw(
        image,
        in: CGRect(
            x: -region.origin.x,
            y: -(imageHeight - region.maxY),
            width: CGFloat(image.width),
            height: CGFloat(image.height)
        )
    )

    var rows: [[String: Any]] = []
    rows.reserveCapacity(height)
    for row in 0 ..< height {
        var counts: [UInt32: Int] = [:]
        counts.reserveCapacity(8)
        let base = row * width * 4
        for column in 0 ..< width {
            let index = base + column * 4
            // Quantised to 8 bits per channel already; packed for hashing only.
            let key = UInt32(pixels[index]) << 16
                | UInt32(pixels[index + 1]) << 8
                | UInt32(pixels[index + 2])
            counts[key, default: 0] += 1
        }
        guard let (dominant, count) = counts.max(by: { $0.value < $1.value }) else { continue }
        rows.append([
            "y": Int(region.origin.y) + row,
            "dominant": [
                Int((dominant >> 16) & 0xFF),
                Int((dominant >> 8) & 0xFF),
                Int(dominant & 0xFF)
            ],
            "share": Double(count) / Double(width)
        ])
    }

    guard let data = try? JSONSerialization.data(withJSONObject: ["rows": rows]),
          let json = String(data: data, encoding: .utf8)
    else { fail(.harness, "cannot serialise the row scan") }
    print(json)
    exit(0)
}
