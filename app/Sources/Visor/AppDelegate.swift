import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments

        if args.contains("--probe") {
            Self.printScreenProbe()
            NSApp.terminate(nil)
            return
        }

        controller = NotchController(startExpanded: args.contains("--expanded"))
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.saveNow()
    }

    private static func printScreenProbe() {
        for (i, screen) in NSScreen.screens.enumerated() {
            print("screen[\(i)] frame=\(screen.frame) safeAreaTop=\(screen.safeAreaInsets.top)")
            if let notch = screen.notchArea {
                print("screen[\(i)] notch=\(notch)")
            } else {
                print("screen[\(i)] no notch (fallback strip would be used)")
            }
        }
    }
}
