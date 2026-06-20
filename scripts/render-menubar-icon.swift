// Renders the Visor "Knot" menu-bar icon as a macOS template image.
// Two V shapes interlocking with alternating over/under weave.
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
    let vHeight: CGFloat = s * 0.35
    let lw: CGFloat = s * 0.12

    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(lw)

    // V (upright): tips top-left/right, vertex bottom-center
    let vTipL = CGPoint(x: cx - spread, y: cy - vHeight)
    let vTipR = CGPoint(x: cx + spread, y: cy - vHeight)
    let vVtx  = CGPoint(x: cx, y: cy + vHeight)

    // Lambda (inverted): vertex top-center, tips bottom-left/right
    let aVtx  = CGPoint(x: cx, y: cy - vHeight)
    let aTipL = CGPoint(x: cx - spread, y: cy + vHeight)
    let aTipR = CGPoint(x: cx + spread, y: cy + vHeight)

    // Arms cross at t=0.5 along each arm (both at y=cy).
    // Weave: left crossing -> V in front; right crossing -> Lambda in front.
    let armLen = sqrt(spread * spread + 4 * vHeight * vHeight)
    let gapT = (lw * 1.1) / armLen

    func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    func stroke(_ from: CGPoint, _ to: CGPoint) {
        ctx.beginPath()
        ctx.move(to: from)
        ctx.addLine(to: to)
        ctx.strokePath()
    }

    let black = CGColor(gray: 0, alpha: 1.0)
    ctx.setStrokeColor(black)

    // V left arm — fully drawn (V is in front at left crossing)
    stroke(vTipL, vVtx)

    // V right arm — gap at right crossing (Lambda is in front there)
    stroke(vTipR, lerp(vTipR, vVtx, 0.5 - gapT))
    stroke(lerp(vTipR, vVtx, 0.5 + gapT), vVtx)

    // Lambda right arm — fully drawn (Lambda is in front at right crossing)
    stroke(aVtx, aTipR)

    // Lambda left arm — gap at left crossing (V is in front there)
    stroke(aVtx, lerp(aVtx, aTipL, 0.5 - gapT))
    stroke(lerp(aVtx, aTipL, 0.5 + gapT), aTipL)

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
