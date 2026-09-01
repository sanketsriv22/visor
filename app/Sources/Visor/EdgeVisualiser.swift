import SwiftUI

/// A dot matrix around the whole screen that moves with your voice.
///
/// Coloured spikes read as a hi-fi display bolted to the desktop's edge; a
/// continuous glow read as a smear. White dots on black is what the notch
/// already is, and they hold their shape at any height because each one is
/// either on or off.
///
/// It sits at the notch's own height all the way round, so at rest the screen
/// looks framed rather than decorated, and grows to two and a half times that.
/// The notch stops being a hole in the display and becomes the thickest part of
/// a border.
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
    /// Grid pitch, along the perimeter and inward from it. The same in both
    /// directions, or the dots stop being a matrix and become dashes.
    private static let pitch: CGFloat = 9
    private static let dot: CGFloat = 3.2

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
        let columns = max(1, Int(half / Self.pitch))
        let step = half / CGFloat(columns)
        let rows = max(2, Int(baseDepth * Self.swell / Self.pitch))
        let baseRows = max(1, Int(baseDepth / Self.pitch))
        let time = now.timeIntervalSinceReferenceDate
        let source = spectrum.stereo ? (Double(spectrum.balance) + 1) / 2 : 0.5

        // The black the dots stand on, following the wave.
        //
        // White dots floating over the desktop would be confetti. Backing them
        // with black is what makes this read as the notch itself stretched
        // around the screen, which was the idea — the notch is black with white
        // dots on it, and so is this. The backing follows the same height the
        // dots do, so the black undulates with them rather than sitting behind
        // them as a fixed frame.
        for mirrored in [false, true] {
            var edge = Path()
            var inner: [CGPoint] = []
            for index in 0...columns {
                let distance = CGFloat(index) * step
                let (point, normal) = place(distance: distance, size: size,
                                            mirrored: mirrored)
                if index == 0 { edge.move(to: point) } else { edge.addLine(to: point) }

                let along = Double(index) / Double(columns)
                let lift = height(along: along, point: point, size: size,
                                  bands: bands, time: time, source: source)
                let lit = min(rows, baseRows + Int((CGFloat(rows - baseRows)
                                                    * CGFloat(lift)).rounded()))
                let depth = CGFloat(lit) * Self.pitch
                inner.append(CGPoint(x: point.x + normal.x * depth,
                                     y: point.y + normal.y * depth))
            }
            for point in inner.reversed() { edge.addLine(to: point) }
            edge.closeSubpath()
            context.fill(edge, with: .color(.black.opacity(0.93)))
        }

        // One path per row rather than one per dot.
        //
        // Five thousand individual fills is a frame budget spent on function
        // calls; the same ellipses collected into a dozen paths is a dozen
        // fills. Grouping by row works because a row is exactly the set of dots
        // that share a colour — depth is what the fade runs on.
        var paths = Array(repeating: Path(), count: rows)

        for mirrored in [false, true] {
            for index in 0..<columns {
                let distance = (CGFloat(index) + 0.5) * step
                let (point, normal) = place(distance: distance, size: size,
                                            mirrored: mirrored)
                let along = Double(index) / Double(columns)
                let lift = height(along: along, point: point, size: size,
                                  bands: bands, time: time, source: source)
                // Resting depth plus whatever the voice adds.
                let lit = min(rows, baseRows + Int((CGFloat(rows - baseRows)
                                                    * CGFloat(lift)).rounded()))

                for row in 0..<lit {
                    let depth = (CGFloat(row) + 0.5) * Self.pitch
                    let centre = CGPoint(x: point.x + normal.x * depth,
                                         y: point.y + normal.y * depth)
                    paths[row].addEllipse(in: CGRect(
                        x: centre.x - Self.dot / 2, y: centre.y - Self.dot / 2,
                        width: Self.dot, height: Self.dot))
                }
            }
        }

        for (row, path) in paths.enumerated() where !path.isEmpty {
            context.fill(path, with: .color(colour(row: row, of: rows)))
        }
    }

    /// White, dimming with depth.
    ///
    /// Purple dots on black were a third thing, belonging to neither the notch
    /// nor the desktop. The notch is white on black and this is the notch, so it
    /// is white on black. The fade inward gives the band some depth without
    /// introducing a colour that has to be explained.
    private func colour(row: Int, of rows: Int) -> Color {
        let depth = Double(row) / Double(max(1, rows - 1))
        return .white.opacity(0.30 + 0.62 * pow(1 - depth, 1.2))
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
        // A light travelling ripple, not a disguise. It used to carry a third
        // of the height, which kept the border moving when nothing was being
        // said and made it look the same whatever you said.
        let drift = 0.5 + 0.5 * sin(along * 11 - time * 3.2)
        let energy = Double(band) * (0.85 + 0.15 * drift)

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
