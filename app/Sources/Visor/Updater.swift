import AppKit
import Sparkle

/// Thin wrapper around Sparkle's updater. All download, signature verification,
/// privilege elevation, swap, and relaunch logic is handled by Sparkle.
///
/// Acts as the user-driver delegate so update UI comes to the front: Visor is an
/// accessory (LSUIElement) app and is never frontmost, so without activating,
/// Sparkle's update window and alerts open *behind* other apps' windows.
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
    }

    /// Bring Visor forward just before Sparkle shows an available update, so the
    /// update window appears on top of whatever the user is currently in.
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Same for Sparkle's modal alerts (e.g. "You're up to date", errors).
    func standardUserDriverWillShowModalAlert() {
        NSApp.activate(ignoringOtherApps: true)
    }
}
