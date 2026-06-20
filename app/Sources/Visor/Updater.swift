import Sparkle

/// Thin wrapper around Sparkle's updater. All download, signature verification,
/// privilege elevation, swap, and relaunch logic is handled by Sparkle.
final class Updater {
    let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }
}
