import AppKit

/// A black pill in the top-right corner saying computer use is on.
///
/// Computer use needed a sign of life outside Settings. Pressing ⌘⌃U and
/// having the screen do nothing at all is indistinguishable from a shortcut
/// that isn't bound, which is how it was first reported.
///
/// Not the notch's listening pill, though that was the obvious thing to reach
/// for. That one belongs to dictation: it is driven by microphone level and it
/// is a game of invaders shot down by talking. Putting it up for something that
/// isn't listening would be a lie about what Visor is doing — which, for a
/// feature whose whole proposition is that it watches your screen, is the one
/// thing it cannot afford to be.
///
/// So: its own island, in the corner, out of the way of the board. Solid black
/// rather than a blur, because it has to read the same over a white chess
/// board, a dark editor and a photo, and a translucent panel reads differently
/// over each.
@MainActor
final class ChessStatusBadge {
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private let dot = CALayer()
    private var hideWork: DispatchWorkItem?

    /// Show `text`. `live` gives it the steady green dot; a transient notice
    /// gets an amber one and fades.
    func show(_ text: String, live: Bool = true, fadingAfter seconds: TimeInterval? = nil) {
        let panel = ensurePanel()
        label.stringValue = text
        label.sizeToFit()

        let height: CGFloat = 34
        let width = min(420, max(180, label.frame.width + 62))
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        // Clear of the menu bar, and clear of the notch on the machines that
        // have one — this sits in the corner, not across the top.
        let frame = CGRect(x: screen.visibleFrame.maxX - width - 16,
                           y: screen.visibleFrame.maxY - height - 10,
                           width: width, height: height)
        panel.setFrame(frame, display: true)

        dot.frame = CGRect(x: 16, y: height / 2 - 4, width: 8, height: 8)
        dot.cornerRadius = 4
        dot.backgroundColor = (live
            ? NSColor(srgbRed: 0.20, green: 0.84, blue: 0.42, alpha: 1)
            : NSColor(srgbRed: 0.98, green: 0.71, blue: 0.20, alpha: 1)).cgColor
        dot.removeAllAnimations()
        if live {
            // Alive rather than merely present. Slow enough not to nag.
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.35
            pulse.duration = 1.1
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            dot.add(pulse, forKey: "pulse")
        }

        label.frame = CGRect(x: 32, y: 0, width: width - 46, height: height)
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
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
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
        // It reports; it is never in the way.
        panel.ignoresMouseEvents = true

        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.88).cgColor
        view.layer?.cornerRadius = 17
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        view.layer?.addSublayer(dot)

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.92)
        label.alignment = .left
        label.backgroundColor = .clear
        label.isBordered = false
        label.lineBreakMode = .byTruncatingTail
        view.addSubview(label)

        panel.contentView = view
        self.panel = panel
        return panel
    }
}
