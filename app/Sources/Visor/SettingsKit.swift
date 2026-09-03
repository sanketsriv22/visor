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
        static let paneTitle = Font.custom(face, size: 18)
        static let sectionLabel = Font.custom(face, size: 10.5)
        static let rowTitle = Font.custom(face, size: 12.5)
        static let body = Font.custom(face, size: 12)
        static let caption = Font.custom(face, size: 11)
        static let mono = Font.custom(face, size: 11)
    }

    /// Adaptive surfaces for the Settings window — the dark-only `Surface` ramp
    /// is for the HUD.
    enum Panel {
        static let card = Color.primary.opacity(0.04)
        static let cardStroke = Color.primary.opacity(0.08)
        static let radius: CGFloat = 12
    }
}

/// A pane's title and one line of what it's for. Replaces the header that was
/// copy-pasted into six panes and had drifted in three.
struct SettingsHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Design.Text.paneTitle)
            if let subtitle {
                Text(subtitle)
                    .font(Design.Text.caption)
                    .foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 8) {
            if let label {
                Text(label.uppercased())
                    .font(Design.Text.sectionLabel)
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
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
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Design.Text.rowTitle)
                if let caption {
                    Text(caption)
                        .font(Design.Text.caption)
                        .foregroundStyle(.secondary)
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
            Text(title).font(Design.Text.body).frame(width: 78, alignment: .leading)
            Slider(value: $value, in: range)
            Text(format(value))
                .font(Design.Text.mono)
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
    }
}
