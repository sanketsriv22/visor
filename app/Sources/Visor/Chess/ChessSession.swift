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
        /// The board on screen stopped matching the one we were keeping.
        /// Guessing on from here means playing illegal moves into someone's
        /// game, so this stops instead.
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
    private let geometry: BoardGeometry
    private let ourColour: PieceColor

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
         position: ChessPosition = .start) {
        self.mode = mode
        self.geometry = geometry
        self.ourColour = ourColour
        self.position = position
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
        if position.turn == ourColour {
            let best = await oracle.analyse(position)
            suggestions = best
            await actuator?.present(best, on: geometry)
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
        guard state == .watching, !resolving else { return }
        if baseline.isEmpty { baseline = current; return }

        let delta = Set(current.compactMap { square, signature -> Square? in
            guard let was = baseline[square], signature.differs(from: was) else { return nil }
            return square
        })
        guard !delta.isEmpty else {
            settling = []
            changeBegan = nil
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
        if let began = changeBegan, Date().timeIntervalSince(began) > 4 {
            fail("Lost track of the game — stop and start again from a fresh board")
        }
    }

    /// Apply what was seen, then decide what happens next.
    private func commit(_ moves: [Move], from before: ChessPosition,
                        current: [Square: ChessWatcher.Signature]) async {
        guard let oracle else { return }
        baseline = current
        settling = []
        for move in moves { position.apply(move) }

        if position.turn == ourColour {
            // Only a single ply the oracle primed for can come out of the
            // table; a two-ply recovery lands on a position nobody predicted.
            let replies = moves.count == 1
                ? await oracle.replies(to: moves[0], from: before)
                : await oracle.analyse(position)
            suggestions = replies
            if let began = changeBegan { lastLatency = Date().timeIntervalSince(began) }
            changeBegan = nil
            tableHitRate = await oracle.hitRate
            await actuator?.present(replies, on: geometry)
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

        var best: (pair: [Move], score: Int)?
        for one in first where delta.contains(one.from) && delta.contains(one.to) {
            let middle = position.applying(one)
            guard let second = await oracle.legalMoves(from: middle) else { continue }
            for two in second where delta.contains(two.from) && delta.contains(two.to) {
                let score = upheaval(one.from) + upheaval(one.to)
                          + upheaval(two.from) + upheaval(two.to)
                if score > (best?.score ?? -1) { best = ([one, two], score) }
            }
        }
        return best?.pair
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

        let matches = legal.filter { delta.contains($0.from) && delta.contains($0.to) }
        guard !matches.isEmpty else { return nil }

        // Promotion variants share both squares, so they all match equally and
        // no amount of looking at pixels separates them. Queen: it is the right
        // answer often enough that the exceptions are a curiosity, and the
        // async check below catches it if a bot ever does otherwise.
        let endpoints = Set(matches.map { [$0.from, $0.to] })
        if matches.count > 1, endpoints.count == 1 {
            return matches.first { $0.promotion == .queen } ?? matches[0]
        }

        func upheaval(_ square: Square) -> Int {
            guard let now = current[square], let was = baseline[square] else { return 0 }
            return abs(Int(now.r) - Int(was.r))
                 + abs(Int(now.g) - Int(was.g))
                 + abs(Int(now.b) - Int(was.b))
        }
        return matches.max { upheaval($0.from) + upheaval($0.to)
                           < upheaval($1.from) + upheaval($1.to) }
    }

    private func fail(_ reason: String) {
        state = .lost(reason)
        actuator?.clear()
        watcher?.stop()
        Task { [oracle] in await oracle?.stop() }
    }
}
