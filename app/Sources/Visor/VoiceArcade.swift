import Foundation

/// The listening animation: your voice, on fire.
///
/// Five attempts came before this and four failed the same way. A scrolling
/// waveform draws a history, so one sound lingers for as long as the buffer
/// takes to cross. A chomper draws the present but is only a character pushed
/// along by a number. Space Invaders had a state worth watching and needed a
/// legible scene to show it, which forty columns of dots is still not.
///
/// So: not a game. The fire effect that every demo and half the shareware of
/// the early nineties opened with — the one thing of that era that was never a
/// picture *of* something, just a process, alive at any size and readable at a
/// glance because there is nothing to read.
///
/// It suits a voice better than a meter does. Each row is the average of three
/// below it, cooled slightly and nudged sideways at random, so heat rises,
/// spreads and gutters on its own. The voice sets what is burning at the
/// bottom: speak and the flames climb the notch, stop and they sink and go out.
/// The height is the level, but the *movement* is the fire's own, which is why
/// it looks alive during a pause instead of dead.
@MainActor
final class VoiceArcade: ObservableObject {
    static let columns = 40
    static let rows = 10

    /// Brightness per column, per row, top row first — what both pills draw.
    @Published private(set) var grid: [[Double]] =
        Array(repeating: Array(repeating: 0, count: VoiceArcade.rows),
              count: VoiceArcade.columns)

    /// Heat, indexed [column][row] with row 0 at the top, so the fire climbs
    /// towards index 0 the way it climbs the screen.
    private var heat: [[Double]] =
        Array(repeating: Array(repeating: 0, count: VoiceArcade.rows),
              count: VoiceArcade.columns)

    /// How much of the heat below survives the trip up one row. Under 1 or the
    /// fire never stops rising; too far under and it never leaves the floor.
    private static let cooling = 0.82
    /// Even in silence the embers keep moving. A grate that goes completely
    /// black looks broken rather than quiet.
    private static let embers = 0.16

    func reset() {
        heat = Array(repeating: Array(repeating: 0, count: Self.rows),
                     count: Self.columns)
        render()
    }

    /// One frame. `level` is the current 0…1 voice level.
    func tick(delta: Double, level: Float) {
        stoke(level: level)
        rise()
        render()
    }

    /// The bottom row is the fuel, and the voice is what feeds it. Random per
    /// column so the flame front is ragged rather than a rising bar.
    private func stoke(level: Float) {
        let strength = Self.embers + Double(max(0, min(1, level))) * (1 - Self.embers)
        for column in 0..<Self.columns {
            heat[column][Self.rows - 1] = strength * Double.random(in: 0.55...1)
        }
    }

    /// Each cell takes from the three below it and loses a little on the way,
    /// which is the whole algorithm. The sideways sampling is what makes flames
    /// lean and travel rather than stand in columns.
    private func rise() {
        for row in 0..<(Self.rows - 1) {
            for column in 0..<Self.columns {
                let below = row + 1
                let left = heat[max(0, column - 1)][below]
                let centre = heat[column][below]
                let right = heat[min(Self.columns - 1, column + 1)][below]
                // A random drift so the fire wanders instead of rising
                // symmetrically — the difference between flames and a graph.
                let drift = Double.random(in: -0.12...0.12)
                let value = (left + centre + right) / 3 * Self.cooling + drift
                heat[column][row] = max(0, min(1, value))
            }
        }
    }

    private func render() {
        // A touch of contrast, so the cool tops fade out rather than lingering
        // as a haze of half-lit dots.
        grid = heat.map { column in column.map { $0 * $0 } }
    }
}
