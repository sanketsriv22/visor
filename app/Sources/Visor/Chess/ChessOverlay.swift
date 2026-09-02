import AppKit

/// Draws arrows on top of the board without being in the way of it.
///
/// A borderless, non-activating panel that ignores mouse events entirely, so
/// the board underneath behaves exactly as it did — you can still pick up a
/// piece through it. Same construction as the notch panel, for the same
/// reason: it has to sit above ordinary windows, follow across spaces, and
/// never take focus.
///
/// Nothing here is chess-specific except which two points an arrow joins. The
/// useful half of this file is a click-through surface that draws pointers onto
/// whatever is underneath, which is the thing Visor wants for pointing at a
/// button in someone else's app. Chess is a demanding first customer for it:
/// the coordinates have to be exact, it redraws several times a minute, and
/// being a square out is instantly obvious.
@MainActor
final class ChessOverlay {
    private var panel: NSPanel?
    private var geometry: BoardGeometry?
    private var arrows: [CAShapeLayer] = []
    private var labels: [CATextLayer] = []

    /// The only saturated colour in the app, and deliberately not in `Design`.
    ///
    /// Every other colour Visor draws sits on Visor's own dark surfaces, where
    /// a white at some opacity is the right answer. These sit on someone
    /// else's board — which might be green, brown, blue or grey, in light mode
    /// or dark — so they have to hold their own against a background we don't
    /// control and can't restyle. That's a different problem, and pretending
    /// it's the same one by reaching for `Design.Ink` would give us arrows that
    /// vanish on half the board themes.
    private enum Ink {
        static let best   = NSColor(srgbRed: 0.18, green: 0.80, blue: 0.55, alpha: 0.92)
        static let second = NSColor(srgbRed: 0.98, green: 0.75, blue: 0.20, alpha: 0.72)
        static let third  = NSColor(srgbRed: 0.60, green: 0.62, blue: 0.70, alpha: 0.58)
        static func forRank(_ rank: Int) -> NSColor {
            switch rank {
            case 0:  return best
            case 1:  return second
            default: return third
            }
        }
    }

    func show(_ moves: [ScoredMove], on geometry: BoardGeometry) {
        guard !moves.isEmpty else { hide(); return }
        let panel = ensurePanel(for: geometry)
        guard let root = panel.contentView?.layer else { return }

        // Rebuilt rather than animated between positions. An arrow that slides
        // from one move to another suggests the two are related, and they
        // aren't — it's a new answer to a new position.
        for layer in arrows + labels { layer.removeFromSuperlayer() }
        arrows.removeAll()
        labels.removeAll()

        // Drawn worst-first so the best move ends up on top where they cross,
        // which they often do — good moves tend to involve the same squares.
        for (rank, scored) in moves.prefix(3).enumerated().reversed() {
            let colour = Ink.forRank(rank)
            let width = geometry.square * (rank == 0 ? 0.17 : rank == 1 ? 0.13 : 0.10)

            let shape = CAShapeLayer()
            shape.path = arrowPath(from: geometry.overlayCenter(of: scored.move.from),
                                   to: geometry.overlayCenter(of: scored.move.to),
                                   width: width,
                                   inset: geometry.square * 0.30)
            shape.fillColor = colour.cgColor
            // A thin dark rim, because a green arrow on a green board is a
            // shape you have to look for rather than one you see.
            shape.strokeColor = NSColor.black.withAlphaComponent(0.28).cgColor
            shape.lineWidth = 1
            root.addSublayer(shape)
            arrows.append(shape)

            if rank == 0 {
                let label = evalLabel(scored.score.display, colour: colour,
                                      at: geometry.overlayCenter(of: scored.move.to),
                                      square: geometry.square)
                root.addSublayer(label)
                labels.append(label)
            }
        }

        panel.orderFrontRegardless()
    }

    func hide() {
        for layer in arrows + labels { layer.removeFromSuperlayer() }
        arrows.removeAll()
        labels.removeAll()
        panel?.orderOut(nil)
    }

    func close() {
        hide()
        panel?.close()
        panel = nil
        geometry = nil
    }

    // ── construction ──────────────────────────────────────────────────

    private func ensurePanel(for geometry: BoardGeometry) -> NSPanel {
        if let panel, self.geometry == geometry { return panel }

        let frame = geometry.appKitRect
        let panel = self.panel ?? {
            let created = NSPanel(contentRect: frame,
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
            created.isReleasedWhenClosed = false   // we hold the reference; close() must not release it too (double-free in the window's dealloc animation)
        created.level = .statusBar
            created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                          .stationary, .ignoresCycle]
            created.isOpaque = false
            created.backgroundColor = .clear
            created.hasShadow = false
            // The whole point: the board underneath still receives every click,
            // so nothing about how the user plays changes while this is up.
            created.ignoresMouseEvents = true
            let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
            view.wantsLayer = true
            created.contentView = view
            return created
        }()

        panel.setFrame(frame, display: false)
        panel.contentView?.frame = CGRect(origin: .zero, size: frame.size)
        self.panel = panel
        self.geometry = geometry
        return panel
    }

    /// A shaft with a head on it, as one filled path.
    ///
    /// Built as a polygon rather than a stroked line with a separate triangle:
    /// two overlapping shapes at the same alpha show their seam, and the seam
    /// is right at the arrowhead where the eye already is.
    ///
    /// Both ends are inset. Starting at the centre of the origin square buries
    /// the tail under the piece being moved, and ending at the centre of the
    /// destination hides the head under whatever is standing there — which, on
    /// a capture, is the thing you most want to see.
    private func arrowPath(from start: CGPoint, to end: CGPoint,
                           width: CGFloat, inset: CGFloat) -> CGPath {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = max(hypot(dx, dy), 0.001)
        let ux = dx / length, uy = dy / length
        let px = -uy, py = ux                       // unit perpendicular

        let tail = CGPoint(x: start.x + ux * inset, y: start.y + uy * inset)
        let tip  = CGPoint(x: end.x - ux * inset * 0.55, y: end.y - uy * inset * 0.55)

        let headLength = width * 2.1
        let headHalf = width * 1.35
        let half = width / 2
        let neck = CGPoint(x: tip.x - ux * headLength, y: tip.y - uy * headLength)

        let path = CGMutablePath()
        path.move(to:    CGPoint(x: tail.x + px * half,     y: tail.y + py * half))
        path.addLine(to: CGPoint(x: neck.x + px * half,     y: neck.y + py * half))
        path.addLine(to: CGPoint(x: neck.x + px * headHalf, y: neck.y + py * headHalf))
        path.addLine(to: tip)
        path.addLine(to: CGPoint(x: neck.x - px * headHalf, y: neck.y - py * headHalf))
        path.addLine(to: CGPoint(x: neck.x - px * half,     y: neck.y - py * half))
        path.addLine(to: CGPoint(x: tail.x - px * half,     y: tail.y - py * half))
        path.closeSubpath()
        return path
    }

    /// The evaluation, tucked into the destination square's corner.
    private func evalLabel(_ text: String, colour: NSColor,
                           at point: CGPoint, square: CGFloat) -> CATextLayer {
        let layer = CATextLayer()
        layer.string = text
        layer.font = NSFont.monospacedDigitSystemFont(ofSize: 0, weight: .semibold)
        layer.fontSize = max(9, square * 0.22)
        layer.foregroundColor = NSColor.white.cgColor
        layer.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        layer.cornerRadius = Design.Radius.control
        layer.alignmentMode = .center
        // Without this the text is drawn at 1x and resampled, which on a retina
        // display looks like a screenshot of a label rather than a label.
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        let size = CGSize(width: square * 0.72, height: square * 0.30)
        layer.frame = CGRect(x: point.x - size.width / 2,
                             y: point.y - square * 0.46,
                             width: size.width, height: size.height)
        return layer
    }
}
