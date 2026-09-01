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
@MainActor
final class ChessController: ObservableObject {
    static let shared = ChessController()

    /// Which mode a session starts in. Persisted, defaulting to the one that
    /// doesn't touch the mouse — the safe default is the useful one here, so
    /// there's no reason to make anybody choose.
    @Published var mode: ChessMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) }
    }

    @Published private(set) var session: ChessSession?
    /// A line for the settings pane. Nil while nothing needs saying.
    @Published private(set) var notice: String?

    private let calibrator = ChessCalibrator()
    private let badge = ChessStatusBadge()
    private var watchingState: AnyCancellable?
    private static let modeKey = "visor.chess.mode"

    private init() {
        mode = UserDefaults.standard.string(forKey: Self.modeKey)
            .flatMap(ChessMode.init(rawValue:)) ?? .advising
    }

    var isWatching: Bool { session != nil }

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
            let shot = try? await ChessScreen.capture()
            guard let shot else {
                self.fail("Couldn't take a picture of the screen.")
                return
            }

            let found = ChessBoardFinder.find(in: shot.image, displayOrigin: shot.origin)
            if let found {
                // A position that isn't the starting one can be *seen* but not
                // *read* — occupancy says a square is busy, never what is
                // standing on it. Starting anyway would track a position that
                // isn't the one on screen and put confident arrows on it, so
                // this says no rather than guessing.
                guard Self.looksLikeAFreshGame(found.occupancy) else {
                    // A game already under way. Occupancy says which squares
                    // are busy and what colour is on them, but never *what* —
                    // and that last part is the only thing worth asking a model
                    // for, once, on a still image, with its answer checked
                    // against the screen before anything is built on it.
                    self.badge.show("Reading the position…", live: false)
                    guard let board = shot.cropping(to: found.geometry.rect) else {
                        self.fail("Couldn't cut the board out of the screenshot.")
                        return
                    }
                    do {
                        let reading = try await ChessVision.read(
                            board: board, occupancy: found.occupancy,
                            flipped: found.geometry.flipped)
                        ChessDiagnostics.record(shot: shot, found: found,
                                                verdict: "joined mid-game: \(reading.position.fen)")
                        self.notice = nil
                        self.begin(with: ChessCalibrator.Result(
                            geometry: found.geometry,
                            ourColour: found.geometry.flipped ? .black : .white),
                                   position: reading.position)
                    } catch {
                        ChessDiagnostics.record(shot: shot, found: found,
                                                verdict: "mid-game read failed: \(error.localizedDescription)")
                        self.fail(error.localizedDescription)
                    }
                    return
                }
                ChessDiagnostics.record(shot: shot, found: found, verdict: "started")
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
                       position: ChessPosition = .start) {
        // The position is assumed to be a fresh game. Nothing here reads
        // pieces — only which squares changed — so there is no way to work out
        // a board that was already in progress, and starting mid-game would
        // silently track a position that isn't the one on screen.
        let session = ChessSession(mode: mode,
                                   geometry: result.geometry,
                                   ourColour: result.ourColour,
                                   position: position)
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
                            self.badge.show("\(what.capitalized) · \(colour)")
                        case .recovering:
                            self.badge.show("Catching up…", live: false)
                        case .lost(let why):
                            self.badge.show(why, live: false, fadingAfter: 8)
                        case .idle:
                            self.badge.hide()
                        }
                    }
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

    /// Where the screenshots and reasoning from the last few attempts went.
    func revealDiagnostics() {
        NSWorkspace.shared.open(ChessDiagnostics.directory)
    }

    func stop() {
        watchingState = nil
        session?.stop()
        session = nil
        notice = nil
        badge.hide()
    }
}
