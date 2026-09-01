import AppKit
import ApplicationServices
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

    /// Pick a board, then start watching it.
    func watchABoard() {
        guard !isWatching else { return }
        if let blocker {
            notice = blocker
            return
        }
        notice = nil

        calibrator.run { [weak self] result in
            guard let self else { return }
            guard let result else { return }               // cancelled
            self.begin(with: result)
        }
    }

    private func begin(with result: ChessCalibrator.Result) {
        // The position is assumed to be a fresh game. Nothing here reads
        // pieces — only which squares changed — so there is no way to work out
        // a board that was already in progress, and starting mid-game would
        // silently track a position that isn't the one on screen.
        let session = ChessSession(mode: mode,
                                   geometry: result.geometry,
                                   ourColour: result.ourColour)
        self.session = session
        Task {
            do {
                try await session.start()
            } catch {
                self.notice = error.localizedDescription
                self.session = nil
            }
        }
    }

    func stop() {
        session?.stop()
        session = nil
        notice = nil
    }
}
