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

    /// Paste `text` into the app dictation started in.
    ///
    /// Via the pasteboard and a synthetic ⌘V rather than typing character by
    /// character: synthesised keystrokes drop and reorder under load, and
    /// mangling someone's dictation is worse than not inserting it.
    ///
    /// The text goes on the clipboard *first*, before any check that could
    /// fail. Every early return below used to leave the words nowhere at all —
    /// the setting being off didn't even copy them. Whatever else goes wrong,
    /// ⌘V now works.
    @MainActor
    @discardableResult
    static func insert(_ text: String) async -> Outcome {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        defer { captured = nil }

        guard insertIntoFocusedApp else {
            return .copied(reason: "typing into other apps is off in Settings")
        }
        guard let target else {
            return .copied(reason: "no other app was in front")
        }
        guard isTrusted else {
            requestTrust()
            return .copied(reason: "Visor needs Accessibility to type it")
        }

        // Focus may have moved to Visor while the transcript was in flight —
        // opening the notch to watch the level meter is enough to do it. Paste
        // without putting the original app back in front and the keystroke
        // goes to Visor, or to nothing.
        if !target.isActive {
            if #available(macOS 14.0, *) {
                target.activate()
            } else {
                target.activate(options: [])
            }
            // Activation is asynchronous, so wait for it rather than guessing a
            // delay: a fixed sleep is either a stall or a race, depending on
            // the machine. Bounded, because an app that won't come forward
            // shouldn't hang dictation — the clipboard already has the text.
            var waited = 0
            while !target.isActive && waited < 30 {
                try? await Task.sleep(nanoseconds: 20_000_000)
                waited += 1
            }
            guard target.isActive else {
                return .copied(reason: "\(name(of: target)) didn't come to the front")
            }
        }

        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return .copied(reason: "couldn't synthesise the keystroke")
        }
        let v: CGKeyCode = 9   // kVK_ANSI_V
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        else { return .copied(reason: "couldn't synthesise the keystroke") }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        // Long enough for the paste to be read before the clipboard changes
        // back under it. Quietly eating what someone had copied is its own
        // small betrayal.
        if let previous {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 700_000_000)
                let board = NSPasteboard.general
                // Only if nothing else has claimed the clipboard since.
                guard board.string(forType: .string) == text else { return }
                board.clearContents()
                board.setString(previous, forType: .string)
            }
        }
        return .inserted(app: name(of: target))
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
