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
        var id: String { rawValue }
        var title: String {
            switch self {
            case .wave:   return "Wave — your voice, flowing right"
            case .mirror: return "Mirror — the wave both ways"
            case .bars:   return "Bars — an equaliser, to the right"
            case .ripple: return "Ripple — rings out from the notch"
            case .fire:   return "Fire — burns as you talk"
            case .comet:  return "Comet — races when you do"
            case .rain:   return "Rain — heavier when you talk"
            case .pulse:  return "Pulse — a heartbeat trace"
            }
        }
        var sides: Sides {
            switch self {
            case .wave, .bars, .comet, .pulse: return .right
            case .mirror, .ripple, .fire, .rain: return .both
            }
        }
        var warm: Bool { self == .fire }
    }

    // MARK: While it transcribes

    enum Idle: String, CaseIterable, Identifiable {
        case scanner, orbit, snake, ember, drizzle, quiet
        var id: String { rawValue }
        var title: String {
            switch self {
            case .scanner: return "Scanner — sweeps through the notch"
            case .orbit:   return "Orbit — a dot circling, to the right"
            case .snake:   return "Snake — runs the edges"
            case .ember:   return "Ember — a low fire"
            case .drizzle: return "Drizzle — light rain"
            case .quiet:   return "Nothing"
            }
        }
        var sides: Sides {
            switch self {
            case .orbit: return .right
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
                for k in 0..<3 where band * 3 + k + 1 < columns { out[band * 3 + k + 1] = col }
            }
            return out
        case .ripple:
            // Each strong syllable launches a ring from the notch; rings run
            // outward through both pills and fade.
            var board = empty(columns * 2)
            let spikes = recent.enumerated().filter { $0.element > 0.55 }
            for (age, _) in spikes.map({ (recent.count - 1 - $0.offset, $0.element) }) {
                let r = Double(age) * 0.9
                let alpha = max(0, 1 - Double(age) / Double(columns))
                for c in 0..<(columns * 2) {
                    let dist = abs(Double(c) + 0.5 - Double(columns))   // from the notch
                    if abs(dist - r) < 0.75 {
                        for row in 0..<rows {
                            let d = abs(Double(row) + 0.5 - Double(rows) / 2)
                            board[c][row] = max(board[c][row], alpha * (d < r * 0.4 + 1 ? 1 : 0.2))
                        }
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
        }
    }

    // MARK: Idle visuals

    static func idle(_ kind: Idle, t: Double, side: ListeningPill.Side) -> [[Double]] {
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
            return slice(rain(t: t, density: 0.1, width: columns * 2), side: side)
        case .quiet:
            return empty()
        }
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
            let base = 0.6 + 0.4 * hash(c, 0, frame / 2)
            return (0..<rows).map { row in
                let fromBottom = Double(rows - row) / Double(rows)      // 1 at the bottom
                let reach = height * base
                let flicker = 0.75 + 0.25 * hash(c, row, frame)
                let v = (reach - (1 - fromBottom)) / reach
                return max(0, min(1, v)) * flicker
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
                    warm: kind.warm, animated: !kind.warm)
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
            DotGrid(columns: NotchGallery.idle(kind, t: t, side: side), warm: kind.warm, animated: false)
        }
    }
}
