import AppKit
import Sparkle
import SwiftUI

/// Main-actor isolated: every member touches AppKit or the notch controller,
/// which is itself main-actor state. The Apple Event handlers below are the
/// reason this is explicit — they arrive as plain @objc selectors with no
/// isolation of their own.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: NotchController?
    private var statusItem: NSStatusItem?
    private let updater = Updater()
    private let ai = AIRunner()
    private var sendToMenu: NSMenu?
    private var runModeMenu: NSMenu?
    private var runInFolderMenu: NSMenu?
    private var settingsWindow: NSWindow?
    /// Global shortcuts, held for the app's lifetime — releasing one
    /// unregisters it.
    private var hotKeys: [HotKey] = []
    /// Hold-a-modifier dictation. Off unless the user turns it on, because it
    /// is the only part of Visor that needs Accessibility.
    let pushToTalk = PushToTalk()

    /// Posted by a second launch so the already-running instance shows its note.
    private static let showNoteNotification = Notification.Name("com.kitalabs.visor.showNote")

    /// A beam URL / `.visor` file that arrived before the note controller existed
    /// (cold launch), held until `applicationDidFinishLaunching` hands it over.
    private var pendingBeamURL: URL?
    private var pendingNoteFiles: [URL] = []

    /// Register the URL + document handlers before launch finishes, so a
    /// `visor://` link or a double-clicked/AirDropped `.visor` file that *launches*
    /// the app is caught. `application(_:open:)` misses that first event for an
    /// accessory app; the kAEGetURL / kAEOpenDocuments Apple Events are reliable.
    func applicationWillFinishLaunching(_ notification: Notification) {
        let mgr = NSAppleEventManager.shared()
        mgr.setEventHandler(
            self, andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        mgr.setEventHandler(
            self, andSelector: #selector(handleOpenDocsEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenDocuments))
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: s), url.scheme == BeamLink.scheme else { return }
        // On cold launch this can fire before the controller is built — stash it
        // and let applicationDidFinishLaunching drain it once everything's ready.
        if let controller { controller.importBeam(from: url) } else { pendingBeamURL = url }
    }

    @objc private func handleOpenDocsEvent(_ event: NSAppleEventDescriptor, withReplyEvent: NSAppleEventDescriptor) {
        guard let list = event.paramDescriptor(forKeyword: keyDirectObject), list.numberOfItems > 0 else { return }
        for i in 1...list.numberOfItems {
            guard let item = list.atIndex(i),
                  let fileURL = item.coerce(toDescriptorType: typeFileURL)?.data,
                  let url = URL(dataRepresentation: fileURL, relativeTo: nil),
                  url.pathExtension.lowercased() == "visor" else { continue }
            if let controller { controller.importNoteFile(from: url) } else { pendingNoteFiles.append(url) }
        }
    }

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

        // Configure Firebase (anonymous auth + Firestore) for live note sharing.
        // No-op when no GoogleService-Info.plist is bundled, so dev builds run fine.
        #if canImport(FirebaseCore)
        FirebaseBootstrap.start()
        #endif

        // Before anything reads a key, so the one remaining prompt happens
        // once at launch rather than the first time a send needs it.
        Keychain.migrateToOpenAccess()

        setUpMainMenu()
        // The status item goes up before anything heavier runs. Its menu only
        // touches `controller` through optionals, and putting it first means a
        // failure further down degrades a feature instead of leaving the user
        // with a running app they have no way to reach.
        setUpStatusItem()
        controller = NotchController(startExpanded: args.contains("--expanded"), ai: ai)

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

        bindShortcuts()
        NotificationCenter.default.addObserver(
            forName: .visorShortcutsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.bindShortcuts()
        }

        pushToTalk.onHoldStart = { [weak self] in self?.controller?.beginDictation() }
        pushToTalk.onHoldEnd = { [weak self] in self?.controller?.endDictation() }
        pushToTalk.onToggle = { [weak self] in self?.controller?.toggleDictation() }
        for (i, key) in Shortcut.numberKeys.enumerated() {
            register("⌘⌃\(i + 1)", key, purpose: "Agent \(i + 1)",
                     modifiers: Shortcut.commandControl) { [weak self] in
                self?.controller?.selectAgent(i)
            }
        }

        // The notch asks for Settings (e.g. from "no agents yet").
        NotificationCenter.default.addObserver(
            forName: .visorOpenSettings, object: nil, queue: .main
        ) { [weak self] _ in
            self?.showSettings(focusing: nil)
        }

        // Tasks sent to a chat agent are answered in the notch itself.
        NotificationCenter.default.addObserver(
            forName: .visorRunInNotch, object: nil, queue: .main
        ) { [weak self] note in
            guard let prompt = note.userInfo?["prompt"] as? String else { return }
            self?.controller?.runInNotch(
                prompt: prompt, agentName: note.userInfo?["provider"] as? String)
        }

        // A send against an agent with no key stored opens Settings instead of
        // leaving a warning under the user's tasks.
        NotificationCenter.default.addObserver(
            forName: .visorProviderNeedsKey, object: nil, queue: .main
        ) { [weak self] note in
            self?.showSettings(focusing: note.userInfo?["provider"] as? String)
        }

        if args.contains("--settings") { openSettings() }

        // A beam link / .visor file that launched the app arrived before the
        // controller existed.
        if let url = pendingBeamURL {
            pendingBeamURL = nil
            controller?.importBeam(from: url)
        }
        for url in pendingNoteFiles { controller?.importNoteFile(from: url) }
        pendingNoteFiles.removeAll()
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
        let icon = NSImage(named: "trefoilTemplate")
            ?? NSImage(named: "MenuBarIconTemplate")
            ?? NSImage(systemSymbolName: "checklist", accessibilityDescription: "Visor")
        icon?.isTemplate = true
        icon?.size = NSSize(width: 18, height: 18)
        item.button?.image = icon

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

        let update = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        update.target = updater.controller
        menu.addItem(update)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Visor", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    private func whatsNewItem() -> NSMenuItem {
        let item = NSMenuItem(title: "What's New", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if let latest = AppInfo.releases.first {
            for b in latest.bullets.prefix(6) { sub.addItem(disabledItem("• \(b)")) }
        } else {
            sub.addItem(disabledItem("No release notes"))
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

    /// The menu is fully offline: it shows the installed version and changelog
    /// from the app's own bundle. No network here — we only reach the network
    /// when the user explicitly clicks "Check for Updates…". Just reset the
    /// item label (e.g. after a previous check left a status on it).
    func menuWillOpen(_ menu: NSMenu) {
        rebuildSendToMenu()
        rebuildRunModeMenu()
        rebuildRunInFolderMenu()
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

    /// Bind every shortcut to whatever the user has chosen.
    ///
    /// Rebuilt from scratch each time rather than patched: releasing the old
    /// HotKey objects is what unregisters them, so dropping the array is both
    /// the simplest and the only correct way to change a binding.
    private func bindShortcuts() {
        hotKeys.removeAll()
        let settings = ShortcutSettings.shared
        for action in ShortcutSettings.Action.allCases {
            let chord = settings.chord(for: action)
            let handler: () -> Void = { [weak self] in
                guard let controller = self?.controller else { return }
                switch action {
                case .toggle:   controller.toggle()
                case .swapMode: controller.swapMode()
                case .hud:      controller.toggleHUD()
                case .dictate:  controller.toggleDictation()
                case .agent1:   controller.selectAgent(0)
                case .agent2:   controller.selectAgent(1)
                case .agent3:   controller.selectAgent(2)
                case .agent4:   controller.selectAgent(3)
                case .agent5:   controller.selectAgent(4)
                }
            }
            let hotKey = HotKey(keyCode: chord.keyCode, modifiers: chord.modifiers,
                                action: handler)
            if let hotKey { hotKeys.append(hotKey) }
            // Recorded either way: a combination another app already owns fails
            // to bind, and a silent failure is indistinguishable from a
            // shortcut that's bound and misbehaving.
            settings.markBound(action, bound: hotKey != nil)
            if hotKey == nil {
                NSLog("[Visor] Couldn't bind \(chord.display) — another app owns it.")
            }
        }
    }

    @objc private func openSettings() { showSettings(focusing: nil) }

    /// Show the Settings window, optionally scrolled to a specific agent (used
    /// when a send is blocked on a missing API key).
    private func showSettings(focusing provider: String?) {
        if let provider { SettingsFocus.shared.provider = provider }
        if settingsWindow == nil {
            // Settings needs a real window now: agents have names, models,
            // personas and keys, plus memory and MCP panes. Resizable, because
            // model ids and MCP commands are long.
            guard let controller else { return }
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 580),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Visor Settings"
            window.contentView = NSHostingView(
                rootView: SettingsView(ai: ai, chat: controller.chat, pushToTalk: pushToTalk))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true) // accessory app must activate to take focus
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleNote() { controller?.toggle() }
    @objc private func quitApp() { NSApp.terminate(nil) }

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
