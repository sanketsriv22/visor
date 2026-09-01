import AppKit
import ScreenCaptureKit
import CoreVideo

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
        let r: UInt8, g: UInt8, b: UInt8

        /// Whether two readings of the same square are different enough to
        /// call it a change. Generous: JPEG-ish compression in the capture
        /// path, subpixel antialiasing and the board's own hover states all
        /// move a channel or two, and a false positive costs a wasted resolve
        /// while a false negative loses the move entirely.
        func differs(from other: Signature, tolerance: Int = 12) -> Bool {
            abs(Int(r) - Int(other.r)) > tolerance
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

    func start() async throws {
        guard Self.isPermitted else { throw WatchError.noScreenRecordingPermission }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let displayID = geometry.displayID,
              let display = content.displays.first(where: { $0.displayID == displayID })
        else { throw WatchError.displayNotFound }

        // Exclude ourselves. The overlay draws arrows *on the board*, inside
        // the rectangle being captured — leave Visor in the capture and every
        // arrow we draw comes back as a changed square, which we resolve into
        // a move, which redraws the arrows. The loop is instantaneous and the
        // board appears to explode.
        let ourselves = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(display: display,
                                     excludingApplications: ourselves,
                                     exceptingWindows: [])

        let config = SCStreamConfiguration()
        // sourceRect is in the display's own logical points, so the board's
        // global position has to have the display's origin taken off it.
        let bounds = CGDisplayBounds(displayID)
        config.sourceRect = geometry.rect.offsetBy(dx: -bounds.origin.x, dy: -bounds.origin.y)
        config.width = Int(geometry.side)
        config.height = Int(geometry.side)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        // As fast as the display will go. ScreenCaptureKit is change-driven, so
        // a still board costs nothing — this buys latency on the frame where
        // something finally happens, not a steady 120fps of work.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        config.queueDepth = 3

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

        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }

        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        // The buffer covers exactly the board, so a square is a fixed fraction
        // of it and none of the screen-space geometry is needed here.
        let squareW = Double(width) / 8, squareH = Double(height) / 8

        var current: [Square: Signature] = [:]
        current.reserveCapacity(64)
        var changed: [Square] = []

        for index in 0..<64 {
            guard let square = Square(index: index) else { continue }
            let (col, row) = geometry.flipped
                ? (7 - square.file, square.rank)
                : (square.file, 7 - square.rank)

            // Nine samples spread over the middle of the square. One pixel is
            // hostage to whatever happens to be under it — a piece's outline, a
            // coordinate label in the corner, the dot chess.com draws on a legal
            // destination. Nine averaged is stable without being a blur.
            var rSum = 0, gSum = 0, bSum = 0, taken = 0
            for dy in 0..<3 {
                for dx in 0..<3 {
                    let x = Int((Double(col) + 0.3 + Double(dx) * 0.2) * squareW)
                    let y = Int((Double(row) + 0.3 + Double(dy) * 0.2) * squareH)
                    guard x >= 0, x < width, y >= 0, y < height else { continue }
                    let offset = y * stride + x * 4          // BGRA
                    bSum += Int(bytes[offset])
                    gSum += Int(bytes[offset + 1])
                    rSum += Int(bytes[offset + 2])
                    taken += 1
                }
            }
            guard taken > 0 else { continue }
            let signature = Signature(r: UInt8(rSum / taken),
                                      g: UInt8(gSum / taken),
                                      b: UInt8(bSum / taken))
            current[square] = signature
            if let was = previous[square], signature.differs(from: was) {
                changed.append(square)
            }
        }

        let hadBaseline = !previous.isEmpty
        previous = current
        // The first frame is the baseline, not an event: everything "changed"
        // because nothing was known.
        guard hadBaseline, !changed.isEmpty else { return }
        onChange(changed, current)
    }
}
