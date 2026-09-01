import Foundation
import SwiftUI

/// What the notch shows while you talk, and while it thinks about what you
/// said.
///
/// These were hard-wired — invaders during, Pong after — and both are good,
/// which is exactly why they should be a choice: someone who likes one will
/// want the other, and a new game shouldn't have to replace an old one to get
/// in. Two slots, because the two moments are different. During recording
/// there is a voice level to drive something with; afterwards there isn't, and
/// what fits there is something that plays itself.
@MainActor
final class NotchVisuals: ObservableObject {
    static let shared = NotchVisuals()

    enum During: String, CaseIterable, Identifiable {
        case invaders, voicePong, pong
        var id: String { rawValue }
        var title: String {
            switch self {
            case .invaders:  return "Invaders — talking fires"
            case .voicePong: return "Pong — talking moves your paddle"
            case .pong:      return "Pong — plays itself"
            }
        }
    }

    enum After: String, CaseIterable, Identifiable {
        case pong, quiet
        var id: String { rawValue }
        var title: String {
            switch self {
            case .pong:  return "Pong"
            case .quiet: return "Nothing"
            }
        }
    }

    @Published var during: During {
        didSet { UserDefaults.standard.set(during.rawValue, forKey: "visor.notch.during") }
    }
    @Published var after: After {
        didSet { UserDefaults.standard.set(after.rawValue, forKey: "visor.notch.after") }
    }

    private init() {
        during = UserDefaults.standard.string(forKey: "visor.notch.during")
            .flatMap(During.init(rawValue:)) ?? .invaders
        after = UserDefaults.standard.string(forKey: "visor.notch.after")
            .flatMap(After.init(rawValue:)) ?? .pong
    }

    /// How much taller the listening pill gets, below the notch.
    ///
    /// Voice Pong wants room: ten rows is enough for a formation to march
    /// across but too tight for a rally to be anything but a blur. The other
    /// games were designed for the notch's own height and stay in it.
    var extraHeight: CGFloat { during == .voicePong ? VoicePong.extraHeight : 0 }
}
