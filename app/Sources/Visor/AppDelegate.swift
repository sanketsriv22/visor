import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: NotchController?
    private var statusItem: NSStatusItem?
    private let updater = Updater()
    private var updateItem: NSMenuItem?

    /// Posted by a second launch so the already-running instance shows its note.
    private static let showNoteNotification = Notification.Name("com.kitalabs.visor.showNote")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments

        if args.contains("--probe") {
            Self.printScreenProbe()
            NSApp.terminate(nil)
            return
        }

        // Single instance: if another Visor is already running, ask it to show
        // its note and quit immediately — two instances would run competing
        // file watchers that race and can clobber the note. This happens before
        // any state or watcher is created.
        if isAnotherInstanceRunning() {
            DistributedNotificationCenter.default().postNotificationName(
                Self.showNoteNotification, object: nil, userInfo: nil, deliverImmediately: true)
            exit(0)
        }

        controller = NotchController(startExpanded: args.contains("--expanded"))
        setUpStatusItem()

        // Re-launching Visor (e.g. from Spotlight) brings the note down.
        DistributedNotificationCenter.default().addObserver(
            forName: Self.showNoteNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.controller?.showNote()
        }
    }

    private func isAnotherInstanceRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != me }
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
        menu.delegate = self

        // Version header + what changed in this version.
        let header = NSMenuItem(title: "Visor \(AppInfo.version)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(whatsNewItem())
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Show / Hide Note", action: #selector(toggleNote), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let update = NSMenuItem(title: "Check for Updates…", action: #selector(updateApp), keyEquivalent: "")
        update.target = self
        menu.addItem(update)
        updateItem = update

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Visor", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item

        // Reflect update progress (after a click) in the menu item's title.
        updater.onStatus = { [weak self] text in
            DispatchQueue.main.async { self?.updateItem?.title = text }
        }
    }

    /// "What's New" → a submenu listing this version's changelog bullets, plus
    /// a link to the full release history.
    private func whatsNewItem() -> NSMenuItem {
        let item = NSMenuItem(title: "What's New", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let releases = AppInfo.releases
        if releases.isEmpty {
            sub.addItem(disabledItem("No release notes"))
        } else {
            // Each release is its own labeled group, separated — never merged.
            for (i, release) in releases.prefix(5).enumerated() {
                if i > 0 { sub.addItem(.separator()) }
                sub.addItem(headerItem(release.title))
                for b in release.bullets.prefix(12) { sub.addItem(disabledItem("    • \(b)")) }
            }
        }
        sub.addItem(.separator())
        let all = NSMenuItem(title: "View all releases…", action: #selector(openReleases), keyEquivalent: "")
        all.target = self
        sub.addItem(all)
        item.submenu = sub
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    /// A bold, disabled version heading that groups the bullets beneath it.
    private func headerItem(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        i.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)]
        )
        return i
    }

    /// The menu is fully offline: it shows the installed version and changelog
    /// from the app's own bundle. No network here — we only reach the network
    /// when the user explicitly clicks "Check for Updates…". Just reset the
    /// item label (e.g. after a previous check left a status on it).
    func menuWillOpen(_ menu: NSMenu) {
        guard !updater.isBusy else { return }
        updateItem?.title = "Check for Updates…"
    }

    @objc private func openReleases() {
        NSWorkspace.shared.open(URL(string: "https://github.com/sanketsriv22/visor/releases")!)
    }

    @objc private func toggleNote() { controller?.toggle() }
    @objc private func quitApp() { NSApp.terminate(nil) }

    @objc private func updateApp() {
        updater.checkThenUpdate()
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
