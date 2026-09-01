import AppKit

/// A small pill saying Visor is watching, and what just happened.
///
/// Computer use needed a sign of life outside Settings. Pressing ⌘⌃U and
/// having the screen do nothing whatsoever is indistinguishable from a
/// shortcut that isn't bound — which is exactly how it was reported.
///
/// Not the notch's listening pill, though that was the obvious thing to reach
/// for. That pill is dictation's: it's driven by microphone level and it is
/// literally a game of invaders shot down by talking. Borrowing it would put a
/// voice indicator on screen for something that isn't listening. This is the
/// same idea, sized for a different thing, and it sits near the board because
/// that is where the eyes already are.
@MainActor
final class ChessStatusBadge {
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    /// Show `text`. `near` anchors it above a board; without one it sits at the
    /// top of the screen with the pointer in it.
    func show(_ text: String, near board: BoardGeometry? = nil, fadingAfter seconds: TimeInterval? = nil) {
        let panel = ensurePanel()
        label.stringValue = text
        label.sizeToFit()

        let width = max(160, label.frame.width + 34)
        let height: CGFloat = 30
        let anchor: CGRect
        if let board {
            let r = board.appKitRect
            anchor = CGRect(x: r.midX - width / 2, y: r.maxY + 12, width: width, height: height)
        } else {
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
                ?? NSScreen.main ?? NSScreen.screens[0]
            anchor = CGRect(x: screen.frame.midX - width / 2,
                            y: screen.frame.maxY - height - 60, width: width, height: height)
        }
        panel.setFrame(anchor, display: true)
        label.frame = CGRect(x: 17, y: 0, width: width - 34, height: height)
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
        panel?.orderOut(nil)
    }

    func close() {
        hide()
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
        panel.hasShadow = false
        // It reports; it is never in the way.
        panel.ignoresMouseEvents = true

        let backing = NSVisualEffectView()
        backing.material = .hudWindow
        backing.blendingMode = .behindWindow
        backing.state = .active
        backing.wantsLayer = true
        backing.layer?.cornerRadius = Design.Radius.pill + 6
        backing.layer?.masksToBounds = true

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.backgroundColor = .clear
        label.isBordered = false
        backing.addSubview(label)

        panel.contentView = backing
        self.panel = panel
        return panel
    }
}
