import SwiftUI

/// The Settings window's design system.
///
/// The panes grew up one at a time, each with its own font sizes, paddings and
/// header — so the window reads as a stack of forms rather than one designed
/// surface. These are the shared pieces: one type scale, one header, one
/// section card, one labelled row. Everything here is adaptive (light and
/// dark), because the Settings window follows the system, where the HUD is
/// always dark and uses `Design.Ink` instead.
extension Design {
    /// A type scale, so a title, a section label and a caption are the same
    /// size in every pane instead of a spread of raw `.system(size:)` literals.
    ///
    /// Set in Departure Mono — a bundled pixel face — as an experiment in giving
    /// Settings its own voice. It's a single weight, so hierarchy comes from
    /// size, not weight. `Font.custom` falls back to the system font cleanly if
    /// the face didn't register, so nothing breaks if it's missing.
    enum Text {
        static let face = "Departure Mono"
        /// The chosen UI font at a given size (any installed family — Appearance).
        static func f(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            VisorFont.current(size, weight: weight)
        }
        static var paneTitle: Font { f(18) }
        static var sectionLabel: Font { f(10.5) }
        static var rowTitle: Font { f(12.5) }
        static var body: Font { f(12) }
        static var caption: Font { f(11) }
        /// Numeric readouts stay monospaced whichever UI font is chosen.
        static var mono: Font {
            VisorFont.currentIsMono ? .custom(face, size: 11)
                                    : .system(size: 11, design: .monospaced)
        }
    }

    /// Settings-window surfaces — now the vintage theme (see `Design.Retro`),
    /// white on near-black with a dark-purple accent, everywhere.
    enum Panel {
        static let card = Design.Retro.panel
        static let cardStroke = Design.Retro.line
        static let radius = Design.Retro.radius
    }
}

/// A pane's title and one line of what it's for. Replaces the header that was
/// copy-pasted into six panes and had drifted in three.
struct SettingsHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title.uppercased())
                    .font(Design.Text.paneTitle)
                    .foregroundStyle(Design.Retro.text)
                    .tracking(1)
                // A run of blocks trailing the title, like a header rule drawn
                // in text.
                Text(String(repeating: "▪", count: 3))
                    .font(.custom(Design.Text.face, size: 10))
                    .foregroundStyle(Design.Retro.accent)
                Spacer(minLength: 0)
            }
            if let subtitle {
                Text(subtitle)
                    .font(Design.Text.caption)
                    .foregroundStyle(Design.Retro.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A grouped section: an optional label above a soft, hairlined card. What
/// every pane reached for with a bare `VStack` and a `Divider`, made one shape
/// so two sections that should look alike finally do.
struct SettingsCard<Content: View>: View {
    var label: String? = nil
    var spacing: CGFloat = 10
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let label {
                HStack(spacing: 6) {
                    Text("»").font(.custom(Design.Text.face, size: 10))
                        .foregroundStyle(Design.Retro.accent)
                    Text(label.uppercased())
                        .font(Design.Text.sectionLabel)
                        .tracking(1)
                        .foregroundStyle(Design.Retro.dim)
                }
            }
            VStack(alignment: .leading, spacing: spacing, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: Design.Panel.radius, style: .continuous)
                    .fill(Design.Panel.card))
                .overlay(RoundedRectangle(cornerRadius: Design.Panel.radius, style: .continuous)
                    .stroke(Design.Panel.cardStroke, lineWidth: 1))
        }
    }
}

/// A labelled row: title (and an optional line of explanation) on the left, a
/// control on the right, baseline-aligned — the toggle and slider rows every
/// pane rebuilt by hand, in one place.
struct SettingsRow<Control: View>: View {
    let title: String
    var caption: String? = nil
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Design.Text.rowTitle).foregroundStyle(Design.Retro.text)
                if let caption {
                    Text(caption)
                        .font(Design.Text.caption)
                        .foregroundStyle(Design.Retro.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control()
        }
    }
}

/// A slider with a right-aligned monospaced readout — the exact idiom the HUD
/// and Chess panes each rebuilt, factored so the readout column lines up.
struct SettingsSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var format: (Double) -> String

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(Design.Text.body).foregroundStyle(Design.Retro.dim)
                .frame(width: 78, alignment: .leading)
            Slider(value: $value, in: range).tint(Design.Retro.accent)
            Text(format(value))
                .font(Design.Text.mono)
                .foregroundStyle(Design.Retro.accent)
                .frame(width: 50, alignment: .trailing)
        }
    }
}

/// A one-line hint with the full explanation folded behind it — click to
/// reveal. Keeps a pane scannable while the detail stays one tap away, instead
/// of a paragraph of prose under every control.
struct InfoNote: View {
    let text: String
    var summary: String = "What this does"
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { open.toggle() } } label: {
                HStack(spacing: 5) {
                    RetroIcon(open ? Glyph.chevron : "▸", size: 9, color: Design.Retro.dim)
                    Text(summary).font(Design.Text.caption2).foregroundStyle(Design.Retro.dim)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                Text(text)
                    .font(Design.Text.caption2).foregroundStyle(Design.Retro.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
