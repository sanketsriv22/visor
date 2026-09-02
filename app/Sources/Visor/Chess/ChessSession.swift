import AppKit

/// What Visor does when it can see a chess board.
///
/// Two modes, and they share everything but the last step:
///
///   capture → diff → resolve the move → look up the reply → actuate
///
/// `advising` draws the top three and never touches the mouse. `playing`
/// clicks the best one. The pipeline doesn't know which is attached, which is
/// the point: the risky mode is the same code as the safe one plus a different
/// object at the end, rather than a flag consulted in five places.
enum ChessMode: String, CaseIterable {
    /// Draws arrows. The default, and the only one that doesn't need
    /// Accessibility.
    case advising
    /// Moves the pieces.
    case playing

    var label: String {
        switch self {
        case .advising: return "Show the best moves"
        case .playing:  return "Play the best move"
        }
    }
}

/// Where the position comes from.
///
/// `.dom` reads it out of the web page — exact, instant, indifferent to theme,
/// highlight, animation, Space or window order, and needs no vision model. It
/// is the truth on any site that has been mapped. `.pixels` is the camera:
/// the general case, and the fallback when there is no page to read.
enum ChessSource: String { case dom, pixels }

@MainActor
final class ChessSession: ObservableObject {
    enum State: Equatable {
        case idle
        case watching
        /// Nothing on screen explains the position we were keeping. Not fatal
        /// and not a reason to make someone start a new game: the watcher stays
        /// up and keeps trying to find a sequence of moves that gets from the
        /// last position we were sure of to the one in front of us.
        case recovering(String)
        /// Given up. Only reached when recovery has been trying for a while.
        case lost(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var position: ChessPosition
    @Published private(set) var suggestions: [ScoredMove] = []
    /// Time from the frame that revealed the opponent's move to the answer
    /// being on screen. The number this whole design exists to keep small, and
    /// published so it can be shown rather than claimed.
    @Published private(set) var lastLatency: TimeInterval?
    @Published private(set) var tableHitRate: Double?

    private let mode: ChessMode
    let source: ChessSource
    /// Readable so a resync can rebuild a session over the same board.
    let geometry: BoardGeometry
    let ourColour: PieceColor
    private var domTask: Task<Void, Never>?
    private let latency: LatencyBand
    private let elo: Int?
    private let searchDepth: Int
    private let skill: Int?

    private var oracle: ChessOracle?
    private var watcher: ChessWatcher?
    private var actuator: MoveActuator?

    /// How the board looked when we last agreed with it.
    ///
    /// Diffs are taken against this rather than against the previous frame:
    /// every mid-animation frame differs from the one before it, so chasing
    /// that produces a fresh "change" every 8ms with no move in any of them.
    private var baseline: [Square: ChessWatcher.Signature] = [:]
    /// Last frame's delta, to notice when it has stopped growing.
    private var settling: Set<Square> = []
    /// When the current change first appeared — the latency figure, and the
    /// clock on how long we've been unable to explain what we're looking at.
    private var changeBegan: Date?
    /// When the tracked position was last checked against the screen, and how
    /// many checks in a row have disagreed.
    private var lastVerified = Date.distantPast
    private var mismatches = 0

    /// The most recent frame from the watcher, settled or not, so a move we
    /// played ourselves can be confirmed against the live board.
    private var latestFrame: [Square: ChessWatcher.Signature] = [:]
    /// True from the moment we click one of our own moves until we have seen it
    /// land. While set, the watcher's changes are our own move arriving, not
    /// the opponent's, and must not be resolved as such.
    private var playingOwnMove = false

    /// Whether this episode's whole-board storm has been captured already.
    private var dumpedStorm = false

    /// One resolve at a time.
    ///
    /// `resolve` awaits the engine, and frames keep arriving at 120Hz while it
    /// does. Without this, every frame after the board settled spawned another
    /// resolve against the same delta: the first applied the move and moved the
    /// baseline, and the rest applied it *again* from their stale copies. Two
    /// plies for one move, and from then on nothing matched and the session sat
    /// waiting for a move that had already been played.
    private var resolving = false

    init(mode: ChessMode, geometry: BoardGeometry, ourColour: PieceColor,
         position: ChessPosition = .start, latency: LatencyBand = .default,
         source: ChessSource = .pixels, elo: Int? = nil, searchDepth: Int = 14,
         skill: Int? = nil) {
        self.elo = elo
        self.searchDepth = searchDepth
        self.skill = skill
        self.mode = mode
        self.source = source
        self.geometry = geometry
        self.ourColour = ourColour
        self.position = position
        self.latency = latency
    }

    // ── lifecycle ─────────────────────────────────────────────────────

    func start() async throws {
        // A wider shortlist when the strength is turned down, so Skill Level
        // has genuinely worse moves to pick from — three candidates are all
        // decent and would never yield a real blunder. Only the top three are
        // ever drawn as arrows regardless.
        let searchLines = (mode == .playing && skill != nil) ? 6 : 3
        let oracle = try ChessOracle(depth: searchDepth, lines: searchLines, elo: elo, skill: skill)
        self.oracle = oracle
        self.actuator = mode == .advising ? AdvisingActuator() : ClickingActuator()

        if source == .dom {
            state = .watching
            ChessDiagnostics.trace("session: started \(mode) as \(ourColour) from the page — \(position.fen)")
            domTask = Task { [weak self] in await self?.followPage() }
            if position.turn == ourColour {
                let a = await oracle.analyse(position)
                ChessDiagnostics.trace("session: our move first; engine offered "
                                     + a.lines.map { "\($0.move.uci) \($0.score.display)" }.joined(separator: ", "))
                suggestions = a.lines
                if mode == .playing { await playOurMove(a.lines, played: a.played) }
                else { await actuator?.present(Array(a.lines.prefix(3)), on: geometry) }
            }
            return
        }

        let watcher = ChessWatcher(geometry: geometry) { [weak self] changed, current in
            // Bound to a constant before the inner closure: a `weak self`
            // capture is a var, and a var can't be captured again by something
            // that runs concurrently.
            guard let self else { return }
            Task { @MainActor in self.saw(changed: changed, current: current) }
        }
        self.watcher = watcher
        try await watcher.start()
        state = .watching

        // Answer immediately rather than waiting for the opponent. Starting
        // mid-game and seeing nothing at all until their next move is
        // indistinguishable from being broken.
        ChessDiagnostics.trace("session: started \(mode) as \(ourColour) — \(position.fen)")
        if position.turn == ourColour {
            let a = await oracle.analyse(position)
            ChessDiagnostics.trace("session: our move first; engine offered "
                                 + a.lines.map { "\($0.move.uci) \($0.score.display)" }.joined(separator: ", "))
            suggestions = a.lines
            if mode == .playing {
                await playOurMove(a.lines, played: a.played)
            } else {
                await actuator?.present(Array(a.lines.prefix(3)), on: geometry)
            }
        } else {
            await oracle.prime(after: position)
        }
    }

    func stop() {
        domTask?.cancel()
        domTask = nil
        watcher?.stop()
        watcher = nil
        actuator?.clear()
        (actuator as? AdvisingActuator)?.close()
        actuator = nil
        let oracle = self.oracle
        self.oracle = nil
        Task { await oracle?.stop() }
        suggestions = []
        baseline = [:]
        settling = []
        state = .idle
    }

    // ── the loop ──────────────────────────────────────────────────────

    private func saw(changed: [Square], current: [Square: ChessWatcher.Signature]) {
        latestFrame = current
        guard !resolving, !playingOwnMove else { return }
        switch state {
        case .watching, .recovering: break
        case .idle, .lost: return
        }
        if baseline.isEmpty {
            baseline = current
            return
        }

        let delta = Set(current.compactMap { square, signature -> Square? in
            guard let was = baseline[square], signature.differs(from: was) else { return nil }
            return square
        })
        guard !delta.isEmpty else {
            settling = []
            changeBegan = nil
            // Nothing is moving, which is the moment to ask whether what we
            // think is on the board is what is on the board.
            verifyStillInSync(current)
            return
        }

        let began = changeBegan ?? Date()
        changeBegan = began
        let held = delta == settling
        settling = delta

        // Normally: wait for the picture to hold still for one frame, because
        // during a slide the delta grows as the sprite crosses squares it isn't
        // going to land on. But "identical two frames running" is not
        // guaranteed — a cursor sitting on the board keeps a hover tint
        // flickering under it — so a quarter second of not settling is taken as
        // settled rather than waiting forever for a stillness that isn't coming.
        guard held || Date().timeIntervalSince(began) > 0.25 else { return }

        resolving = true
        Task { await resolve(delta: delta, current: current) }
    }

    private func resolve(delta: Set<Square>, current: [Square: ChessWatcher.Signature]) async {
        defer { resolving = false }
        guard let oracle else { return }

        // The position as the oracle primed it, before anything is applied.
        let before = position

        // A whole-board change isn't a move and doesn't need a candidate; skip
        // straight to the storm handling below rather than searching and
        // logging twenty times a second.
        let one = delta.count > 20 ? nil : await candidate(in: delta, current: current)
        if delta.count <= 20 {
            ChessDiagnostics.trace("resolve: turn=\(position.turn == ourColour ? "ours" : "theirs") "
                                 + "delta=[\(delta.sorted { $0.index < $1.index }.map(\.name).joined(separator: ","))] "
                                 + "→ \(one?.uci ?? "nothing")")
        }
        if let move = one {
            await commit([move], from: before, current: current)
            return
        }

        // Nothing single-ply fits. The usual reason is that a move was missed —
        // the board was covered, or a window came forward over it — and what is
        // being looked at now is two plies on rather than one. Recovering that
        // matters more than it sounds: the baseline only advances on a
        // successful resolve, so one missed move otherwise ratchets, the delta
        // grows against every later move, and the session never recovers on its
        // own.
        if delta.count >= 3, let pair = await twoPly(in: delta, current: current) {
            await commit(pair, from: before, current: current)
            return
        }

        // Most of the board changing at once is not a move — it's a window
        // that came forward over it, a scroll, or a switch to another space.
        // Waiting is the right response: the board comes back, and if moves
        // were played while it was hidden the two-ply recovery above picks
        // them up. Counting this against the stall clock would declare the
        // game lost every time you checked your email.
        if delta.count > 20 {
            changeBegan = nil
            // First time this episode: keep the frame, and both readings.
            if !dumpedStorm {
                dumpedStorm = true
                ChessDiagnostics.trace("storm: \(delta.count) of 64 squares differ from baseline — capturing frame")
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                watcher?.dumpNextFrameTo = ChessDiagnostics.directory.appendingPathComponent("storm-\(stamp).png")
                var out = "storm: baseline mean/occ | current mean/occ, a1..h1 then a2..\n"
                for index in 0..<64 {
                    guard let sq = Square(index: index), let b = baseline[sq], let c = current[sq] else { continue }
                    out += String(format: "  %@  %3d,%3d,%3d %@ | %3d,%3d,%3d %@\n", sq.name,
                                  Int(b.r), Int(b.g), Int(b.b), b.occupied ? "X" : ".",
                                  Int(c.r), Int(c.g), Int(c.b), c.occupied ? "X" : ".")
                }
                ChessDiagnostics.trace(out)
            }
            return
        }

        // Still nothing. Say so rather than sitting quietly: a session that has
        // lost the thread looks exactly like one waiting for a slow opponent,
        // and there is no way to tell them apart from outside.
        if let began = changeBegan, Date().timeIntervalSince(began) > 3 {
            switch state {
            case .recovering:
                // Been trying a while. Say so plainly rather than looking busy.
                if Date().timeIntervalSince(began) > 40 {
                    fail("Lost track of the game — stop and start again from a fresh board")
                }
            default:
                state = .recovering("Lost the thread — watching for something it recognises")
            }
        }
    }

    /// Apply what was seen, then decide what happens next.
    private func commit(_ moves: [Move], from before: ChessPosition,
                        current: [Square: ChessWatcher.Signature]) async {
        guard let oracle else { return }
        // Whatever it was, it is understood again.
        if case .recovering = state { state = .watching }
        baseline = current
        settling = []
        dumpedStorm = false
        for move in moves { position.apply(move) }
        ChessDiagnostics.trace("commit: applied \(moves.map(\.uci).joined(separator: "+")) "
                             + "→ now \(position.turn == ourColour ? "our" : "their") turn")

        // Never suggest into a position the screen plainly disagrees with. An
        // illegal move offered confidently is worse than no move at all, and
        // this is the last place to catch one. Gross disagreement only — the
        // move was just resolved against this same screen, so a square or two
        // is the highlight settling, not a wrong position.
        let observed = observedOccupancy(current)
        let wrong = 64 - agreement(position, with: observed)
        if wrong >= 6 {
            ChessDiagnostics.trace("suggest: withheld, \(wrong) squares disagree")
            suggestions = []
            actuator?.clear()
            state = .recovering("The board stopped matching what Visor is tracking")
            return
        }

        if position.turn == ourColour {
            // Only a single ply the oracle primed for can come out of the
            // table; a two-ply recovery lands on a position nobody predicted.
            let replies = moves.count == 1
                ? await oracle.replies(to: moves[0], from: before)
                : await oracle.analyse(position).lines
            suggestions = replies
            // Measured before the wait, not after: this is how fast the answer
            // was actually found, which is the number worth knowing. The wait
            // is a choice about when to use it.
            let began = changeBegan
            if let began { lastLatency = Date().timeIntervalSince(began) }
            changeBegan = nil
            tableHitRate = await oracle.hitRate

            if mode == .playing {
                // Counted from when the opponent's move appeared rather than
                // from now, so the band means total response time — otherwise
                // the search would be added on top of it and the shortest
                // setting could never be reached. Floored at 400ms regardless:
                // the opponent's piece is still sliding when we first see the
                // move, and a drag that starts during their animation gets
                // half-registered. Clicking in the same second as the detect
                // was most of why the second move never landed.
                let target = max(0.4, latency.sample())
                let spent = began.map { Date().timeIntervalSince($0) } ?? 0
                if target > spent {
                    try? await Task.sleep(nanoseconds: UInt64((target - spent) * 1_000_000_000))
                }
                // The board can move while we wait — the opponent premoved, or
                // the game ended. Acting on a stale answer would play into a
                // position that no longer exists.
                guard state == .watching, position.turn == ourColour else { return }
            }
            if mode == .playing {
                await playOurMove(replies)
            } else {
                await actuator?.present(replies, on: geometry)
            }
        } else {
            suggestions = []
            actuator?.clear()
            changeBegan = nil
            await oracle.prime(after: position)
        }
    }

    /// Two plies at once, for when one was missed.
    ///
    /// Costs a legal-move query per candidate first move, which is why it is
    /// only reached once the single-ply answer has failed. Recovery is allowed
    /// to be slow; it is not allowed to be absent.
    private func twoPly(in delta: Set<Square>,
                        current: [Square: ChessWatcher.Signature]) async -> [Move]? {
        guard let oracle, let first = await oracle.legalMoves(from: position) else { return nil }

        func upheaval(_ square: Square) -> Int {
            guard let now = current[square], let was = baseline[square] else { return 0 }
            return abs(Int(now.r) - Int(was.r)) + abs(Int(now.g) - Int(was.g))
                 + abs(Int(now.b) - Int(was.b))
        }

        let observed = observedOccupancy(current)
        var best: (pair: [Move], score: Int)?
        for one in first where delta.contains(one.from) && delta.contains(one.to) {
            let middle = position.applying(one)
            guard let second = await oracle.legalMoves(from: middle) else { continue }
            for two in second where delta.contains(two.from) && delta.contains(two.to) {
                // Same rule as a single ply: the board after both has to be
                // the board on screen, or this is a guess dressed as recovery.
                if !observed.isEmpty, agreement(middle.applying(two), with: observed) < 60 { continue }
                let score = upheaval(one.from) + upheaval(one.to)
                          + upheaval(two.from) + upheaval(two.to)
                if score > (best?.score ?? -1) { best = ([one, two], score) }
            }
        }
        return best?.pair
    }

    /// Is the position we are tracking still the position on screen?
    ///
    /// Nothing used to ask. `agreement` existed and was only ever used to pick
    /// between candidate moves, so a position that had drifted — from a
    /// misread board at the start, or one wrong resolution in the middle —
    /// stayed wrong forever and every suggestion after it was built on a
    /// fiction. That is how a knight came to be sent onto a pawn: the engine
    /// was right about the position it was given and the position was wrong.
    ///
    /// Checked while the board is still, once a second, and only believed after
    /// three in a row — a piece mid-animation or a square under the cursor
    /// should not be able to stop a game.
    private func verifyStillInSync(_ current: [Square: ChessWatcher.Signature]) {
        guard case .watching = state else { return }
        guard Date().timeIntervalSince(lastVerified) > 1 else { return }
        lastVerified = Date()

        let observed = observedOccupancy(current)
        guard !observed.isEmpty else { return }
        // Only a gross mismatch is worth acting on. A square or two adrift is
        // an animation frame or a piece being dragged; five or more is a
        // position that has genuinely diverged, and only then is it worth
        // throwing away what we have. Believed after three such frames running,
        // so a transient can't trip it.
        let wrong = 64 - agreement(position, with: observed)
        guard wrong >= 5 else { mismatches = 0; return }

        mismatches += 1
        ChessDiagnostics.trace("verify: \(wrong) squares disagree (\(mismatches)/3)")
        if mismatches == 1 { dumpMismatch(observed) }
        guard mismatches >= 3 else { return }
        mismatches = 0
        suggestions = []
        actuator?.clear()
        state = .recovering("The board stopped matching what Visor is tracking")
    }

    /// Check the click actually moved a piece, and click again if it didn't.
    ///
    /// Synthetic clicks land in someone else's web page, and a page is entitled
    /// to be busy, mid-animation, or briefly not listening. Firing once and
    /// assuming it worked is what made this feel unreliable: a move that didn't
    /// take left the session waiting for a change that was never coming, and
    /// the game simply stopped. Watching for the board to move is the only
    /// honest confirmation available.
    /// Read the page every quarter second and act on what changed.
    ///
    /// This replaces the whole detect-and-resolve chain when the position can
    /// be read directly. There is nothing to resolve: the page says where every
    /// piece is, and the colour of the piece that moved says whose turn it now
    /// is. A move is a difference between two readings.
    /// When the game last visibly advanced, for the watchdog below.
    private var lastProgress = Date()

    private func followPage() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            switch state { case .watching, .recovering: break; default: continue }
            guard !playingOwnMove, let oracle else { continue }
            guard let reading = try? await ChessDOM.read() else {
                ChessDiagnostics.trace("page: read failed")
                continue
            }

            let seen = reading.position
            if seen.placement == position.placement {
                // Nothing changed. Usually that's right — we're waiting for the
                // opponent. But if it's our turn and stays our turn, we failed
                // to play and would wait forever; a fresh ⌘⌃U was fixing that
                // by hand. The watchdog does it instead: after a few seconds
                // stuck on our own turn, play again.
                if position.turn == ourColour, Date().timeIntervalSince(lastProgress) > 4 {
                    ChessDiagnostics.trace("page: watchdog — our turn stalled, replaying")
                    lastProgress = Date()
                    let a = await oracle.analyse(position)
                    suggestions = a.lines
                    if mode == .playing { await playOurMove(a.lines, played: a.played) }
                    else { await actuator?.present(Array(a.lines.prefix(3)), on: geometry) }
                }
                continue
            }
            lastProgress = Date()

            // Whose turn it is, the simple and reliable way: it was one
            // colour's turn, the board changed, so it's the other colour's now.
            // Flipping from the turn we already knew needs no move-list selector
            // and no highlight — both of which are per-site, fragile, and were
            // producing garbage (playing as black never moved because the
            // highlight read wrong). The move-list ply count, when it can be
            // read, is an absolute cross-check that corrects a missed ply or a
            // restart; the highlight is gone.
            var next = seen
            next.turn = position.turn.opposite
            var how = "flip"
            if reading.plies > 0 {
                next.turn = reading.plies % 2 == 0 ? .white : .black
                how = "plies"
            }
            // A check has the last word: the checked side must be to move, so
            // it overrides a flip that drifted or a stale ply count.
            if let forced = next.forcedTurn { next.turn = forced; how = "check" }
            ChessDiagnostics.trace("page: turn " + (next.turn == ourColour ? "ours" : "theirs") + " (" + how + ")")
            // Rights are only ever lost. Keep ours, minus whatever the page
            // shows has moved off its home square.
            next.castling = position.castling.intersection(next.castling)
            let wasOurs = position.turn == ourColour
            position = next
            if case .recovering = state { state = .watching }
            ChessDiagnostics.trace("page: changed → \(next.turn == ourColour ? "our" : "their") turn — \(next.fen)")

            if next.turn == ourColour {
                // Where the opponent's move landed, for spotting a recapture.
                let oppTo = Self.movedToSquare(from: position, to: next, mover: ourColour.opposite)
                let a = await oracle.analyse(next)
                // Confirm the board is still what we analysed before acting on
                // it. The engine only ever returns a legal move for the
                // position it was given, so a move that "doesn't get out of
                // check" means the position it was given wasn't the one on the
                // board — the read caught the board a moment from settled, or
                // the opponent moved again while we thought. A fresh read
                // settles it: if the board has moved on, drop this and let the
                // next tick handle the real position rather than play a move
                // that was legal a moment ago and isn't now.
                if let fresh = try? await ChessDOM.read(),
                   fresh.position.placement != next.placement {
                    ChessDiagnostics.trace("page: board moved while thinking — re-reading")
                    continue
                }
                ChessDiagnostics.trace("page: our turn \(next.fen)  clock="
                                     + (reading.clockSeconds.map { String(format: "%.0fs", $0) } ?? "none")
                                     + " → " + a.lines.map { $0.move.uci }.prefix(3).joined(separator: ","))
                suggestions = a.lines
                if mode == .playing { await playOurMove(a.lines, played: a.played, recaptureOn: oppTo, clock: reading.clockSeconds) }
                else { await actuator?.present(Array(a.lines.prefix(3)), on: geometry) }
            } else if wasOurs {
                // Our move (made by hand, in advise mode) has landed.
                suggestions = []
                actuator?.clear()
            }
        }
    }

    /// The colour of whatever moved between two placements: the piece now on
    /// a square that was empty or held the other colour.
    private static func colourThatMoved(from a: ChessPosition, to b: ChessPosition) -> PieceColor? {
        for index in 0..<64 {
            guard let sq = Square(index: index) else { continue }
            if let now = b[sq], a[sq] == nil || a[sq]?.color != now.color { return now.color }
        }
        return nil
    }

    /// How long to wait before playing — fast when obvious, slow on a real
    /// decision. Forced is instant, a recapture near-instant; otherwise the
    /// clearer the best move stands above the next best, the sooner it comes,
    /// and a position where several moves are close drifts to the slow end of
    /// the band, the way a person lingers over a hard choice. Jittered so it is
    /// never mechanical.
    private func smartDelay(_ replies: [ScoredMove], forced: Bool, recapture: Bool,
                           clock: Double?) -> TimeInterval {
        let lo = min(latency.shortest, latency.longest)
        let hi = max(latency.shortest, latency.longest)
        if forced { return 0 }
        if recapture { return lo }

        // Fast by default, slow only for a genuine decision. Most positions
        // have a clear enough best move, so the gap to the second-best is
        // usually well over half a pawn — those come quick. Only a near-tie,
        // where several moves are within a fraction of a pawn, drifts to the
        // slow end. Squared, so the middle leans fast rather than sitting in
        // the centre of the band.
        var closeness = 0.0
        if replies.count >= 2 {
            let gap = abs(replies[0].score.centipawns - replies[1].score.centipawns)
            let raw = min(1.0, max(0.0, Double(60 - gap) / 60.0))   // 0 by 60cp, 1 at a dead tie
            closeness = raw * raw
        }
        var base = lo + closeness * (hi - lo)
        let jitter = (hi - lo) * 0.12
        base = max(lo, min(hi, base + Double.random(in: -jitter...jitter)))

        // Blitz as the flag approaches. Under a minute the whole delay is
        // scaled down towards zero in proportion to the time left, the way a
        // person stops thinking and just moves when low.
        if let clock, clock < 60 {
            let urgency = max(0.05, clock / 60.0)
            base *= urgency
        }
        return base
    }

    /// The square a move of `mover`'s colour landed on, between two positions —
    /// the opponent's destination, for spotting a recapture.
    private static func movedToSquare(from a: ChessPosition, to b: ChessPosition,
                                      mover: PieceColor) -> Square? {
        for index in 0..<64 {
            guard let sq = Square(index: index), let now = b[sq], now.color == mover else { continue }
            if a[sq] == nil || a[sq]?.color != mover { return sq }
        }
        return nil
    }

    private func playOurMove(_ replies: [ScoredMove], played: Move? = nil,
                            recaptureOn: Square? = nil, clock: Double? = nil) async {
        // The move to play is the engine's own choice — skill-noised when the
        // strength is turned down, so a weak setting can pick a genuinely worse
        // move than the top line the arrow shows.
        guard let move = played ?? replies.first?.move else { return }

        if !latestFrame.isEmpty, observedOccupancy(latestFrame)[move.from] == false {
            ChessDiagnostics.trace("play: \(move.uci) from an empty square — re-reading")
            suggestions = []
            actuator?.clear()
            state = .recovering("The board doesn't match — re-reading")
            return
        }

        suggestions = replies
        playingOwnMove = true

        if mode == .playing {
            let forced = (await oracle?.legalMoves(from: position)?.count ?? 2) <= 1
            let recapture = recaptureOn != nil && move.to == recaptureOn
            let wait = smartDelay(replies, forced: forced, recapture: recapture, clock: clock)
            ChessDiagnostics.trace(String(format: "play: %@ wait %.2fs (%@)", move.uci, wait,
                forced ? "forced" : recapture ? "recapture" : "paced"))
            if wait > 0.01 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            if source == .dom, let r = try? await ChessDOM.read(),
               r.position.placement != position.placement {
                playingOwnMove = false
                return
            }
        }

        position.apply(move)                 // it is the opponent's turn now
        await confirmOwnMove(move, attempt: 1)
    }

    /// Click our move and check the board actually took it, up to three times.
    ///
    /// The old path clicked, then waited for the *watcher* to notice the move
    /// land and treat it as a detected move — which raced the retry timer,
    /// double-counted the move, flipped the turn back to us, and had Visor play
    /// White's whole opening by itself and premove into the opponent's clock.
    /// We made the move; we don't rediscover it. Apply it, click it, confirm it
    /// against the live board, and absorb it into the baseline so the next
    /// change the watcher reports is the opponent's reply.
    private func confirmOwnMove(_ move: Move, attempt: Int) async {
        await actuator?.present([ScoredMove(move: move, score: .centipawns(0))], on: geometry)

        // Give it up to 1.8s to land, checking as it goes rather than once. A
        // single check at 900ms caught the piece mid-animation and called it
        // not landed, which triggered a retry that only made things worse.
        var landed = false
        for _ in 0..<6 {
            try? await Task.sleep(nanoseconds: 300_000_000)
            switch state { case .watching, .recovering: break; default: playingOwnMove = false; return }
            if source == .dom {
                // Landed once our piece has left its square. The whole board
                // need not match our applied position — against a bot that
                // recaptures in the same beat, it usually won't, because the
                // reply has already landed. Requiring an exact match made a
                // successful capture read as a failure, retry a pawn that had
                // already moved, and give up on a game that was fine.
                if let r = try? await ChessDOM.read(),
                   r.position[move.from]?.color != ourColour {
                    landed = true; break
                }
            } else {
                let occ = observedOccupancy(latestFrame)
                if occ[move.from] == false && occ[move.to] == true { landed = true; break }
            }
        }
        if landed {
            ChessDiagnostics.trace("play: \(move.uci) landed")
            lastProgress = Date()
            baseline = latestFrame            // absorb our move; next change is theirs
            settling = []
            changeBegan = nil
            playingOwnMove = false
            if case .recovering = state { state = .watching }
            await oracle?.prime(after: position)
            return
        }
        guard attempt < 3 else {
            ChessDiagnostics.trace("play: \(move.uci) didn't take after 3 tries")
            playingOwnMove = false
            if source == .dom {
                // The page is still the truth; let the poll re-read and decide,
                // rather than ending a game that may well be fine.
                if let r = try? await ChessDOM.read() {
                    position = r.position
                    if let mover = Self.colourThatMoved(from: position, to: r.position) {
                        position.turn = mover.opposite
                    }
                }
                state = .watching
            } else {
                fail("Played \(move.uci) three times and the board didn't take it")
            }
            return
        }
        ChessDiagnostics.trace("play: \(move.uci) not landed, retry \(attempt)")
        await confirmOwnMove(move, attempt: attempt + 1)
    }

    /// Which squares currently have something standing on them.
    private func observedOccupancy(_ current: [Square: ChessWatcher.Signature]) -> [Square: Bool] {
        var out: [Square: Bool] = [:]
        for (square, signature) in current { out[square] = signature.occupied }
        return out
    }

    /// How many of the 64 squares a candidate position agrees with the screen
    /// about. 64 is a perfect match.
    private func agreement(_ candidate: ChessPosition, with observed: [Square: Bool]) -> Int {
        guard !observed.isEmpty else { return 0 }
        var score = 0
        for index in 0..<64 {
            guard let square = Square(index: index), let seen = observed[square] else { continue }
            if (candidate[square] != nil) == seen { score += 1 }
        }
        return score
    }

    /// Which legal move the changed squares describe.
    ///
    /// Usually exactly one move has both its ends in the delta and there is
    /// nothing to decide. The ambiguous case is real, though: a board that
    /// highlights the last move puts four squares in play, and two unrelated
    /// legal moves can each have both ends inside that set.
    ///
    /// The tiebreak is how *much* each square changed. A square that lost or
    /// gained a piece changes enormously; one that only had a highlight wash
    /// removed barely changes at all. Summing both ends and taking the largest
    /// picks the move that actually happened.
    private func candidate(in delta: Set<Square>,
                           current: [Square: ChessWatcher.Signature]) async -> Move? {
        guard let oracle,
              let legal = await oracle.legalMoves(from: position),
              !legal.isEmpty
        else { return nil }

        let observed = observedOccupancy(current)

        // Reconcile the whole board, not the two squares that changed.
        //
        // The old rule — a legal move with both its squares inside the delta —
        // is a weak filter. Several legal moves can satisfy it, a highlight or
        // a legal-move dot pads the delta, and picking wrong desynced the
        // tracked position past recovery. Occupancy is reliable now, so the
        // real test is available: the move that happened is the one that makes
        // the tracked board's occupancy equal the board on screen. A move that
        // leaves even one square disagreeing is not the move that was played.
        //
        // This also rejects a move outright when the tracked position is
        // already wrong — nothing reconciles a fiction with reality — which is
        // the signal to re-read rather than drift further.
        guard !observed.isEmpty else {
            // No occupancy to check against (shouldn't happen once watching):
            // fall back to the endpoint filter.
            let ends = legal.filter { delta.contains($0.from) && delta.contains($0.to) }
            return ends.count == 1 ? ends[0] : nil
        }

        func reconciled(_ move: Move) -> Int {
            // How many of the 64 squares agree on occupancy after this move.
            let after = position.applying(move)
            var score = 0
            for index in 0..<64 {
                guard let sq = Square(index: index), let seen = observed[sq] else { continue }
                if (after[sq] != nil) == seen { score += 1 }
            }
            return score
        }

        // Only moves that put the whole board right, give or take one square
        // for a piece caught mid-slide.
        let scored = legal.map { ($0, reconciled($0)) }.filter { $0.1 >= 63 }
        guard !scored.isEmpty else { return nil }
        if scored.count == 1 { return scored[0].0 }

        // More than one move reconciles — usually two pieces that could reach
        // the same square, or promotion variants. The one whose *from* is in
        // the delta is the piece that actually left; failing that, prefer a
        // queen promotion, then the fuller reconciliation.
        let moved = scored.filter { delta.contains($0.0.from) && delta.contains($0.0.to) }
        let pool = moved.isEmpty ? scored : moved
        if let queen = pool.first(where: { $0.0.promotion == .queen }) { return queen.0 }
        return pool.max { $0.1 < $1.1 }?.0
    }

    /// Draw what the screen says next to what we think, so a disagreement can
    /// be read rather than guessed. Occupancy only — that is the thing in
    /// question.
    private func dumpMismatch(_ observed: [Square: Bool]) {
        var out = "occupancy — tracked | screen (X piece, . empty, ? unseen)\n"
        for rank in stride(from: 7, through: 0, by: -1) {
            var tracked = "  ", screen = ""
            for file in 0..<8 {
                guard let sq = Square(file: file, rank: rank) else { continue }
                tracked += position[sq] != nil ? "X " : ". "
                switch observed[sq] {
                case true?:  screen += "X "
                case false?: screen += ". "
                case nil:    screen += "? "
                }
            }
            out += tracked + "   " + screen + "\n"
        }
        ChessDiagnostics.trace(out)
    }

    private func fail(_ reason: String) {
        state = .lost(reason)
        actuator?.clear()
        watcher?.stop()
        Task { [oracle] in await oracle?.stop() }
    }
}
