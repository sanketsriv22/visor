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
    static let commandShift = UInt32(cmdKey | shiftKey)

    /// Number-row 1…5, for picking an agent. Carbon key codes aren't
    /// contiguous across the number row, so they're listed rather than derived.
    static let numberKeys: [UInt32] = [
        UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2), UInt32(kVK_ANSI_3),
        UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5),
    ]
}
