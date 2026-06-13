// Renders the Visor app icon (1024pt): a dark squircle with the notch at
// the top and a sticky note flipped down beneath it.
// Usage: swift render-icon.swift /path/to/out.png
import AppKit

let size = CGSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

// macOS icon grid: rounded square inset 100pt, corner radius ~185pt
let squircle = NSBezierPath(
    roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
    xRadius: 185, yRadius: 185
)
NSColor(calibratedWhite: 0.10, alpha: 1).setFill()
squircle.fill()
squircle.setClip()

// The sticky note, hanging down from the notch
let note = NSBezierPath(
    roundedRect: NSRect(x: 312, y: 360, width: 400, height: 500),
    xRadius: 52, yRadius: 52
)
NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.35, alpha: 1).setFill()
note.fill()

// Task lines on the note
NSColor(calibratedWhite: 0.12, alpha: 0.85).setStroke()
for (i, width) in [248.0, 190.0, 224.0].enumerated() {
    let y = 740 - CGFloat(i) * 96
    let line = NSBezierPath()
    line.move(to: NSPoint(x: 388, y: y))
    line.line(to: NSPoint(x: 388 + width, y: y))
    line.lineWidth = 30
    line.lineCapStyle = .round
    line.stroke()
}

// The notch, drawn last so the note tucks underneath it
let notch = NSBezierPath(
    roundedRect: NSRect(x: 352, y: 846, width: 320, height: 110),
    xRadius: 34, yRadius: 34
)
NSColor.black.setFill()
notch.fill()

image.unlockFocus()

guard CommandLine.arguments.count > 1,
      let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("render-icon: failed\n".utf8))
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
