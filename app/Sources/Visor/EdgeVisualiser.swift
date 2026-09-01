import SwiftUI

/// The notch, taken to the full width of the screen.
///
/// Everything else in this app is deliberately small — the notch extension
/// exists precisely so dictation doesn't throw a panel over your work. This is
/// the opposite on purpose, and it's opt-in for that reason: a mode you turn on
/// because you want the room to look like something is happening, not a default
/// that interrupts you fifty times a day.
///
/// It grows out of the notch rather than appearing around it. The bars are
/// mirrored about the centre so the two halves open outwards from the hardware,
/// which is the only arrangement that reads as the notch *becoming* this rather
/// than something else arriving on top of it.
struct EdgeVisualiser: View {
    @ObservedObject var spectrum: SpectrumAnalyser
    /// Width of the physical notch, kept clear so the hardware stays part of it.
    var notchWidth: CGFloat
    var visible: Bool

    /// Tall enough to have somewhere to dance, short enough to leave a screen
    /// underneath it.
    static let height: CGFloat = 88

    var body: some View {
        GeometryReader { geometry in
            let half = max(1, (geometry.size.width - notchWidth) / 2)
            HStack(spacing: 0) {
                bars(width: half, mirrored: true)
                Color.clear.frame(width: notchWidth)
                bars(width: half, mirrored: false)
            }
            .frame(width: geometry.size.width, height: Self.height, alignment: .top)
            .background(alignment: .top) {
                // The ground the bars stand on: black at the top edge, fading
                // out below, so the strip has no bottom border to notice.
                LinearGradient(
                    colors: [.black, .black.opacity(0.92), .black.opacity(0)],
                    startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.height)
            }
        }
        .frame(height: Self.height)
        .opacity(visible ? 1 : 0)
        // Slower out than in, like everything else here.
        .animation(visible ? .spring(response: 0.42, dampingFraction: 0.82)
                           : .easeOut(duration: 0.45), value: visible)
        .allowsHitTesting(false)
    }

    /// One half of the spectrum. The mirrored side runs high frequencies inward
    /// so both halves rise from the notch outward together.
    private func bars(width: CGFloat, mirrored: Bool) -> some View {
        let values = mirrored ? spectrum.bands.reversed().map { $0 } : spectrum.bands
        let count = max(1, values.count)
        let slot = width / CGFloat(count)

        return HStack(alignment: .top, spacing: slot * 0.28) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                let position = mirrored
                    ? Double(count - 1 - index) / Double(count)
                    : Double(index) / Double(count)
                Capsule()
                    .fill(gradient(at: position))
                    .frame(width: max(1, slot * 0.72),
                           height: max(2, Self.height * CGFloat(value) * 0.92))
                    .animation(.easeOut(duration: 0.06), value: value)
            }
        }
        .frame(width: width, alignment: .top)
    }

    /// Hue across the width rather than up each bar.
    ///
    /// Colouring by height is what a level meter does — green, amber, red for
    /// "how loud". Colouring by position says "which frequency", which is what
    /// this is actually showing, and it means the whole strip carries the
    /// gradient instead of every bar repeating the same three colours.
    private func gradient(at position: Double) -> LinearGradient {
        let hue = 0.72 - position * 0.72          // violet at the notch, red at the edges
        return LinearGradient(
            colors: [
                Color(hue: hue, saturation: 0.75, brightness: 1),
                Color(hue: max(0, hue - 0.06), saturation: 0.95, brightness: 0.78),
            ],
            startPoint: .top, endPoint: .bottom)
    }
}


/// Hosts the strip in its own window and keeps it in step with the microphone.
struct EdgeVisualiserHost: View {
    @ObservedObject var voice: VoiceInput
    @ObservedObject var ui: UIState

    var body: some View {
        EdgeVisualiser(spectrum: voice.spectrum,
                       notchWidth: ui.trueNotch.width,
                       visible: voice.state == .recording)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.colorScheme, .dark)
    }
}
