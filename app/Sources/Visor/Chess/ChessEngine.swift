import Foundation

/// How good a move is, from the perspective of whoever is to move.
///
/// UCI already reports scores that way, and every position we ask about is one
/// where it's our turn, so positive is always good for us and nothing needs
/// negating. The one rule worth writing down, because forgetting it inverts the
/// arrows and looks like the engine has lost its mind.
enum Score: Equatable, Comparable {
    case centipawns(Int)
    /// Positive is mate we deliver in n; negative is mate we receive.
    case mate(Int)

    /// A single ordering across both cases. Mate is worth more than any
    /// material advantage, and a shorter mate more than a longer one.
    private var rank: Int {
        switch self {
        case .centipawns(let cp): return cp
        case .mate(let n): return n > 0 ? 1_000_000 - n : -1_000_000 - n
        }
    }
    static func < (a: Score, b: Score) -> Bool { a.rank < b.rank }

    /// What to draw next to an arrow. Pawns, signed, the way every chess UI
    /// in the world shows it.
    var display: String {
        switch self {
        case .mate(let n): return n > 0 ? "M\(n)" : "-M\(abs(n))"
        case .centipawns(let cp):
            let pawns = Double(cp) / 100
            return (cp > 0 ? "+" : "") + String(format: "%.1f", pawns)
        }
    }
}

struct ScoredMove: Equatable {
    let move: Move
    let score: Score
}

/// Turns a pipe into a sequence of lines.
///
/// A separate object rather than state on the actor, for a dull but immovable
/// reason: `readabilityHandler` is set during the engine's `init`, and a
/// closure created there cannot capture `self` — it isn't fully formed yet.
/// A small class that is finished before the handler is attached can be
/// captured, and it can own the partial-line buffer that the handler has to
/// mutate.
///
/// Stockfish writes whole lines; the pipe does not respect them. A read can
/// land mid-line and the next one carries the rest, so the splitting has to
/// happen somewhere. Doing it here lets everything above assume a line is a
/// line.
private final class LineReader: @unchecked Sendable {
    private let lock = NSLock()
    private var buffered: [String] = []
    private var waiter: CheckedContinuation<String?, Never>?
    private var partial = ""
    private var finished = false

    func attach(to handle: FileHandle) {
        handle.readabilityHandler = { [self] handle in ingest(handle.availableData) }
    }

    /// No more is coming. Anyone waiting gets nil rather than hanging.
    func finish() {
        lock.lock()
        finished = true
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume(returning: nil)
    }

    private func ingest(_ data: Data) {
        guard !data.isEmpty else { finish(); return }
        lock.lock()
        partial += String(decoding: data, as: UTF8.self)
        var ready: [String] = []
        while let newline = partial.firstIndex(of: "\n") {
            ready.append(String(partial[partial.startIndex..<newline]))
            partial = String(partial[partial.index(after: newline)...])
        }
        // Hand the first line straight to whoever is waiting and buffer the
        // rest. Resuming a continuation while holding the lock would run the
        // waiting task's next hop inside the critical section.
        var handoff: (CheckedContinuation<String?, Never>, String)?
        if let waiting = waiter, let first = ready.first {
            waiter = nil
            handoff = (waiting, first)
            ready.removeFirst()
        }
        buffered.append(contentsOf: ready)
        lock.unlock()
        if let (continuation, line) = handoff { continuation.resume(returning: line) }
    }

    /// A line already in hand, or the news that there won't be any more.
    private enum Ready {
        case line(String)
        case ended
    }

    func next() async -> String? {
        switch takeReady() {
        case .line(let line): return line
        case .ended:          return nil
        case nil:             return await withCheckedContinuation { install($0) }
        }
    }

    /// What can be answered without waiting, or nil meaning "you'll have to".
    ///
    /// Split out of `next()` because NSLock may not be taken from an async
    /// context — it's a warning today and an error under Swift 6, and the
    /// reason is real: holding a lock across a suspension point parks it on
    /// whatever thread resumes.
    private func takeReady() -> Ready? {
        lock.lock()
        defer { lock.unlock() }
        if !buffered.isEmpty { return .line(buffered.removeFirst()) }
        if finished { return .ended }
        return nil
    }

    private func install(_ continuation: CheckedContinuation<String?, Never>) {
        lock.lock()
        // Re-checked: a line can arrive between `takeReady` returning nil and
        // this running, and without the second look it would sit in the buffer
        // with a waiter installed that nothing will ever wake.
        if !buffered.isEmpty {
            let line = buffered.removeFirst()
            lock.unlock()
            continuation.resume(returning: line)
            return
        }
        if finished {
            lock.unlock()
            continuation.resume(returning: nil)
            return
        }
        waiter = continuation
        lock.unlock()
    }
}

/// One Stockfish process, spoken to in UCI.
///
/// An actor because the protocol is a conversation on a single pipe: two
/// overlapping questions and the answers interleave into nonsense. Serialising
/// at the type level is cheaper than remembering to.
actor ChessEngine {
    enum EngineError: LocalizedError {
        case notFound
        case died
        case timedOut(String)

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "Stockfish isn't installed — `brew install stockfish`"
            case .died:
                return "The engine stopped responding"
            case .timedOut(let what):
                return "The engine didn't answer \(what) in time"
            }
        }
    }

    private let process: Process
    private let input: FileHandle
    private let reader: LineReader

    /// Where a Stockfish might be.
    ///
    /// Checked as paths rather than by running `which`, which needs a login
    /// shell to have the Homebrew prefix on PATH and a GUI app launched from
    /// Finder does not have one. An app bundle that inherits Finder's
    /// environment sees a PATH of `/usr/bin:/bin:/usr/sbin:/sbin` and concludes
    /// that a perfectly well installed engine isn't there.
    static func locate() -> URL? {
        var candidates: [String] = []
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "stockfish") {
            candidates.append(bundled.path)
        }
        candidates += [
            "/opt/homebrew/bin/stockfish",     // Apple silicon Homebrew
            "/usr/local/bin/stockfish",        // Intel Homebrew
            "/opt/local/bin/stockfish",        // MacPorts
            "/usr/games/stockfish",
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { $0 + "/stockfish" }
        }
        return candidates.lazy
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
            .first
            .map { URL(fileURLWithPath: $0) }
    }

    private let elo: Int?

    init(threads: Int = 1, hashMB: Int = 64, elo: Int? = nil) throws {
        self.elo = elo
        guard let binary = Self.locate() else { throw EngineError.notFound }

        let process = Process()
        process.executableURL = binary
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        let reader = LineReader()
        reader.attach(to: stdout.fileHandleForReading)
        process.terminationHandler = { _ in reader.finish() }
        try process.run()

        self.process = process
        self.input = stdin.fileHandleForWriting
        self.reader = reader

        Task { try? await self.handshake(threads: threads, hashMB: hashMB, elo: elo) }
    }

    deinit {
        try? input.write(contentsOf: Data("quit\n".utf8))
        process.terminate()
    }

    // ── the conversation ──────────────────────────────────────────────

    private func write(_ command: String) {
        guard process.isRunning else { return }
        try? input.write(contentsOf: Data((command + "\n").utf8))
    }

    /// Send a command and collect output until `isDone` recognises the last
    /// line. Bounded, because a wedged engine should fail rather than hang the
    /// whole loop waiting for a `bestmove` that isn't coming.
    private func ask(_ command: String, what: String, timeout: TimeInterval = 10,
                     until isDone: (String) -> Bool) async throws -> [String] {
        write(command)
        var collected: [String] = []
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let line = await reader.next() else { throw EngineError.died }
            collected.append(line)
            if isDone(line) { return collected }
        }
        throw EngineError.timedOut(what)
    }

    private func handshake(threads: Int, hashMB: Int, elo: Int?) async throws {
        _ = try await ask("uci", what: "uci") { $0.hasPrefix("uciok") }
        write("setoption name Threads value \(threads)")
        write("setoption name Hash value \(hashMB)")
        // Play down to a rating, when asked. Stockfish's own limiter — it
        // deliberately picks weaker moves rather than searching shallower, so
        // the play *feels* like a human of that rating rather than a strong
        // engine given less time. Its floor is 1320; below that it clamps.
        if let elo {
            write("setoption name UCI_LimitStrength value true")
            write("setoption name UCI_Elo value \(max(1320, min(3190, elo)))")
        }
        _ = try await ask("isready", what: "isready") { $0.hasPrefix("readyok") }
    }

    /// Wait until the engine has finished digesting whatever it was last told.
    func ready() async throws {
        _ = try await ask("isready", what: "isready") { $0.hasPrefix("readyok") }
    }

    // ── what we actually ask it ───────────────────────────────────────

    /// Every legal move in a position.
    ///
    /// `go perft 1` walks the root and prints each move with its node count,
    /// which is a complete, correct, already-debugged move generator we get for
    /// the price of a pipe write. The alternative was writing one, and a move
    /// generator that is wrong about en passant in one position out of a
    /// thousand is worse than no move generator at all: it fails rarely enough
    /// to look like something else.
    func legalMoves(from fen: String) async throws -> [Move] {
        let output = try await ask("position fen \(fen)\ngo perft 1",
                                   what: "perft") { $0.hasPrefix("Nodes searched") }
        return output.compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return Move(uci: String(line[line.startIndex..<colon]))
        }
    }

    /// The best `lines` moves, deepest evaluation first.
    func analyse(fen: String, depth: Int, lines count: Int) async throws -> [ScoredMove] {
        write("setoption name MultiPV value \(count)")
        let output = try await ask("position fen \(fen)\ngo depth \(depth)",
                                   what: "search", timeout: 20) { $0.hasPrefix("bestmove") }

        // Keep the last `info` line for each multipv slot: Stockfish reports
        // every iteration of the deepening loop and only the final one is at
        // the depth we asked for.
        var best: [Int: ScoredMove] = [:]
        for line in output where line.hasPrefix("info ") {
            let fields = line.split(separator: " ").map(String.init)
            guard let pvIndex = fields.firstIndex(of: "multipv"),
                  let slot = Int(fields[safe: pvIndex + 1] ?? ""),
                  let scoreIndex = fields.firstIndex(of: "score"),
                  let kind = fields[safe: scoreIndex + 1],
                  let value = Int(fields[safe: scoreIndex + 2] ?? ""),
                  let moveIndex = fields.firstIndex(of: "pv"),
                  let move = Move(uci: fields[safe: moveIndex + 1] ?? "")
            else { continue }
            let score: Score = kind == "mate" ? .mate(value) : .centipawns(value)
            best[slot] = ScoredMove(move: move, score: score)
        }
        return best.sorted { $0.key < $1.key }.map(\.value)
    }

    /// Stop whatever search is running. The engine still emits a `bestmove`,
    /// so the caller's `ask` completes rather than timing out.
    func interrupt() { write("stop") }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
