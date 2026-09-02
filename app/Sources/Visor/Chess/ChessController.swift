import AppKit
import ApplicationServices
import Combine
import ScreenCaptureKit

/// Owns the chess session, and everything the user has to be told before one
/// can start.
///
/// Kept separate from `ChessSession` because the session is a pipeline and this
/// is a switch: the session assumes it has a board, an engine and permission,
/// and this is what establishes those and says which one is missing when it
/// can't. Cramming the two together would put "Stockfish isn't installed"
/// inside the frame handler.
/// How long to wait before playing a move, as a range to pick from.
///
/// A move played the instant the opponent's lands is the one thing about this
/// that looks nothing like a person at the board. Answering in forty
/// milliseconds every single time is also just worse to sit next to — the reply
/// arrives before you have finished seeing what was played. The engine is still
/// as fast as it was; this decides when to use the answer, not when to find it.
/// How strong the engine plays. Full strength, or capped to a rating.
struct ChessStrength: Equatable {
    /// nil = full strength; otherwise a UCI Elo (Stockfish floor is 1320).
    var elo: Int?

    static let `default` = ChessStrength(elo: nil)
    static let range: ClosedRange<Double> = 1320...3000

    var display: String { elo.map { "\($0) Elo" } ?? "Full strength" }

    /// How deep the engine searches. This, more than UCI_Elo, is what makes it
    /// play like the rating rather than a strong engine picking quiet moves:
    /// Stockfish's Elo limiter avoids blunders even at its 1320 floor, so it
    /// still scores ~99% accuracy. A shallow search misses the tactics a player
    /// of that level would miss, which is what "weaker" actually looks like.
    /// Full strength searches deep; 1320 searches only a few ply.
    var searchDepth: Int {
        guard let elo else { return 14 }
        let t = Double(elo - 1320) / Double(3000 - 1320)   // 0 at floor, 1 at top
        return Int((4.0 + t * 10.0).rounded())             // 4 … 14
    }

    /// Stockfish Skill Level (0–20). Below 20 it randomly plays a worse move —
    /// the source of the occasional real blunder a weak human makes, which the
    /// Elo limiter alone never produces. Low ratings get a low level.
    var skillLevel: Int? {
        guard let elo else { return nil }              // full strength: no skill cap
        let t = Double(elo - 1320) / Double(3000 - 1320)
        return Int((1.0 + t * 19.0).rounded())         // 1 … 20
    }

    private static let key = "visor.chess.elo"
    static var stored: ChessStrength {
        get {
            let v = UserDefaults.standard.integer(forKey: key)   // 0 when unset
            return ChessStrength(elo: v == 0 ? nil : v)
        }
        set { UserDefaults.standard.set(newValue.elo ?? 0, forKey: key) }
    }
}

struct LatencyBand: Equatable {
    /// Seconds.
    var shortest: TimeInterval
    var longest: TimeInterval

    static let `default` = LatencyBand(shortest: 0.05, longest: 3.0)
    /// What the sliders allow.
    static let range: ClosedRange<TimeInterval> = 0...10

    /// A wait, uniform across the band.
    func sample() -> TimeInterval {
        let low = min(shortest, longest), high = max(shortest, longest)
        return low == high ? low : .random(in: low...high)
    }

    var display: String {
        func label(_ seconds: TimeInterval) -> String {
            seconds < 1 ? "\(Int(seconds * 1000))ms"
                        : String(format: "%.1fs", seconds)
        }
        return "\(label(min(shortest, longest))) – \(label(max(shortest, longest)))"
    }

    private static let key = "visor.chess.latencyBand"

    static var stored: LatencyBand {
        get {
            let defaults = UserDefaults.standard
            guard let pair = defaults.array(forKey: key) as? [Double], pair.count == 2
            else { return .default }
            return LatencyBand(shortest: pair[0], longest: pair[1])
        }
        set {
            UserDefaults.standard.set([newValue.shortest, newValue.longest], forKey: key)
        }
    }
}

@MainActor
final class ChessController: ObservableObject {
    static let shared = ChessController()

    /// Which mode a session starts in. Persisted, defaulting to the one that
    /// doesn't touch the mouse — the safe default is the useful one here, so
    /// there's no reason to make anybody choose.
    @Published var mode: ChessMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) }
    }

    /// Only consulted when Visor is the one moving the pieces. Arrows have no
    /// reason to arrive late — the whole point of them is to be there before
    /// you have finished looking.
    @Published var latency: LatencyBand {
        didSet { LatencyBand.stored = latency }
    }
    /// Only takes effect on the next game — engines read it when they launch.
    @Published var strength: ChessStrength {
        didSet { ChessStrength.stored = strength }
    }

    @Published private(set) var session: ChessSession?
    /// A line for the settings pane. Nil while nothing needs saying.
    @Published private(set) var notice: String?

    private let calibrator = ChessCalibrator()
    private let badge = ChessStatusBadge()
    private var watchingState: AnyCancellable?
    private var watchingInfo: AnyCancellable?
    private var resyncing = false
    private static let modeKey = "visor.chess.mode"

    private init() {
        mode = UserDefaults.standard.string(forKey: Self.modeKey)
            .flatMap(ChessMode.init(rawValue:)) ?? .advising
        latency = LatencyBand.stored
        strength = ChessStrength.stored
    }

    var isWatching: Bool { session != nil }

    /// What ⌘⌃U does. Starting with one key and having to open Settings to
    /// stop is a half-built shortcut.
    func toggle() {
        if isWatching { stop() } else { watchABoard() }
    }

    // ── what has to be true first ─────────────────────────────────────

    /// Whether an engine can be found. Checked rather than assumed: without one
    /// there is nothing to say about a position, and the failure would
    /// otherwise land as an empty overlay.
    var engine: URL? { ChessEngine.locate() }
    var hasScreenRecording: Bool { ChessWatcher.isPermitted }
    var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Accessibility is only needed to move pieces. Advising never touches the
    /// mouse, so asking for it up front would be asking for a permission the
    /// default mode has no use for.
    var needsAccessibility: Bool { mode == .playing }

    var isReady: Bool {
        engine != nil && hasScreenRecording && (!needsAccessibility || hasAccessibility)
    }

    /// What's stopping it, in the order worth fixing.
    var blocker: String? {
        if engine == nil { return "Stockfish isn't installed" }
        if !hasScreenRecording { return "Visor can't see the screen yet" }
        if needsAccessibility && !hasAccessibility { return "Visor can't move the mouse yet" }
        return nil
    }

    func requestScreenRecording() {
        // Returns immediately and the grant only takes effect for a fresh
        // launch, which is macOS's rule and not something to paper over — so
        // say it rather than leaving the button looking broken.
        _ = ChessWatcher.requestPermission()
        notice = "Granted? Quit and reopen Visor — macOS only hands screen access to a new launch."
        objectWillChange.send()
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        objectWillChange.send()
    }

    func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    // ── running ───────────────────────────────────────────────────────

    /// Find a board and start watching it.
    ///
    /// Looks for one first. The drag picker only appears when that fails,
    /// which is the right way round: being asked to draw a box around
    /// something already on screen is a chore, and it was only ever there
    /// because nothing was looking.
    func watchABoard() {
        guard !isWatching else { return }
        if let blocker {
            notice = blocker
            return
        }
        notice = "Looking for a board…"
        badge.show("Finding board…", live: false)

        Task {
            // The page first, and on its own — a browser board is read straight
            // from the DOM, geometry and all, with no screenshot and no pixel
            // search. Gating this behind the pixel finder was why Lichess
            // "couldn't find the board": the finder failed on its theme and the
            // DOM read that would have worked was never reached.
            if let page = try? await ChessDOM.read(), let rect = page.boardRect {
                var position = page.position
                let fresh = position.placement == ChessPosition.start.placement
                // Whose turn at the join, as reliably as a single snapshot
                // allows, in order: the starting position is White's; a check
                // forces the checked side to move; the page's move count, when
                // it can be read, gives it; otherwise ask, because guessing
                // wrong makes us wait forever for a move already made — which is
                // exactly what "as black it never moved from the start" was, the
                // move count reading zero after White's first move.
                if fresh {
                    position.turn = .white
                } else if let forced = position.forcedTurn {
                    position.turn = forced
                } else if page.plies > 0 {
                    position.turn = page.plies % 2 == 0 ? .white : .black
                } else {
                    guard let turn = await self.askWhoseTurn(suggested: position.turn) else {
                        self.notice = nil; self.badge.hide(); return
                    }
                    position.turn = turn
                }
                let geometry = BoardGeometry(origin: rect.origin, square: rect.width / 8,
                                             flipped: page.flipped)
                ChessDiagnostics.trace("join via \(page.site): \(position.fen)  board \(rect)")
                self.notice = nil
                self.begin(with: ChessCalibrator.Result(
                    geometry: geometry, ourColour: page.flipped ? .black : .white),
                           position: position, source: .dom)
                return
            }

            // No page to read: the pixel path, and the draw-a-box fallback.
            let shot = try? await ChessScreen.capture()
            guard let shot else {
                self.fail("Couldn't take a picture of the screen.")
                return
            }

            let found = ChessBoardFinder.find(in: shot.image, displayOrigin: shot.origin)
            if let found {
                guard Self.looksLikeAFreshGame(found.occupancy) else {
                    self.badge.show("Reading the position…", live: false)
                    guard let board = shot.cropping(to: found.geometry.rect) else {
                        self.fail("Couldn't cut the board out of the screenshot.")
                        return
                    }
                    do {
                        let reading = try await ChessVision.read(
                            board: board, occupancy: found.occupancy,
                            flipped: found.geometry.flipped, tolerance: 3)
                        guard let turn = await self.askWhoseTurn(suggested: reading.position.turn) else {
                            self.notice = nil; self.badge.hide(); return
                        }
                        var position = reading.position
                        position.turn = turn
                        ChessDiagnostics.record(shot: shot, found: found,
                                                verdict: "joined mid-game (pixels): \(position.fen)")
                        self.notice = nil
                        self.begin(with: ChessCalibrator.Result(
                            geometry: found.geometry,
                            ourColour: found.geometry.flipped ? .black : .white),
                                   position: position)
                    } catch {
                        ChessDiagnostics.record(shot: shot, found: found,
                                                verdict: "mid-game read failed: \(error.localizedDescription)")
                        self.fail(error.localizedDescription)
                    }
                    return
                }
                ChessDiagnostics.record(shot: shot, found: found, verdict: "started (pixels)")
                self.notice = nil
                self.begin(with: ChessCalibrator.Result(
                    geometry: found.geometry,
                    ourColour: found.geometry.flipped ? .black : .white))
                return
            }

            ChessDiagnostics.record(shot: shot, found: nil, verdict: "no board found")
            self.notice = "Couldn't find a board on that screen — draw a box around it."
            self.badge.show("No board found", live: false, fadingAfter: 4)
            self.calibrator.run { [weak self] result in
                guard let self, let result else { self?.notice = nil; self?.badge.hide(); return }
                self.notice = nil
                self.begin(with: result)
            }
        }
    }

    /// Thirty-two pieces, all of them on the outer two ranks at each end.
    ///
    /// Deliberately not exact: a piece can be mid-animation, and a square under
    /// the cursor can be tinted enough to be missed. Thirty of thirty-two, all
    /// at home, is a fresh game; anything else isn't, and the difference
    /// matters more than the precision does.
    private static func looksLikeAFreshGame(_ occupancy: [Square: PieceColor?]) -> Bool {
        let occupied = occupancy.compactMap { $0.value == nil ? nil : $0.key }
        guard occupied.count >= 30 else { return false }
        // Two strays forgiven. A square under the cursor picks up a hover
        // tint, a piece can be mid-animation, and a legal-move dot is a real
        // mark on an empty square — none of which mean the game has started,
        // and demanding a perfect read makes a fresh board fail for reasons
        // nobody can see.
        let strays = occupied.filter { !($0.rank <= 1 || $0.rank >= 6) }
        return strays.count <= 2
    }

    private func begin(with result: ChessCalibrator.Result,
                       position: ChessPosition = .start, source: ChessSource = .pixels) {
        // The position is assumed to be a fresh game. Nothing here reads
        // pieces — only which squares changed — so there is no way to work out
        // a board that was already in progress, and starting mid-game would
        // silently track a position that isn't the one on screen.
        let session = ChessSession(mode: mode,
                                   geometry: result.geometry,
                                   ourColour: result.ourColour,
                                   position: position,
                                   latency: latency,
                                   source: source,
                                   elo: strength.elo,
                                   searchDepth: strength.searchDepth,
                                   skill: strength.skillLevel)
        self.session = session
        Task {
            do {
                try await session.start()
                let colour = result.ourColour == .white ? "White" : "Black"
                let what = self.mode == .advising ? "watching" : "playing"
                self.badge.show("\(what.capitalized) · \(colour)")

                // The island is the only place most of this is ever seen —
                // Settings is not the window anybody is looking at during a
                // game.
                self.watchingState = session.$state
                    .receive(on: RunLoop.main)
                    .sink { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .watching:
                            self.badge.show(session.info.isEmpty
                                ? "\(what.capitalized) · \(colour)" : session.info)
                        case .recovering:
                            self.badge.show("Catching up…", live: false)
                            self.scheduleResync()
                        case .lost(let why):
                            self.badge.show(why, live: false, fadingAfter: 8)
                        case .idle:
                            self.badge.hide()
                        }
                    }
                // Live status: refresh the island text as the game moves.
                self.watchingInfo = session.$info
                    .receive(on: RunLoop.main)
                    .sink { [weak self] text in
                        guard let self, case .watching = session.state, !text.isEmpty else { return }
                        self.badge.show(text)
                    }
                // Clicking the island stops it, which is the other half of the
                // shortcut and the only control most people will ever see.
                self.badge.onClick = { [weak self] in self?.stop() }
            } catch {
                self.fail(error.localizedDescription)
                self.session = nil
            }
        }
    }

    /// Say it in both places. Settings explains; the badge is what gets seen,
    /// because Settings is usually not the window being looked at.
    private func fail(_ reason: String) {
        notice = reason
        badge.show(reason, live: false, fadingAfter: 5)
    }

    /// Read the board again and carry on from what is actually there.
    ///
    /// The session can tell when its position has stopped matching the screen,
    /// but not what the right one is — it only ever sees which squares changed,
    /// never what is on them. Re-reading is the only way back, and it is much
    /// better than the alternative of telling someone to abandon a game they
    /// are in the middle of.
    private func scheduleResync() {
        guard !resyncing else { return }
        resyncing = true
        Task { [weak self] in
            // A short grace for ordinary catching-up — a covered board or a
            // single missed move fixes itself and needs no re-read. Nine
            // seconds of it felt like a hang; under two does not, and a genuine
            // desync still re-reads promptly.
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard let self else { return }
            defer { self.resyncing = false }
            guard let session = self.session, case .recovering = session.state else { return }
            await self.resync(over: session.geometry)
        }
    }

    private func resync(over geometry: BoardGeometry) async {
        guard OpenRouterClient.key != nil else {
            self.notice = "Lost the position, and re-reading the board needs an OpenRouter key."
            return
        }
        badge.show("Re-reading the board…", live: false)

        guard let shot = try? await ChessScreen.capture(),
              let found = ChessBoardFinder.find(in: shot.image, displayOrigin: shot.origin),
              let board = shot.cropping(to: found.geometry.rect)
        else {
            fail("Couldn't find the board to re-read it.")
            return
        }
        do {
            let reading = try await ChessVision.read(board: board, occupancy: found.occupancy,
                                                     flipped: found.geometry.flipped)
            guard let turn = await askWhoseTurn(suggested: reading.position.turn) else {
                stop()
                return
            }
            var position = reading.position
            position.turn = turn
            ChessDiagnostics.record(shot: shot, found: found,
                                    verdict: "resynced to \(position.fen)")
            // A fresh session rather than a position swap: the watcher has to
            // relearn its baseline and what an empty square looks like, and
            // half-updating a running one is how you get a third kind of drift.
            stop()
            begin(with: ChessCalibrator.Result(
                geometry: found.geometry,
                ourColour: found.geometry.flipped ? .black : .white),
                  position: position)
        } catch {
            ChessDiagnostics.record(shot: shot, found: found,
                                    verdict: "resync failed: \(error.localizedDescription)")
            fail("Couldn't re-read the board — \(error.localizedDescription)")
        }
    }

    /// Whose move it is, from the one source that knows.
    ///
    /// A still picture of a board does not say whose turn it is. The model
    /// guesses, and the guess is right about as often as a coin — which meant
    /// joining a game as White and being told what Black should play. Nothing
    /// downstream can recover from that: every suggestion is for the wrong
    /// side and every one of them is legal. So it is asked, once, in the
    /// island, with the guess lit as the default. Nil means they changed their
    /// mind.
    private func askWhoseTurn(suggested: PieceColor) async -> PieceColor? {
        let picked = await badge.ask("Who moves next?", options: ["White", "Black"],
                                     suggested: suggested == .white ? 0 : 1)
        switch picked {
        case 0:  return .white
        case 1:  return .black
        default: return nil
        }
    }

    /// Where the screenshots and reasoning from the last few attempts went.
    func revealDiagnostics() {
        NSWorkspace.shared.open(ChessDiagnostics.directory)
    }

    func stop() {
        watchingState = nil
        watchingInfo = nil
        session?.stop()
        session = nil
        notice = nil
        badge.hide()
    }
}
