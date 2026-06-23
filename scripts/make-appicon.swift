import AppKit
let src = NSImage(contentsOfFile: "/Users/Kita/repos/kitalabs-website/public/icon-512.png")!
let N = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: N, pixelsHigh: N,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: N*4, bitsPerPixel: 32)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
src.draw(in: NSRect(x: 0, y: 0, width: N, height: N))
NSGraphicsContext.restoreGraphicsState()
let d = rep.bitmapData!; let bpr = rep.bytesPerRow
@inline(__always) func i(_ x:Int,_ y:Int)->Int{y*bpr+x*4}
@inline(__always) func L(_ x:Int,_ y:Int)->Double{let p=i(x,y);return Double(d[p])*0.3+Double(d[p+1])*0.59+Double(d[p+2])*0.11}

// Estimate background luminance per row from the far-left/right edge columns (pure background).
var bg = [Double](repeating: 0, count: N)
for y in 0..<N {
    var s = 0.0, n = 0.0
    for x in 0..<60 { s += L(x,y); n += 1 }
    for x in (N-60)..<N { s += L(x,y); n += 1 }
    bg[y] = s/n
}
// Smooth bg vertically.
var bgs = bg
for y in 0..<N { var s=0.0,n=0.0; for k in -20...20 { let yy=y+k; if yy>=0&&yy<N {s+=bg[yy];n+=1} }; bgs[y]=s/n }

// Matte: alpha from how much DARKER a pixel is than its row background.
let K = 55.0
for y in 0..<N { for x in 0..<N {
    let p = i(x,y)
    var a = (bgs[y] - L(x,y)) / K          // dark knot -> high; background/specular -> <=0
    a = max(0, min(1, a))
    // Composite original colour over white using a.
    for c in 0..<3 { d[p+c] = UInt8(255*(1-a) + Double(d[p+c])*a) }
    d[p+3] = 255
}}

// Squircle mask (inset 100, r 185 on 1024 grid) -> transparent corners.
let minX=100.0,maxX=924.0,minY=100.0,maxY=924.0,r=185.0
for y in 0..<N { for x in 0..<N {
    let fx=Double(x)+0.5, fy=Double(y)+0.5
    let dx=max(minX+r-fx,0,fx-(maxX-r)), dy=max(minY+r-fy,0,fy-(maxY-r))
    if !(fx>=minX&&fx<=maxX&&fy>=minY&&fy<=maxY&&dx*dx+dy*dy<=r*r) { d[i(x,y)+3]=0 }
}}
try! rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"/tmp/visor-icon-matte.png"))
print("wrote /tmp/visor-icon-matte.png")
