import CoreGraphics
import Foundation

/// Finds a chess board in a screenshot, without being told where it is.
///
/// A board is the most regular thing on a screen. Eight squares of one colour
/// and eight of another, in strict alternation, in a perfect square — nothing
/// else in an interface looks like that, and the regularity is what makes it
/// findable rather than guessable.
///
/// Two stages, and the second is what makes it trustworthy:
///
/// 1. **Where the lines are.** Summing the horizontal gradient down each column
///    gives a signal with a spike wherever a vertical edge runs the height of
///    the image. A board contributes nine of them, evenly spaced. Sweeping a
///    nine-toothed comb over that signal and taking the best (period, phase)
///    recovers the square size and the grid origin. Same again for rows.
///
/// 2. **Whether it's actually a board.** Stage one will happily lock onto a
///    table, a code editor's indent guides, or a calendar. So the candidate has
///    to pass a test only a chessboard passes: sample every square's corner,
///    split them by parity, and require the two groups to be internally
///    consistent and far apart from each other. Corners rather than centres,
///    because a piece sits in the middle of its square and the board colour is
///    what's being measured.
///
/// A wrong answer here is worse than no answer — it would put the arrows on a
/// grid that isn't the board — so the confidence gate is deliberately strict
/// and the drag picker is still there for when this declines.
enum ChessBoardFinder {

    /// Set to have the finder narrate why it declined. Off in the app; the
    /// diagnostics dump turns it on when something needs explaining.
    static var explain = false
    /// What the last run thought, kept so a failure can be looked at after the
    /// fact instead of reproduced. Debugging this blind — over SSH, against a
    /// board on someone else's screen — is otherwise guesswork.
    private(set) static var reasoning: [String] = []
    private static func say(_ what: @autoclosure () -> String) {
        let line = what()
        reasoning.append(line)
        if explain { FileHandle.standardError.write(Data((line + "\n").utf8)) }
    }

    struct Found {
        let geometry: BoardGeometry
        /// How cleanly the checkerboard test separated. 0…1.
        let confidence: Double
        /// Per square: the colour of the piece on it, or nil for empty.
        let occupancy: [Square: PieceColor?]
    }

    /// Squares smaller than this are unreadable anyway; larger than this and
    /// the board wouldn't fit on a screen.
    private static let minSquare = 14
    private static let maxSquare = 120       // in the downscaled image

    /// `image` is a screenshot of one display; `origin` is that display's
    /// top-left in global CoreGraphics screen points, so the result comes back
    /// in the coordinates everything else uses.
    static func find(in image: CGImage, displayOrigin origin: CGPoint) -> Found? {
        reasoning.removeAll()
        guard let sample = Raster(image, targetWidth: 1500) else {
            say("image too small to work with"); return nil
        }
        say("image \(image.width)×\(image.height), working at \(sample.width)×\(sample.height)")

        // Gradient energy per column and per row. A vertical grid line shows up
        // as a column where the horizontal gradient is large all the way down.
        let columns = sample.columnEdgeEnergy()
        let rows = sample.rowEdgeEnergy()

        // Candidates on each axis, not a single winner.
        //
        // Taking the top comb per axis independently loses to any periodic UI
        // that happens to out-shout the board on one axis — a list of rows, a
        // table, a column of text — because the strongest vertical period and
        // the strongest horizontal one then describe two different objects and
        // the "squares are square" check rejects the pair. Enumerating instead
        // and letting the checkerboard test say which pair is a board fixes
        // that, and dissolves the harmonic problem too: sampled at twice the
        // real square size every square has the same parity, so the two colour
        // groups collapse into one and the test throws it out by itself.
        let xs = combCandidates(in: columns)
        let ys = combCandidates(in: rows)
        guard !xs.isEmpty, !ys.isEmpty else { say("no comb candidates"); return nil }

        var pairs: [(x: Comb, y: Comb)] = []
        for x in xs {
            for y in ys {
                let period = Double(x.period + y.period) / 2
                guard abs(Double(x.period - y.period)) / period < 0.06 else { continue }
                pairs.append((x, y))
            }
        }
        guard !pairs.isEmpty else { say("no pair agreed on a period"); return nil }
        pairs.sort { $0.x.score + $0.y.score > $1.x.score + $1.y.score }

        for pair in pairs.prefix(24) {
            let period = Double(pair.x.period + pair.y.period) / 2
            let rect = CGRect(x: Double(pair.x.phase), y: Double(pair.y.phase),
                              width: period * 8, height: period * 8)
            guard rect.maxX <= Double(sample.width), rect.maxY <= Double(sample.height)
            else { continue }
            guard let check = sample.checkerboard(in: rect), check.confidence > 0.55
            else { continue }

            say("board at \(rect) period \(period) confidence \(String(format: "%.2f", check.confidence))")
            let scale = sample.scale
            let onScreen = CGRect(x: origin.x + rect.minX * scale,
                                  y: origin.y + rect.minY * scale,
                                  width: rect.width * scale, height: rect.height * scale)
            let flipped = check.darkOnBottom
            let geometry = BoardGeometry(boundingBox: onScreen, flipped: flipped)
            return Found(geometry: geometry,
                         confidence: check.confidence,
                         occupancy: occupancy(from: check, flipped: flipped))
        }
        say("\(pairs.count) candidate pairs, none passed the checkerboard test")
        return nil
    }

    /// Turn the board-as-drawn readings into squares, which depends on which
    /// way round the board is.
    private static func occupancy(from check: Raster.Checkerboard,
                                  flipped: Bool) -> [Square: PieceColor?] {
        var occupancy: [Square: PieceColor?] = [:]
        for (index, occupant) in check.occupancy.enumerated() {
            let column = index % 8, row = index / 8
            guard let square = flipped ? Square(file: 7 - column, rank: row)
                                       : Square(file: column, rank: 7 - row)
            else { continue }
            occupancy[square] = occupant
        }
        return occupancy
    }

    // ── the comb ──────────────────────────────────────────────────────

    private struct Comb { let period: Int; let phase: Int; let score: Double }

    /// The nine evenly spaced peaks that a board's grid lines make.
    ///
    /// Scored against the local mean rather than in absolute terms: a board in
    /// a bright window and one in a dark window have wildly different edge
    /// energy, and only the *contrast* between the grid lines and their
    /// surroundings is common to both.
    private static func combCandidates(in signal: [Double]) -> [Comb] {
        guard signal.count > minSquare * 8 else { return [] }
        let mean = signal.reduce(0, +) / Double(signal.count)
        guard mean > 0 else { return [] }

        // Best phase for every period, kept rather than reduced, because the
        // winner on score alone is the wrong answer — see below.
        var byPeriod: [Int: Comb] = [:]
        for period in minSquare...min(maxSquare, signal.count / 8) {
            let span = period * 8
            guard span < signal.count else { break }
            var best: Comb?
            for phase in 0...(signal.count - span - 1) {
                var total = 0.0
                for tooth in 0...8 { total += signal[phase + tooth * period] }
                let score = total / 9 / mean
                if score > (best?.score ?? 0) {
                    best = Comb(period: period, phase: phase, score: score)
                }
            }
            byPeriod[period] = best
        }

        guard let peak = byPeriod.values.map(\.score).max(), peak > 1.6 else {
            say("no comb above threshold (best \(String(format: "%.2f", byPeriod.values.map(\.score).max() ?? 0)))")
            return []
        }

        // The smallest period that explains the signal, not the strongest.
        //
        // A comb of period 2p lands every tooth on a real grid line of a
        // period-p board — every *other* line — so it scores just as well as
        // the truth, and a comb of 4p does too. An earlier version broke the
        // tie by preferring larger periods, on the theory that a big board
        // beats a coincidence, which meant it reliably locked onto double the
        // real square size. The two axes then picked different harmonics, the
        // "squares are square" check caught the disagreement, and a perfectly
        // ordinary board was declined.
        //
        // The fundamental is the smallest period that scores near the peak.
        // Harmonics can equal it but never beat it by much, so a generous
        // margin still lands on the truth.
        // Everything within half the peak is worth offering; the checkerboard
        // test is cheap and is the only opinion that actually knows what a
        // board looks like.
        return byPeriod.values
            .filter { $0.score >= max(1.6, peak * 0.45) }
            .sorted { $0.score > $1.score }
            .prefix(10)
            .map { $0 }
    }
}

/// A screenshot, downscaled, as plain bytes we can index.
private struct Raster {
    let pixels: [UInt8]          // RGBA8
    let width: Int
    let height: Int
    /// Multiply a coordinate here by this to get back to screen points.
    let scale: Double

    init?(_ image: CGImage, targetWidth: Int) {
        let factor = max(1, Int((Double(image.width) / Double(targetWidth)).rounded()))
        let w = image.width / factor, h = image.height / factor
        guard w > 80, h > 80 else { return nil }

        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = buffer.withUnsafeMutableBytes({ raw -> CGContext? in
            CGContext(data: raw.baseAddress, width: w, height: h,
                      bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        self.pixels = buffer
        self.width = w
        self.height = h
        // The context draws bottom-up relative to CoreGraphics' top-left
        // screen origin, but the board is symmetric in y about its own centre
        // and the phase is recovered from the same buffer it's applied to, so
        // no flip is needed here — only when handing coordinates back.
        self.scale = Double(image.width) / Double(w)
    }

    private func luminance(_ x: Int, _ y: Int) -> Double {
        let i = (y * width + x) * 4
        return 0.299 * Double(pixels[i]) + 0.587 * Double(pixels[i + 1])
             + 0.114 * Double(pixels[i + 2])
    }

    private func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
        let i = (y * width + x) * 4
        return (Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]))
    }

    func columnEdgeEnergy() -> [Double] {
        var out = [Double](repeating: 0, count: width)
        for x in 1..<width {
            var total = 0.0
            for y in stride(from: 0, to: height, by: 2) {
                total += abs(luminance(x, y) - luminance(x - 1, y))
            }
            out[x] = total
        }
        return out
    }

    func rowEdgeEnergy() -> [Double] {
        var out = [Double](repeating: 0, count: height)
        for y in 1..<height {
            var total = 0.0
            for x in stride(from: 0, to: width, by: 2) {
                total += abs(luminance(x, y) - luminance(x, y - 1))
            }
            out[y] = total
        }
        return out
    }

    struct Checkerboard {
        let confidence: Double
        /// Board as drawn, top-left first: the piece colour on each square, or
        /// nil where the square is empty.
        let occupancy: [PieceColor?]
        /// Whether the dark pieces are nearest the bottom of the screen, which
        /// is what "you are playing black" looks like.
        let darkOnBottom: Bool
    }

    /// Test the candidate the way only a chess board passes.
    func checkerboard(in rect: CGRect) -> Checkerboard? {
        let side = rect.width / 8
        guard side >= 8 else { return nil }

        var light: [Double] = [], dark: [Double] = []
        var squareLuma = [Double](repeating: 0, count: 64)
        var squareRGB = [(Double, Double, Double)](repeating: (0, 0, 0), count: 64)

        // All four corners, and take the median.
        //
        // One corner is not enough, and this is the bug that made a fresh game
        // read as one already under way. Chess.com prints its coordinates
        // *inside* the board — rank numbers in the top-left of the a-file
        // squares, file letters in the bottom-right of the first rank — drawn
        // in the opposite square's colour. Sampling a single top-left corner
        // landed exactly on the rank numbers, so eight squares reported the
        // wrong board colour, their centres then looked nothing like it, and
        // eight empty squares were confidently occupied. Four corners with a
        // label in at most one of them is a median away from correct.
        for row in 0..<8 {
            for column in 0..<8 {
                var samples: [(Double, (Double, Double, Double))] = []
                for (dx, dy) in [(0.12, 0.12), (0.88, 0.12), (0.12, 0.88), (0.88, 0.88)] {
                    let x = Int(rect.minX + (Double(column) + dx) * side)
                    let y = Int(rect.minY + (Double(row) + dy) * side)
                    guard x >= 0, x < width, y >= 0, y < height else { return nil }
                    samples.append((luminance(x, y), rgb(x, y)))
                }
                samples.sort { $0.0 < $1.0 }
                // Mean of the middle two: the median of an even count, and it
                // survives one poisoned corner at either end.
                let value = (samples[1].0 + samples[2].0) / 2
                let colour = ((samples[1].1.0 + samples[2].1.0) / 2,
                              (samples[1].1.1 + samples[2].1.1) / 2,
                              (samples[1].1.2 + samples[2].1.2) / 2)
                squareLuma[row * 8 + column] = value
                squareRGB[row * 8 + column] = colour
                if (row + column) % 2 == 0 { light.append(value) } else { dark.append(value) }
            }
        }

        func mean(_ xs: [Double]) -> Double { xs.reduce(0, +) / Double(xs.count) }
        func spread(_ xs: [Double]) -> Double {
            let m = mean(xs)
            return (xs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(xs.count)).squareRoot()
        }

        let lightMean = mean(light), darkMean = mean(dark)
        let separation = abs(lightMean - darkMean)
        let noise = (spread(light) + spread(dark)) / 2 + 1
        // Far apart between the groups, tight within them. A table of text
        // scores near zero here; a board scores enormously.
        let confidence = min(1, separation / (noise * 4))
        guard separation > 12 else { return nil }

        // Occupancy: a square whose middle is a different colour from its own
        // corner has something standing on it.
        //
        // Measured as distance in RGB rather than in luminance, which is the
        // difference between finding thirty-two pieces and finding twenty-four.
        // A white piece on a light square is the awkward case — cream squares
        // and ivory pieces are within about nine of each other in luminance,
        // under any threshold that isn't also triggered by a highlight — but
        // they are thirty apart in blue, because the square is warm and the
        // piece is not. Throwing away the colour channels throws away the only
        // signal that case has.
        var occupancy = [PieceColor?](repeating: nil, count: 64)
        var topDark = 0.0, bottomDark = 0.0
        for row in 0..<8 {
            for column in 0..<8 {
                let cx = Int(rect.minX + (Double(column) + 0.5) * side)
                let cy = Int(rect.minY + (Double(row) + 0.5) * side)
                guard cx >= 0, cx < width, cy >= 0, cy < height else { continue }
                let index = row * 8 + column
                let (r, g, b) = rgb(cx, cy)
                let (br, bg, bb) = squareRGB[index]
                let distance = ((r - br) * (r - br) + (g - bg) * (g - bg)
                              + (b - bb) * (b - bb)).squareRoot()
                guard distance > max(24, noise * 1.5) else { continue }

                // Which colour it is stays a luminance question: a piece is
                // lighter or darker than what it stands on, and that is the
                // one thing every piece set in the world agrees about.
                let centre = 0.299 * r + 0.587 * g + 0.114 * b
                let isLightPiece = centre > squareLuma[index]
                occupancy[index] = isLightPiece ? .white : .black
                if !isLightPiece {
                    if row < 4 { topDark += 1 } else { bottomDark += 1 }
                }
            }
        }

        return Checkerboard(confidence: confidence,
                            occupancy: occupancy,
                            darkOnBottom: bottomDark > topDark)
    }
}
