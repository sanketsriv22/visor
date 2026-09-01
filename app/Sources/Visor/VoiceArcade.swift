import Foundation

/// The listening animation, simulated rather than drawn.
///
/// The chomper worked and was still only a character being pushed along by a
/// number. Nothing it did depended on what you had said a moment ago, so there
/// was no reason to keep watching it.
///
/// This has a state that your voice changes: invaders descend on their own, and
/// speaking is what shoots them. Go quiet and they gain on you; talk and they
/// clear. So the picture is a short account of the last few seconds rather than
/// a reading of the current instant — which is the thing a meter could never do
/// and the reason the arcade is worth borrowing from at all.
///
/// Ticked from the audio sampler at 50 Hz, so the simulation runs on the same
/// clock as the level that drives it, and both halves of the notch read one
/// grid — the formation spans the gap.
@MainActor
final class VoiceArcade: ObservableObject {
    static let columns = 28
    static let rows = 6

    /// Brightness per column, per row. What both pills draw.
    @Published private(set) var grid: [[Double]] =
        Array(repeating: Array(repeating: 0, count: VoiceArcade.rows),
              count: VoiceArcade.columns)

    /// Alive invaders, as grid columns, per formation row.
    private var alive: Set<Int> = []
    private var formationRow = 0
    private var drift = 0
    private var driftDirection = 1
    private var shots: [(column: Int, y: Double)] = []
    private var sinceStep: Double = 0
    private var sinceShot: Double = 0
    private var clearedFor: Double = 0

    /// Where the two cannons sit — the middle of each side, since the notch is
    /// between them and a single central cannon would be behind it.
    private static let cannons = [6, 21]
    /// One column of invaders every three, so they read as a formation with
    /// gaps rather than a solid bar.
    private static let spacing = 3
    private static let stepEvery: Double = 0.55
    private static let shotEvery: Double = 0.12
    private static let shotSpeed: Double = 14

    init() { spawn() }

    private func spawn() {
        alive = Set(stride(from: 1, to: Self.columns, by: Self.spacing))
        formationRow = 0
        drift = 0
        driftDirection = 1
        shots = []
    }

    func reset() {
        spawn()
        clearedFor = 0
        render()
    }

    /// One frame. `level` is the current 0…1 voice level.
    func tick(delta: Double, level: Float) {
        advanceFormation(delta)
        fire(delta, level: level)
        advanceShots(delta)
        render()
    }

    private func advanceFormation(_ delta: Double) {
        guard !alive.isEmpty else {
            // Beaten. A moment of empty sky, then they come back — this runs
            // for as long as someone is talking, so it cannot end.
            clearedFor += delta
            if clearedFor > 0.6 { spawn(); clearedFor = 0 }
            return
        }
        sinceStep += delta
        guard sinceStep >= Self.stepEvery else { return }
        sinceStep = 0
        // Side to side, and down a row at each turn: the march everyone knows.
        drift += driftDirection
        if abs(drift) >= 2 {
            driftDirection *= -1
            formationRow = min(formationRow + 1, Self.rows - 3)
        }
    }

    private func fire(_ delta: Double, level: Float) {
        sinceShot += delta
        // The threshold is what makes silence feel like losing ground: below it
        // nothing is fired and the formation keeps coming.
        guard level > 0.12, sinceShot >= Self.shotEvery / Double(max(0.2, level))
        else { return }
        sinceShot = 0
        for cannon in Self.cannons {
            shots.append((column: cannon, y: Double(Self.rows - 2)))
        }
    }

    private func advanceShots(_ delta: Double) {
        guard !shots.isEmpty else { return }
        var surviving: [(column: Int, y: Double)] = []
        for var shot in shots {
            shot.y -= Self.shotSpeed * delta
            guard shot.y > -1 else { continue }
            // A hit is a shot reaching the formation's row in a live column.
            let row = Int(shot.y.rounded())
            if row <= formationRow + 1, row >= formationRow {
                let target = shot.column - drift
                if alive.contains(target) {
                    alive.remove(target)
                    continue
                }
            }
            surviving.append(shot)
        }
        shots = surviving
    }

    private func render() {
        var next = Array(repeating: Array(repeating: 0.0, count: Self.rows),
                         count: Self.columns)

        for column in alive {
            let x = column + drift
            guard x >= 0, x < Self.columns else { continue }
            // Two rows tall, which is the least a thing can be and still look
            // like a creature rather than a dot.
            next[x][formationRow] = 1
            if formationRow + 1 < Self.rows { next[x][formationRow + 1] = 0.55 }
        }

        for shot in shots {
            let row = Int(shot.y.rounded())
            guard row >= 0, row < Self.rows,
                  shot.column >= 0, shot.column < Self.columns else { continue }
            next[shot.column][row] = max(next[shot.column][row], 0.9)
        }

        for cannon in Self.cannons where cannon < Self.columns {
            next[cannon][Self.rows - 1] = 1
            if cannon > 0 { next[cannon - 1][Self.rows - 1] = 0.4 }
            if cannon + 1 < Self.columns { next[cannon + 1][Self.rows - 1] = 0.4 }
        }

        grid = next
    }
}
