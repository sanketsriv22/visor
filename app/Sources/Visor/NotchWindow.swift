import AppKit
import SwiftUI

/// Borderless panel that can become key (for the text editor) without
/// activating the app — clicking the notch never steals focus visibly.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// AppKit normally refuses to place windows over the menu bar /
    /// notch area; we need exactly that.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Hosting view that accepts the first click even when the panel isn't key,
/// so a single click on the notch always toggles.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Which surface the notch is showing. Visor is one window with two faces,
/// not two windows.
enum VisorMode: String, CaseIterable, Identifiable, Codable {
    case notes, chat

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notes: return "Notes"
        case .chat:  return "Chat"
        }
    }

    var symbol: String {
        switch self {
        case .notes: return "checklist"
        case .chat:  return "bubble.left.and.bubble.right"
        }
    }
}

final class UIState: ObservableObject {
    @Published var expanded = false
    /// Restored on launch, so the notch reopens on whichever face you left it.
    @Published var mode: VisorMode = .notes
    @Published var notchSize = CGSize(width: 200, height: 32)
    /// True briefly while the card animates open. Rows pass under the cursor
    /// during the slide, so hover affordances are suppressed until it settles.
    @Published var settling = false
}

/// Main-actor isolated: it owns the panel and drives the chat controller, both
/// of which are main-actor state.
@MainActor
final class NotchController {
    /// The notes card keeps its established size; chat needs more room for a
    /// transcript and a composer.
    static let cardHeight: CGFloat = 260
    static let cardWidth: CGFloat = 420
    static let chatCardHeight: CGFloat = 330
    static let chatCardWidth: CGFloat = 530

    /// The window is sized to the larger of the two modes for as long as it's
    /// open, so switching modes resizes *nothing*.
    ///
    /// The alternative — resizing the panel per mode — means driving an
    /// NSWindow frame animation alongside the SwiftUI spring and hoping the two
    /// timing curves agree. They don't, and the card visibly lags its own
    /// window. Holding the window at the union lets SwiftUI animate the card
    /// alone, which is what makes the horizontal growth fluid. The extra
    /// window area is transparent, and transparent SwiftUI content doesn't
    /// hit-test, so clicks still pass through to whatever is underneath.
    static var maxCardSize: CGSize {
        CGSize(width: max(cardWidth, chatCardWidth),
               height: max(cardHeight, chatCardHeight))
    }

    static func cardSize(for mode: VisorMode) -> CGSize {
        switch mode {
        case .notes: return CGSize(width: cardWidth, height: cardHeight)
        case .chat:  return CGSize(width: chatCardWidth, height: chatCardHeight)
        }
    }
    /// The cursor is invisible inside the notch, so people naturally click
    /// slightly below it. Extend the collapsed hit area this far beneath.
    private static let underhang: CGFloat = 8
    /// Transparent breathing room around the card when expanded, so the card's
    /// (minimal) drop shadow fades out inside the window instead of being
    /// clipped to a hard rectangle at the window edge. Kept just big enough for
    /// the shadow so the window covers as little underneath as possible.
    private static let shadowPadX: CGFloat = 8
    private static let shadowPadBottom: CGFloat = 10

    private let panel: NotchPanel
    private let store = NotesStore()
    private let ui = UIState()
    let ai: AIRunner
    let chat: ChatController
    private let modeKey = "visor.mode"
    private var screenObserver: Any?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?

    init(startExpanded: Bool, ai: AIRunner) {
        self.ai = ai
        self.chat = ChatController(ai: ai)
        panel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true

        if let saved = UserDefaults.standard.string(forKey: modeKey),
           let mode = VisorMode(rawValue: saved) {
            ui.mode = mode
        }

        let root = StickyRootView(
            store: store, ui: ui, ai: ai, chat: chat,
            onToggle: { [weak self] in self?.toggle() },
            onMode: { [weak self] mode in self?.setMode(mode) })
        panel.contentView = FirstMouseHostingView(rootView: root)

        ui.expanded = startExpanded
        applyFrame(expanded: startExpanded)
        panel.orderFrontRegardless()
        if startExpanded {
            panel.makeKeyAndOrderFront(nil)
        }

        // Toggle on raw mouse-down instead of a tap gesture: tap gestures
        // cancel if the mouse moves between press and release, which is
        // exactly what happens when clicking mid-motion under an invisible
        // cursor.
        //
        // Two monitors are needed. A *local* monitor only sees events
        // delivered to our app — but clicks in the very top strip of the
        // notch get routed to the system menu bar instead, so our window
        // never receives them (the dead zone at the top of the notch). A
        // *global* monitor catches exactly those. The two are mutually
        // exclusive per event (an event goes to our app or elsewhere, never
        // both), so there's no double-toggle.
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            if !self.ui.expanded {
                self.toggle()
                return nil
            }
            // Expanded: close only when the *notch itself* is clicked — the
            // same area that opens it. The top band also spans the menu-bar
            // shoulders (VISOR / the count), and clicking those shouldn't close.
            let inTopBand = event.locationInWindow.y >= self.panel.frame.height - self.ui.notchSize.height
            let dxFromCenter = abs(event.locationInWindow.x - self.panel.frame.width / 2)
            if inTopBand && dxFromCenter <= self.ui.notchSize.width / 2 {
                self.toggle()
                return nil
            }
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self, let screen = self.targetScreen else { return }
            let loc = NSEvent.mouseLocation
            if self.ui.expanded {
                // Close when the notch is clicked. The very top of the notch
                // routes to the menu bar, so the local monitor never sees it —
                // this catches that strip up to the screen's top edge.
                if self.notchHitRect(on: screen).contains(loc) { self.toggle() }
            } else if self.collapsedHitTestRect(on: screen).contains(loc) {
                self.toggle()
            }
        }

        // Re-anchor under the notch when displays change (lid, monitors, resolution).
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.applyFrame(expanded: self.ui.expanded)
        }
    }

    func saveNow() { store.saveNow() }

    /// Switch faces, animating the card between the two widths. No-op if we're
    /// already there, so a repeated ⌘1 doesn't restart the spring.
    func setMode(_ mode: VisorMode) {
        guard ui.mode != mode else { return }
        UserDefaults.standard.set(mode.rawValue, forKey: modeKey)
        // Loose enough to read as elastic, damped enough not to wobble: this
        // is the curve the card's width and height are morphing along.
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            ui.mode = mode
        }
    }

    /// Open the notch on the chat face with a prompt already running — how
    /// tasks sent to a chat agent surface.
    func runInNotch(prompt: String, agentName: String?) {
        setMode(.chat)
        showNote()
        chat.seed(prompt: prompt, agentName: agentName)
    }

    /// Import a note from an incoming beam URL and slide the note down to show
    /// it. No-op if the URL's payload can't be decoded.
    @discardableResult
    func importBeam(from url: URL) -> Bool {
        guard store.importBeamed(from: url) else { return false }
        showNote()
        return true
    }

    /// Import a note from a `.visor` file (e.g. AirDrop) and show it.
    @discardableResult
    func importNoteFile(from url: URL) -> Bool {
        guard store.importNoteFile(from: url) else { return false }
        showNote()
        return true
    }

    /// Expand the note if it's collapsed; no-op if already showing. Used when
    /// the app is re-launched while already running.
    func showNote() {
        guard !ui.expanded else { return }
        toggle()
    }

    func toggle() {
        if ui.expanded {
            store.prepareToHide()  // prune blank rows + save (discards the note if now empty)
            // Suppress the notch hover popup until the collapse + window resize
            // settle, so it doesn't reflow right-to-left under a resting cursor.
            ui.settling = true
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                ui.expanded = false
            }
            panel.resignKey()
            // Shrink the window back to just the notch strip after the
            // card has animated away, so it can't intercept clicks.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
                guard let self, !self.ui.expanded else { return }
                self.applyFrame(expanded: false)
                // Window is now its final notch size — let the popup appear cleanly.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(.easeInOut(duration: 0.2)) { self.ui.settling = false }
                }
            }
        } else {
            store.reloadFromDiskIfClean()
            applyFrame(expanded: true)
            ui.settling = true
            // Higher damping so the card settles at its resting spot instead
            // of overshooting (dropping too low) before springing back.
            withAnimation(.spring(response: 0.34, dampingFraction: 0.95)) {
                ui.expanded = true
            }
            panel.makeKeyAndOrderFront(nil)
            // Let the slide finish before hover affordances can appear.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.ui.settling = false
            }
        }
    }

    // MARK: - Geometry

    private var targetScreen: NSScreen? {
        NSScreen.screens.first { $0.notchArea != nil } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// The clickable strip: the real notch, or a synthetic strip centered
    /// at the top of the screen when there is no notch (external display).
    private func stripRect(on screen: NSScreen) -> NSRect {
        if let notch = screen.notchArea { return notch }
        let width: CGFloat = 200
        let menuBar = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        return NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - menuBar,
            width: width,
            height: menuBar
        )
    }

    /// Collapsed click target in screen coordinates: the notch plus a
    /// forgiving band just below it (the cursor is invisible inside the
    /// notch, so people aim slightly low).
    private func collapsedHitRect(on screen: NSScreen) -> NSRect {
        let notch = stripRect(on: screen)
        return NSRect(
            x: notch.minX,
            y: notch.minY - Self.underhang,
            width: notch.width,
            height: notch.height + Self.underhang
        )
    }

    /// Hit test for the global monitor. macOS clamps the cursor's y to the
    /// screen's top edge, which is exactly `collapsedHitRect.maxY` — and
    /// `NSRect.contains` treats the max edge as outside, so a click at the
    /// very top of the notch fails the test. Extend past the top edge (and a
    /// few points sideways) so that topmost row is reliably caught.
    private func collapsedHitTestRect(on screen: NSScreen) -> NSRect {
        let r = collapsedHitRect(on: screen)
        return NSRect(x: r.minX - 4, y: r.minY, width: r.width + 8, height: r.height + 8)
    }

    /// When expanded, clicking the notch closes the card. This is the notch
    /// strip extended past the screen's top edge (same half-open-interval
    /// reason as above) so a click at the very top still registers a close.
    private func notchHitRect(on screen: NSScreen) -> NSRect {
        let notch = stripRect(on: screen)
        return NSRect(x: notch.minX - 4, y: notch.minY, width: notch.width + 8, height: notch.height + 8)
    }

    private func applyFrame(expanded: Bool) {
        guard let screen = targetScreen else { return }
        let notch = stripRect(on: screen)

        let frame: NSRect
        if expanded {
            ui.notchSize = notch.size
            let cardW = max(Self.maxCardSize.width, notch.width)
            let width = cardW + Self.shadowPadX * 2
            let height = notch.height + Self.maxCardSize.height + Self.shadowPadBottom
            frame = NSRect(
                x: notch.midX - width / 2,
                y: screen.frame.maxY - height,
                width: width,
                height: height
            )
        } else {
            let hit = collapsedHitRect(on: screen)
            ui.notchSize = hit.size
            frame = hit
        }
        panel.setFrame(frame, display: true)
    }
}

extension NSScreen {
    /// Screen-coordinate rect of the camera notch, if this screen has one.
    var notchArea: NSRect? {
        guard safeAreaInsets.top > 0,
              let left = auxiliaryTopLeftArea,
              let right = auxiliaryTopRightArea else { return nil }
        return NSRect(
            x: left.maxX,
            y: frame.maxY - safeAreaInsets.top,
            width: right.minX - left.maxX,
            height: safeAreaInsets.top
        )
    }
}
