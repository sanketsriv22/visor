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

    /// Begin recording — on the key's first instant. Waiting to learn
    /// whether a press was a hold or a tap was a 280 ms delay on every
    /// dictation and clipped the first syllable; now a press always starts
    /// recording, and the release decides how it ends: let go after a
    /// hold and it transcribes; a tap leaves it running until the next tap.
    var onHoldStart: (() -> Void)?
    /// End the recording (and transcribe).
    var onHoldEnd: (() -> Void)?
    /// Double-tap: start or stop, and stay in that state.
    var onToggle: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?

    /// How long the key must be down before it counts as a hold rather than a
    /// tap. Short enough not to clip the start of speech, long enough that a
    /// double-tap's first press isn't mistaken for one.
    private let holdThreshold: TimeInterval = 0.28

    private var pressedAt: Date?
    private var holding = false
    /// A double-tap left the recording running; the next press ends it.
    private var toggledOn = false
    private var holdWork: DispatchWorkItem?

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

    private func pressed() {
        guard pressedAt == nil else { return }   // autorepeat
        pressedAt = Date()
        if toggledOn { return }                  // this press ends it, on release
        onHoldStart?()                           // recording starts now
    }

    private func released() {
        let heldFor = pressedAt.map { Date().timeIntervalSince($0) } ?? 0
        cancelHold()
        if toggledOn {
            // Tapped while toggled on: done.
            toggledOn = false
            onHoldEnd?()
        } else if heldFor >= holdThreshold {
            // Held: done when let go.
            onHoldEnd?()
        } else {
            // Tapped: keep recording until the next tap.
            toggledOn = true
        }
    }

    private func cancelHold() {
        holdWork?.cancel()
        holdWork = nil
        holding = false
        pressedAt = nil
    }
}
