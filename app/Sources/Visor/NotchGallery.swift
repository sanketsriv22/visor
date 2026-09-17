import SwiftUI

/// The notch's visuals, all drawn in the same dot matrix, all generated —
/// nothing shipped but code. Two families: ones your voice drives while
/// you talk, and ones that play themselves while it transcribes. Each
/// says whether it wants one side of the notch or both.
///
/// Every visual is a pure function from (time, levels, side) to a grid of
/// 20 columns × 10 rows of 0…1 — so they can't drift between the two
/// pills, survive being interrupted at any frame, and cost nothing to
/// keep.
enum NotchGallery {
    static let columns = 20
    static let rows = 10

    /// Which pills a visual occupies.
    enum Sides { case right, both }

    // MARK: While you talk

    enum Live: String, CaseIterable, Identifiable {
        case wave, mirror, bars, ripple, fire, comet, rain, pulse
        case spectrum, warp, helix, lightning, swarm, needle, lissajous, spectrogram, fireworks, bounce, plasma
        var id: String { rawValue }
        var title: String {
            switch self {
            case .wave:        return "Wave — your voice, flowing right"
            case .mirror:      return "Mirror — the wave both ways"
            case .bars:        return "Bars — an equaliser, to the right"
            case .ripple:      return "Ripple — rings out from the notch"
            case .fire:        return "Fire — burns as you talk"
            case .comet:       return "Comet — races when you do"
            case .rain:        return "Rain — heavier when you talk"
            case .pulse:       return "Pulse — a heartbeat trace"
            case .spectrum:    return "Spectrum — an analyser with peak caps, both ways"
            case .warp:        return "Warp — stars streak out of the notch"
            case .helix:       return "Helix — a double helix that twists wider"
            case .lightning:   return "Lightning — loud syllables crack out of the notch"
            case .swarm:       return "Swarm — dots that scatter when you talk"
            case .needle:      return "Needle — a VU meter"
            case .lissajous:   return "Lissajous — an oscilloscope figure"
            case .spectrogram: return "Spectrogram — a waterfall of your voice"
            case .fireworks:   return "Fireworks — every loud word launches one"
            case .bounce:      return "Bounce — balls jump higher as you talk"
            case .plasma:      return "Plasma — glows up with your voice"
            }
        }
        var sides: Sides {
            switch self {
            case .wave, .bars, .comet, .pulse, .helix, .needle, .lissajous, .spectrogram: return .right
            case .mirror, .ripple, .fire, .rain, .spectrum, .warp, .lightning, .swarm, .fireworks, .bounce, .plasma: return .both
            }
        }
        var warm: Bool { self == .fire }
    }

    // MARK: While it transcribes

    enum Idle: String, CaseIterable, Identifiable {
        case scanner, orbit, snake, ember, drizzle, breathe, bouncer, life, figure, sea, quiet
        var id: String { rawValue }
        var title: String {
            switch self {
            case .scanner: return "Scanner — sweeps through the notch"
            case .orbit:   return "Orbit — a dot circling, to the right"
            case .snake:   return "Snake — runs the edges"
            case .ember:   return "Ember — a low fire"
            case .drizzle: return "Drizzle — light rain"
            case .breathe: return "Breathe — a glow that swells from the notch"
            case .bouncer: return "Bouncer — a block that bounces off the edges"
            case .life:    return "Life — Conway's game, reseeded now and then"
            case .figure:  return "Figure — a slowly turning Lissajous"
            case .sea:     return "Sea — swell rolling under the notch"
            case .quiet:   return "Nothing"
            }
        }
        var sides: Sides {
            switch self {
            case .orbit, .figure: return .right
            default: return .both
            }
        }
        var warm: Bool { self == .ember }
    }

    // MARK: Grids

    /// Both-sided visuals draw one 40-wide board; the pill takes its half.
    static func slice(_ board: [[Double]], side: ListeningPill.Side) -> [[Double]] {
        let start = side == .trailing ? columns : 0
        return (0..<columns).map { i in
            let c = start + i
            return c < board.count ? board[c] : Array(repeating: 0, count: rows)
        }
    }

    static func empty(_ width: Int = columns) -> [[Double]] {
        Array(repeating: Array(repeating: 0, count: rows), count: width)
    }

    /// A column lit from the middle out to `level`, with a soft shoulder.
    static func spine(_ level: Double) -> [Double] {
        let half = Double(rows) / 2
        let reach = 0.5 + max(0, min(1, level)) * (half - 0.5)
        return (0..<rows).map { row in
            let d = abs(Double(row) + 0.5 - half)
            if d <= reach { return 1 }
            if d <= reach + 1 { return 0.35 }
            return 0
        }
    }

    /// A column lit from the bottom up to `level`.
    static func bar(_ level: Double, peak: Bool = true) -> [Double] {
        let lit = Int((max(0, min(1, level)) * Double(rows)).rounded())
        return (0..<rows).map { row in
            let fromBottom = rows - row
            if fromBottom <= lit { return peak && fromBottom == lit ? 1 : 0.7 }
            return 0
        }
    }

    // MARK: Live visuals

    static func live(_ kind: Live, levels: [Float], t: Double, side: ListeningPill.Side) -> [[Double]] {
        // A one-sided visual on the left pill is the right pill in a mirror:
        // it grows out of the notch on both sides.
        if kind.sides == .right, side == .leading {
            return live(kind, levels: levels, t: t, side: .trailing).reversed()
        }
        let recent = levels.suffix(columns).map(Double.init)   // oldest first
        let newest = recent.last ?? 0
        switch kind {
        case .wave:
            let flow = Array(recent.reversed())               // newest at the notch
            return (0..<columns).map { spine($0 < flow.count ? flow[$0] : 0) }
        case .mirror:
            let flow = Array(recent.reversed())
            let right = (0..<columns).map { spine($0 < flow.count ? flow[$0] : 0) }
            return side == .trailing ? right : right.reversed()
        case .bars:
            // Six bands, each a differently smoothed read of the level, so
            // they move like a spectrum rather than in lockstep.
            let n = recent.count
            var out = empty()
            for band in 0..<6 {
                let window = 1 + band * 2
                let slice = recent.suffix(min(n, window))
                let v = slice.isEmpty ? 0 : slice.reduce(0, +) / Double(slice.count)
                let wobble = 0.85 + 0.15 * sin(t * (3 + Double(band)) + Double(band))
                let col = bar(v * wobble)
                for k in 0..<2 where band * 3 + k + 1 < columns { out[band * 3 + k + 1] = col }
            }
            return out
        case .ripple:
            // Each strong syllable launches a ring from the notch; rings run
            // outward through both pills and fade.
            var board = empty(columns * 2)
            let spikes = recent.enumerated().filter { $0.element > 0.55 }
            let cx = Double(columns), cy = Double(rows) / 2
            for (age, _) in spikes.map({ (recent.count - 1 - $0.offset, $0.element) }) {
                let r = 1.5 + Double(age) * 0.85
                let alpha = max(0, 1 - Double(age) / Double(columns))
                guard alpha > 0 else { continue }
                for c in 0..<(columns * 2) {
                    for row in 0..<rows {
                        let dx = Double(c) + 0.5 - cx
                        let dy = (Double(row) + 0.5 - cy) * 2.2          // cells are wider than tall on screen
                        let dist = (dx * dx + dy * dy).squareRoot()
                        let d = abs(dist - r)
                        guard d < 1.2 else { continue }
                        board[c][row] = max(board[c][row], alpha * (1 - d / 1.2))
                    }
                }
            }
            return slice(board, side: side)
        case .fire:
            return slice(fire(t: t, height: 0.35 + newest * 0.65, width: columns * 2), side: side)
        case .comet:
            let speed = 6 + newest * 30
            let head = (t * speed).truncatingRemainder(dividingBy: Double(columns + 8)) - 4
            let row = Int((sin(t * 2.2) + 1) / 2 * Double(rows - 1))
            var out = empty()
            for c in 0..<columns {
                let behind = head - Double(c)
                guard behind >= 0, behind < 7 else { continue }
                out[c][row] = max(0.08, 1 - behind / 7)
            }
            return out
        case .rain:
            return slice(rain(t: t, density: 0.12 + newest * 0.5, width: columns * 2), side: side)
        case .pulse:
            // An ECG trace scrolling right; the spike is your level.
            var out = empty()
            let phase = t * 14
            for c in 0..<columns {
                let x = (phase - Double(c)).truncatingRemainder(dividingBy: 20)
                let mid = Double(rows) / 2
                var y = mid
                let amp = 0.3 + (c < recent.count ? recent.reversed()[c] : 0) * 0.7
                if x > 6, x < 7 { y = mid + 1.5 * amp }
                else if x >= 7, x < 8.5 { y = mid - 4.5 * amp }
                else if x >= 8.5, x < 9.5 { y = mid + 2.5 * amp }
                else if x >= 11, x < 13 { y = mid - 1.0 * amp }
                let r = min(rows - 1, max(0, Int(y.rounded())))
                out[c][r] = 1
                if r > 0 { out[c][r - 1] = max(out[c][r - 1], 0.25) }
            }
            return out
        case .spectrum:    return slice(spectrum(recent, t: t), side: side)
        case .warp:        return slice(warp(newest, t: t), side: side)
        case .helix:       return helix(recent, t: t)
        case .lightning:   return slice(lightning(recent, t: t), side: side)
        case .swarm:       return slice(swarm(newest, t: t), side: side)
        case .needle:      return needle(recent)
        case .lissajous:   return lissajous(newest, t: t)
        case .spectrogram: return spectrogram(recent, t: t)
        case .fireworks:   return slice(fireworks(recent), side: side)
        case .bounce:      return slice(bounce(newest, t: t), side: side)
        case .plasma:      return slice(plasma(newest, t: t, width: columns * 2), side: side)
        }
    }

    // MARK: Live visuals, the second batch

    private static let mid = Double(rows) / 2
    /// Cells are about twice as wide as tall on screen; distances in rows
    /// are scaled so circles read as circles.
    private static let aspect = 0.45

    private static func plot(_ board: inout [[Double]], _ x: Double, _ y: Double, _ v: Double) {
        let c = Int(x.rounded()), r = Int(y.rounded())
        guard c >= 0, c < board.count, r >= 0, r < rows, v > 0 else { return }
        board[c][r] = max(board[c][r], min(1, v))
    }

    /// Ten bands a side, mirrored about the notch, each a differently
    /// smoothed read of the level; a cap rides the recent maximum and
    /// settles after it.
    private static func spectrum(_ recent: [Double], t: Double) -> [[Double]] {
        var board = empty(columns * 2)
        let n = recent.count
        for band in 0..<10 {
            let window = 1 + band
            let tail = recent.suffix(min(n, window))
            let v = tail.isEmpty ? 0 : tail.reduce(0, +) / Double(tail.count)
            let weight = 0.6 + 0.4 * hash(band, 7, 0)
            let wobble = 0.9 + 0.1 * sin(t * (2.5 + Double(band) * 0.7) + Double(band))
            let cap = (recent.suffix(min(n, 14)).max() ?? 0) * weight
            var col = bar(v * weight * wobble, peak: false)
            let capRow = rows - Int((max(0, min(1, cap)) * Double(rows)).rounded())
            if capRow >= 0, capRow < rows { col[capRow] = 1 }
            let right = columns + band * 2, left = columns - 1 - band * 2
            board[right] = col; board[right + 1 < columns * 2 ? right + 1 : right] = col
            board[left] = col; if left - 1 >= 0 { board[left - 1] = col }
        }
        return board
    }

    /// Stars fly out of the notch on fixed rays; talking lengthens their
    /// streaks and lights the dim ones.
    private static func warp(_ level: Double, t: Double) -> [[Double]] {
        var board = empty(columns * 2)
        let cx = Double(columns), streak = 1 + level * 6
        for k in 0..<26 {
            let angle = hash(k, 11, 0) * .pi * 2
            let speed = 5 + 7 * hash(k, 12, 0)
            let head = (t * speed + hash(k, 13, 0) * 30).truncatingRemainder(dividingBy: 24)
            let bright = 0.3 + 0.7 * hash(k, 14, 0)
            var s = 0.0
            while s <= streak {
                let r = head - s
                guard r > 0.8 else { break }
                let v = bright * (1 - s / (streak + 0.5)) * (level > 0.05 || bright > 0.7 ? 1 : 0.5)
                plot(&board, cx + cos(angle) * r, mid + sin(angle) * r * aspect, v)
                s += 0.5
            }
        }
        return board
    }

    /// Two strands and their rungs, scrolling out of the notch; the helix
    /// is wider where you were louder. The strand in front is brighter.
    private static func helix(_ recent: [Double], t: Double) -> [[Double]] {
        var board = empty()
        let flow = Array(recent.reversed())
        for c in 0..<columns {
            let amp = 1 + (c < flow.count ? flow[c] : 0) * 3.4
            let phase = Double(c) * 0.55 + t * 4
            let s1 = sin(phase), s2 = sin(phase + .pi)
            let front1 = cos(phase) >= 0
            let y1 = mid + amp * s1, y2 = mid + amp * s2
            plot(&board, Double(c), y1, front1 ? 1 : 0.4)
            plot(&board, Double(c), y2, front1 ? 0.4 : 1)
            if c % 3 == 1 {
                let lo = min(y1, y2), hi = max(y1, y2)
                var y = lo + 1
                while y < hi - 0.5 { plot(&board, Double(c), y, 0.2); y += 1 }
            }
        }
        return board
    }

    /// A loud syllable cracks a bolt out of each side of the notch, jagged
    /// by hash, flashing then gone within a third of a second.
    private static func lightning(_ recent: [Double], t: Double) -> [[Double]] {
        var board = empty(columns * 2)
        let cx = Double(columns)
        for (i, v) in recent.enumerated() where v > 0.6 {
            let age = recent.count - 1 - i
            let alpha = max(0, 1 - Double(age) / 7)
            guard alpha > 0 else { continue }
            let seed = Int(t * 50) - age
            if age == 0 { for c in 0..<(columns * 2) { for r in 0..<rows { board[c][r] = max(board[c][r], 0.12) } } }
            for dir in [-1.0, 1.0] {
                var y = mid
                for step in 0..<columns {
                    y += (hash(seed, step, dir > 0 ? 1 : 2) - 0.5) * 2.4
                    y = min(Double(rows) - 0.5, max(0.5, y))
                    let x = cx + dir * (Double(step) + 0.5)
                    plot(&board, x, y, alpha * (step % 2 == 0 ? 1 : 0.7))
                    if hash(seed, step, 3) > 0.8 {           // a fork
                        plot(&board, x, y + (hash(seed, step, 4) > 0.5 ? 1.5 : -1.5), alpha * 0.5)
                    }
                }
            }
        }
        return board
    }

    /// Dots that huddle at the notch in silence and fly out as you talk,
    /// each on its own orbit.
    private static func swarm(_ level: Double, t: Double) -> [[Double]] {
        var board = empty(columns * 2)
        let cx = Double(columns)
        for k in 0..<30 {
            let home = hash(k, 21, 0) * .pi * 2
            let spin = (1 + 2 * hash(k, 22, 0)) * (hash(k, 23, 0) > 0.5 ? 1 : -1)
            let reach = (1.2 + level * 12) * (0.6 + 0.4 * hash(k, 24, 0))
            let a = home + t * spin
            plot(&board, cx + cos(a) * reach, mid + sin(a) * reach * aspect, 0.45 + 0.55 * hash(k, 25, 0))
        }
        return board
    }

    /// A VU meter: a dim arc, and a needle from the corner by the notch
    /// that swings up with the level.
    private static func needle(_ recent: [Double]) -> [[Double]] {
        var board = empty()
        let tail = recent.suffix(4)
        let level = tail.isEmpty ? 0 : tail.reduce(0, +) / Double(tail.count)
        let px = 0.5, py = Double(rows) - 0.5, length = 18.0
        var a = 0.0
        while a <= 1.25 {
            plot(&board, px + cos(a) * length, py - sin(a) * length * aspect, a > 1.0 ? 0.45 : 0.2)
            a += 0.06
        }
        let angle = 0.05 + max(0, min(1, level)) * 1.2
        var s = 0.0
        while s <= length {
            plot(&board, px + cos(angle) * s, py - sin(angle) * s * aspect, 0.5 + 0.5 * s / length)
            s += 0.5
        }
        return board
    }

    /// An oscilloscope figure; the level bends its ratio, so it knots up
    /// as you talk and settles to a bow in silence.
    private static func lissajous(_ level: Double, t: Double) -> [[Double]] {
        var board = empty()
        let cx = Double(columns) / 2
        let a = 3.0, b = 2.0 + level * 3.0
        for k in 0..<60 {
            let tau = t * 1.6 - Double(k) * 0.035
            let v = 1 - Double(k) / 60
            plot(&board, cx + 8.5 * sin(a * tau), mid + 4 * sin(b * tau + 1.0), v)
        }
        return board
    }

    /// A waterfall: time runs out of the notch, and each column glows as
    /// wide as you were loud, textured so it reads as sound not a bar.
    private static func spectrogram(_ recent: [Double], t: Double) -> [[Double]] {
        var board = empty()
        let flow = Array(recent.reversed())
        let frame = Int(t * 50)
        for c in 0..<columns {
            let v = c < flow.count ? flow[c] : 0
            for r in 0..<rows {
                let d = abs(Double(r) + 0.5 - mid) / mid
                let envelope = max(0, v * 1.25 - d)
                let grain = 0.55 + 0.45 * hash(frame - c, r, 5)
                board[c][r] = min(1, envelope * grain * 1.4)
            }
        }
        return board
    }

    /// Each loud syllable launches a shell up each pill; it bursts at the
    /// top into sparks that spread and sag.
    private static func fireworks(_ recent: [Double]) -> [[Double]] {
        var board = empty(columns * 2)
        for (i, v) in recent.enumerated() where v > 0.6 {
            let age = Double(recent.count - 1 - i)
            for dir in [-1.0, 1.0] {
                let x0 = Double(columns) + dir * (5 + hash(i, 31, dir > 0 ? 1 : 0) * 11)
                if age < 4 {
                    plot(&board, x0, Double(rows) - 0.5 - age * 1.8, 1)
                    plot(&board, x0, Double(rows) - 0.5 - age * 1.8 + 1, 0.3)
                } else {
                    let spread = age - 4
                    let fade = max(0, 1 - spread / 11)
                    guard fade > 0 else { continue }
                    for j in 0..<12 {
                        let angle = hash(i, j, 32) * .pi * 2
                        let x = x0 + cos(angle) * spread * 0.9
                        let y = 2.5 + sin(angle) * spread * 0.9 * aspect + spread * spread * 0.05
                        plot(&board, x, y, fade * (0.5 + 0.5 * hash(i, j, 33)))
                    }
                }
            }
        }
        return board
    }

    /// Eight balls on the floor, each bouncing to its own rhythm; talking
    /// raises the ceiling.
    private static func bounce(_ level: Double, t: Double) -> [[Double]] {
        var board = empty(columns * 2)
        let height = 1.5 + 7.5 * (0.15 + level * 0.85)
        for k in 0..<8 {
            let x = 2.5 + Double(k) * 5 + (k >= 4 ? 0 : 0)
            let w = 3 + 2 * hash(k, 41, 0), phase = hash(k, 42, 0) * .pi
            let y = Double(rows) - 0.5 - abs(sin(t * w + phase)) * height
            plot(&board, x, y, 1)
            plot(&board, x, Double(rows) - 0.5, 0.2)
        }
        return board
    }

    /// Three sines summed; the level sets how bright the plasma burns.
    private static func plasma(_ level: Double, t: Double, width: Int) -> [[Double]] {
        let gain = 0.2 + 0.8 * level
        return (0..<width).map { c in
            let x = Double(c)
            return (0..<rows).map { r in
                let y = Double(r) * 2
                let v = (sin(x * 0.35 + t * 1.5) + sin(y * 0.5 - t * 1.1) + sin((x + y) * 0.2 + t * 0.7)) / 3
                let n = (v + 1) / 2
                return n * n * gain
            }
        }
    }

    // MARK: Idle visuals

    static func idle(_ kind: Idle, t: Double, side: ListeningPill.Side) -> [[Double]] {
        if kind.sides == .right, side == .leading {
            return idle(kind, t: t, side: .trailing).reversed()
        }
        switch kind {
        case .scanner:
            // A bright bar that runs across both pills and back, dimming
            // behind it; through the notch it simply isn't seen for a beat.
            let width = columns * 2
            let period = 1.4
            let u = (t / period).truncatingRemainder(dividingBy: 2)
            let x = (u < 1 ? u : 2 - u) * Double(width - 1)
            var board = empty(width)
            for c in 0..<width {
                let d = abs(Double(c) - x)
                guard d < 6 else { continue }
                let v = 1 - d / 6
                for row in 3..<7 { board[c][row] = v * v }
            }
            return slice(board, side: side)
        case .orbit:
            var out = empty()
            let cx = Double(columns) / 2, cy = Double(rows) / 2
            for k in 0..<6 {
                let a = t * 3.2 - Double(k) * 0.35
                let x = Int((cx + cos(a) * 6).rounded()), y = Int((cy + sin(a) * 3.2).rounded())
                if (0..<columns).contains(x), (0..<rows).contains(y) { out[x][y] = max(out[x][y], 1 - Double(k) / 6) }
            }
            return out
        case .snake:
            // Runs the perimeter of the whole board, six dots long.
            let width = columns * 2
            let path = perimeter(width: width, height: rows)
            var board = empty(width)
            let head = Int(t * 28) % path.count
            for k in 0..<7 {
                let (x, y) = path[(head - k + path.count) % path.count]
                board[x][y] = max(board[x][y], 1 - Double(k) / 7)
            }
            return slice(board, side: side)
        case .ember:
            return slice(fire(t: t, height: 0.3, width: columns * 2), side: side)
        case .drizzle:
            return slice(rain(t: t, density: 0.3, width: columns * 2), side: side)
        case .breathe:
            // A glow that swells out of the notch and draws back, slowly.
            var board = empty(columns * 2)
            let phase = (sin(t * 1.1) + 1) / 2
            let reach = 3 + phase * 16
            for c in 0..<(columns * 2) {
                for r in 0..<rows {
                    let dx = Double(c) + 0.5 - Double(columns), dy = (Double(r) + 0.5 - mid) / aspect
                    let d = (dx * dx + dy * dy).squareRoot()
                    board[c][r] = max(0, 1 - d / reach) * (0.25 + 0.75 * phase)
                }
            }
            return slice(board, side: side)
        case .bouncer:
            // The screensaver block: across the whole board, through the notch.
            let width = columns * 2
            func tri(_ u: Double, _ span: Double) -> Double {
                let p = u.truncatingRemainder(dividingBy: span * 2)
                return p < span ? p : span * 2 - p
            }
            let x = Int(tri(t * 9, Double(width - 2)).rounded()), y = Int(tri(t * 3.3, Double(rows - 2)).rounded())
            var board = empty(width)
            for dx in 0..<2 { for dy in 0..<2 { plot(&board, Double(x + dx), Double(y + dy), 1) } }
            return slice(board, side: side)
        case .life:
            return slice(life(t: t), side: side)
        case .figure:
            return lissajous(0.15 + 0.15 * sin(t * 0.3), t: t * 0.6)
        case .sea:
            // Swell rolling under the notch: a bright surface, dim water,
            // foam where a crest is steep.
            let width = columns * 2
            var board = empty(width)
            for c in 0..<width {
                let x = Double(c)
                let surface = mid + 1.6 * sin(x * 0.45 + t * 1.6) + 0.8 * sin(x * 1.1 - t * 0.9)
                let slope = 1.6 * 0.45 * cos(x * 0.45 + t * 1.6) + 0.8 * 1.1 * cos(x * 1.1 - t * 0.9)
                for r in 0..<rows {
                    let y = Double(r) + 0.5
                    if y > surface + 0.5 { board[c][r] = 0.18 }
                }
                plot(&board, x, surface, 1)
                if slope < -0.9 { plot(&board, x, surface - 1, 0.6) }
            }
            return slice(board, side: side)
        case .quiet:
            return empty()
        }
    }

    /// Conway's Life on the whole board as a torus, seeded fresh every ten
    /// seconds and stepped six times a second from that seed — so any
    /// frame is a pure function of the clock.
    static func life(t: Double) -> [[Double]] {
        let width = columns * 2
        let epoch = Int(t / 10)
        let steps = min(60, Int((t - Double(epoch) * 10) * 6))
        var cells = (0..<width).map { c in (0..<rows).map { r in hash(c, r, epoch * 7 + 3) < 0.32 } }
        for _ in 0..<steps {
            var next = cells
            for c in 0..<width {
                for r in 0..<rows {
                    var n = 0
                    for dc in -1...1 { for dr in -1...1 where dc != 0 || dr != 0 {
                        if cells[(c + dc + width) % width][(r + dr + rows) % rows] { n += 1 }
                    } }
                    next[c][r] = cells[c][r] ? (n == 2 || n == 3) : n == 3
                }
            }
            cells = next
        }
        return cells.map { $0.map { $0 ? 1.0 : 0.0 } }
    }

    // MARK: Shared simulations (deterministic in t)

    private static func hash(_ x: Int, _ y: Int, _ z: Int) -> Double {
        var h = UInt32(truncatingIfNeeded: x &* 374761393 &+ y &* 668265263 &+ z &* 2147483647)
        h = (h ^ (h >> 13)) &* 1274126177
        return Double(h ^ (h >> 16)) / Double(UInt32.max)
    }

    /// Demo-scene fire: heat rises from the bottom row, cooling as it goes,
    /// with the flicker read from a hash of (column, row, frame).
    static func fire(t: Double, height: Double, width: Int) -> [[Double]] {
        let frame = Int(t * 18)
        return (0..<width).map { c in
            // Each column's tongue has its own height that wanders, so the
            // top of the fire is ragged rather than a level line.
            let base = 0.55 + 0.45 * hash(c, 0, frame / 3)
            let neighbour = 0.5 * (hash(c - 1, 0, frame / 3) + hash(c + 1, 0, frame / 3))
            let reach = max(0.08, min(0.95, height * (0.6 * base + 0.4 * neighbour)))
            return (0..<rows).map { row in
                let fromBottom = Double(row + 1) / Double(rows)         // 1 at the bottom row
                let flicker = 0.7 + 0.3 * hash(c, row, frame)
                let v = max(0, min(1, (reach - (1 - fromBottom)) / reach))
                return v * v * flicker
            }
        }
    }

    /// Columns of falling dots; each column has its own speed and phase.
    static func rain(t: Double, density: Double, width: Int) -> [[Double]] {
        (0..<width).map { c in
            let speed = 6 + 8 * hash(c, 1, 0)
            let phase = hash(c, 2, 0) * 40
            let head = (t * speed + phase).truncatingRemainder(dividingBy: Double(rows) / density)
            return (0..<rows).map { row in
                let behind = head - Double(row)
                guard behind >= 0, behind < 4 else { return 0 }
                return 1 - behind / 4
            }
        }
    }

    private static func perimeter(width: Int, height: Int) -> [(Int, Int)] {
        var p: [(Int, Int)] = []
        for x in 0..<width { p.append((x, 0)) }
        for y in 1..<height { p.append((width - 1, y)) }
        for x in stride(from: width - 2, through: 0, by: -1) { p.append((x, height - 1)) }
        for y in stride(from: height - 2, through: 1, by: -1) { p.append((0, y)) }
        return p
    }
}

/// A live visual in a pill, driven by the voice's level history.
struct NotchLiveView: View {
    @ObservedObject var voice: VoiceInput
    let kind: NotchGallery.Live
    let side: ListeningPill.Side

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            DotGrid(columns: NotchGallery.live(kind, levels: voice.levels, t: t, side: side),
                    mirrored: side == .leading, warm: kind.warm, animated: !kind.warm)
        }
    }
}

/// A self-playing visual in a pill.
struct NotchIdleView: View {
    let kind: NotchGallery.Idle
    let side: ListeningPill.Side

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            DotGrid(columns: NotchGallery.idle(kind, t: t, side: side), mirrored: side == .leading, warm: kind.warm, animated: false)
        }
    }
}
