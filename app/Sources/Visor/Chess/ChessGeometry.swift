import AppKit

/// Where the board is on screen, and which way round it is.
///
/// One struct rather than numbers threaded through the watcher, the overlay and
/// the clicker, because all three have to agree on where e4 is to the pixel. If
/// the overlay and the clicker disagree by half a square, the arrows point at
/// the right move and the mouse plays a different one, and it takes a while to
/// work out that both halves are individually correct.
///
/// Everything here is in CoreGraphics screen points: origin top-left of the
/// primary display, y increasing downwards. That's what ScreenCaptureKit and
/// CGEvent both speak. AppKit disagrees, and `appKitRect` is the one place that
/// argument is settled.
struct BoardGeometry: Equatable {
    /// Top-left corner of the playable 8×8, excluding any coordinate gutter.
    var origin: CGPoint
    /// One square's side. Boards are square; a board that isn't means the
    /// calibration found the wrong rectangle.
    var square: CGFloat
    /// True when the user is playing black, so a1 is top-right.
    var flipped: Bool

    var side: CGFloat { square * 8 }
    var rect: CGRect { CGRect(origin: origin, size: CGSize(width: side, height: side)) }

    init(origin: CGPoint, square: CGFloat, flipped: Bool = false) {
        self.origin = origin
        self.square = square
        self.flipped = flipped
    }

    /// Build from the rectangle a calibration pass found.
    ///
    /// The short side wins. A board measured a few points wide because the
    /// detected contour caught a border is still a board; one measured as a
    /// rectangle and *used* as a rectangle drifts a little further from true
    /// with every file.
    init(boundingBox: CGRect, flipped: Bool = false) {
        let side = min(boundingBox.width, boundingBox.height)
        self.origin = CGPoint(x: boundingBox.minX + (boundingBox.width - side) / 2,
                              y: boundingBox.minY + (boundingBox.height - side) / 2)
        self.square = side / 8
        self.flipped = flipped
    }

    // ── squares ↔ pixels ──────────────────────────────────────────────

    /// Column and row as drawn, counting from the top-left of the board.
    private func screenCell(of square: Square) -> (col: Int, row: Int) {
        flipped ? (7 - square.file, square.rank)
                : (square.file, 7 - square.rank)
    }

    func rect(of sq: Square) -> CGRect {
        let (col, row) = screenCell(of: sq)
        return CGRect(x: origin.x + CGFloat(col) * square,
                      y: origin.y + CGFloat(row) * square,
                      width: square, height: square)
    }

    func center(of sq: Square) -> CGPoint {
        let r = rect(of: sq)
        return CGPoint(x: r.midX, y: r.midY)
    }

    func square(at point: CGPoint) -> Square? {
        guard rect.contains(point) else { return nil }
        let col = Int((point.x - origin.x) / square)
        let row = Int((point.y - origin.y) / square)
        return flipped ? Square(file: 7 - col, rank: row)
                       : Square(file: col, rank: 7 - row)
    }

    /// Every square, with the point to sample it at, in board order.
    ///
    /// The centre is the wrong place to look: it's where the piece is, and a
    /// piece is exactly what we're trying to see past when deciding whether a
    /// square changed. But it's also where the piece *is*, which is what we
    /// want. Both are true, so the watcher takes a small patch around the
    /// centre and averages — near enough the middle to catch the piece,
    /// wide enough not to hinge on one pixel of anti-aliasing.
    var sampleGrid: [(square: Square, point: CGPoint)] {
        (0..<64).compactMap { index in
            guard let sq = Square(index: index) else { return nil }
            return (sq, center(of: sq))
        }
    }

    /// Build from a rectangle measured in AppKit's coordinates.
    ///
    /// The calibration overlay is an ordinary window, so what the user drags is
    /// AppKit-shaped: origin bottom-left of the primary screen, y upwards.
    /// Everything downstream — capture, clicks — is CoreGraphics-shaped. This
    /// is the inverse of `appKitRect` and the only other place that argument is
    /// had.
    init(appKitBoundingBox box: CGRect, flipped: Bool = false) {
        let height = NSScreen.screens.first?.frame.height ?? box.maxY
        let asCoreGraphics = CGRect(x: box.minX, y: height - box.maxY,
                                    width: box.width, height: box.height)
        self.init(boundingBox: asCoreGraphics, flipped: flipped)
    }

    // ── the AppKit argument ───────────────────────────────────────────

    /// The same rectangle, in the coordinates `NSWindow.setFrame` wants.
    ///
    /// AppKit's origin is the bottom-left of the primary screen and its y grows
    /// upward; CoreGraphics' is the top-left and grows down. Flipping needs the
    /// *primary* screen's height specifically — not the screen the board is on
    /// — because that is the origin both systems are measured from. Using the
    /// board's own screen puts the overlay in the right place on a single
    /// display and somewhere else entirely on a second one, which is a bug that
    /// only ever reproduces on the reporter's desk.
    var appKitRect: CGRect {
        guard let primary = NSScreen.screens.first else { return rect }
        return CGRect(x: rect.minX,
                      y: primary.frame.height - rect.maxY,
                      width: rect.width, height: rect.height)
    }

    /// A square's rectangle in the overlay's own coordinates: relative to the
    /// board, y up, so it can be handed straight to a layer.
    func overlayRect(of sq: Square) -> CGRect {
        let r = rect(of: sq)
        return CGRect(x: r.minX - origin.x,
                      y: side - (r.maxY - origin.y),
                      width: r.width, height: r.height)
    }

    func overlayCenter(of sq: Square) -> CGPoint {
        let r = overlayRect(of: sq)
        return CGPoint(x: r.midX, y: r.midY)
    }

    /// The display the board is sitting on, which is the one to capture.
    var displayID: CGDirectDisplayID? {
        let screen = NSScreen.screens.first { $0.frame.intersects(appKitRect) }
        return (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value
    }
}
