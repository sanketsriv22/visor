import AppKit
import ApplicationServices

/// What to do once we know what to play.
///
/// The two modes differ here and nowhere else. Everything upstream — capture,
/// diffing, resolving the move, looking up the reply — is identical whether
/// we're drawing an arrow or moving a piece, and keeping the difference behind
/// one method is what stops "and also click it" from growing into a flag
/// checked in five places.
@MainActor
protocol MoveActuator: AnyObject {
    func present(_ moves: [ScoredMove], on geometry: BoardGeometry) async
    func clear()
}

/// The default. Draws the top three and touches nothing.
@MainActor
final class AdvisingActuator: MoveActuator {
    private let overlay = ChessOverlay()

    func present(_ moves: [ScoredMove], on geometry: BoardGeometry) async {
        overlay.show(moves, on: geometry)
    }

    func clear() { overlay.hide() }
    func close() { overlay.close() }
}

/// Plays the best move by clicking it.
///
/// Opt-in, and gated on approval where it's registered as a tool. The
/// difference between this and the advisor isn't technical — it's that one of
/// them takes the mouse out of the user's hands, and that is a thing to be
/// asked for rather than configured into being by accident.
@MainActor
final class ClickingActuator: MoveActuator {
    enum ClickError: LocalizedError {
        case notTrusted
        var errorDescription: String? {
            "Visor needs Accessibility to move pieces — " + TextInsertion.staleGrantAdvice
        }
    }

    /// How long to leave between the parts of a click, and between the two
    /// clicks of a move.
    ///
    /// Not padding. Events posted back-to-back arrive inside the same run loop
    /// turn, and a web board that tracks selection in JavaScript sees a
    /// mousedown and mouseup on two different squares as a drag it never
    /// started. A few milliseconds is the difference between a move and a
    /// piece left hanging mid-air.
    private let withinClick: UInt64 = 12_000_000      // 12ms
    private let betweenClicks: UInt64 = 28_000_000    // 28ms

    /// Put back where the user left it. They didn't ask for their pointer to
    /// end up on h8.
    private var restoreTo: CGPoint?

    func present(_ moves: [ScoredMove], on geometry: BoardGeometry) async {
        guard let best = moves.first else { return }
        try? await play(best.move, on: geometry)
    }

    func clear() {}

    func play(_ move: Move, on geometry: BoardGeometry) async throws {
        guard AXIsProcessTrusted() else { throw ClickError.notTrusted }
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }

        restoreTo = CGEvent(source: nil)?.location

        try await click(geometry.center(of: move.from), source: source)
        try await Task.sleep(nanoseconds: betweenClicks)
        try await click(geometry.center(of: move.to), source: source)

        // The one place in this whole subsystem that knows which website it's
        // looking at. A promotion opens a picker over the promotion square,
        // with the queen in the cell nearest the back rank — which is the
        // destination square itself, so clicking the same point again takes
        // it. Anything other than a queen would need to know the picker's
        // layout, and no bot on the site has ever made under-promotion the
        // right answer.
        if move.promotion != nil {
            try await Task.sleep(nanoseconds: betweenClicks)
            try await click(geometry.center(of: move.to), source: source)
        }

        if let restoreTo {
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                    mouseCursorPosition: restoreTo, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        restoreTo = nil
    }

    private func click(_ point: CGPoint, source: CGEventSource) async throws {
        // Move first. Boards that highlight the square under the cursor decide
        // what a click means from their hover state, and a click that arrives
        // without the pointer ever having been there can land on the square the
        // mouse was over before.
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: withinClick)

        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: withinClick)

        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }
}
