import AppKit
import ApplicationServices

/// Puts dictated text into whatever app the user is actually working in.
///
/// Dictation fires from a global shortcut, so the composer is usually *not*
/// where the words belong — if you're mid-sentence in an editor and press the
/// key, the transcript should land in the editor. Anything else means going to
/// find it and moving it by hand, which is most of the point gone.
///
/// This is the one place Visor synthesises input, and it needs Accessibility.
/// What it must never do is fail quietly: the words were spoken, and the user
/// is entitled to know where they went.
enum TextInsertion {
    private static let key = "visor.insertDictation"
    /// Separate from the value, so "never set" and "deliberately off" aren't
    /// the same thing — a default can be changed later, an explicit choice
    /// can't be overridden.
    private static let decidedKey = "visor.insertDictation.set"

    /// Whether transcripts are typed into the app in front.
    ///
    /// On by default now. It was off, on the reasoning that typing into
    /// whatever happens to be frontmost isn't a thing to do unasked — but the
    /// reasoning was about a feature nobody had asked for, and this one is
    /// asked for by definition: you pressed a dictation key while looking at
    /// an editor. Off by default meant the shortcut appeared to do nothing,
    /// and the transcript had to be dug out of the voice log.
    static var insertIntoFocusedApp: Bool {
        get {
            let defaults = UserDefaults.standard
            guard defaults.bool(forKey: decidedKey) else { return true }
            return defaults.bool(forKey: key)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            UserDefaults.standard.set(true, forKey: decidedKey)
        }
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// The app dictation started in.
    ///
    /// Captured when recording begins rather than read when the transcript
    /// arrives. Transcription is a network round trip and the tidy-up pass is
    /// another, so by the time there are words to insert, seconds have passed —
    /// and if opening the notch or any dialog moved focus in between, reading
    /// "frontmost" then gives the wrong app, or Visor itself, which the old
    /// code treated as nowhere to paste and dropped the text.
    private static var captured: NSRunningApplication?
    /// Asked for at most once a launch. A permission dialog every time you
    /// speak would be its own bug.
    private static var promptedForTrust = false

    /// Remember where the user is typing. Call when recording starts.
    static func captureTarget() {
        let front = NSWorkspace.shared.frontmostApplication
        guard front?.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        captured = front
    }

    /// Where the text should go: where dictation began, or failing that
    /// whatever is in front now.
    private static var target: NSRunningApplication? {
        if let captured, !captured.isTerminated { return captured }
        let front = NSWorkspace.shared.frontmostApplication
        guard front?.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        return front
    }

    /// What happened, so the caller can say so.
    enum Outcome {
        case inserted(app: String)
        /// On the clipboard, not typed. Says why.
        case copied(reason: String?)

        /// A line for the user, or nil when it worked and needs no comment.
        var notice: String? {
            switch self {
            case .inserted: return nil
            case .copied(let reason):
                guard let reason else { return "Copied to the clipboard" }
                return "Copied to the clipboard — \(reason)"
            }
        }
    }

    /// Put `text` where the caret is, in the app dictation started in.
    ///
    /// Nothing here goes through the clipboard on the way. Dictation should
    /// land at the caret and be finished — needing to press ⌘V afterwards is
    /// the feature not working. And the clipboard belongs to the user: they
    /// may have something in it they are part-way through using, and borrowing
    /// it for 700ms is still borrowing it. Something pasted in that window is
    /// the wrong thing, and no amount of putting it back afterwards helps.
    ///
    /// So the clipboard is touched in exactly one case: both insertion routes
    /// failed and the alternative is losing the words. Then it's a rescue, not
    /// a mechanism, and the user is told it happened.
    @MainActor
    @discardableResult
    static func insert(_ text: String) async -> Outcome {
        defer { captured = nil }

        guard insertIntoFocusedApp else {
            return stash(text, reason: "typing into other apps is off in Settings")
        }
        guard let target else {
            return stash(text, reason: "no other app was in front")
        }
        guard isTrusted else {
            requestTrust()
            return stash(text, reason: "Visor needs Accessibility to type it")
        }

        // Focus may have moved to Visor while the transcript was in flight —
        // opening the notch to watch the level meter is enough to do it.
        // Without putting the original app back in front, the text goes to
        // Visor, or to nothing.
        if !target.isActive {
            if #available(macOS 14.0, *) {
                target.activate()
            } else {
                target.activate(options: [])
            }
            // Activation is asynchronous, so wait for it rather than guessing a
            // delay: a fixed sleep is either a stall or a race, depending on
            // the machine. Bounded, because an app that won't come forward
            // shouldn't hang dictation.
            var waited = 0
            while !target.isActive && waited < 30 {
                try? await Task.sleep(nanoseconds: 20_000_000)
                waited += 1
            }
            guard target.isActive else {
                return stash(text, reason: "\(name(of: target)) didn't come to the front")
            }
        }

        // Two ways in, neither of which is ⌘V.
        //
        // Synthesising ⌘V assumes the target app maps ⌘V to paste. Terminals
        // routinely don't — the report was dictating into cmux and getting
        // nothing, in a terminal where ⌘C already didn't copy. The keystroke
        // was posted, the app had no such binding, and the words went nowhere
        // with everything apparently working.
        //
        // Accessibility first: it writes into the focused field directly, at
        // the caret, so it can't be misrouted by a keybinding. Where that
        // isn't offered — most terminals — the text is typed as characters,
        // which is what a terminal is built to receive.
        if insertViaAccessibility(text) { return .inserted(app: name(of: target)) }
        if typeOut(text) { return .inserted(app: name(of: target)) }
        return stash(text, reason: "\(name(of: target)) wouldn't take the text")
    }

    /// Last resort: the words survive on the clipboard, and the user is told.
    ///
    /// Only ever reached when they can't be inserted — losing a transcript
    /// outright is the one outcome worse than borrowing the clipboard.
    private static func stash(_ text: String, reason: String) -> Outcome {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        return .copied(reason: reason)
    }

    /// Hand the text to the focused field through the Accessibility API.
    ///
    /// Replaces the selection, which with an ordinary caret is an insert. Only
    /// attempted where the element says it's settable — writing to something
    /// that isn't leaves the app in a state neither of us intended.
    private static func insertViaAccessibility(_ text: String) -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success,
              let raw = focused
        else { return false }
        let element = raw as! AXUIElement

        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString,
                                             &settable) == .success,
              settable.boolValue
        else { return false }

        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                            text as CFTypeRef) == .success
    }

    /// Type the text as characters.
    ///
    /// Unicode is attached to the event rather than translated into key codes,
    /// so it doesn't depend on the keyboard layout and can't be scrambled into
    /// a different character on a non-US layout.
    ///
    /// Newlines become spaces. In a terminal a newline is not a line break,
    /// it's Return — it would run whatever is on the line. Dictation should
    /// never be able to submit something on the user's behalf.
    private static func typeOut(_ text: String) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        let flat = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let units = Array(flat.utf16)
        guard !units.isEmpty else { return false }

        var index = 0
        while index < units.count {
            // Short chunks: the event's unicode payload is small, and a long
            // string silently truncates rather than erroring.
            let end = min(index + 16, units.count)
            var chunk = Array(units[index..<end])
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { return false }
            down.flags = []
            up.flags = []
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            index = end
            // Enough for the receiving app to keep up. Without it, fast
            // consecutive events arrive out of order in some apps.
            usleep(3_000)
        }
        return true
    }

    private static func name(of app: NSRunningApplication) -> String {
        app.localizedName ?? "the app in front"
    }

    /// Ask for Accessibility, once, with the system's own dialog.
    private static func requestTrust() {
        guard !promptedForTrust else { return }
        promptedForTrust = true
        // The notch panel sits above the menu bar, so it has to step aside for
        // a system dialog — the same dance the microphone prompt does.
        NotificationCenter.default.post(name: .visorSystemPrompt, object: nil,
                                        userInfo: ["showing": true])
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            NotificationCenter.default.post(name: .visorSystemPrompt, object: nil,
                                            userInfo: ["showing": false])
        }
    }
}
