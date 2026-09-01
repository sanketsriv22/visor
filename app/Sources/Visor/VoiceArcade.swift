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
    static let columns = 40
    static let rows = 10

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

    /// Where the two cannons are — one patrolling each side, since the notch
    /// is between them and a single cannon crossing it would vanish behind it
    /// half the time.
    ///
    /// They used to be fixed at the middle of each side, and that was a bug
    /// with a shape nobody noticed for a while: the invaders spawn every
    /// fourth column and only drift two either way, so a fixed cannon could
    /// ever line up with exactly one of them. Eight of ten were unreachable
    /// by construction. Now they sweep, so every column comes under a gun
    /// eventually, and talking is about *when* you fire rather than a thing
    /// you do at a target that may never arrive.
    private var cannons: [Double] = [9, 30]
    private var cannonDirection: [Double] = [1, -1]
    /// Columns per second. A half is twenty wide; this crosses it in about
    /// three seconds, which is slow enough to be aimed at.
    private static let cannonSpeed: Double = 6.5
    private static let halves: [ClosedRange<Double>] = [1...18, 21...38]
    /// One column of invaders every three, so they read as a formation with
    /// gaps rather than a solid bar.
    private static let spacing = 4
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

    private func patrol(_ delta: Double) {
        for index in cannons.indices {
            cannons[index] += cannonDirection[index] * Self.cannonSpeed * delta
            let bounds = Self.halves[index]
            if cannons[index] <= bounds.lowerBound {
                cannons[index] = bounds.lowerBound
                cannonDirection[index] = 1
            } else if cannons[index] >= bounds.upperBound {
                cannons[index] = bounds.upperBound
                cannonDirection[index] = -1
            }
        }
    }

    func reset() {
        spawn()
        clearedFor = 0
        render()
    }

    /// One frame. `level` is the current 0…1 voice level.
    func tick(delta: Double, level: Float) {
        patrol(delta)
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
            formationRow += 1
            // They used to stop four rows short and hover there for as long as
            // you kept talking, which read as a stalemate rather than a game.
            // Now they land, and a fresh line starts from the top — the ones
            // that got through are simply gone.
            if formationRow >= Self.rows - 1 { spawn() }
        }
    }

    private func fire(_ delta: Double, level: Float) {
        sinceShot += delta
        // The threshold is what makes silence feel like losing ground: below it
        // nothing is fired and the formation keeps coming.
        guard level > 0.12, sinceShot >= Self.shotEvery / Double(max(0.2, level))
        else { return }
        sinceShot = 0
        for cannon in cannons {
            shots.append((column: Int(cannon.rounded()), y: Double(Self.rows - 2)))
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

        for position in cannons {
            let cannon = Int(position.rounded())
            guard cannon >= 0, cannon < Self.columns else { continue }
            next[cannon][Self.rows - 1] = 1
            if cannon > 0 { next[cannon - 1][Self.rows - 1] = 0.4 }
            if cannon + 1 < Self.columns { next[cannon + 1][Self.rows - 1] = 0.4 }
        }

        grid = next
    }
}


/// Pong you play by talking.
///
/// The after-transcription Pong plays itself; this one doesn't. Your paddle is
/// on the left and it only moves while you are speaking — in whichever
/// direction it was last going, until it meets the top or bottom and turns
/// round. Go quiet and it stops where it is. So keeping a rally alive is a
/// matter of talking at the right moments, which is a strange and rather good
/// thing to be doing with a dictation.
///
/// The other paddle is Visor's, and it is slightly slower than the ball. It
/// can be beaten; it mostly isn't.
///
/// Taller than the notch. Ten rows is enough for a formation to march across;
/// a rally in ten rows is a blur. The pill grows downward for this one.
@MainActor
final class VoicePong: ObservableObject {
    static let columns = 40
    static let rows = 18
    /// Points added below the notch for this game — eight more rows at the
    /// grid's cell pitch.
    static let extraHeight: CGFloat = 26

    @Published private(set) var grid: [[Double]] =
        Array(repeating: Array(repeating: 0, count: VoicePong.rows),
              count: VoicePong.columns)

    private var ball = (x: 20.0, y: 9.0, vx: -13.0, vy: 6.0)
    private var yours = (y: 7.0, direction: 1.0)
    private var theirs = 7.0
    /// After a miss the ball waits in the middle for a moment, so the point
    /// registers as a point rather than the ball simply appearing elsewhere.
    private var pause = 0.0
    private var servingTo: Double = -1

    private static let paddle = 4.0
    private static let yourSpeed = 13.0
    private static let theirSpeed = 10.5
    private static let serveSpeed = 13.0

    func reset() {
        ball = (20, 9, -Self.serveSpeed, 6)
        yours = (7, 1)
        theirs = 7
        pause = 0
        render()
    }

    func tick(delta: Double, level: Float) {
        // Your paddle: talk to move.
        if level > 0.12 {
            yours.y += yours.direction * Self.yourSpeed * delta
            let top = 0.0, bottom = Double(Self.rows) - Self.paddle
            if yours.y <= top { yours.y = top; yours.direction = 1 }
            if yours.y >= bottom { yours.y = bottom; yours.direction = -1 }
        }

        // Their paddle: chases the ball, not quite fast enough.
        let want = ball.y - Self.paddle / 2
        let step = Self.theirSpeed * delta
        if abs(want - theirs) <= step { theirs = want } else { theirs += want > theirs ? step : -step }
        theirs = min(max(theirs, 0), Double(Self.rows) - Self.paddle)

        if pause > 0 {
            pause -= delta
            if pause <= 0 { serve() }
            render()
            return
        }

        ball.x += ball.vx * delta
        ball.y += ball.vy * delta

        // Top and bottom.
        if ball.y < 0 { ball.y = 0; ball.vy = abs(ball.vy) }
        if ball.y > Double(Self.rows - 1) { ball.y = Double(Self.rows - 1); ball.vy = -abs(ball.vy) }

        // Your side.
        if ball.x <= 1, ball.vx < 0 {
            if ball.y >= yours.y - 0.5, ball.y <= yours.y + Self.paddle + 0.5 {
                ball.x = 1
                ball.vx = abs(ball.vx) * 1.04
                // Where on the paddle it struck steers it, which is the whole
                // of what makes Pong a game rather than a metronome.
                ball.vy += (ball.y - (yours.y + Self.paddle / 2)) * 3
            } else {
                servingTo = 1
                pause = 0.7
            }
        }
        // Their side.
        if ball.x >= Double(Self.columns - 2), ball.vx > 0 {
            if ball.y >= theirs - 0.5, ball.y <= theirs + Self.paddle + 0.5 {
                ball.x = Double(Self.columns - 2)
                ball.vx = -abs(ball.vx) * 1.04
                ball.vy += (ball.y - (theirs + Self.paddle / 2)) * 3
            } else {
                servingTo = -1
                pause = 0.7
            }
        }
        // Never so fast it tunnels through a paddle between ticks.
        ball.vx = min(max(ball.vx, -30), 30)
        ball.vy = min(max(ball.vy, -22), 22)

        render()
    }

    private func serve() {
        ball = (20, Double(Self.rows) / 2, servingTo * Self.serveSpeed,
                Double.random(in: -8...8))
    }

    private func render() {
        var next = Array(repeating: Array(repeating: 0.0, count: Self.rows),
                         count: Self.columns)
        func light(_ x: Int, _ y: Int, _ v: Double) {
            guard x >= 0, x < Self.columns, y >= 0, y < Self.rows else { return }
            next[x][y] = max(next[x][y], v)
        }
        for row in 0..<Int(Self.paddle) {
            light(0, Int(yours.y.rounded()) + row, 1)
            light(Self.columns - 1, Int(theirs.rounded()) + row, 1)
        }
        if pause <= 0 {
            light(Int(ball.x.rounded()), Int(ball.y.rounded()), 1)
            // A short tail, so direction reads at a glance.
            light(Int((ball.x - ball.vx * 0.04).rounded()),
                  Int((ball.y - ball.vy * 0.04).rounded()), 0.35)
        }
        grid = next
    }
}
