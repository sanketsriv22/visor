import SwiftUI

/// A band of light around the whole screen that moves with your voice.
///
/// Earlier versions were a row of coloured spikes, which read as a hi-fi
/// display bolted to the edge of the desktop. This is a single continuous band
/// instead: it sits at the notch's own height all the way round, so at rest the
/// screen looks framed rather than decorated, and swells from there. The notch
/// stops being a hole in the display and becomes the thickest part of a border.
///
/// It also leans. A MacBook's microphones are an array, so speaking into the
/// left of the machine genuinely reaches the left one louder — the band answers
/// on that side. Nothing here invents the direction; with a single input
/// channel it stays even all the way round rather than guessing.
///
/// Drawn in a Canvas. Three hundred samples redrawn at the frame rate is three
/// hundred view identities for SwiftUI to diff, against three hundred strokes.
struct EdgeVisualiser: View {
    @ObservedObject var spectrum: SpectrumAnalyser
    /// Kept clear so the hardware stays part of the picture.
    var notchWidth: CGFloat
    /// The band's resting depth: the notch's own height, so the border and the
    /// hardware are the same thickness.
    var baseDepth: CGFloat
    var visible: Bool

    /// How far a full-strength crest reaches, as a multiple of the resting
    /// depth.
    private static let swell: CGFloat = 2.5
    /// Points sampled around the perimeter. Enough that the strokes overlap
    /// into one band rather than reading as teeth.
    private static let resolution = 320

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { canvas, size in
                draw(in: &canvas, size: size, now: context.date)
            }
        }
        .opacity(visible ? 1 : 0)
        .animation(visible ? .easeOut(duration: 0.3) : .easeOut(duration: 0.55),
                   value: visible)
        .allowsHitTesting(false)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, now: Date) {
        let bands = spectrum.bands
        guard !bands.isEmpty, size.width > 1 else { return }

        let half = (size.width - notchWidth) / 2 + size.height + size.width / 2
        let step = half / CGFloat(Self.resolution)
        let time = now.timeIntervalSinceReferenceDate
        // Where the voice is, across the screen: 0 is the left edge, 1 the right.
        let source = spectrum.stereo ? (Double(spectrum.balance) + 1) / 2 : 0.5

        for mirrored in [false, true] {
            for index in 0..<Self.resolution {
                let distance = (CGFloat(index) + 0.5) * step
                let (point, normal) = place(distance: distance, size: size,
                                            mirrored: mirrored)
                let along = Double(index) / Double(Self.resolution)

                let depth = baseDepth * (1 + (Self.swell - 1)
                    * CGFloat(height(along: along, point: point, size: size,
                                     bands: bands, time: time, source: source)))

                var path = Path()
                path.move(to: point)
                path.addLine(to: CGPoint(x: point.x + normal.x * depth,
                                         y: point.y + normal.y * depth))

                // Purple at the screen's edge, falling away to nothing inward,
                // so the band has an outer edge and no inner one — a glow
                // rather than a stripe with a border.
                context.stroke(path,
                               with: .linearGradient(
                                Gradient(stops: [
                                    .init(color: Color(red: 0.42, green: 0.13,
                                                       blue: 0.68, opacity: 0.95),
                                          location: 0),
                                    .init(color: Color(red: 0.28, green: 0.06,
                                                       blue: 0.52, opacity: 0.55),
                                          location: 0.45),
                                    .init(color: .black.opacity(0), location: 1),
                                ]),
                                startPoint: point,
                                endPoint: CGPoint(x: point.x + normal.x * depth,
                                                  y: point.y + normal.y * depth)),
                               style: StrokeStyle(lineWidth: step * 2.2, lineCap: .round))
            }
        }
    }

    /// How high the band stands at this point: 0 at rest, 1 at a full crest.
    ///
    /// Three things multiplied. The spectrum gives it shape, so the border
    /// answers to what you said rather than only to how loudly. A slow travelling
    /// sine keeps it breathing when a note is held, since a band that freezes at
    /// a steady volume looks broken. And the spatial weight tips the whole thing
    /// towards whichever side of the machine you're speaking into.
    private func height(along: Double, point: CGPoint, size: CGSize,
                        bands: [Float], time: TimeInterval, source: Double) -> Double {
        let band = bands[min(bands.count - 1, Int(along * Double(bands.count)))]
        let drift = 0.5 + 0.5 * sin(along * 9 - time * 2.4)
        let energy = Double(band) * (0.65 + 0.35 * drift)

        // Distance from the voice, measured across the screen. Everything moves
        // a little; the near side moves most.
        let x = Double(point.x / max(1, size.width))
        let nearness = 1 - min(1, abs(x - source))
        let weight = spectrum.stereo ? 0.35 + 0.95 * nearness : 1

        return max(0, min(1, energy * weight))
    }

    /// Where `distance` along the perimeter lands, and which way is inward.
    ///
    /// The edges are walked in order — the rest of the top, then the side, then
    /// the bottom back towards the middle — because a bar has to know which wall
    /// it stands on to know which way to grow.
    private func place(distance: CGFloat, size: CGSize,
                       mirrored: Bool) -> (CGPoint, CGPoint) {
        let topRun = (size.width - notchWidth) / 2
        var point: CGPoint
        var normal: CGPoint

        if distance <= topRun {
            point = CGPoint(x: size.width / 2 + notchWidth / 2 + distance, y: 0)
            normal = CGPoint(x: 0, y: 1)
        } else if distance <= topRun + size.height {
            point = CGPoint(x: size.width, y: distance - topRun)
            normal = CGPoint(x: -1, y: 0)
        } else {
            let along = distance - topRun - size.height
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

/// Hosts the band in its own window and keeps it in step with the microphone.
struct EdgeVisualiserHost: View {
    @ObservedObject var voice: VoiceInput
    @ObservedObject var ui: UIState

    var body: some View {
        EdgeVisualiser(spectrum: voice.spectrum,
                       notchWidth: ui.trueNotch.width,
                       baseDepth: max(28, ui.trueNotch.height),
                       visible: voice.state == .recording)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.colorScheme, .dark)
    }
}
