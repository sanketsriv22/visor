import AppKit
import ApplicationServices

/// Puts dictated text into whatever app the user is actually working in.
///
/// Dictation is triggered by a global shortcut from anywhere, so the composer
/// is usually *not* where the words belong — if you're writing an email and
/// press the key, the transcript should land in the email. Sending everything
/// to Visor's own composer means finding it there later and moving it by hand,
/// which is most of the value gone.
///
/// This is the one place Visor synthesises input. It needs Accessibility, the
/// same grant push-to-talk uses, and it does nothing at all without it — never
/// silently, always saying so.
enum TextInsertion {
    /// Whether inserting into other apps is switched on. Off unless asked for:
    /// typing into whatever happens to be frontmost is not a reasonable
    /// default for something triggered by a hotkey.
    static var insertIntoFocusedApp: Bool {
        get { UserDefaults.standard.bool(forKey: "visor.insertDictation") }
        set { UserDefaults.standard.set(newValue, forKey: "visor.insertDictation") }
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// The app that will receive the text, for showing the user where it went.
    static var frontmostAppName: String? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return nil }
        return front.localizedName
    }

    /// Result of trying to place text somewhere other than Visor.
    enum Outcome {
        case inserted(app: String)
        /// On the clipboard, but not typed — paste it yourself.
        case copied
        case unavailable
    }

    /// Paste `text` into the frontmost application.
    ///
    /// Via the pasteboard and a synthetic ⌘V rather than typing the characters
    /// one at a time: synthesised keystrokes drop and reorder under load, and
    /// mangling someone's dictation is worse than not inserting it. The
    /// previous clipboard contents are restored afterwards, because quietly
    /// eating what someone had copied is its own small betrayal.
    @discardableResult
    static func insert(_ text: String) -> Outcome {
        guard insertIntoFocusedApp else { return .unavailable }
        guard let app = frontmostAppName else { return .unavailable }

        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard isTrusted, let source = CGEventSource(stateID: .combinedSessionState) else {
            // Copied at least — the user can paste it themselves, which is
            // strictly better than losing it.
            return .copied
        }

        let v: CGKeyCode = 9   // kVK_ANSI_V
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        else { return .copied }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        // Long enough for the paste to be read before the clipboard changes
        // back under it.
        if let previous {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let board = NSPasteboard.general
                // Only restore if nothing else has claimed the clipboard since.
                guard board.string(forType: .string) == text else { return }
                board.clearContents()
                board.setString(previous, forType: .string)
            }
        }
        return .inserted(app: app)
    }
}
