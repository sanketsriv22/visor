import SwiftUI

/// The one place the app's visual constants live.
///
/// They were previously chosen per control: hover backgrounds at 0.06, 0.07 and
/// 0.08 white; corner radii of 4, 5, 6, 7, 9, 10 and 14; secondary text at a
/// different opacity in nearly every view. Individually each is defensible and
/// none is noticeable, which is exactly the problem — the eye reads the
/// disagreement even when it can't name it, and that reads as an interface
/// assembled rather than designed.
///
/// Nothing here is novel. The point is that there is one of each.
enum Design {
    /// Corner radii, by the size of the thing being rounded. A 20pt control and
    /// a 500pt panel can't share a radius and look related.
    enum Radius {
        static let control: CGFloat = 5
        static let pill: CGFloat = 7
        static let panel: CGFloat = 10
        static let card: CGFloat = 14
        static let surface: CGFloat = 26
    }

    /// Spacing, in one series. Values off it are the reason two rows that
    /// should look identical don't quite.
    enum Space {
        static let hair: CGFloat = 2
        static let tight: CGFloat = 4
        static let snug: CGFloat = 6
        static let normal: CGFloat = 8
        static let roomy: CGFloat = 12
        static let loose: CGFloat = 16
        static let section: CGFloat = 22
    }

    /// White overlays for state. One ramp, so a hovered row and a hovered
    /// button lift by the same amount.
    enum Surface {
        static let hover = Color.white.opacity(0.07)
        static let press = Color.white.opacity(0.13)
        static let selected = Color.white.opacity(0.15)
        static let hairline = Color.white.opacity(0.07)
        /// A resting surface — a chip or capsule that sits slightly proud of
        /// the card behind it, before anyone has touched it.
        static let raised = Color.white.opacity(0.06)
    }

    /// Text weights by role rather than by number, so "secondary" means the
    /// same thing everywhere.
    enum Ink {
        static let primary = Color.white.opacity(0.92)
        static let secondary = Color.white.opacity(0.6)
        static let tertiary = Color.white.opacity(0.38)
        static let faint = Color.white.opacity(0.22)
    }

    /// Short enough to feel immediate, long enough not to snap.
    static let hover = Animation.easeOut(duration: 0.11)
    static let press = Animation.easeOut(duration: 0.07)
}

/// A control that responds to being hovered and to being pressed.
///
/// `.buttonStyle(.plain)` — which nearly every button here used — gives no
/// press feedback whatsoever. The click works and nothing acknowledges it, and
/// that half-frame of silence is most of what "doesn't feel premium" actually
/// is. It's not a thing you notice; it's a thing you notice the absence of.
struct VisorControl: ButtonStyle {
    /// Shown as filled regardless of state — for a control that's currently on.
    var active = false
    /// Slightly inset background, for rows that span their container.
    var inset: CGFloat = 0
    var radius: CGFloat = Design.Radius.control

    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: radius)
                    .fill(fill(pressed: configuration.isPressed))
                    .padding(.horizontal, inset))
            // A pressed control gives slightly, which is the cheapest possible
            // way to say the click landed. Small enough not to be a bounce.
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Design.press, value: configuration.isPressed)
            .animation(Design.hover, value: hovering)
            .onHover { hovering = $0 }
    }

    private func fill(pressed: Bool) -> Color {
        if pressed { return Design.Surface.press }
        if hovering { return Design.Surface.hover }
        if active { return Design.Surface.selected }
        return .clear
    }
}

extension ButtonStyle where Self == VisorControl {
    static var visor: VisorControl { VisorControl() }
    static func visor(active: Bool = false, inset: CGFloat = 0,
                      radius: CGFloat = Design.Radius.control) -> VisorControl {
        VisorControl(active: active, inset: inset, radius: radius)
    }
}


/// Press feedback for a control that already draws its own background.
///
/// Chips, capsules and rows that carry their own fill can't take `VisorControl`
/// — its background would sit under theirs and read as a double edge. But they
/// were still on `.plain`, so they had hover and no press: the two halves of
/// the same gesture answered differently depending on which control you
/// touched. This gives them the same give, and nothing else.
struct VisorBareControl: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Design.press, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == VisorBareControl {
    static var visorBare: VisorBareControl { VisorBareControl() }
}
