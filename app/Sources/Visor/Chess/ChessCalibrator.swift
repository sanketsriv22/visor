import AppKit

/// Asks the user where the board is.
///
/// Everything downstream is exact to the pixel, and none of it can work out on
/// its own which rectangle on a 5K display is a chess board. Finding one
/// automatically is a real problem with a real answer — a board is a strongly
/// periodic pattern, so an autocorrelation over the luminance edges recovers
/// both the square size and the grid phase — and it is the obvious next
/// version. It is not this version, because writing signal processing that
/// can't be checked against a real screenshot is how you ship something that
/// works on one board theme.
///
/// So: drag a box, say which colour you are, done. Ten seconds, once a game,
/// and it cannot be subtly wrong in a way nobody notices.
@MainActor
final class ChessCalibrator {
    struct Result {
        let geometry: BoardGeometry
        let ourColour: PieceColor
    }

    private var window: NSWindow?
    private var completion: ((Result?) -> Void)?

    /// Put the picker up. Hands back nil if the user changes their mind.
    func run(completion: @escaping (Result?) -> Void) {
        guard window == nil else { return }
        self.completion = completion

        // One window per screen would let the board be picked on any display;
        // the board is on the screen the user is looking at, and that is the
        // one with the mouse in it.
        let screen = NSScreen.screens.first {
            $0.frame.contains(NSEvent.mouseLocation)
        } ?? NSScreen.main ?? NSScreen.screens[0]

        let window = NSWindow(contentRect: screen.frame,
                              styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // Unlike the arrow overlay this one *wants* the mouse: it is the mouse.
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true

        let picker = PickerView(frame: CGRect(origin: .zero, size: screen.frame.size))
        picker.onFinish = { [weak self] box, colour in
            guard let self else { return }
            self.dismiss()
            guard let box else { completion(nil); return }
            // The drag is in the picker's coordinates; the window is at the
            // screen's origin, so adding it back gives AppKit screen space.
            let onScreen = box.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
            completion(Result(geometry: BoardGeometry(appKitBoundingBox: onScreen,
                                                      flipped: colour == .black),
                              ourColour: colour))
        }
        window.contentView = picker
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(picker)
        self.window = window
    }

    private func dismiss() {
        window?.orderOut(nil)
        window?.close()
        window = nil
        completion = nil
    }

    // ── the picker ────────────────────────────────────────────────────

    /// A dimmed screen with a hole cut where the board is.
    ///
    /// Drawn as a dim over everything *except* the selection, rather than a
    /// bright rectangle over the selection. The board has to stay visible while
    /// it's being framed — you're aiming at its edges, and a tint over the
    /// thing you're aiming at is exactly the wrong place to put one.
    private final class PickerView: NSView {
        var onFinish: ((CGRect?, PieceColor) -> Void)?

        private var anchor: CGPoint?
        private var current: CGRect?
        /// Set once the drag is done and the question becomes which colour.
        private var awaitingColour = false

        override var acceptsFirstResponder: Bool { true }

        /// The selection, squared off the way `BoardGeometry` will square it,
        /// so what is drawn is what will be used.
        private var squared: CGRect? {
            guard let current, current.width > 40, current.height > 40 else { return nil }
            let side = min(current.width, current.height)
            return CGRect(x: current.minX + (current.width - side) / 2,
                          y: current.minY + (current.height - side) / 2,
                          width: side, height: side)
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.black.withAlphaComponent(0.45).setFill()
            guard let board = squared else {
                bounds.fill()
                caption("Drag a box around the chess board", in: bounds)
                return
            }

            // Dim everything but the board.
            let dim = NSBezierPath(rect: bounds)
            dim.append(NSBezierPath(rect: board))
            dim.windingRule = .evenOdd
            dim.fill()

            NSColor.white.withAlphaComponent(0.9).setStroke()
            let outline = NSBezierPath(rect: board)
            outline.lineWidth = 2
            outline.stroke()

            // The 8×8 the geometry will actually use, so a misframed board is
            // visible now rather than as arrows a square off later.
            NSColor.white.withAlphaComponent(0.25).setStroke()
            let grid = NSBezierPath()
            grid.lineWidth = 1
            for step in 1..<8 {
                let offset = board.width / 8 * CGFloat(step)
                grid.move(to: CGPoint(x: board.minX + offset, y: board.minY))
                grid.line(to: CGPoint(x: board.minX + offset, y: board.maxY))
                grid.move(to: CGPoint(x: board.minX, y: board.minY + offset))
                grid.line(to: CGPoint(x: board.maxX, y: board.minY + offset))
            }
            grid.stroke()

            caption(awaitingColour
                        ? "Which colour are you playing?   W — white     B — black        ⎋ cancel"
                        : "Let go when the grid lines up with the board's squares        ⎋ cancel",
                    in: bounds)
        }

        private func caption(_ text: String, in rect: CGRect) {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15, weight: .medium),
                .foregroundColor: NSColor.white,
                .paragraphStyle: style,
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            let box = CGRect(x: rect.midX - size.width / 2 - 16,
                             y: rect.maxY - 96,
                             width: size.width + 32, height: size.height + 16)
            NSColor.black.withAlphaComponent(0.72).setFill()
            NSBezierPath(roundedRect: box, xRadius: Design.Radius.panel,
                         yRadius: Design.Radius.panel).fill()
            (text as NSString).draw(at: CGPoint(x: box.minX + 16, y: box.minY + 8),
                                    withAttributes: attributes)
        }

        // ── the drag ──

        override func mouseDown(with event: NSEvent) {
            guard !awaitingColour else { return }
            anchor = convert(event.locationInWindow, from: nil)
            current = nil
            needsDisplay = true
        }

        override func mouseDragged(with event: NSEvent) {
            guard let anchor else { return }
            let point = convert(event.locationInWindow, from: nil)
            current = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                             width: abs(point.x - anchor.x), height: abs(point.y - anchor.y))
            needsDisplay = true
        }

        override func mouseUp(with event: NSEvent) {
            anchor = nil
            // A stray click isn't a board. Without this, tapping the overlay
            // hands back a zero-sized geometry and every square is the same
            // pixel.
            guard squared != nil else { current = nil; needsDisplay = true; return }
            awaitingColour = true
            needsDisplay = true
        }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 53:                                   // escape
                onFinish?(nil, .white)
            case 13 where awaitingColour:              // w
                onFinish?(squared, .white)
            case 11 where awaitingColour:              // b
                onFinish?(squared, .black)
            default:
                super.keyDown(with: event)
            }
        }
    }
}
