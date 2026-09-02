import AppKit
import ScreenCaptureKit
import CoreVideo
import CoreImage

/// Watches the board and says which squares changed.
///
/// It deliberately doesn't say what the change *means*. Reading "a piece moved
/// from e2 to e4" out of pixels needs to know what was there a moment ago, and
/// that knowledge lives with the position, not with the camera. So this reports
/// the smallest honest fact — these squares don't look the way they did — and
/// the session resolves it against a board it's been keeping all along.
///
/// The first version of this looked for chess.com's last-move highlight, which
/// is genuinely the fastest signal available: it appears the instant the move
/// is made, before the piece has finished sliding. It was also a hard
/// dependency on one site's theme colours, and it broke on the board themes
/// where the highlight is a border rather than a wash. Diffing costs a fraction
/// of a millisecond more and depends on nothing.
final class ChessWatcher: NSObject, SCStreamOutput, @unchecked Sendable {
    /// A square's appearance, packed small enough to compare 64 of them without
    /// thinking about it.
    struct Signature: Equatable {
        /// The square's average colour, for noticing that *something* changed.
        let r: UInt8, g: UInt8, b: UInt8
        /// Whether a piece is standing on this square.
        ///
        /// Decided by the one method that survives contact with a real board of
        /// any theme, and the several that didn't taught it. A square holds a
        /// piece when a real share of the pixels in its middle are far from the
        /// square's own colour. Not the *average* of the middle — a pawn is
        /// small and averaging blends it back into the green around it until it
        /// vanishes. Not the middle against its own corners — a black piece on a
        /// dark square, or a white one on a light square, matches its corners
        /// and disappears. Counting the pixels that don't match the square, with
        /// the square's two colours learned from the board itself, catches a
        /// pawn, a same-toned piece, and anything on anyone's theme, and leaves
        /// an empty square — highlighted or not — reading empty, because a wash
        /// moves every pixel together and none of them away from the others.
        let occupied: Bool

        func differs(from other: Signature, tolerance: Int = 12) -> Bool {
            occupied != other.occupied
                || abs(Int(r) - Int(other.r)) > tolerance
                || abs(Int(g) - Int(other.g)) > tolerance
                || abs(Int(b) - Int(other.b)) > tolerance
        }
    }

    enum WatchError: LocalizedError {
        case noScreenRecordingPermission
        case displayNotFound

        var errorDescription: String? {
            switch self {
            case .noScreenRecordingPermission:
                return "Visor needs Screen Recording to see the board — "
                     + "Privacy & Security ▸ Screen Recording"
            case .displayNotFound:
                return "Couldn't find the display the board is on"
            }
        }
    }

    private let geometry: BoardGeometry
    private let onChange: @Sendable ([Square], [Square: Signature]) -> Void
    /// When set, the next frame is written here as a PNG and the flag cleared.
    /// Set from the session when the board reads as entirely changed, because
    /// "all 64 squares differ" is not something a chess game does and the only
    /// way to learn what the watcher is actually looking at is to look at it.
    var dumpNextFrameTo: URL?
    private var stream: SCStream?
    private var previous: [Square: Signature] = [:]
    private let queue = DispatchQueue(label: "visor.chess.capture", qos: .userInteractive)

    init(geometry: BoardGeometry,
         onChange: @escaping @Sendable ([Square], [Square: Signature]) -> Void) {
        self.geometry = geometry
        self.onChange = onChange
    }

    /// Whether macOS will let us look at the screen at all.
    ///
    /// Asked before starting rather than discovered afterwards: without the
    /// grant, SCStream doesn't error, it delivers frames of solid black. The
    /// board would appear to be a board on which nothing ever happens, which
    /// is a much worse failure than being told no.
    static var isPermitted: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Where the board sits inside the captured buffer, in buffer pixels.
    /// For a window capture the buffer is the whole window and the board is
    /// somewhere inside it; for the display fallback the buffer *is* the board.
    private var boardInBuffer = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// The size in points that the buffer represents, so a retina buffer can
    /// be mapped back to the point geometry.
    private var bufferPointSize = CGSize(width: 1, height: 1)

    func start() async throws {
        guard Self.isPermitted else { throw WatchError.noScreenRecordingPermission }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard let displayID = geometry.displayID,
              let display = content.displays.first(where: { $0.displayID == displayID })
        else { throw WatchError.displayNotFound }

        let ourselves = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }

        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        // As fast as the display will go. ScreenCaptureKit is change-driven, so
        // a still board costs nothing — this buys latency on the frame where
        // something finally happens, not a steady 120fps of work.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        config.queueDepth = 3

        // Capture the window the board is in, not the patch of screen it was
        // on.
        //
        // A display-region capture grabs whatever is on screen at those
        // coordinates. Switch Spaces to type in another app and the watcher is
        // handed *that app* — every square differs from baseline, the landed
        // check reads garbage, retries fire, and nothing recovers until the
        // board is back on screen and something makes a frame flow. The frame
        // dump showed Slack and a sessions sidebar where the board should be.
        // A window capture follows the window: across Spaces, behind other
        // windows, wherever it goes.
        let centre = CGPoint(x: geometry.rect.midX, y: geometry.rect.midY)
        let host = content.windows.first { window in
            window.windowLayer == 0 && window.isOnScreen
                && window.frame.contains(centre)
                && window.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
        }

        let filter: SCContentFilter
        if let host {
            filter = SCContentFilter(desktopIndependentWindow: host)
            // Whole window, at its own size; the board is a sub-rectangle.
            config.width = Int(host.frame.width)
            config.height = Int(host.frame.height)
            boardInBuffer = CGRect(x: geometry.rect.minX - host.frame.minX,
                                   y: geometry.rect.minY - host.frame.minY,
                                   width: geometry.side, height: geometry.side)
            bufferPointSize = host.frame.size
            ChessDiagnostics.trace("watch: window capture of \(host.owningApplication?.applicationName ?? "?") "
                                 + "\(Int(host.frame.width))×\(Int(host.frame.height)), board at \(boardInBuffer)")
        } else {
            // No window under the board; fall back to the region.
            filter = SCContentFilter(display: display, excludingApplications: ourselves,
                                     exceptingWindows: [])
            let bounds = CGDisplayBounds(displayID)
            config.sourceRect = geometry.rect.offsetBy(dx: -bounds.origin.x, dy: -bounds.origin.y)
            config.width = Int(geometry.side)
            config.height = Int(geometry.side)
            boardInBuffer = CGRect(x: 0, y: 0, width: geometry.side, height: geometry.side)
            bufferPointSize = CGSize(width: geometry.side, height: geometry.side)
            ChessDiagnostics.trace("watch: no window under the board — display region capture")
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        let stream = self.stream
        self.stream = nil
        previous.removeAll()
        Task { try? await stream?.stopCapture() }
    }

    /// Forget what the board looked like, so the next frame is a fresh
    /// baseline rather than a diff against a stale one. Called after a resync.
    func rebaseline() {
        queue.async { self.previous.removeAll() }
    }

    // ── the hot path ──────────────────────────────────────────────────

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen,
              CMSampleBufferIsValid(buffer),
              let pixels = CMSampleBufferGetImageBuffer(buffer)
        else { return }

        // A frame ScreenCaptureKit marks as idle is one where nothing on the
        // display changed. Reading 64 squares off it would find 64 identical
        // squares, which is true and useless.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw), status != .complete {
            return
        }

        if let url = dumpNextFrameTo {
            dumpNextFrameTo = nil
            let ci = CIImage(cvPixelBuffer: pixels)
            if let cg = CIContext().createCGImage(ci, from: ci.extent) {
                let rep = NSBitmapImageRep(cgImage: cg)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
        }

        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }

        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        // The board is a sub-rectangle of the buffer — the whole window, for a
        // window capture — and the buffer may be at a different scale from the
        // points the geometry was measured in (retina hands back 2×).
        let scaleX = Double(width) / Double(bufferPointSize.width)
        let scaleY = Double(height) / Double(bufferPointSize.height)
        let originX = Double(boardInBuffer.minX) * scaleX
        let originY = Double(boardInBuffer.minY) * scaleY
        let squareW = Double(boardInBuffer.width) * scaleX / 8
        let squareH = Double(boardInBuffer.height) * scaleY / 8

        // Read a pixel at a fraction across a square, given its drawn cell.
        func pixel(col: Int, row: Int, _ fx: Double, _ fy: Double) -> (r: Int, g: Int, b: Int)? {
            let x = Int(originX + (Double(col) + fx) * squareW)
            let y = Int(originY + (Double(row) + fy) * squareH)
            guard x >= 0, x < width, y >= 0, y < height else { return nil }
            let o = y * stride + x * 4                    // BGRA
            return (Int(bytes[o + 2]), Int(bytes[o + 1]), Int(bytes[o]))
        }
        func cell(_ square: Square) -> (col: Int, row: Int) {
            geometry.flipped ? (7 - square.file, square.rank) : (square.file, 7 - square.rank)
        }

        // Pass one: the board's own two colours, learned from the corners.
        //
        // Corners because a piece sits in the middle and mostly leaves them
        // showing; median because the few corners a large piece does touch are
        // outvoted by the fifty-odd that are clean square. Learned every frame,
        // so nothing is assumed about the site or the theme — the board says
        // what light and dark are, here, now.
        var lightC: [(Int, Int, Int)] = [], darkC: [(Int, Int, Int)] = []
        for index in 0..<64 {
            guard let square = Square(index: index) else { continue }
            let (col, row) = cell(square)
            var rs = 0, gs = 0, bs = 0, n = 0
            for (fx, fy) in [(0.1, 0.1), (0.9, 0.1), (0.1, 0.9), (0.9, 0.9)] {
                if let p = pixel(col: col, row: row, fx, fy) { rs += p.r; gs += p.g; bs += p.b; n += 1 }
            }
            guard n > 0 else { continue }
            let c = (rs / n, gs / n, bs / n)
            if (square.file + square.rank) % 2 == 1 { lightC.append(c) } else { darkC.append(c) }
        }
        func median(_ xs: [Int]) -> Int { xs.isEmpty ? 0 : xs.sorted()[xs.count / 2] }
        func squareColour(_ cs: [(Int, Int, Int)]) -> (Int, Int, Int) {
            (median(cs.map { $0.0 }), median(cs.map { $0.1 }), median(cs.map { $0.2 }))
        }
        let lightSquare = squareColour(lightC), darkSquare = squareColour(darkC)

        // Pass two: occupancy by counting, and a mean for change detection.
        var current: [Square: Signature] = [:]
        current.reserveCapacity(64)
        var changed: [Square] = []

        for index in 0..<64 {
            guard let square = Square(index: index) else { continue }
            let (col, row) = cell(square)
            let sq = (square.file + square.rank) % 2 == 1 ? lightSquare : darkSquare

            var far = 0, total = 0
            var mr = 0, mg = 0, mb = 0
            // An 11×11 grid over the middle 64% of the square. A pixel counts as
            // "a piece" if it is well clear of the square's colour; enough of
            // them and a piece is standing here.
            for gy in 0..<11 {
                for gx in 0..<11 {
                    let fx = 0.18 + Double(gx) * 0.064
                    let fy = 0.18 + Double(gy) * 0.064
                    guard let p = pixel(col: col, row: row, fx, fy) else { continue }
                    mr += p.r; mg += p.g; mb += p.b
                    let dr = p.r - sq.0, dg = p.g - sq.1, db = p.b - sq.2
                    if dr * dr + dg * dg + db * db > 45 * 45 { far += 1 }
                    total += 1
                }
            }
            guard total > 0 else { continue }
            let signature = Signature(
                r: UInt8(mr / total), g: UInt8(mg / total), b: UInt8(mb / total),
                occupied: Double(far) / Double(total) > 0.13)
            current[square] = signature
            if let was = previous[square], signature.differs(from: was) { changed.append(square) }
        }

        let hadBaseline = !previous.isEmpty
        previous = current
        // The first frame is the baseline, not an event: everything "changed"
        // because nothing was known.
        guard hadBaseline, !changed.isEmpty else { return }
        onChange(changed, current)
    }
}
