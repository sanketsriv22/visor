import Foundation

/// Answers "what should I play" in about a microsecond, by having answered it
/// before the question was asked.
///
/// The naive loop searches when the opponent moves, and a search is the slowest
/// thing in the pipeline by two orders of magnitude — everything else is pixels
/// and pointer arithmetic. But chess is turn-based, and the opponent's thinking
/// time is dead air we own: their position is known, their legal moves are
/// enumerable, and there are only ever thirty or forty of them. So we answer
/// all of them in advance, and the "search" at move time becomes a dictionary
/// lookup.
///
/// This is what makes the thing quick. Not the capture rate and not the event
/// posting — those were never the problem. It's that by the time the opponent
/// has moved, the reply has been sitting in a hash table for a second and a
/// half.
///
/// Stockfish's own `go ponder` does a version of this for the single expected
/// move. That isn't enough here: the bots on chess.com are deliberately weak
/// and play the second- or fifth-best move constantly, so pondering the top
/// line would miss more often than it hit. Covering every legal reply costs
/// more and misses never.
actor ChessOracle {
    /// How deep each precomputed line goes. Twelve is already far beyond every
    /// bot on the site and lands in about 30ms a position. There is no prize
    /// for winning by more.
    private let depth: Int
    /// How many moves to show. Three arrows is a glance; five is homework.
    private let lines: Int

    /// Answers the questions that are on the critical path — which moves are
    /// legal, and what to play when the table missed.
    ///
    /// Deliberately not one of the pool. An actor serialises its callers, so a
    /// scout that was also priming would make every legal-move lookup queue
    /// behind a 30ms search, and that lookup happens on the one path where the
    /// milliseconds are being counted.
    private let scout: ChessEngine
    /// Does the precomputing, and nothing that is ever waited on.
    private var pool: [ChessEngine]

    private var table: [Move: [ScoredMove]] = [:]
    private var priming: Task<Void, Never>?

    /// Whether answers came out of the table or had to be searched. Worth
    /// surfacing: a run that misses constantly is one where the priming window
    /// is too short, which is a tuning problem rather than a bug, and the two
    /// look identical from the outside.
    private(set) var hits = 0
    private(set) var misses = 0
    var hitRate: Double? {
        let total = hits + misses
        return total == 0 ? nil : Double(hits) / Double(total)
    }

    init(poolSize: Int = 6, depth: Int = 12, lines: Int = 3, elo: Int? = nil) throws {
        self.depth = depth
        self.lines = lines
        self.scout = try ChessEngine(threads: 1, hashMB: 16, elo: elo)
        // One thread each. We're already running as many searches as there are
        // cores, and Stockfish threads within a search fight each other for the
        // same hash table — more threads per engine here would be slower, not
        // faster.
        self.pool = try (0..<max(1, poolSize)).map { _ in
            try ChessEngine(threads: 1, hashMB: 32, elo: elo)
        }
    }

    /// Every legal move in a position. On the critical path, so it goes to the
    /// scout.
    func legalMoves(from position: ChessPosition) async -> [Move]? {
        try? await scout.legalMoves(from: position.fen)
    }

    /// Start answering every move the opponent could make from `position`.
    ///
    /// Returns immediately. Call it the instant our own move lands, so the work
    /// happens while the opponent is still thinking — that window is the whole
    /// budget, and it costs nothing.
    func prime(after position: ChessPosition) async {
        priming?.cancel()
        table.removeAll(keepingCapacity: true)

        guard let moves = await legalMoves(from: position), !moves.isEmpty else { return }

        let pool = self.pool
        let depth = self.depth
        let lines = self.lines
        let stride = max(1, Int((Double(moves.count) / Double(pool.count)).rounded(.up)))
        // Each engine gets its own slice rather than pulling from a shared
        // queue. The slices cost near enough the same, and a queue would need
        // another actor hop per position just to hand out the next one.
        let chunks = Swift.stride(from: 0, to: moves.count, by: stride)
            .map { Array(moves[$0..<Swift.min($0 + stride, moves.count)]) }

        priming = Task { [weak self] in
            await withTaskGroup(of: [(Move, [ScoredMove])].self) { group in
                for (engine, chunk) in zip(pool, chunks) {
                    group.addTask {
                        var answers: [(Move, [ScoredMove])] = []
                        for move in chunk {
                            if Task.isCancelled { return answers }
                            guard let best = try? await engine.analyse(
                                fen: position.applying(move).fen, depth: depth, lines: lines)
                            else { continue }
                            answers.append((move, best))
                        }
                        return answers
                    }
                }
                for await answers in group {
                    await self?.store(answers)
                }
            }
        }
    }

    private func store(_ answers: [(Move, [ScoredMove])]) {
        for (move, best) in answers { table[move] = best }
    }

    /// What to play now that the opponent has played `move` from `position`.
    ///
    /// The fast path is a lookup and costs nothing. The slow path is a real
    /// search, which happens when priming hadn't finished or the opponent did
    /// something the table doesn't cover. It still lands well inside the
    /// budget; it just isn't free.
    func replies(to move: Move, from position: ChessPosition) async -> [ScoredMove] {
        if let cached = table[move] {
            hits += 1
            return cached
        }
        misses += 1
        priming?.cancel()
        return (try? await scout.analyse(fen: position.applying(move).fen,
                                         depth: depth, lines: lines)) ?? []
    }

    /// Analyse a position nobody predicted — used when watching starts
    /// mid-game, so there are arrows up before the opponent's next move rather
    /// than after it.
    func analyse(_ position: ChessPosition) async -> [ScoredMove] {
        (try? await scout.analyse(fen: position.fen, depth: depth, lines: lines)) ?? []
    }

    func stop() async {
        priming?.cancel()
        priming = nil
        table.removeAll()
        await scout.interrupt()
        for engine in pool { await engine.interrupt() }
    }
}
