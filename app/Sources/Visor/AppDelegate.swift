import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: NotchController?
    private var statusItem: NSStatusItem?
    private let updater = Updater()
    private let ai = AIRunner()
    private var updateItem: NSMenuItem?
    private var sendToMenu: NSMenu?
    private var runModeMenu: NSMenu?
    private var runInFolderMenu: NSMenu?
    private var settingsWindow: NSWindow?
    private var clearStatusWork: DispatchWorkItem?
    private var hudPanel: NSPanel?

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

        setUpMainMenu()
        controller = NotchController(startExpanded: args.contains("--expanded"), ai: ai)
        setUpStatusItem()

        // Re-launching Visor (e.g. from Spotlight) brings the note down.
        DistributedNotificationCenter.default().addObserver(
            forName: Self.showNoteNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.controller?.showNote()
        }

        // Flush the note whenever the app loses focus — extra safety before an
        // accidental quit. (A normal quit also saves via applicationWillTerminate.)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.controller?.saveNow()
        }

        if args.contains("--settings") { openSettings() }
    }

    /// Install a main menu with a standard Edit menu so ⌘X/⌘C/⌘V/⌘A/⌘Z reach
    /// the focused text field. Without it, those shortcuts have nothing to
    /// dispatch them (the menu bar stays hidden — this is just for key equivalents).
    private func setUpMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Visor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
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

        // Settings: which agent the ✈ send buttons target.
        let sendTo = NSMenuItem(title: "Send tasks to", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sendToMenu = sub
        rebuildSendToMenu()
        sendTo.submenu = sub
        menu.addItem(sendTo)

        // Whether a send opens a Terminal window or runs in the background.
        let runIn = NSMenuItem(title: "Run agents in", action: nil, keyEquivalent: "")
        let runSub = NSMenu()
        runModeMenu = runSub
        rebuildRunModeMenu()
        runIn.submenu = runSub
        menu.addItem(runIn)

        // Which local repo/folder agents run in (the task is for that project).
        let folder = NSMenuItem(title: "Run in folder", action: nil, keyEquivalent: "")
        let folderSub = NSMenu()
        runInFolderMenu = folderSub
        rebuildRunInFolderMenu()
        folder.submenu = folderSub
        menu.addItem(folder)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

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

        // Reflect update progress both in the menu item AND beside the menu-bar
        // icon — the latter stays visible after the menu closes on click.
        updater.onStatus = { [weak self] text in
            DispatchQueue.main.async {
                self?.updateItem?.title = text
                self?.showUpdateProgress(text)
            }
        }
    }

    /// Show update progress as a small floating pill just below the menu-bar
    /// icon — more reliable than text in the menu bar (which the menu hides on
    /// click, and which gets lost on a crowded bar). In-progress messages end
    /// with "…" and stay up; a terminal message shows briefly then disappears.
    private func showUpdateProgress(_ text: String) {
        clearStatusWork?.cancel()
        let inProgress = text.hasSuffix("…")
        showHUD(text, inProgress: inProgress)
        guard !inProgress else { return }
        let work = DispatchWorkItem { [weak self] in self?.hudPanel?.orderOut(nil) }
        clearStatusWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func showHUD(_ text: String, inProgress: Bool) {
        let panel = ensureHUDPanel()
        let hosting = NSHostingView(rootView: UpdateHUDView(text: text, inProgress: inProgress))
        let size = hosting.fittingSize
        panel.contentView = hosting
        panel.setContentSize(size)
        panel.setFrameOrigin(hudOrigin(for: size))
        panel.orderFrontRegardless() // an accessory app must order it in without activating
    }

    private func ensureHUDPanel() -> NSPanel {
        if let p = hudPanel { return p }
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false // the pill draws its own shadow; a window shadow would box the clear panel
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        hudPanel = p
        return p
    }

    /// Centered just beneath the menu-bar icon; clamped on-screen so it stays
    /// visible even if the icon is tucked into a crowded bar's overflow.
    private func hudOrigin(for size: NSSize) -> NSPoint {
        let screen = statusItem?.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let full = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let vis = screen?.visibleFrame ?? full
        let iconFrame = statusItem?.button?.window?.frame
        var x = (iconFrame?.midX ?? full.maxX - 14) - size.width / 2
        x = min(max(x, vis.minX + 8), vis.maxX - size.width - 8)
        let topRef = iconFrame?.minY ?? (full.maxY - 24)
        return NSPoint(x: x, y: topRef - 6 - size.height)
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
        rebuildSendToMenu()
        rebuildRunModeMenu()
        rebuildRunInFolderMenu()
        if !updater.isBusy { updateItem?.title = "Check for Updates…" }
    }

    @objc private func openReleases() {
        NSWorkspace.shared.open(URL(string: "https://github.com/sanketsriv22/visor/releases")!)
    }

    /// Build the "Send tasks to" submenu: one item per agent, a checkmark on
    /// the active one, plus a link to edit the providers file.
    private func rebuildSendToMenu() {
        guard let sub = sendToMenu else { return }
        sub.removeAllItems()
        for provider in ai.providers {
            let it = NSMenuItem(title: provider.name, action: #selector(selectProvider(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = provider.name
            it.state = (provider.name == ai.defaultProviderName) ? .on : .off
            sub.addItem(it)
        }
        sub.addItem(.separator())
        let manage = NSMenuItem(title: "Manage agents…", action: #selector(openSettings), keyEquivalent: "")
        manage.target = self
        sub.addItem(manage)
    }

    @objc private func selectProvider(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        ai.setDefault(name)
        rebuildSendToMenu()
    }

    /// Build the "Run agents in" submenu: Terminal vs Background, checkmark on
    /// the active mode.
    private func rebuildRunModeMenu() {
        guard let sub = runModeMenu else { return }
        sub.removeAllItems()
        for mode in AIRunner.RunMode.allCases {
            let it = NSMenuItem(title: mode.menuTitle, action: #selector(selectRunMode(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = mode.rawValue
            it.state = (mode == ai.runMode) ? .on : .off
            sub.addItem(it)
        }
    }

    @objc private func selectRunMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = AIRunner.RunMode(rawValue: raw) else { return }
        ai.setRunMode(mode)
        rebuildRunModeMenu()
    }

    /// Build the "Run in folder" submenu: a header showing the active folder,
    /// the git repos under ~/repos to pick from, and a folder browser.
    private func rebuildRunInFolderMenu() {
        guard let sub = runInFolderMenu else { return }
        sub.removeAllItems()

        let header = NSMenuItem(title: "Current: \(ai.workDirDisplay)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        sub.addItem(header)
        sub.addItem(.separator())

        let active = ai.projectDir?.standardizedFileURL
        for repo in ai.availableRepos {
            let it = NSMenuItem(title: repo.lastPathComponent, action: #selector(selectRepo(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = repo.path
            it.state = (repo.standardizedFileURL == active) ? .on : .off
            sub.addItem(it)
        }
        if ai.availableRepos.isEmpty {
            sub.addItem(disabledItem("No git repos in ~/repos"))
        }

        sub.addItem(.separator())
        let choose = NSMenuItem(title: "Choose folder…", action: #selector(chooseRepo), keyEquivalent: "")
        choose.target = self
        sub.addItem(choose)
    }

    @objc private func selectRepo(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        ai.setProjectDir(URL(fileURLWithPath: path))
        rebuildRunInFolderMenu()
    }

    @objc private func chooseRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose the local repo/folder agents should work in."
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("repos")
        NSApp.activate(ignoringOtherApps: true) // accessory app must activate for a panel
        if panel.runModal() == .OK, let url = panel.url {
            ai.setProjectDir(url)
            rebuildRunInFolderMenu()
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 480),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Visor Settings"
            window.contentView = NSHostingView(rootView: SettingsView(ai: ai))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true) // accessory app must activate to take focus
        settingsWindow?.makeKeyAndOrderFront(nil)
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

/// The small floating pill shown beneath the menu-bar icon during an update.
private struct UpdateHUDView: View {
    let text: String
    let inProgress: Bool

    var body: some View {
        HStack(spacing: 8) {
            if inProgress {
                ProgressView().controlSize(.small).tint(.white)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Text(text).font(.system(size: 12, weight: .medium)).lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.black.opacity(0.9), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .fixedSize()
        .padding(12) // room for the shadow inside the (clear) panel bounds
        .environment(\.colorScheme, .dark)
    }
}
