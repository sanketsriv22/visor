import AppKit
import SwiftUI

/// Where the product's real controls are on screen, by name — so the
/// introduction can draw around the actual Allow chip and the actual Stop
/// button rather than guessing where they ought to be. A control opts in
/// with `.spotlight("allow")`; the registry keeps its frame in screen
/// coordinates (origin bottom-left, like `NSScreen.frame`) and drops it
/// when the control goes away.
@MainActor
final class Spotlight: ObservableObject {
    static let shared = Spotlight()
    @Published private(set) var frames: [String: CGRect] = [:]
    private var anchors: [ObjectIdentifier: () -> Void] = [:]
    private var timer: Timer?

    /// A control's position changes without any layout of its own — the
    /// transcript scrolls under it, the card resizes around it — so while
    /// someone is watching, every anchor re-reports twenty times a second.
    /// `set` publishes only when a frame actually changed.
    func track(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        guard on else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.anchors.values.forEach { $0() } }
        }
    }

    fileprivate func attach(_ key: ObjectIdentifier, report: @escaping () -> Void) { anchors[key] = report }
    fileprivate func detach(_ key: ObjectIdentifier) { anchors.removeValue(forKey: key) }

    func set(_ id: String, _ frame: CGRect?) {
        if let frame {
            if frames[id] != frame { frames[id] = frame }
        } else if frames[id] != nil {
            frames.removeValue(forKey: id)
        }
    }
}

extension View {
    /// Report this view's frame on screen under `id` for the introduction.
    func spotlight(_ id: String) -> some View {
        background(SpotlightAnchor(id: id))
    }
}

/// A zero-cost view that knows its window, and therefore its place on
/// screen. Reports on layout and whenever its window moves or resizes;
/// clears on removal.
private struct SpotlightAnchor: NSViewRepresentable {
    let id: String

    func makeNSView(context: Context) -> AnchorView {
        let v = AnchorView()
        v.id = id
        return v
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.id = id
        view.report()
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        let id = view.id
        Task { @MainActor in Spotlight.shared.set(id, nil) }
    }

    final class AnchorView: NSView {
        var id = ""
        private var observers: [NSObjectProtocol] = []

        override var isOpaque: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            let key = ObjectIdentifier(self)
            guard let window else {
                Spotlight.shared.detach(key)
                report(nil)
                return
            }
            Spotlight.shared.attach(key) { [weak self] in self?.report() }
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main) { [weak self] _ in self?.report() })
            }
            report()
        }

        override func layout() {
            super.layout()
            report()
        }

        override func viewDidEndLiveResize() {
            super.viewDidEndLiveResize()
            report()
        }

        func report(_ frame: CGRect? = .zero) {
            guard let window, let frame else {
                Spotlight.shared.set(id, nil)
                return
            }
            _ = frame
            let inWindow = convert(bounds, to: nil)
            let onScreen = window.convertToScreen(inWindow)
            guard onScreen.width > 0, onScreen.height > 0 else { return }
            Spotlight.shared.set(id, onScreen)
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            let key = ObjectIdentifier(self)
            Task { @MainActor in Spotlight.shared.detach(key) }
        }
    }
}
