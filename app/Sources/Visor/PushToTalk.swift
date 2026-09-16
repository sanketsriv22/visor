import AppKit
import ApplicationServices

/// Hold-a-modifier-to-talk, and double-tap-to-toggle, from anywhere.
///
/// This is the one feature that needs Accessibility permission, and it can't
/// avoid it: a bare modifier press produces no key equivalent, so Carbon's
/// `RegisterEventHotKey` (which every other Visor shortcut uses precisely
/// because it needs no permission) can't see it. Watching `.flagsChanged`
/// globally is the only way, and macOS gates that behind Accessibility.
///
/// So it's off by default. Turning it on is what triggers the prompt.
@MainActor
final class PushToTalk: ObservableObject {
    /// Which physical key arms dictation. Sides matter — people rest a thumb
    /// on the left modifiers constantly, so the right-hand ones and Fn are the
    /// only sane choices.
    enum Trigger: String, CaseIterable, Identifiable, Codable {
        case off
        case fn
        case rightOption, leftOption
        case rightCommand
        case rightControl, leftControl
        case rightShift
        case capsLock

        var id: String { rawValue }

        var title: String {
            switch self {
            case .off:           return "Off"
            case .fn:            return "Fn"
            case .rightOption:   return "Right ⌥"
            case .leftOption:    return "Left ⌥"
            case .rightCommand:  return "Right ⌘"
            case .rightControl:  return "Right ⌃"
            case .leftControl:   return "Left ⌃"
            case .rightShift:    return "Right ⇧"
            case .capsLock:      return "Caps Lock"
            }
        }

        /// Virtual key codes for the modifier keys themselves.
        var keyCode: UInt16? {
            switch self {
            case .off:          return nil
            case .capsLock:     return 57
            case .rightCommand: return 54
            case .leftControl:  return 59
            case .rightShift:   return 60
            case .rightOption:  return 61
            case .rightControl: return 62
            case .fn:           return 63
            case .leftOption:   return 58
            }
        }

        var flag: NSEvent.ModifierFlags? {
            switch self {
            case .off:                       return nil
            case .fn:                        return .function
            case .rightOption, .leftOption:  return .option
            case .rightCommand:              return .command
            case .rightControl, .leftControl: return .control
            case .rightShift:                return .shift
            case .capsLock:                  return .capsLock
            }
        }
    }

    @Published private(set) var trigger: Trigger = .off

    /// The key went down: open the microphone now, quietly, so nothing said
    /// in the first instant is lost — but show nothing yet. A modifier key
    /// gets tapped by accident constantly; a tap must be nothing, and a
    /// recording that showed and then vanished was a flash.
    var onArm: (() -> Void)?
    /// The press has lasted long enough to be a hold: show that we're
    /// listening. Recording has been running since `onArm`.
    var onHoldStart: (() -> Void)?
    /// End the recording (and transcribe).
    var onHoldEnd: (() -> Void)?
    /// The press turned out to be a tap: drop what the microphone caught.
    var onCancel: (() -> Void)?
    /// Double-tap: start or stop, and stay in that state.
    var onToggle: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?

    /// How long the key must be down before it counts as a hold rather than a
    /// tap. Short enough not to clip the start of speech, long enough that a
    /// double-tap's first press isn't mistaken for one.
    /// Long enough to tell a hold from a tap, short enough that the pill
    /// feels immediate. Audio is captured from the first instant regardless.
    let holdThreshold: TimeInterval = 0.18
    /// Two taps inside this window toggle recording on until the next press.
    let doubleTapWindow: TimeInterval = 0.4
    private var lastTapAt: Date?

    private var pressedAt: Date?
    private var holding = false
    /// A double-tap left the recording running; the next press ends it.
    private var toggledOn = false
    private var holdWork: DispatchWorkItem?
    /// A lone tap drops what it armed — but only once the double-tap window
    /// has passed, so a second tap carries on with the microphone and
    /// session the first one opened instead of tearing them down and
    /// reopening: that rebuild cost a double-tap most of half a second.
    private var tapWork: DispatchWorkItem?

    private let triggerKey = "visor.pushToTalkTrigger"
    /// Asked once per launch at most.
    ///
    /// AXIsProcessTrusted() keeps returning false after the user approves,
    /// because TCC binds the grant to the app's code signature and every
    /// ad-hoc build is a different signature. Re-prompting on that basis sends
    /// people to System Settings to approve something already listed there. A
    /// Developer ID signature fixes the underlying problem; until then, ask
    /// once and say what's happening.
    private var hasPrompted = false

    init() {
        if let raw = UserDefaults.standard.string(forKey: triggerKey),
           let saved = Trigger(rawValue: raw) {
            trigger = saved
        }
        if trigger != .off { startMonitoring() }
    }

    deinit {
        // Monitors outlive the object otherwise, and keep firing into nothing.
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }

    // MARK: - Permission

    var isTrusted: Bool { AXIsProcessTrusted() }

    /// Ask for Accessibility, showing the system prompt.
    func requestTrust() {
        NotificationCenter.default.post(name: .visorSystemPrompt, object: nil,
                                        userInfo: ["showing": true])
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        // The prompt is non-blocking; give it long enough to come forward.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            NotificationCenter.default.post(name: .visorSystemPrompt, object: nil,
                                            userInfo: ["showing": false])
        }
    }

    // MARK: - Configuration

    func setTrigger(_ trigger: Trigger) {
        self.trigger = trigger
        UserDefaults.standard.set(trigger.rawValue, forKey: triggerKey)
        stopMonitoring()
        guard trigger != .off else { return }
        if !isTrusted && !hasPrompted {
            hasPrompted = true
            requestTrust()
        }
        startMonitoring()
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        guard globalMonitor == nil else { return }
        // Global sees other apps; local sees our own window. An event goes to
        // one or the other, never both.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
            return event
        }
    }

    private func stopMonitoring() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        cancelHold()
    }

    private func handle(_ event: NSEvent) {
        guard let code = trigger.keyCode, let flag = trigger.flag,
              event.keyCode == code else { return }

        // flagsChanged doesn't say up or down; the flag's presence does.
        let isDown = event.modifierFlags.contains(flag)
        isDown ? pressed() : released()
    }

    /// The key went down. Internal so the state machine can be driven in
    /// tests without synthesising key events.
    func pressed() {
        guard pressedAt == nil else { return }   // autorepeat
        pressedAt = Date()
        if toggledOn { return }                  // this press ends it, on release
        if let tapWork {                         // second press of a double-tap: still armed
            tapWork.cancel()
            self.tapWork = nil
        } else {
            onArm?()                             // the microphone, now
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pressedAt != nil, !self.holding else { return }
            self.holding = true
            self.onHoldStart?()                  // the pill, once it's a hold
        }
        holdWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: work)
    }

    /// The key came up. `heldFor` can be given by tests.
    func released(heldFor override: TimeInterval? = nil) {
        guard pressedAt != nil else { return }   // a release we never saw the press of
        let heldFor = override ?? pressedAt.map { Date().timeIntervalSince($0) } ?? 0
        let wasHolding = holding || heldFor >= holdThreshold
        cancelHold()
        if toggledOn {
            toggledOn = false                    // tapped while toggled on: done
            lastTapAt = nil
            onHoldEnd?()
            return
        }
        if wasHolding {
            lastTapAt = nil
            onHoldEnd?()
            return
        }
        // A tap. Two inside the window toggle on — the second tap's arm
        // becomes the recording; one alone is nothing.
        let now = Date()
        if let last = lastTapAt, now.timeIntervalSince(last) <= doubleTapWindow {
            lastTapAt = nil
            toggledOn = true
            onHoldStart?()
        } else {
            lastTapAt = now
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.tapWork = nil
                self.onCancel?()
            }
            tapWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow, execute: work)
        }
    }

    /// Run the pending lone-tap cancel now instead of after the window.
    /// Internal for tests.
    func settleTap() {
        guard let tapWork else { return }
        tapWork.cancel()
        self.tapWork = nil
        onCancel?()
    }

    private func cancelHold() {
        tapWork?.cancel(); tapWork = nil
        holdWork?.cancel()
        holdWork = nil
        holding = false
        pressedAt = nil
    }
}
