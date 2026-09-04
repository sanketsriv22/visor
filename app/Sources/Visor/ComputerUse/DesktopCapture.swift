import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import ScreenCaptureKit

/// A persistent screen-capture session for computer use.
///
/// `ChessScreen` takes one-shot stills with `SCScreenshotManager`, which starts
/// and stops a capture on every call — that is what makes the screen-recording
/// indicator blink on every step, and re-enumerating the shareable content each
/// time is slow. This keeps a single `SCStream` running for the life of a task:
/// the indicator stays steadily lit, and grabbing a frame is just reading the
/// most recent buffer the stream delivered, so each step is quicker.
@available(macOS 13.0, *)
@MainActor
final class DesktopCapture {
    struct Frame {
        let image: CGImage
        /// The captured display's top-left in global CoreGraphics screen points.
        let origin: CGPoint
        /// Captured image pixels per screen point. 1 here — we capture at point
        /// resolution deliberately, so model coordinates map straight to points.
        let scale: CGFloat
    }

    private var stream: SCStream?
    private var sink: FrameSink?
    private var origin: CGPoint = .zero
    private var scale: CGFloat = 1

    /// Begin capturing the display the pointer is on. Excludes Visor's own
    /// windows so the HUD never ends up in the picture the model reasons about.
    func start() async throws {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { throw ChessScreen.CaptureError.noDisplay }
        let displayID = CGDirectDisplayID(number.uint32Value)
        let bounds = CGDisplayBounds(displayID)
        origin = bounds.origin

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID })
        else { throw ChessScreen.CaptureError.noDisplay }
        let ourselves = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(display: display,
                                     excludingApplications: ourselves,
                                     exceptingWindows: [])

        // Capture at point resolution (not native retina pixels): smaller and
        // faster, and it makes `scale` 1 so model pixel coordinates are points.
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.showsCursor = true                       // let the model see the pointer
        config.minimumFrameInterval = CMTime(value: 1, timescale: 6)   // ~6fps is plenty
        config.queueDepth = 3
        scale = bounds.width > 0 ? CGFloat(config.width) / bounds.width : 1

        let sink = FrameSink()
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(sink, type: .screen,
                                   sampleHandlerQueue: DispatchQueue(label: "com.visor.capture"))
        try await stream.startCapture()
        self.sink = sink
        self.stream = stream
    }

    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
        sink = nil
    }

    /// The most recent frame, or nil if none has arrived yet.
    func grab() -> Frame? {
        guard let image = sink?.latest() else { return nil }
        return Frame(image: image, origin: origin, scale: scale)
    }
}

/// Receives stream frames on a background queue and keeps the latest as a
/// `CGImage`, behind a lock so the main actor can read it.
@available(macOS 13.0, *)
private final class FrameSink: NSObject, SCStreamOutput {
    private let lock = NSLock()
    private var image: CGImage?
    private let ci = CIContext(options: [.useSoftwareRenderer: false])

    func latest() -> CGImage? { lock.lock(); defer { lock.unlock() }; return image }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        // Skip incomplete frames (SCStream marks status on each buffer).
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw), status != .complete {
            return
        }
        guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let rect = CGRect(x: 0, y: 0,
                          width: CVPixelBufferGetWidth(pixel),
                          height: CVPixelBufferGetHeight(pixel))
        guard let cg = ci.createCGImage(CIImage(cvPixelBuffer: pixel), from: rect) else { return }
        lock.lock(); image = cg; lock.unlock()
    }
}
