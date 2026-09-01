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
            Text("Computer use").font(.headline)
            Text("Visor watching part of the screen and acting on what changes there. "
               + "Nothing is captured until you point it at something, and only the "
               + "rectangle you pick is ever looked at.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Chess

    private var chessSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Chess").font(.headline)
                Spacer()
                if chess.isWatching {
                    Label("Watching", systemImage: "eye")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
            }

            Text("Point Visor at a board and it reads the moves as they're played, "
               + "answering from a table it filled while your opponent was thinking.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            modePicker
            requirements

            if let notice = chess.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
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
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var requirements: some View {
        VStack(alignment: .leading, spacing: 7) {
            RequirementRow(
                met: chess.engine != nil,
                title: chess.engine.map { "Stockfish — \($0.path)" } ?? "Stockfish isn't installed",
                fix: chess.engine == nil ? "Install with  brew install stockfish" : nil,
                action: nil)

            RequirementRow(
                met: chess.hasScreenRecording,
                title: "Screen Recording",
                fix: chess.hasScreenRecording ? nil
                    : "Needed to see the board. Only the rectangle you pick is read.",
                action: chess.hasScreenRecording ? nil
                    : ("Open Settings", { chess.openScreenRecordingSettings() }))

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
        HStack(spacing: Design.Space.normal) {
            if chess.isWatching {
                Button("Stop watching") { chess.stop() }
                    .buttonStyle(.visor())
            } else {
                Button("Watch a board…") { chess.watchABoard() }
                    .buttonStyle(.visor(active: true))
                    .disabled(!chess.isReady)
            }
            Text(chess.isWatching
                    ? "Drag-select happens once per game."
                    : "You'll drag a box around the board, then press W or B for your colour.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
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
                .font(.system(size: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12))
                if let fix {
                    Text(fix)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
            if let (label, run) = action {
                Button(label, action: run).buttonStyle(.visor())
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
                Text("Stopped.").font(.caption).foregroundStyle(.secondary)
            case .lost(let why):
                Text(why).font(.caption).foregroundStyle(.orange)
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
                        .font(.caption).foregroundStyle(.secondary)
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
            Text(label).font(.caption2).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 13, weight: .medium, design: .monospaced))
        }
    }
}
