import AppKit
import Foundation

/// New builds arrive while you're using the app — sometimes mid-dictation,
/// and a kill-and-replace lost the words. So the installer no longer
/// kills anything: it stages the new app and leaves a note. This watches
/// for the note, waits until nothing is in flight (no dictation, no live
/// conversation, no computer-use run), then asks — Install now, or Not
/// now — and only on Install swaps the bundle and relaunches.
///
/// The note is `~/Library/Application Support/Visor/update-ready.json`:
/// `{"path": "/tmp/visor-staged/Visor.app", "build": "470"}`. The answer
/// is written to `update-result` (`installed`, `declined`) for the
/// installer script to read.
@MainActor
final class UpdateInstaller: ObservableObject {
    static let shared = UpdateInstaller()

    /// Whether something would be lost by relaunching right now.
    var isBusy: () -> Bool = { false }

    /// A build staged and waiting — after Not now, the menu-bar panel
    /// offers it until it's installed. Cleared on install.
    @Published private(set) var staged: (path: String, build: String)? = nil

    private var timer: Timer?
    private var asking = false
    /// Declined this launch: the panel's row is the way in until the app
    /// next starts, when it asks once more.
    private var declinedBuild: String?

    private static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Visor")
    static let noteURL = dir.appendingPathComponent("update-ready.json")
    static let resultURL = dir.appendingPathComponent("update-result")

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    private func check() {
        guard !asking, let data = try? Data(contentsOf: Self.noteURL),
              let note = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let path = note["path"] else { return }
        let build = note["build"] ?? "?"
        guard FileManager.default.fileExists(atPath: path) else {
            try? FileManager.default.removeItem(at: Self.noteURL)
            staged = nil
            return
        }
        if staged?.build != build { staged = (path, build) }
        if build == declinedBuild { return }
        if isBusy() { return }          // ask when whatever is in flight has landed
        ask(path: path, build: build)
    }

    /// The menu-bar panel's row: install the staged build now. Asks first
    /// only if something is in flight.
    func installNow() {
        guard let staged else { return }
        if isBusy() {
            let alert = NSAlert()
            alert.messageText = "Something is still in flight"
            alert.informativeText = "A dictation, live conversation or computer-use run is running. Finish it, then install."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        install(path: staged.path, build: staged.build)
    }

    private func ask(path: String, build: String) {
        asking = true
        let alert = NSAlert()
        alert.messageText = "Visor build \(build) is ready"
        alert.informativeText = "Install it and relaunch now? Nothing is in flight. Not now keeps this build; \"Install build \(build)\" stays in the menu-bar panel, and you'll be asked once more the next time Visor starts."
        alert.addButton(withTitle: "Install now")
        alert.addButton(withTitle: "Not now")
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        let choice = alert.runModal()
        asking = false
        if choice == .alertFirstButtonReturn {
            install(path: path, build: build)
        } else {
            declinedBuild = build
            try? "declined".write(to: Self.resultURL, atomically: true, encoding: .utf8)
        }
    }

    private func install(path: String, build: String) {
        DictationLog.note("update: installing build \(build) from \(path)")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = [path, "/Applications/Visor.app"]
        // Replace in place: a running bundle keeps its open files, and the
        // new one is what launches next.
        try? FileManager.default.removeItem(atPath: "/Applications/Visor.app")
        try? ditto.run(); ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            DictationLog.note("update: ditto failed \(ditto.terminationStatus)")
            try? "failed".write(to: Self.resultURL, atomically: true, encoding: .utf8)
            return
        }
        let strip = Process()
        strip.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        strip.arguments = ["-dr", "com.apple.quarantine", "/Applications/Visor.app"]
        try? strip.run(); strip.waitUntilExit()
        try? FileManager.default.removeItem(at: Self.noteURL)
        staged = nil
        try? "installed".write(to: Self.resultURL, atomically: true, encoding: .utf8)
        // Relaunch after this process has gone, then go.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open -n /Applications/Visor.app"]
        try? relaunch.run()
        NSApp.terminate(nil)
    }
}
