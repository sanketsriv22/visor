import SwiftUI

/// The notch, taken all the way around the screen.
///
/// The first attempt only made the top edge taller, which is not what "the
/// whole edge" means. This runs the full perimeter: bars leave the notch in
/// both directions, travel the top, turn down the sides, and meet again at the
/// bottom centre — so the screen is framed by its own sound.
///
/// Everything else about dictation is deliberately small; the notch extension
/// exists precisely so speaking never puts a panel over your work. This is the
/// opposite on purpose, which is why it is a mode you switch on rather than
/// something you are given.
///
/// Drawn in a Canvas, not as views. A hundred and twenty bars redrawn at the
/// frame rate is a hundred and twenty view identities for SwiftUI to diff; the
/// same thing in one canvas is a hundred and twenty strokes.
struct EdgeVisualiser: View {
    @ObservedObject var spectrum: SpectrumAnalyser
    /// Kept clear so the hardware stays part of the picture.
    var notchWidth: CGFloat
    var visible: Bool

    /// How far a full-strength band reaches in from the edge.
    private static let depth: CGFloat = 78

    var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
        .opacity(visible ? 1 : 0)
        // Slower out than in, like everything else here.
        .animation(visible ? .easeOut(duration: 0.28) : .easeOut(duration: 0.5),
                   value: visible)
        .allowsHitTesting(false)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let bands = spectrum.bands
        guard !bands.isEmpty else { return }

        // Half the perimeter, from the notch's edge round to the bottom centre.
        let half = (size.width - notchWidth) / 2 + size.height + size.width / 2
        let slot = half / CGFloat(bands.count)

        for (index, value) in bands.enumerated() {
            let distance = (CGFloat(index) + 0.5) * slot
            let hue = 0.72 - Double(index) / Double(bands.count) * 0.72
            let reach = Self.depth * CGFloat(max(0, min(1, value)))
            guard reach > 1 else { continue }

            // Both ways round, so the two halves open outward from the notch
            // together and meet at the bottom.
            for mirrored in [false, true] {
                let (point, normal) = place(distance: distance, size: size,
                                            mirrored: mirrored)
                var path = Path()
                path.move(to: point)
                path.addLine(to: CGPoint(x: point.x + normal.x * reach,
                                         y: point.y + normal.y * reach))

                // A wide, faint pass under a narrow bright one: the glow is
                // what makes it look lit rather than printed.
                context.stroke(path,
                               with: .color(Color(hue: hue, saturation: 0.9,
                                                  brightness: 1, opacity: 0.18)),
                               style: StrokeStyle(lineWidth: slot * 1.6, lineCap: .round))
                context.stroke(path,
                               with: .linearGradient(
                                Gradient(colors: [
                                    Color(hue: hue, saturation: 0.55, brightness: 1),
                                    Color(hue: hue, saturation: 1, brightness: 0.85),
                                ]),
                                startPoint: point,
                                endPoint: CGPoint(x: point.x + normal.x * reach,
                                                  y: point.y + normal.y * reach)),
                               style: StrokeStyle(lineWidth: slot * 0.66, lineCap: .round))
            }
        }
    }

    /// Where `distance` along the perimeter lands, and which way is inward.
    ///
    /// Walks the edges in order — the rest of the top, then the side, then the
    /// bottom back towards the middle — because a bar has to know which wall it
    /// is standing on to know which way to grow.
    private func place(distance: CGFloat, size: CGSize,
                       mirrored: Bool) -> (CGPoint, CGPoint) {
        let topRun = (size.width - notchWidth) / 2
        let sideRun = size.height
        var point: CGPoint
        var normal: CGPoint

        if distance <= topRun {
            point = CGPoint(x: size.width / 2 + notchWidth / 2 + distance, y: 0)
            normal = CGPoint(x: 0, y: 1)
        } else if distance <= topRun + sideRun {
            point = CGPoint(x: size.width, y: distance - topRun)
            normal = CGPoint(x: -1, y: 0)
        } else {
            let along = distance - topRun - sideRun
            point = CGPoint(x: size.width - along, y: size.height)
            normal = CGPoint(x: 0, y: -1)
        }

        if mirrored {
            point.x = size.width - point.x
            normal.x = -normal.x
        }
        return (point, normal)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.colorScheme, .dark)
    }
}
