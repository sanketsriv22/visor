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
    /// Readable so a resync can rebuild a session over the same board.
    let geometry: BoardGeometry
    let ourColour: PieceColor
    private let latency: LatencyBand

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
    /// What an empty square looks like, per colour, learned from the opening
    /// position where the middle four ranks are known to be bare.
    ///
    /// This is what makes a candidate move checkable. Knowing which squares
    /// *should* be occupied after a move, and being able to see which ones
    /// actually are, turns "which of these legal moves changed the most
    /// pixels" — a guess — into "which of these legal moves produces the board
    /// I am looking at".
    private var emptyLook: [Bool: ChessWatcher.Signature] = [:]

    /// When the tracked position was last checked against the screen, and how
    /// many checks in a row have disagreed.
    private var lastVerified = Date.distantPast
    private var mismatches = 0

    /// How many times the current move has been clicked at the board without
    /// the board changing.
    private var playAttempts = 0

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
         position: ChessPosition = .start, latency: LatencyBand = .default) {
        self.mode = mode
        self.geometry = geometry
        self.ourColour = ourColour
        self.position = position
        self.latency = latency
    }

    // ── lifecycle ─────────────────────────────────────────────────────

    func start() async throws {
        let oracle = try ChessOracle()
        self.oracle = oracle
        self.actuator = mode == .advising ? AdvisingActuator() : ClickingActuator()

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
            let best = await oracle.analyse(position)
            ChessDiagnostics.trace("session: our move first; engine offered "
                                 + best.map { "\($0.move.uci) \($0.score.display)" }.joined(separator: ", "))
            suggestions = best
            await actuator?.present(best, on: geometry)
            // The same watch-and-retry a mid-game click gets. Without it a
            // click that didn't take on the very first move failed silently
            // and the session sat waiting for a board that never changed.
            if mode == .playing { confirmPlayed(best) }
        } else {
            await oracle.prime(after: position)
        }
    }

    func stop() {
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
        guard !resolving else { return }
        switch state {
        case .watching, .recovering: break
        case .idle, .lost: return
        }
        if baseline.isEmpty {
            baseline = current
            learnEmptySquares(from: current)
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

        if let move = await candidate(in: delta, current: current) {
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
        playAttempts = 0
        for move in moves { position.apply(move) }

        // Never suggest into a position the screen disagrees with. An illegal
        // move offered confidently is worse than no move at all, and this is
        // the last place to catch one.
        let observed = observedOccupancy(current)
        if !observed.isEmpty, agreement(position, with: observed) < 60 {
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
                : await oracle.analyse(position)
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
                // setting could never be reached.
                let target = latency.sample()
                let spent = began.map { Date().timeIntervalSince($0) } ?? 0
                if target > spent {
                    try? await Task.sleep(nanoseconds: UInt64((target - spent) * 1_000_000_000))
                }
                // The board can move while we wait — the opponent premoved, or
                // the game ended. Acting on a stale answer would play into a
                // position that no longer exists.
                guard state == .watching, position.turn == ourColour else { return }
            }
            await actuator?.present(replies, on: geometry)
            if mode == .playing { confirmPlayed(replies) }
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
        guard case .watching = state, !emptyLook.isEmpty else { return }
        guard Date().timeIntervalSince(lastVerified) > 1 else { return }
        lastVerified = Date()

        let observed = observedOccupancy(current)
        guard !observed.isEmpty else { return }
        guard agreement(position, with: observed) < 61 else { mismatches = 0; return }

        mismatches += 1
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
    private func confirmPlayed(_ replies: [ScoredMove]) {
        playAttempts += 1
        let expected = position.fen
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard let self, self.mode == .playing, self.state == .watching else { return }
            // Anything moved means it landed — `commit` resets the count.
            guard self.position.fen == expected, self.position.turn == self.ourColour else { return }
            guard self.playAttempts < 3 else {
                ChessDiagnostics.trace("session: gave up on \(replies.first?.move.uci ?? "?") after 3 tries")
                self.fail("Played \(replies.first?.move.uci ?? "a move") three times "
                        + "and the board didn't change — " + TextInsertion.staleGrantAdvice)
                return
            }
            ChessDiagnostics.trace("session: board unchanged after \(replies.first?.move.uci ?? "?"), retrying (\(self.playAttempts))")
            await self.actuator?.present(replies, on: self.geometry)
            self.confirmPlayed(replies)
        }
    }

    /// Learn the two empty-square colours from the position we are starting
    /// from, whatever it is.
    ///
    /// This used to assume the middle four ranks were bare, which is true of a
    /// fresh game and of nothing else — and became wrong the moment a game
    /// could be joined midway. Asking the position which squares are empty
    /// works for both and is no harder.
    private func learnEmptySquares(from current: [Square: ChessWatcher.Signature]) {
        var sums: [Bool: (r: Int, g: Int, b: Int, n: Int)] = [:]
        for (square, signature) in current where position[square] == nil {
            let isLight = (square.file + square.rank) % 2 == 1
            var bucket = sums[isLight] ?? (0, 0, 0, 0)
            bucket.r += Int(signature.r); bucket.g += Int(signature.g)
            bucket.b += Int(signature.b); bucket.n += 1
            sums[isLight] = bucket
        }
        for (isLight, bucket) in sums where bucket.n > 0 {
            emptyLook[isLight] = ChessWatcher.Signature(
                r: UInt8(bucket.r / bucket.n),
                g: UInt8(bucket.g / bucket.n),
                b: UInt8(bucket.b / bucket.n))
        }
    }

    /// Which squares currently have something standing on them.
    private func observedOccupancy(_ current: [Square: ChessWatcher.Signature]) -> [Square: Bool] {
        guard !emptyLook.isEmpty else { return [:] }
        var out: [Square: Bool] = [:]
        for (square, signature) in current {
            let isLight = (square.file + square.rank) % 2 == 1
            guard let empty = emptyLook[isLight] else { continue }
            let distance = abs(Int(signature.r) - Int(empty.r))
                         + abs(Int(signature.g) - Int(empty.g))
                         + abs(Int(signature.b) - Int(empty.b))
            // Generous, because a last-move highlight is a real wash over an
            // empty square and must not read as a piece.
            out[square] = distance > 90
        }
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

        var matches = legal.filter { delta.contains($0.from) && delta.contains($0.to) }
        guard !matches.isEmpty else { return nil }

        // A move has happened only if the piece has left.
        //
        // Selecting a piece on chess.com highlights its square and draws a dot
        // on every square it could go to — so for as long as you are thinking,
        // the origin and every legal destination all count as "changed", and
        // every legal move of that piece looks complete. This resolved one of
        // them, applied a move that had not been made, and the real move then
        // matched nothing: nine seconds of catching up and a re-read of the
        // board, every time you paused with a piece selected. Visor's own
        // clicks are ninety milliseconds apart, which is why playing mode
        // never saw it. The tell is simple: after a real move the square it
        // came from is empty, and something is standing where it went.
        let observed = observedOccupancy(current)
        if !observed.isEmpty {
            matches = matches.filter { observed[$0.from] == false && observed[$0.to] == true }
            guard !matches.isEmpty else { return nil }
        }

        // Promotion variants share both squares, so no amount of looking at
        // pixels separates them. Queen: right often enough that the exceptions
        // are a curiosity.
        let endpoints = Set(matches.map { [$0.from, $0.to] })
        if matches.count > 1, endpoints.count == 1 {
            return matches.first { $0.promotion == .queen } ?? matches[0]
        }
        if matches.count == 1 { return matches[0] }

        // Rank by whether the move produces the board actually on screen.
        //
        // This replaced ranking by how much the two squares changed, which is
        // only a proxy and picks wrong whenever two legal moves both have their
        // ends inside the delta — which a last-move highlight makes common. One
        // wrong pick was unrecoverable: the tracked position diverged, every
        // later move failed to match, and the session sat waiting. Comparing
        // against the screen is the difference between a guess and a check.
        func upheaval(_ square: Square) -> Int {
            guard let now = current[square], let was = baseline[square] else { return 0 }
            return abs(Int(now.r) - Int(was.r)) + abs(Int(now.g) - Int(was.g))
                 + abs(Int(now.b) - Int(was.b))
        }
        return matches.max { a, b in
            let sa = agreement(position.applying(a), with: observed)
            let sb = agreement(position.applying(b), with: observed)
            if sa != sb { return sa < sb }
            return upheaval(a.from) + upheaval(a.to) < upheaval(b.from) + upheaval(b.to)
        }
    }

    private func fail(_ reason: String) {
        state = .lost(reason)
        actuator?.clear()
        watcher?.stop()
        Task { [oracle] in await oracle?.stop() }
    }
}
