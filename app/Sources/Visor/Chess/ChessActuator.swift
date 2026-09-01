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
    /// started.
    private let withinClick: UInt64 = 18_000_000      // 18ms
    private let betweenClicks: UInt64 = 90_000_000    // 90ms

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

        // Bring the board's app forward first.
        //
        // Without this the first click is spent activating the window and never
        // reaches the board, so the piece is never picked up and the second
        // click lands on an empty selection. Settings being frontmost is the
        // usual way into that, which is exactly where somebody is when they
        // turn this on.
        await activateApp(under: geometry.center(of: move.from))

        try await click(geometry.center(of: move.from), source: source)
        try await Task.sleep(nanoseconds: betweenClicks)
        try await click(geometry.center(of: move.to), source: source)

        // The one place in this subsystem that knows which website it is
        // looking at. A promotion opens a picker over the promotion square with
        // the queen nearest the back rank — which is the destination square
        // itself, so clicking the same point again takes it.
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

    /// Make whatever owns that point frontmost, and wait until it is.
    private func activateApp(under point: CGPoint) async {
        // The point is in CoreGraphics screen space; NSWorkspace deals in
        // running applications, so go via the window list to find who owns it.
        guard let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return }

        for window in windows {
            guard let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t
            else { continue }
            let frame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                               width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            guard frame.contains(point) else { continue }
            guard pid != ProcessInfo.processInfo.processIdentifier,
                  let app = NSRunningApplication(processIdentifier: pid)
            else { return }
            guard !app.isActive else { return }

            if #available(macOS 14.0, *) { app.activate() } else { app.activate(options: []) }
            // Activation is asynchronous. A fixed sleep is either a stall or a
            // race depending on the machine, so wait for the fact instead —
            // bounded, because an app that won't come forward shouldn't hang
            // the move.
            var waited = 0
            while !app.isActive && waited < 25 {
                try? await Task.sleep(nanoseconds: 20_000_000)
                waited += 1
            }
            return
        }
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

        // Every click is the first click.
        //
        // This is what made moving a piece work sometimes and not others. The
        // window server decides click count from timing and proximity, so two
        // clicks a few tens of milliseconds apart on neighbouring squares were
        // being delivered as a double-click: the board selected the piece and
        // then immediately deselected it, and the move never happened. It
        // failed on short moves and worked on long ones, which is exactly what
        // "inconsistent" looks like from the outside. Stating the click state
        // explicitly stops the server inferring one.
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                      mouseCursorPosition: point, mouseButton: .left)
            else { continue }
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.post(tap: .cghidEventTap)
            if type == .leftMouseDown { try await Task.sleep(nanoseconds: withinClick) }
        }
    }
}
