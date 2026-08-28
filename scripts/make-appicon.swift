// Builds Visor's macOS app icon from the flat brand mark (white trefoil on
// black) that ships in the kitalabs-website repo.
//
//   swift make-appicon.swift [source.png] [out.iconset]
//
// The source is a full-bleed square. macOS icons aren't full-bleed: the art
// sits inside a squircle inset from the canvas edge, so the Dock's own
// spacing works out. We clip to a true superellipse (n = 5, which tracks
// Apple's continuous-corner shape far more closely than a plain rounded
// rect) and paint the black ground inside that clip, so the source's own
// black edge blends into it seamlessly.
//
// Emits a full .iconset; scripts/make-appicon.sh runs iconutil over it.

import AppKit

let args = CommandLine.arguments
let srcPath = args.count > 1
    ? args[1]
    : NSString(string: "~/repos/kitalabs-website/public/icon-1024.png").expandingTildeInPath
let outDir = args.count > 2 ? args[2] : "AppIcon.iconset"

guard let src = NSImage(contentsOfFile: srcPath),
      let srcCG = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("error: can't read source image at \(srcPath)\n".utf8))
    exit(1)
}

/// A true superellipse |x/a|^n + |y/b|^n = 1, sampled densely enough that the
/// polyline is indistinguishable from the curve at icon resolutions. n = 5 is
/// the value that visually matches Apple's icon corner.
func squircle(in rect: CGRect, n: Double = 5, samples: Int = 2048) -> CGPath {
    let a = Double(rect.width) / 2, b = Double(rect.height) / 2
    let cx = Double(rect.midX), cy = Double(rect.midY)
    let path = CGMutablePath()
    for i in 0...samples {
        let t = Double(i) / Double(samples) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * pow(abs(ct), 2 / n) * (ct < 0 ? -1 : 1)
        let y = cy + b * pow(abs(st), 2 / n) * (st < 0 ? -1 : 1)
        let p = CGPoint(x: x, y: y)
        i == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    path.closeSubpath()
    return path
}

/// Render one square icon at `size` px. Geometry is defined on Apple's 1024
/// grid (824pt body inset 100pt) and scaled down, so every size is
/// proportionally identical.
func render(size: Int) -> Data {
    let N = CGFloat(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    cg.interpolationQuality = .high
    let inset = 100.0 / 1024.0 * N
    let body = CGRect(x: inset, y: inset, width: N - inset * 2, height: N - inset * 2)

    cg.saveGState()
    cg.addPath(squircle(in: body))
    cg.clip()
    // Ground first: the source's black matches this exactly, so any edge
    // rounding error shows as black-on-black rather than a transparent notch.
    cg.setFillColor(NSColor.black.cgColor)
    cg.fill(body)
    cg.draw(srcCG, in: body)
    cg.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// The set macOS expects; @2x entries are the same pixels as the next size up.
let variants: [(name: String, px: Int)] = [
    ("icon_16x16", 16),      ("icon_16x16@2x", 32),
    ("icon_32x32", 32),      ("icon_32x32@2x", 64),
    ("icon_128x128", 128),   ("icon_128x128@2x", 256),
    ("icon_256x256", 256),   ("icon_256x256@2x", 512),
    ("icon_512x512", 512),   ("icon_512x512@2x", 1024),
]

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
// Render each distinct pixel size once; @2x aliases reuse the same bytes.
var cache: [Int: Data] = [:]
for v in variants {
    let png = cache[v.px] ?? render(size: v.px)
    cache[v.px] = png
    try! png.write(to: URL(fileURLWithPath: "\(outDir)/\(v.name).png"))
}
// Keep a 1024 master next to the iconset for the website / release assets.
try! cache[1024]!.write(to: URL(fileURLWithPath: "AppIcon-1024.png"))
print("wrote \(outDir) (\(variants.count) entries) + AppIcon-1024.png")
