import AppKit
import ScreenCaptureKit

/// One still of the display the pointer is on.
///
/// Separate from `ChessWatcher`, which streams. This is used once, at the
/// moment somebody asks Visor to find a board, and the difference matters: the
/// stream is tuned to notice small changes cheaply, where this wants the best
/// picture available and doesn't care what it costs.
enum ChessScreen {
    struct Shot {
        let image: CGImage
        /// The display's top-left in global CoreGraphics screen points, so
        /// anything found in the image can be placed on the desktop.
        let origin: CGPoint
    }

    enum CaptureError: LocalizedError {
        case noDisplay
        case failed

        var errorDescription: String? {
            switch self {
            case .noDisplay: return "Couldn't work out which screen to look at"
            case .failed:    return "Couldn't take a picture of the screen"
            }
        }
    }

    static func capture() async throws -> Shot {
        // The board is on the screen being looked at, and that is the one with
        // the pointer in it.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber
        else { throw CaptureError.noDisplay }
        let displayID = CGDirectDisplayID(number.uint32Value)
        let origin = CGDisplayBounds(displayID).origin

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID })
        else { throw CaptureError.noDisplay }

        // Visor is left out. Settings is open when this runs — it is where the
        // button is — and a window of ours sitting over the board would be
        // searched for a board.
        let ourselves = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(display: display,
                                     excludingApplications: ourselves,
                                     exceptingWindows: [])

        // `SCScreenshotManager` arrived in Sonoma. The package still targets
        // Ventura, so the old call stays for it — deprecated, and the only
        // thing available there.
        if #available(macOS 14.0, *) {
            let configuration = SCStreamConfiguration()
            configuration.width = display.width
            configuration.height = display.height
            configuration.showsCursor = false
            configuration.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration)
            return Shot(image: image, origin: origin)
        } else {
            guard let image = CGDisplayCreateImage(displayID) else {
                throw CaptureError.failed
            }
            return Shot(image: image, origin: origin)
        }
    }
}
