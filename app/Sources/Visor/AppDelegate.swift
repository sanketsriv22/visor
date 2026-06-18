import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController?
    private var statusItem: NSStatusItem?
    private let updater = Updater()
    private var updateItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments

        if args.contains("--probe") {
            Self.printScreenProbe()
            NSApp.terminate(nil)
            return
        }

        controller = NotchController(startExpanded: args.contains("--expanded"))
        setUpStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.saveNow()
    }

    /// A small menu-bar icon — the only visible chrome. Gives a way to toggle
    /// the note and to quit (the app is otherwise invisible and non-activating).
    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "Visor")

        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Show / Hide Note", action: #selector(toggleNote), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let update = NSMenuItem(title: "Update Visor", action: #selector(updateApp), keyEquivalent: "")
        update.target = self
        menu.addItem(update)
        updateItem = update

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Visor", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item

        // Reflect update progress in the menu item's title.
        updater.onStatus = { [weak self] text in
            DispatchQueue.main.async { self?.updateItem?.title = text }
        }
    }

    @objc private func toggleNote() { controller?.toggle() }
    @objc private func quitApp() { NSApp.terminate(nil) }

    @objc private func updateApp() {
        updateItem?.title = "Checking for update…"
        updater.update()
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
