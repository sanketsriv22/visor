import AppKit

/// A small floating island saying computer use is on.
///
/// Computer use needed a sign of life outside Settings: pressing ⌘⌃U and having
/// the screen do nothing at all is indistinguishable from a shortcut that isn't
/// bound, which is how it was first reported.
///
/// Not the notch's listening pill, though that was the obvious thing to reach
/// for. That one belongs to dictation — driven by microphone level, and
/// literally a game of invaders shot down by talking. Putting it up for
/// something that isn't listening would misreport what Visor is doing, which is
/// the one thing a feature about watching your screen cannot afford.
///
/// Draggable, because the top-right corner is only the right place until it
/// isn't — a board, a video call or a second display all move where "out of the
/// way" is. Where it gets dragged to is remembered.
@MainActor
final class ChessStatusBadge {
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private let dot = CALayer()
    private var hideWork: DispatchWorkItem?
    private var island: Island?
    /// Clicking it stops watching. The other half of ⌘⌃U, and the only control
    /// most people will ever see — Settings is not open during a game.
    var onClick: (() -> Void)?
    private var resting = ""

    private static let originKey = "visor.chess.badgeOrigin"

    /// Show `text`. `live` gives the steady green dot; a notice gets amber.
    ///
    /// Keep it short. This sits over someone's game — it reports state, it
    /// isn't a place to explain anything, and the explanation is in Settings.
    func show(_ text: String, live: Bool = true, fadingAfter seconds: TimeInterval? = nil) {
        let panel = ensurePanel()
        resting = text
        label.stringValue = text

        // Size to what it has to say. It was capped at 300 points and
        // truncated with an ellipsis, which for a status pill whose only job is
        // to be read is the one failure that defeats the object. Grow to fit
        // up to a sensible width, and wrap onto a second line past that rather
        // than cut off — a second line is still glanceable; a "…" is not.
        let maxTextWidth: CGFloat = 440
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.preferredMaxLayoutWidth = maxTextWidth
        let measured = label.sizeThatFits(NSSize(width: maxTextWidth, height: 200))
        let textWidth = min(maxTextWidth, measured.width)
        let textHeight = measured.height

        let height = max(32, textHeight + 14)
        let width = max(132, textWidth + 54)

        // Keep the same top-right corner as it grows, so a longer message
        // extends leftwards and downwards rather than marching off the screen.
        let saved = savedOrigin(width: width, height: height)
        var frame = CGRect(origin: saved, size: CGSize(width: width, height: height))
        if let previous = panel.frame.isEmpty ? nil : panel.frame {
            frame.origin = CGPoint(x: previous.maxX - width, y: previous.maxY - height)
        }
        // Keep it on a screen: a remembered position from a display that is no
        // longer attached would otherwise put it nowhere.
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
            frame.origin = defaultOrigin(width: width, height: height)
        }
        panel.setFrame(frame, display: true)
        island?.layer?.cornerRadius = min(16, height / 2)

        dot.frame = CGRect(x: 15, y: height / 2 - 4, width: 8, height: 8)
        dot.cornerRadius = 4
        dot.backgroundColor = (live
            ? NSColor(srgbRed: 0.22, green: 0.85, blue: 0.44, alpha: 1)
            : NSColor(srgbRed: 0.98, green: 0.71, blue: 0.20, alpha: 1)).cgColor
        dot.removeAllAnimations()
        if live {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.35
            pulse.duration = 1.1
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            dot.add(pulse, forKey: "pulse")
        }

        // Centred properly. `sizeToFit` gives the glyph height, and an
        // NSTextField handed a taller frame sits its baseline near the top of
        // it rather than in the middle — which is what made this look a couple
        // of pixels wrong without it being obvious why.
        label.frame = CGRect(x: 30, y: (height - textHeight) / 2,
                             width: textWidth + 4, height: textHeight)

        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        guard let seconds else { return }
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        }
    }

    func close() {
        hideWork?.cancel()
        hideWork = nil
        island = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    // ── where it lives ────────────────────────────────────────────────

    private func defaultOrigin(width: CGFloat, height: CGFloat) -> CGPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        return CGPoint(x: screen.visibleFrame.maxX - width - 16,
                       y: screen.visibleFrame.maxY - height - 10)
    }

    private func savedOrigin(width: CGFloat, height: CGFloat) -> CGPoint {
        guard let stored = UserDefaults.standard.string(forKey: Self.originKey) else {
            return defaultOrigin(width: width, height: height)
        }
        let point = NSPointFromString(stored)
        return point == .zero ? defaultOrigin(width: width, height: height) : point
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        // Moved by hand rather than by `isMovableByWindowBackground`, which
        // swallows the mouse-up and would leave no way to tell a click from a
        // drag — and a click has to mean something here.
        panel.isMovableByWindowBackground = false

        let island = Island()
        island.wantsLayer = true
        // Solid black, not a material. It has to read the same over a white
        // board, a dark editor and a photograph, and a translucent panel reads
        // differently over each.
        island.layer?.backgroundColor = NSColor.black.cgColor
        island.layer?.cornerRadius = 16   // reset per show() for two-line pills
        island.layer?.cornerCurve = .continuous
        island.layer?.borderWidth = 1
        island.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        island.layer?.addSublayer(dot)
        island.onClick = { [weak self] in self?.onClick?() }
        island.onMoved = { origin in
            UserDefaults.standard.set(NSStringFromPoint(origin), forKey: Self.originKey)
        }
        island.onHover = { [weak self] inside in
            guard let self else { return }
            self.label.stringValue = inside ? "Stop watching" : self.resting
        }

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.94)
        label.alignment = .left
        label.backgroundColor = .clear
        label.isBordered = false
        label.lineBreakMode = .byTruncatingTail
        island.addSubview(label)

        panel.contentView = island
        self.island = island
        self.panel = panel
        return panel
    }

    /// The pill itself: draggable, clickable, and able to tell the two apart.
    private final class Island: NSView {
        var onClick: (() -> Void)?
        var onMoved: ((CGPoint) -> Void)?
        var onHover: ((Bool) -> Void)?

        private var grab: CGSize?
        private var dragged = false
        private var tracking: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: bounds,
                                      options: [.mouseEnteredAndExited, .activeAlways],
                                      owner: self)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            let mouse = NSEvent.mouseLocation
            grab = CGSize(width: mouse.x - window.frame.origin.x,
                          height: mouse.y - window.frame.origin.y)
            dragged = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window, let grab else { return }
            let mouse = NSEvent.mouseLocation
            let origin = CGPoint(x: mouse.x - grab.width, y: mouse.y - grab.height)
            // A few pixels of slop, so a click with a shaky hand is still a
            // click rather than a one-pixel move that eats it.
            if abs(origin.x - window.frame.origin.x) > 2
                || abs(origin.y - window.frame.origin.y) > 2 { dragged = true }
            window.setFrameOrigin(origin)
        }

        override func mouseUp(with event: NSEvent) {
            defer { grab = nil }
            guard let window else { return }
            if dragged { onMoved?(window.frame.origin) } else { onClick?() }
        }
    }
}
