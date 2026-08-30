import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut.
///
/// Carbon's `RegisterEventHotKey` is the right API here despite its age. The
/// SwiftUI/AppKit alternative — a global `NSEvent` monitor — needs
/// Accessibility permission (a scary prompt to show for a notch toggle) and
/// still can't *consume* the keystroke, so the shortcut would also reach
/// whatever app is frontmost. `RegisterEventHotKey` needs no permission and
/// swallows the event.
///
/// The hot key stays registered for the lifetime of the instance; drop the
/// reference to unregister.
final class HotKey {
    /// Four-char code identifying our hot keys, so the shared Carbon handler
    /// can ignore anyone else's.
    private static let signature = OSType(0x5653524B)  // 'VSRK'

    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    private let id: UInt32
    private var ref: EventHotKeyRef?

    /// Register `action` on a key combination. `modifiers` uses Carbon's
    /// masks (`cmdKey`, `shiftKey`, …), not AppKit's. Returns nil if the
    /// combination is already claimed by another app — the caller decides
    /// whether that's worth surfacing.
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        Self.installHandlerIfNeeded()
        id = Self.nextID
        Self.nextID += 1

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode, modifiers,
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        self.ref = ref
        Self.actions[id] = action
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.actions[id] = nil
    }

    /// One Carbon handler serves every hot key; it fans out by id.
    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hkID = EventHotKeyID()
                let err = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hkID)
                guard err == noErr, hkID.signature == HotKey.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                // The Carbon callback isn't guaranteed to be on the main queue
                // and the action touches UI.
                DispatchQueue.main.async { HotKey.actions[hkID.id]?() }
                return noErr
            },
            1, &spec, nil, nil)
    }
}

/// Carbon virtual key codes and modifier masks Visor binds.
enum Shortcut {
    static let kKey = UInt32(kVK_ANSI_K)
    static let mKey = UInt32(kVK_ANSI_M)
    static let iKey = UInt32(kVK_ANSI_I)
    static let vKey = UInt32(kVK_ANSI_V)
    static let commandShift = UInt32(cmdKey | shiftKey)

    /// Control-Option-Command: what Visor's letter shortcuts use.
    ///
    /// Command-Shift collides constantly — macOS owns 3, 4 and 5 there for
    /// screenshots, and Command-Shift-V is Paste and Match Style in
    /// essentially every text app. ⌘⌥ is no better for
    /// a developer: ⌘⌥I is Web Inspector, ⌘⌥D toggles the Dock, ⌘⌥Esc is Force
    /// Quit. Three modifiers is more fingers, but almost nothing claims it, and
    /// a global hotkey *wins* over the app underneath — so a collision here
    /// doesn't inconvenience Visor, it breaks the app you're actually using.
    ///
    /// Left-Option specifically isn't available: RegisterEventHotKey's masks
    /// have no side, and distinguishing them would mean an NSEvent monitor and
    /// the Accessibility prompt that comes with it.
    static let hyper = UInt32(cmdKey | optionKey | controlKey)
    /// Agent shortcuts use this instead of ⌘⇧, which macOS owns for
    /// screenshots on 3, 4 and 5. RegisterEventHotKey happily takes them and
    /// shadows the system, so Visor was quietly breaking screenshots.
    static let commandOption = UInt32(cmdKey | optionKey)

    /// Number-row 1…5, for picking an agent. Carbon key codes aren't
    /// contiguous across the number row, so they're listed rather than derived.
    static let numberKeys: [UInt32] = [
        UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2), UInt32(kVK_ANSI_3),
        UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5),
    ]
}

/// What Visor asked for, and what it actually got.
///
/// RegisterEventHotKey returns nil when another app already owns a
/// combination, and a shortcut that silently does nothing is impossible to
/// tell from one that's bound but broken. Settings shows this list so the
/// answer is visible rather than guessed at.
@MainActor
final class ShortcutRegistry: ObservableObject {
    static let shared = ShortcutRegistry()

    struct Entry: Identifiable {
        let id = UUID()
        let label: String
        let purpose: String
        let bound: Bool
    }

    @Published private(set) var entries: [Entry] = []

    func record(_ label: String, purpose: String, bound: Bool) {
        entries.removeAll { $0.label == label }
        entries.append(Entry(label: label, purpose: purpose, bound: bound))
    }
}
