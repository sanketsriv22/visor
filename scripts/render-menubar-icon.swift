// Renders the Visor "Knot" menu-bar icon as a macOS template image.
// Two curved V shapes interlocking — the back V at lower opacity,
// the front V at full opacity, creating the weave effect.
// Output: MenuBarIconTemplate.png (18x18) and @2x (36x36) in the given directory.
// Usage: swift render-menubar-icon.swift /path/to/output-dir
import AppKit

func renderKnot(pointSize: CGFloat, scale: CGFloat) -> NSBitmapImageRep {
    let px = Int(pointSize * scale)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pointSize, height: pointSize)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    let s = pointSize
    let cx = s / 2
    let cy = s / 2
    let spread: CGFloat = s * 0.37
    let vHeight: CGFloat = s * 0.38
    let lw: CGFloat = s * 0.11
    let curvePull: CGFloat = s * 0.08

    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))
    ctx.setLineCap(.round)
    ctx.setLineWidth(lw)

    // Inverted V (behind — low opacity, drawn first)
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.30))

    ctx.beginPath()
    ctx.move(to: CGPoint(x: cx, y: cy - vHeight))
    ctx.addCurve(
        to: CGPoint(x: cx - spread, y: cy + vHeight),
        control1: CGPoint(x: cx - curvePull, y: cy - vHeight * 0.2),
        control2: CGPoint(x: cx - spread - curvePull, y: cy + vHeight * 0.5))
    ctx.strokePath()

    ctx.beginPath()
    ctx.move(to: CGPoint(x: cx, y: cy - vHeight))
    ctx.addCurve(
        to: CGPoint(x: cx + spread, y: cy + vHeight),
        control1: CGPoint(x: cx + curvePull, y: cy - vHeight * 0.2),
        control2: CGPoint(x: cx + spread + curvePull, y: cy + vHeight * 0.5))
    ctx.strokePath()

    // Upright V (in front — full opacity)
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.85))

    ctx.beginPath()
    ctx.move(to: CGPoint(x: cx - spread, y: cy - vHeight))
    ctx.addCurve(
        to: CGPoint(x: cx, y: cy + vHeight),
        control1: CGPoint(x: cx - spread - curvePull, y: cy - vHeight * 0.5),
        control2: CGPoint(x: cx + curvePull, y: cy + vHeight * 0.2))
    ctx.strokePath()

    ctx.beginPath()
    ctx.move(to: CGPoint(x: cx + spread, y: cy - vHeight))
    ctx.addCurve(
        to: CGPoint(x: cx, y: cy + vHeight),
        control1: CGPoint(x: cx + spread + curvePull, y: cy - vHeight * 0.5),
        control2: CGPoint(x: cx - curvePull, y: cy + vHeight * 0.2))
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

let rep1x = renderKnot(pointSize: 18, scale: 1)
let rep2x = renderKnot(pointSize: 18, scale: 2)

guard let d1 = rep1x.representation(using: .png, properties: [:]),
      let d2 = rep2x.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("render-menubar-icon: failed\n".utf8))
    exit(1)
}

try! d1.write(to: URL(fileURLWithPath: "\(outDir)/MenuBarIconTemplate.png"))
try! d2.write(to: URL(fileURLWithPath: "\(outDir)/MenuBarIconTemplate@2x.png"))
print("Wrote MenuBarIconTemplate.png and MenuBarIconTemplate@2x.png to \(outDir)")
