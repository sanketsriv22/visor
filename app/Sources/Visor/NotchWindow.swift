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

final class UIState: ObservableObject {
    @Published var expanded = false
    @Published var notchSize = CGSize(width: 200, height: 32)
}

final class NotchController {
    static let cardHeight: CGFloat = 260
    static let cardWidth: CGFloat = 420
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
    private let devin = DevinRunner()
    private var screenObserver: Any?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?

    init(startExpanded: Bool) {
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

        let root = StickyRootView(store: store, ui: ui, devin: devin) { [weak self] in
            self?.toggle()
        }
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
            // Expanded: only the notch strip at the top closes; clicks in
            // the card below pass through to the text editor.
            if event.locationInWindow.y >= self.panel.frame.height - self.ui.notchSize.height {
                self.toggle()
                return nil
            }
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self, !self.ui.expanded,
                  let screen = self.targetScreen,
                  self.collapsedHitTestRect(on: screen).contains(NSEvent.mouseLocation) else { return }
            self.toggle()
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

    func toggle() {
        if ui.expanded {
            store.saveNow()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                ui.expanded = false
            }
            panel.resignKey()
            // Shrink the window back to just the notch strip after the
            // card has animated away, so it can't intercept clicks.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
                guard let self, !self.ui.expanded else { return }
                self.applyFrame(expanded: false)
            }
        } else {
            store.reloadFromDiskIfClean()
            applyFrame(expanded: true)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                ui.expanded = true
            }
            panel.makeKeyAndOrderFront(nil)
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

    private func applyFrame(expanded: Bool) {
        guard let screen = targetScreen else { return }
        let notch = stripRect(on: screen)

        let frame: NSRect
        if expanded {
            ui.notchSize = notch.size
            let cardW = max(Self.cardWidth, notch.width)
            let width = cardW + Self.shadowPadX * 2
            let height = notch.height + Self.cardHeight + Self.shadowPadBottom
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
