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
        // The gallery's, then the games.
        case wave, mirror, bars, ripple, fire, comet, rain, pulse
        case invaders, voicePong, pong
        var id: String { rawValue }
        var title: String {
            switch self {
            case .invaders:  return "Invaders — talking fires"
            case .voicePong: return "Pong — talking moves your paddle"
            case .pong:      return "Pong — plays itself"
            default:         return gallery?.title ?? rawValue
            }
        }
        var gallery: NotchGallery.Live? { NotchGallery.Live(rawValue: rawValue) }
        var rightOnly: Bool { gallery?.sides == .right }
    }

    enum After: String, CaseIterable, Identifiable {
        case scanner, orbit, snake, ember, drizzle, pong, quiet
        var id: String { rawValue }
        var title: String {
            switch self {
            case .pong:  return "Pong — through the notch"
            default:     return gallery?.title ?? rawValue
            }
        }
        var gallery: NotchGallery.Idle? { NotchGallery.Idle(rawValue: rawValue) }
        var rightOnly: Bool { gallery?.sides == .right }
    }

    @Published var during: During {
        didSet { UserDefaults.standard.set(during.rawValue, forKey: "visor.notch.during") }
    }
    /// One-sided visuals drawn on both sides too, mirrored about the notch.
    @Published var bothSides: Bool {
        didSet { UserDefaults.standard.set(bothSides, forKey: "visor.notch.bothSides") }
    }
    /// The dots' colour.
    enum Palette: String, CaseIterable, Identifiable {
        case mono, rainbow
        var id: String { rawValue }
        var title: String { self == .mono ? "White" : "Rainbow" }
    }
    @Published var palette: Palette {
        didSet { UserDefaults.standard.set(palette.rawValue, forKey: "visor.notch.palette") }
    }
    @Published var after: After {
        didSet { UserDefaults.standard.set(after.rawValue, forKey: "visor.notch.after") }
    }

    private init() {
        during = UserDefaults.standard.string(forKey: "visor.notch.during")
            .flatMap(During.init(rawValue:)) ?? .invaders
        after = UserDefaults.standard.string(forKey: "visor.notch.after")
            .flatMap(After.init(rawValue:)) ?? .pong
        bothSides = UserDefaults.standard.bool(forKey: "visor.notch.bothSides")
        palette = UserDefaults.standard.string(forKey: "visor.notch.palette")
            .flatMap(Palette.init(rawValue:)) ?? .mono
    }

    /// The shape the notch takes while listening: whether there is a left
    /// pill, and how far the pills hang below the notch.
    ///
    /// This is the one value the window frame, the pills and the strip
    /// under the notch all read. It is snapshotted when a listening session
    /// begins (`beginSession`) and held until it ends, so nothing changes
    /// shape under the pills when recording turns into transcribing, and
    /// changing the setting mid-session takes effect next time. That
    /// invariant is tested (ListeningTests).
    struct Shape: Equatable {
        var leftPill: Bool
        var extraHeight: CGFloat

        /// The shape the current settings would give a new session.
        static func current(during: During, bothSides: Bool = false) -> Shape {
            Shape(leftPill: !during.rightOnly || bothSides,
                  // Voice Pong wants room: ten rows is enough for a formation
                  // to march across but too tight for a rally to be anything
                  // but a blur. Everything else stays in the notch's height.
                  extraHeight: during == .voicePong ? VoicePong.extraHeight : 0)
        }
    }

    /// The session in progress, or nil between sessions.
    @Published private(set) var session: Shape? = nil

    /// What the pills and the frame use right now: the session's shape
    /// while one is on, else what the settings would give.
    var active: Shape { session ?? Shape.current(during: during, bothSides: bothSides) }

    func beginSession() { session = Shape.current(during: during, bothSides: bothSides) }
    func endSession() { session = nil }

    var extraHeight: CGFloat { active.extraHeight }
    var rightOnly: Bool { !active.leftPill }
}
