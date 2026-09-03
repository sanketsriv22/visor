import AppKit
import SwiftUI

/// The Computer Use tab.
///
/// One surface so far — chess — but the tab is the general one on purpose.
/// Watching the screen and acting on what's there is the capability; a chess
/// board is the first thing pointed at, and a demanding one, which is why it
/// went first rather than something forgiving.
struct ComputerUsePane: View {
    @ObservedObject private var chess = ChessController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Divider()
            chessSection
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Computer Use").font(Design.Text.paneTitle)
            Text("Visor watching part of the screen and acting on what changes there. "
               + "Nothing is captured until you point it at something, and only the "
               + "rectangle you pick is ever looked at.")
                .font(Design.Text.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Chess

    private var chessSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Chess").font(Design.Text.headline)
                Spacer()
                if chess.isWatching {
                    Label("Watching", systemImage: "eye")
                        .font(Design.Text.caption)
                        .foregroundStyle(Color.accentColor)
                }
            }

            Text("Visor reads the position straight out of the chess.com or Lichess page "
               + "— exact, instant, any theme — and falls back to watching the pixels "
               + "anywhere else. For Safari, turn on Develop ▸ Allow JavaScript from "
               + "Apple Events once; Chrome asks the same under View ▸ Developer. macOS "
               + "will ask once to let Visor talk to the browser.")
                .font(Design.Text.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            modePicker
            strengthControl
            if chess.mode == .playing { latencyBand }
            requirements

            if let notice = chess.notice {
                HStack(alignment: .firstTextBaseline, spacing: Design.Space.normal) {
                    Text(notice)
                        .font(Design.Text.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    // Every attempt leaves a screenshot and the finder's own
                    // reasoning behind. Without them, "it didn't find my board"
                    // is a symptom with a dozen causes and no way to tell them
                    // apart from the outside.
                    PaneButton(title: "Show what it saw") { chess.revealDiagnostics() }
                }
            }

            controls

            if let session = chess.session {
                Divider()
                WatchingReadout(session: session)
            }
        }
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: Binding(get: { chess.mode },
                                          set: { chess.mode = $0 })) {
                ForEach(ChessMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // Swapping the thing that acts, mid-game, while a table primed for
            // the other one is in flight. Stop first.
            .disabled(chess.isWatching)

            Text(chess.mode == .advising
                    ? "Draws the three best moves on the board. Never touches your mouse."
                    : "Plays the best move by clicking it. Visor takes the pointer for a moment.")
                .font(Design.Text.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// How strong the engine plays — a pixel power-gauge and a difficulty tier,
    /// not a slider. Off means full strength; on, you drag it down to a rating.
    private var strengthControl: some View {
        let lo = ChessStrength.range.lowerBound
        let hi = ChessStrength.range.upperBound
        let on = chess.strength.elo != nil
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Engine strength").font(Design.Text.rowTitle).foregroundStyle(Design.Retro.text)
                Spacer()
                Text(on ? "\(chess.strength.elo ?? 0)" : "MAX")
                    .font(.custom(Design.Text.face, size: 18))
                    .foregroundStyle(Design.Retro.accent)
                Text(Self.tier(on ? chess.strength.elo : nil))
                    .font(Design.Text.caption2).foregroundStyle(Design.Retro.dim)
                    .frame(width: 74, alignment: .trailing)
            }
            HStack(spacing: 12) {
                Toggle("", isOn: Binding(
                    get: { on },
                    set: { chess.strength = $0 ? ChessStrength(elo: 1500) : ChessStrength(elo: nil) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                PixelGauge(value: Binding(
                    get: { (Double(chess.strength.elo ?? Int(hi)) - lo) / max(1, hi - lo) },
                    set: { frac in
                        let stepped = ((lo + frac * (hi - lo)) / 20).rounded() * 20
                        chess.strength = ChessStrength(elo: Int(stepped))
                    }), enabled: on)
            }
            Text("Off is full strength. On, the engine plays down to the rating — "
               + "weaker moves, not faster ones, so it feels like an opponent of "
               + "that level. Takes effect on the next game.")
                .font(Design.Text.caption2).foregroundStyle(Design.Retro.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    /// A human name for a rating, so the number isn't the only cue.
    private static func tier(_ elo: Int?) -> String {
        guard let e = elo else { return "full" }
        switch e {
        case ..<1400: return "BEGINNER"
        case ..<1700: return "CASUAL"
        case ..<2000: return "CLUB"
        case ..<2300: return "EXPERT"
        case ..<2600: return "MASTER"
        default:      return "GRANDMASTER"
        }
    }

    /// How long to sit on the answer before playing it.
    ///
    /// Only shown for the mode that moves pieces. Arrows have no reason to
    /// arrive late — being there before you have finished looking is the whole
    /// point of them.
    private var latencyBand: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Response time").font(.custom(Design.Text.face, size: 12))
                Spacer()
                Text(chess.latency.display)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            // One slider, two thumbs — the fast end and the slow end of the
            // band, instead of two separate sliders for one range. Squared, so
            // the sub-second part of the range is reachable (see below).
            let span = LatencyBand.range.upperBound
            RangeSlider(
                low: Binding(
                    get: { (chess.latency.shortest / span).squareRoot() },
                    set: { chess.latency.shortest = min($0 * $0 * span, chess.latency.longest) }),
                high: Binding(
                    get: { (chess.latency.longest / span).squareRoot() },
                    set: { chess.latency.longest = max($0 * $0 * span, chess.latency.shortest) }))
            HStack {
                Text("fast").font(Design.Text.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text("slow").font(Design.Text.caption2).foregroundStyle(.tertiary)
            }
            Text("Each move waits a random time inside the band. The engine is "
               + "as quick either way — this only decides when the answer gets used.")
                .font(Design.Text.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    /// Squared, so the low end is reachable.
    ///
    /// A linear nought-to-ten-seconds slider gives fifty milliseconds and five
    /// hundred milliseconds the same half-pixel of travel, which makes the
    /// interesting part of the range impossible to set. Squaring puts most of
    /// the movement under a second, where the choices actually differ.
    private func bandSlider(_ label: String,
                            get: @escaping () -> TimeInterval,
                            set: @escaping (TimeInterval) -> Void) -> some View {
        let span = LatencyBand.range.upperBound
        return HStack(spacing: Design.Space.normal) {
            Text(label)
                .font(Design.Text.caption2).foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Slider(value: Binding(
                get: { (get() / span).squareRoot() },
                set: { set($0 * $0 * span) }), in: 0...1)
        }
    }

    private var requirements: some View {
        VStack(alignment: .leading, spacing: 7) {
            RequirementRow(
                met: chess.engine != nil,
                title: chess.engine.map { "Stockfish — \($0.path)" } ?? "Stockfish isn't installed",
                // Stockfish isn't in the app — it's GPL, so Visor uses the copy
                // on your machine. The button copies the install command and
                // opens the download page rather than fetching a binary itself.
                fix: chess.engine == nil
                    ? "Not bundled (it's GPL). Run  brew install stockfish  — the command is copied for you."
                    : nil,
                action: chess.engine != nil ? nil : ("Get Stockfish", {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install stockfish", forType: .string)
                    if let url = URL(string: "https://stockfishchess.org/download/") {
                        NSWorkspace.shared.open(url)
                    }
                }))

            RequirementRow(
                met: chess.hasScreenRecording,
                title: "Screen Recording",
                fix: chess.hasScreenRecording ? nil
                    : "Needed to see the board. Only the rectangle you pick is read.",
                action: chess.hasScreenRecording ? nil
                    : ("Open Settings", { chess.openScreenRecordingSettings() }))

            // The grant is real but `CGPreflightScreenCaptureAccess` keeps
            // answering with what was true at launch, so a user who has just
            // ticked the box sees this row still unmet and concludes it didn't
            // work. Say what's actually happening and make the fix one click.
            if !chess.hasScreenRecording {
                HStack(alignment: .firstTextBaseline, spacing: Design.Space.normal) {
                    Text("Already ticked it? macOS only hands screen access to a fresh launch.")
                        .font(Design.Text.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    PaneButton(title: "Quit Visor") { NSApp.terminate(nil) }
                }
                .padding(.leading, 20)
            }

            if chess.needsAccessibility {
                RequirementRow(
                    met: chess.hasAccessibility,
                    title: "Accessibility",
                    fix: chess.hasAccessibility ? nil : "Needed to click the pieces.",
                    action: chess.hasAccessibility ? nil
                        : ("Grant", { chess.requestAccessibility() }))
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: Design.Space.normal) {
                if chess.isWatching {
                    PaneButton(title: "Stop watching") { chess.stop() }
                } else {
                    PaneButton(title: "Watch a board…", prominent: chess.isReady) {
                        chess.watchABoard()
                    }
                    .disabled(!chess.isReady)
                }
                Spacer(minLength: 0)
            }

            // A disabled button that says nothing is the same as a broken one.
            // Whatever is stopping it gets said here, permanently, rather than
            // only after a click that can't happen.
            if chess.isWatching {
                Text("Drag-select happens once per game.")
                    .font(Design.Text.caption2).foregroundStyle(.tertiary)
            } else if let blocker = chess.blocker {
                Text("Can't start yet — \(blocker.lowercased()). See above.")
                    .font(Design.Text.caption2).foregroundStyle(.orange)
            } else {
                Text("⌘⌃U does this from anywhere. If no board is found you'll be "
                   + "asked to draw a box around it.")
                    .font(Design.Text.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

/// A button that looks like a button.
///
/// `VisorControl` draws hover and press state *behind* whatever label it is
/// handed and adds no padding of its own, so a bare `Button("Text")` gets a
/// background clamped to the glyphs and reads as a mis-rendered label. Every
/// other button in the app gives its label its own padding and content shape —
/// this is that, named once, because this pane needs four of them.
private struct PaneButton: View {
    let title: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.custom(Design.Text.face, size: 12))
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.visor(active: prominent))
    }
}

/// One line of "this has to be true first".
private struct RequirementRow: View {
    let met: Bool
    let title: String
    let fix: String?
    let action: (String, () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.normal) {
            Image(systemName: met ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(met ? Color.green : Color.secondary)
                .font(.custom(Design.Text.face, size: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.custom(Design.Text.face, size: 12))
                if let fix {
                    Text(fix)
                        .font(Design.Text.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
            if let (label, run) = action {
                PaneButton(title: label, action: run)
            }
        }
    }
}

/// What the session is doing, while it does it.
///
/// A separate view because `ChessSession` is its own `ObservableObject` — held
/// through the controller, SwiftUI wouldn't see it change, and the readout
/// would sit at whatever it said when the pane was built.
private struct WatchingReadout: View {
    @ObservedObject var session: ChessSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch session.state {
            case .idle:
                Text("Stopped.").font(Design.Text.caption).foregroundStyle(.secondary)
            case .recovering(let why):
                Text(why + " — it will pick the game back up on its own.")
                    .font(Design.Text.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .lost(let why):
                Text(why).font(Design.Text.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .watching:
                HStack(spacing: Design.Space.loose) {
                    stat("Reply in", session.lastLatency.map {
                        "\(Int($0 * 1000))ms"
                    } ?? "—")
                    stat("From the table", session.tableHitRate.map {
                        "\(Int($0 * 100))%"
                    } ?? "—")
                    stat("To move",
                         session.position.turn == .white ? "White" : "Black")
                }
                if session.suggestions.isEmpty {
                    Text("Waiting for your opponent.")
                        .font(Design.Text.caption).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: Design.Space.snug) {
                        ForEach(Array(session.suggestions.prefix(3).enumerated()),
                                id: \.offset) { index, scored in
                            Text("\(scored.move.uci)  \(scored.score.display)")
                                .font(.system(size: 11, design: .monospaced))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: Design.Radius.control)
                                    .fill(Design.Surface.raised.opacity(index == 0 ? 2 : 1)))
                        }
                    }
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(Design.Text.caption2).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 13, weight: .medium, design: .monospaced))
        }
    }
}
