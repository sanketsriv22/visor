import AppKit
import CoreGraphics

/// The hands for general computer use — synthesised pointer and keyboard input,
/// so the agent can act on whatever the user pointed it at. Enabled only while a
/// task the user typed and started is running, driven step by step by the model,
/// and stoppable at any moment; it is not a background automation.
///
/// Global CoreGraphics coordinates (top-left origin, points), the same space
/// `ChessScreen` reports captures in, so a point the model picks on the
/// screenshot maps straight to where the cursor goes. Each method is one
/// visible action, so the agent's log reads as a plain list of what happened.
enum DesktopActuator {
    private static var source: CGEventSource? {
        CGEventSource(stateID: .combinedSessionState)
    }

    /// Move the pointer to a global point and left-click.
    static func click(at point: CGPoint) {
        guard let source else { return }
        move(to: point, source: source)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: source, mouseType: type,
                    mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }

    /// A double-click — selects a word, opens an item.
    static func doubleClick(at point: CGPoint) {
        guard let source else { return }
        move(to: point, source: source)
        for _ in 0..<2 {
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                let e = CGEvent(mouseEventSource: source, mouseType: type,
                                mouseCursorPosition: point, mouseButton: .left)
                e?.setIntegerValueField(.mouseEventClickState, value: 2)
                e?.post(tap: .cghidEventTap)
            }
        }
    }

    /// Type a string via the unicode fast-path, so it works regardless of
    /// keyboard layout and for characters with no key of their own.
    static func type(_ text: String) {
        guard let source else { return }
        for scalar in text.unicodeScalars {
            var unit = UniChar(scalar.value > 0xFFFF ? 0x20 : scalar.value)
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                else { continue }
                e.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
                e.post(tap: .cghidEventTap)
            }
        }
    }

    /// Press a named key, optionally with modifiers ("return", "tab", "cmd+a").
    /// A closed set of names, so a hallucinated key does nothing rather than
    /// something surprising.
    static func key(_ name: String) {
        guard let source else { return }
        var flags: CGEventFlags = []
        var keyName = name.lowercased()
        for part in name.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd", "command", "⌘":       flags.insert(.maskCommand)
            case "shift", "⇧":                flags.insert(.maskShift)
            case "opt", "option", "alt", "⌥": flags.insert(.maskAlternate)
            case "ctrl", "control", "⌃":      flags.insert(.maskControl)
            default:                          keyName = part
            }
        }
        guard let code = Self.keyCodes[keyName] else { return }
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }

    /// Scroll vertically by a number of lines (negative scrolls content up).
    static func scroll(lines: Int) {
        guard let source else { return }
        CGEvent(scrollWheelEvent2Source: source, units: .line,
                wheelCount: 1, wheel1: Int32(lines), wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
    }

    private static func move(to point: CGPoint, source: CGEventSource) {
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    /// The named keys the agent is allowed to press — a closed set.
    private static let keyCodes: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51,
        "escape": 53, "esc": 53, "left": 123, "right": 124, "down": 125, "up": 126,
        "a": 0, "c": 8, "v": 9, "x": 7, "z": 6, "f": 3, "l": 37, "t": 17, "w": 13,
        "k": 40, "g": 5, "n": 45, "s": 1, "e": 14, "r": 15, "p": 35, "d": 2,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
    ]
}
