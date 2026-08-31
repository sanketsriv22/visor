import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A key combination, stored so the user's choice survives launches.
struct Chord: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    /// How it reads in the UI. Order follows Apple's: ⌃⌥⇧⌘.
    var display: String {
        var out = ""
        if modifiers & UInt32(controlKey) != 0 { out += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { out += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { out += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { out += "⌘" }
        return out + Self.name(for: keyCode)
    }

    /// Whether this is even bindable. A hotkey with no modifiers would fire
    /// while you were typing in any app.
    var isUsable: Bool {
        modifiers & UInt32(cmdKey | controlKey | optionKey) != 0
    }

    static func name(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"; case kVK_ANSI_B: return "B"; case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"; case kVK_ANSI_E: return "E"; case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"; case kVK_ANSI_H: return "H"; case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"; case kVK_ANSI_K: return "K"; case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"; case kVK_ANSI_N: return "N"; case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"; case kVK_ANSI_Q: return "Q"; case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"; case kVK_ANSI_T: return "T"; case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"; case kVK_ANSI_W: return "W"; case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"; case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"; case kVK_ANSI_1: return "1"; case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"; case kVK_ANSI_4: return "4"; case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"; case kVK_ANSI_7: return "7"; case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "Space"; case kVK_Return: return "↩"; case kVK_Escape: return "esc"
        case kVK_ANSI_Slash: return "/"; case kVK_ANSI_Period: return "."
        case kVK_ANSI_Comma: return ","; case kVK_ANSI_Backslash: return "\\"
        default: return "key \(keyCode)"
        }
    }

    /// Carbon modifier masks from an NSEvent's flags.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var out: UInt32 = 0
        if flags.contains(.command) { out |= UInt32(cmdKey) }
        if flags.contains(.control) { out |= UInt32(controlKey) }
        if flags.contains(.option)  { out |= UInt32(optionKey) }
        if flags.contains(.shift)   { out |= UInt32(shiftKey) }
        return out
    }
}

/// Every shortcut Visor binds, and what the user has chosen for it.
///
/// Defaults are a guess about someone else's machine, and a wrong guess here
/// doesn't inconvenience Visor — a global hotkey wins over whatever is in
/// front, so a collision breaks the app you were actually using. macOS's own
/// bindings can be designed around; the dozen apps you happen to have
/// installed cannot. So the answer isn't better defaults, it's letting you
/// change them.
@MainActor
final class ShortcutSettings: ObservableObject {
    static let shared = ShortcutSettings()

    enum Action: String, CaseIterable, Identifiable, Codable {
        case toggle, swapMode, hud, dictate
        case agent1, agent2, agent3, agent4, agent5

        var id: String { rawValue }

        var title: String {
            switch self {
            case .toggle:   return "Open or close the notch"
            case .swapMode: return "Swap notes and chat"
            case .hud:      return "Expand to the HUD"
            case .dictate:  return "Dictate"
            case .agent1:   return "Agent 1"
            case .agent2:   return "Agent 2"
            case .agent3:   return "Agent 3"
            case .agent4:   return "Agent 4"
            case .agent5:   return "Agent 5"
            }
        }

        /// Command-Control throughout: two modifiers, one family, and clear of
        /// what macOS reserves there (F, Space, Q and D).
        var fallback: Chord {
            let cmdCtrl = UInt32(cmdKey | controlKey)
            switch self {
            case .toggle:   return Chord(keyCode: UInt32(kVK_ANSI_K), modifiers: cmdCtrl)
            case .swapMode: return Chord(keyCode: UInt32(kVK_ANSI_I), modifiers: cmdCtrl)
            case .hud:      return Chord(keyCode: UInt32(kVK_ANSI_M), modifiers: cmdCtrl)
            case .dictate:  return Chord(keyCode: UInt32(kVK_ANSI_V), modifiers: cmdCtrl)
            case .agent1:   return Chord(keyCode: UInt32(kVK_ANSI_1), modifiers: cmdCtrl)
            case .agent2:   return Chord(keyCode: UInt32(kVK_ANSI_2), modifiers: cmdCtrl)
            case .agent3:   return Chord(keyCode: UInt32(kVK_ANSI_3), modifiers: cmdCtrl)
            case .agent4:   return Chord(keyCode: UInt32(kVK_ANSI_4), modifiers: cmdCtrl)
            case .agent5:   return Chord(keyCode: UInt32(kVK_ANSI_5), modifiers: cmdCtrl)
            }
        }
    }

    @Published private(set) var chords: [Action: Chord] = [:]
    /// Set when a chosen combination couldn't be bound, so Settings can say so
    /// against the row rather than leaving it looking fine.
    @Published private(set) var failed: Set<Action> = []

    private let key = "visor.shortcuts"

    private init() {
        var stored: [Action: Chord] = [:]
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: Chord].self, from: data) {
            for (raw, chord) in decoded {
                if let action = Action(rawValue: raw) { stored[action] = chord }
            }
        }
        for action in Action.allCases where stored[action] == nil {
            stored[action] = action.fallback
        }
        chords = stored
    }

    func chord(for action: Action) -> Chord {
        chords[action] ?? action.fallback
    }

    /// How a binding reads, for tooltips. Hard-coded hints went stale the
    /// moment shortcuts became editable, and a tooltip naming a key that does
    /// nothing is worse than a tooltip with no key in it.
    static func hint(_ action: Action) -> String {
        shared.chord(for: action).display
    }

    /// The binding for the nth agent slot, for the HUD's agent list.
    static func agentHint(_ index: Int) -> String {
        let slots: [Action] = [.agent1, .agent2, .agent3, .agent4, .agent5]
        guard slots.indices.contains(index) else { return "" }
        return hint(slots[index])
    }

    func set(_ chord: Chord, for action: Action) {
        chords[action] = chord
        save()
        NotificationCenter.default.post(name: .visorShortcutsChanged, object: nil)
    }

    func reset(_ action: Action) {
        set(action.fallback, for: action)
    }

    func markBound(_ action: Action, bound: Bool) {
        if bound { failed.remove(action) } else { failed.insert(action) }
    }

    /// Another action already using this combination, if any.
    func conflict(with chord: Chord, excluding action: Action) -> Action? {
        chords.first { $0.key != action && $0.value == chord }?.key
    }

    private func save() {
        let raw = Dictionary(uniqueKeysWithValues: chords.map { ($0.key.rawValue, $0.value) })
        guard let data = try? JSONEncoder().encode(raw) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

extension Notification.Name {
    /// Posted when a shortcut changes, so the app rebinds without a relaunch.
    static let visorShortcutsChanged = Notification.Name("visor.shortcutsChanged")
}

/// Click, press a combination, done.
struct ShortcutRecorder: View {
    let action: ShortcutSettings.Action
    @ObservedObject var settings = ShortcutSettings.shared

    @State private var recording = false
    @State private var monitor: Any?
    @State private var warning: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(action.title)
                .font(.caption)
                .frame(width: 150, alignment: .leading)

            Button(recording ? "Press keys…" : settings.chord(for: action).display) {
                recording ? stop() : start()
            }
            .font(.system(size: 11, design: .monospaced))
            .frame(width: 96)
            .foregroundStyle(recording ? Color.orange : .primary)

            if settings.failed.contains(action) {
                Label("in use by another app", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
            } else if let warning {
                Text(warning).font(.caption2).foregroundStyle(.orange)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2).foregroundStyle(.green)
            }

            Spacer(minLength: 0)

            Button("Reset") { settings.reset(action); warning = nil }
                .font(.caption)
                .buttonStyle(.borderless)
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        warning = nil
        recording = true
        // A local monitor is enough: Settings is a normal window and has focus
        // while you're recording, so this needs no Accessibility grant.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let chord = Chord(keyCode: UInt32(event.keyCode),
                              modifiers: Chord.carbonModifiers(from: event.modifierFlags))
            if event.keyCode == kVK_Escape && chord.modifiers == 0 {
                stop()
                return nil
            }
            guard chord.isUsable else {
                warning = "needs ⌘, ⌃ or ⌥"
                return nil
            }
            if let clash = settings.conflict(with: chord, excluding: action) {
                warning = "already \(clash.title.lowercased())"
                return nil
            }
            settings.set(chord, for: action)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
