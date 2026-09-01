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
    /// When the current change first appeared, for the latency figure.
    private var changeBegan: Date?

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
        guard state == .watching else { return }
        if baseline.isEmpty { baseline = current; return }

        let delta = Set(current.compactMap { square, signature -> Square? in
            guard let was = baseline[square], signature.differs(from: was) else { return nil }
            return square
        })
        guard !delta.isEmpty else { settling = []; return }

        if changeBegan == nil { changeBegan = Date() }

        // Wait for the picture to hold still for one frame. During a piece's
        // slide the delta grows as the sprite crosses squares it isn't going to
        // land on, and resolving against a half-finished animation finds a move
        // that looks legal and isn't the one played. One frame at 120Hz costs
        // eight milliseconds of a five-hundred millisecond budget.
        guard delta == settling else {
            settling = delta
            return
        }

        Task { await resolve(delta: delta, current: current) }
    }

    private func resolve(delta: Set<Square>, current: [Square: ChessWatcher.Signature]) async {
        guard let oracle else { return }

        guard let move = await candidate(in: delta, current: current) else {
            // A wide delta that resolves to no legal move isn't a move at all —
            // it's a scrolled page, a resized window, or a new game. Narrow ones
            // are just noise and are left to settle.
            if delta.count > 6 {
                fail("The board stopped matching the game — start again once it's settled")
            }
            return
        }

        // The position as the oracle primed it: opponent to move, before this
        // move was played. Both `prime(after:)` and `replies(to:from:)` are
        // keyed on it, so it has to be captured before `apply`.
        let before = position

        baseline = current
        settling = []
        position.apply(move)

        if position.turn == ourColour {
            let replies = await oracle.replies(to: move, from: before)
            suggestions = replies
            if let began = changeBegan { lastLatency = Date().timeIntervalSince(began) }
            changeBegan = nil
            tableHitRate = await oracle.hitRate
            await actuator?.present(replies, on: geometry)
        } else {
            // Our own move just landed on screen — in `playing` mode because we
            // clicked it, in `advising` mode because the user did. Either way
            // the opponent's clock has started, and their clock is our compute
            // window.
            suggestions = []
            actuator?.clear()
            changeBegan = nil
            await oracle.prime(after: position)
        }
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
