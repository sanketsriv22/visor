import AppKit
import SwiftUI

/// The one place the app's visual constants live.
///
/// They were previously chosen per control: hover backgrounds at 0.06, 0.07 and
/// 0.08 white; corner radii of 3, 4, 5, 6, 7, 9, 10, 12, 14, 24 and 28;
/// secondary text at a different opacity in nearly every view; 1pt strokes
/// that are two pixels on every display the app runs on. Individually each is
/// defensible and none is noticeable, which is exactly the problem — the eye
/// reads the disagreement even when it can't name it.
///
/// Nothing here is novel. The point is that there is one of each, and that a
/// control's size is decided here rather than by whatever label happens to be
/// inside it. See docs/design-system.md for the rules these encode.
enum Design {
    // MARK: Studies

    /// Two expressions of the same system. `clarity` is the shipping
    /// direction: quiet, native, system type. `retro` keeps Visor's pixel
    /// identity louder — pixel-face labels, sharper corners — and exists so
    /// the two can be rendered side by side on identical content.
    enum Study: String {
        case clarity, retro
        static let key = "visor.study"
        static var current: Study {
            Study(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .clarity
        }
    }

    // MARK: Type

    /// Text roles. Sizes in points; every text in the product wears one of
    /// these. `hudScale` multiplies only the reading roles (body, secondary,
    /// caption) in the HUD — chrome never scales.
    enum Typography {
        static func display(_ scale: Double = 1) -> Font { .system(size: 20 * scale, weight: .semibold) }
        static func title(_ scale: Double = 1) -> Font { .system(size: 15 * scale, weight: .semibold) }
        static func heading(_ scale: Double = 1) -> Font { .system(size: 13.5 * scale, weight: .semibold) }
        static func body(_ scale: Double = 1) -> Font { .system(size: 13.5 * scale) }
        static func bodyMedium(_ scale: Double = 1) -> Font { .system(size: 13.5 * scale, weight: .medium) }
        static func secondary(_ scale: Double = 1) -> Font { .system(size: 12 * scale) }
        static func secondaryMedium(_ scale: Double = 1) -> Font { .system(size: 12 * scale, weight: .medium) }
        static func caption(_ scale: Double = 1) -> Font { .system(size: 11 * scale) }
        static func captionMedium(_ scale: Double = 1) -> Font { .system(size: 11 * scale, weight: .medium) }
        static func mono(_ scale: Double = 1) -> Font { .system(size: 12 * scale, design: .monospaced) }
        /// Section and panel labels. Uppercase, tracked. The retro study sets
        /// these in the pixel face; clarity keeps the system face.
        static var label: Font {
            Study.current == .retro ? .custom(Text.face, size: 10) : .system(size: 10.5, weight: .semibold)
        }
        static var labelTracking: CGFloat { Study.current == .retro ? 1.6 : 0.7 }
        /// Leading added between lines of body text.
        static let bodyLeading: CGFloat = 3
    }

    // MARK: Spacing

    /// One series, on a 4pt grid. Values off it are the reason two rows that
    /// should look identical don't quite.
    enum Space {
        static let hair: CGFloat = 2
        static let tight: CGFloat = 4
        static let snug: CGFloat = 6
        static let normal: CGFloat = 8
        static let roomy: CGFloat = 12
        static let loose: CGFloat = 16
        static let wide: CGFloat = 20
        static let section: CGFloat = 24
    }

    // MARK: Controls

    /// Control dimensions. A chip, a button and a round composer control
    /// are these sizes because the system says so, not because of what
    /// they contain.
    enum Metric {
        /// Chips and inline selectors.
        static let small: CGFloat = 24
        /// Header buttons, rows in a selector.
        static let regular: CGFloat = 28
        /// The composer's round controls.
        static let large: CGFloat = 32
        /// Symbol point sizes that sit optically centred in each.
        static let iconSmall: CGFloat = 11
        static let iconRegular: CGFloat = 13
        static let iconLarge: CGFloat = 15
        /// Minimum pointer target, whatever the glyph.
        static let target: CGFloat = 24
        /// Selector rows.
        static let row: CGFloat = 30
        /// Comfortable reading measure for long replies.
        static let readingWidth: CGFloat = 720
    }

    // MARK: Geometry

    /// Corner radii by the size of the thing being rounded. Nested corners
    /// follow the outer curve at the inset when the inset is small
    /// (inner = outer − inset); past 8pt of inset they use their own role.
    enum Radius {
        static var control: CGFloat { Study.current == .retro ? 4 : 8 }
        static var chip: CGFloat { Study.current == .retro ? 5 : 999 }
        static var popover: CGFloat { Study.current == .retro ? 6 : 12 }
        static var panel: CGFloat { Study.current == .retro ? 8 : 14 }
        static var composer: CGFloat { Study.current == .retro ? 8 : 16 }
        static var card: CGFloat { Study.current == .retro ? 10 : 18 }
        static let surface: CGFloat = 26
        /// Older name, kept while the sweep completes.
        static var pill: CGFloat { control }
    }

    // MARK: Strokes

    /// One device pixel, whatever the display, so a hairline is a hairline
    /// on Retina and doesn't turn into a 2px outline.
    enum Stroke {
        static var hairline: CGFloat {
            1 / (NSScreen.main?.backingScaleFactor ?? 2)
        }
        /// The edge of a raised surface on the card.
        static let edge = Color.white.opacity(0.10)
        /// The edge of a control that must read as one (composer, chips).
        static let control = Color.white.opacity(0.16)
        /// Divider inside a surface.
        static let divider = Color.white.opacity(0.07)
    }

    // MARK: Surfaces

    /// White overlays for state and level. One ramp, so a hovered row and a
    /// hovered button lift by the same amount. Three levels on the card:
    /// base (the black card), raised (composer, chips, rails), overlay
    /// (popovers, menus — opaque, see `Retro.bg`).
    enum Surface {
        static let raised = Color.white.opacity(0.06)
        static let raisedStrong = Color.white.opacity(0.09)
        static let hover = Color.white.opacity(0.07)
        static let press = Color.white.opacity(0.13)
        static let selected = Color.white.opacity(0.15)
        static let hairline = Color.white.opacity(0.07)
        /// The HUD's glass tint over its material.
        static let glassTint = Color.black.opacity(0.62)
        /// The HUD without transparency.
        static let glassOpaque = Color(red: 0.07, green: 0.07, blue: 0.09)
        /// A rail on the HUD.
        static let rail = Color.white.opacity(0.045)
    }

    // MARK: Ink

    /// Text weights by role rather than by number, so "secondary" means the
    /// same thing everywhere.
    enum Ink {
        static let primary = Color.white.opacity(0.92)
        static let secondary = Color.white.opacity(0.62)
        static let tertiary = Color.white.opacity(0.42)
        static let faint = Color.white.opacity(0.24)
        static let link = Color(red: 0.62, green: 0.72, blue: 1.0)
        /// Warnings and failures. The one non-accent colour on the card.
        static let warning = Color(red: 1.0, green: 0.62, blue: 0.24)
        static let destructive = Color(red: 1.0, green: 0.36, blue: 0.36)
    }

    // MARK: Motion

    /// Short enough to feel immediate, long enough not to snap.
    static let hover = Animation.easeOut(duration: 0.12)
    static let press = Animation.easeOut(duration: 0.07)

    /// Surface motion, gated on the system accessibility settings.
    ///
    /// Every animation that moves a surface goes through `animation(_:)`,
    /// which returns `nil` under Reduce Motion so the change lands in one
    /// frame. Read live rather than cached: the setting can change while the
    /// app runs. The presets are the whole vocabulary — a new animation
    /// picks one rather than inventing a fifth curve.
    enum Motion {
        static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        static var reducedTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
        static func animation(_ animation: Animation) -> Animation? { reduced ? nil : animation }

        /// Control feedback: hover, press, selection.
        static let quick = Animation.easeOut(duration: 0.12)
        /// Content changes: composer growth, popover presentation, rows.
        static let standard = Animation.easeOut(duration: 0.2)
        /// The card opening, closing and changing face.
        static let surface = Animation.spring(response: 0.34, dampingFraction: 0.95)
        /// The HUD unfolding from the notch.
        static let hud = Animation.spring(response: 0.52, dampingFraction: 0.86)
    }
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
                RoundedRectangle(cornerRadius: radius, style: .continuous)
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
/// — its background would sit under theirs and read as a double edge. This
/// gives them the same give, and nothing else.
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

// MARK: - Shared pieces

/// A square icon button at one of the three control sizes. The header's
/// buttons, the code block's copy, the HUD's collapse — one component, so
/// their targets, icon sizes and feedback agree.
struct IconButton: View {
    let symbol: String
    var size: CGFloat = Design.Metric.regular
    var tint: Color = Design.Ink.secondary
    var active = false
    var help: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.visor(active: active, radius: size >= Design.Metric.large ? size / 2 : Design.Radius.control))
        .focusable(false)
        .help(help)
    }

    private var iconSize: CGFloat {
        if size < Design.Metric.regular { return Design.Metric.iconSmall }
        if size < Design.Metric.large { return Design.Metric.iconRegular }
        return Design.Metric.iconLarge
    }
}

/// A section or panel label: uppercase, tracked, in the study's label face.
struct SectionLabel: View {
    let text: String
    var tint: Color = Design.Ink.tertiary

    init(_ text: String, tint: Color = Design.Ink.tertiary) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text.uppercased())
            .font(Design.Typography.label)
            .tracking(Design.Typography.labelTracking)
            .foregroundStyle(tint)
    }
}

/// A raised surface on the card: composer, chips, rails, approval cards.
/// One fill, one hairline, one radius — applied as a modifier so nothing
/// re-invents the combination.
struct RaisedSurface: ViewModifier {
    var radius: CGFloat
    var strong = false
    var stroke: Color = Design.Stroke.edge

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(strong ? Design.Surface.raisedStrong : Design.Surface.raised))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(stroke, lineWidth: Design.Stroke.hairline))
    }
}

extension View {
    func raised(_ radius: CGFloat = Design.Radius.control, strong: Bool = false,
                stroke: Color = Design.Stroke.edge) -> some View {
        modifier(RaisedSurface(radius: radius, strong: strong, stroke: stroke))
    }
}
