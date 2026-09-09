import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    /// Show the introduction again — from the menu-bar panel.
    static let visorReplayIntroduction = Notification.Name("visor.replayIntroduction")
}

/// What the takeover is showing right now. Owned by `TakeoverGuide` in the
/// app and built by hand in the Design Lab, so the same view renders both.
@MainActor
final class TakeoverState: ObservableObject {
    enum Step: Int, CaseIterable {
        case boot, clickNotch, addTask, swapToChat, ask, expandHUD, backDown, hide, summon, finale
        static var count: Int { allCases.count }
    }

    /// Screen geometry the guide draws around, in the panel's own
    /// coordinate space (origin bottom-left, like AppKit).
    struct Geometry {
        var bounds: CGRect
        /// The physical notch (or the synthetic strip on a notchless display).
        var notch: CGRect
        /// The card for the current face, including the band behind the notch.
        var card: CGRect
        /// The mode switcher, on the notch's left shoulder.
        var switcher: CGRect
        /// Whether the HUD is up, which changes what the scrim has to do.
        var hud = false
    }

    @Published var step: Step = .boot
    @Published var geometry: Geometry
    /// Incremented for every completed step; the view fires a pixel burst
    /// from the notch each time it changes.
    @Published var bursts = 0
    @Published var lastBurst = Date.distantPast
    @Published var leaving = false
    @Published var stepStarted = Date()

    init(geometry: Geometry, step: Step = .boot) {
        self.geometry = geometry
        self.step = step
    }

    struct Line {
        let kicker: String
        let title: String
        let body: String
    }

    var line: Line { Self.line(for: step) }

    static func line(for step: Step) -> Line {
        let k = ShortcutSettings.hint(.toggle)
        let swap = ShortcutSettings.hint(.swapMode)
        let hud = ShortcutSettings.hint(.hud)
        switch step {
        case .boot:
            return Line(kicker: "VISOR", title: "Your Mac has a notch.",
                        body: "Let's put something in it.")
        case .clickNotch:
            return Line(kicker: "01 · THE NOTCH", title: "Click the notch.",
                        body: "Right there, at the top of the screen. That's where Visor lives.")
        case .addTask:
            return Line(kicker: "02 · A NOTE", title: "Type something you need to do, then press Return.",
                        body: "It's saved as plain Markdown in ~/Documents/Visor the moment you type it — a file your agents can read and write too.")
        case .swapToChat:
            return Line(kicker: "03 · CHAT", title: "Press \(swap) to flip to chat.",
                        body: "Same card, other face. The switcher up by the notch does the same thing.")
        case .ask:
            return Line(kicker: "04 · SAY ANYTHING", title: "Ask it anything, then press Return.",
                        body: "This first reply is on the house — no key, no agent needed yet.")
        case .expandHUD:
            return Line(kicker: "05 · THE HUD", title: "Now press \(hud).",
                        body: "When a conversation outgrows the card, it expands out of the notch into the whole screen.")
        case .backDown:
            return Line(kicker: "05 · THE HUD", title: "Press Esc to come back down.",
                        body: "The HUD is the same chat at another scale — your agents, tasks and memory on the rails.")
        case .hide:
            return Line(kicker: "06 · GONE", title: "Press \(k) to make it disappear.",
                        body: "Visor gets out of the way completely. Nothing in the Dock, nothing on screen.")
        case .summon:
            return Line(kicker: "07 · BACK", title: "Press \(k) again.",
                        body: "That's the one thing to remember. Or click the notch, or the mark in the menu bar.")
        case .finale:
            return Line(kicker: "THAT'S VISOR", title: "You're in.",
                        body: "Add an agent to make chat real — any model through OpenRouter, or Claude Code, Codex and Devin already on your Mac.")
        }
    }
}

/// The introduction as a screen takeover.
///
/// Not a window that explains Visor: the Mac dims, and a guide draws on the
/// real screen — a rough ring around the real notch, an arrow to the real
/// composer — and waits until you actually do the thing. Every step is the
/// product itself: you click the notch, you type a task into the note that
/// lands in ~/Documents/Visor, you send a message and a reply streams into
/// the real transcript, you expand into the HUD and back, you make Visor
/// disappear and summon it again. Nothing is simulated except the one reply,
/// which is scripted so chat works before any agent or key exists.
///
/// Mechanically it is one more panel at the notch's level, ordered *under*
/// the notch's windows and never key, so the card stays clickable and
/// typeable through it while everything else on screen is held. During the
/// HUD steps it moves above the HUD and thins its scrim, so the guide stays
/// legible over the glass.
@MainActor
final class TakeoverGuide {
    let state: TakeoverState
    let controller: NotchController
    var onOpenSettings: (() -> Void)?
    var onFinish: (() -> Void)?

    private var panel: NotchPanel?
    private var sinks = Set<AnyCancellable>()
    private var taskBaseline = 0
    private var demoBaseline = 0
    private var pending: DispatchWorkItem?

    init?(controller: NotchController) {
        guard let geo = controller.takeoverGeometry() else { return nil }
        self.controller = controller
        self.state = TakeoverState(geometry: geo)
    }

    // MARK: Lifecycle

    func start() {
        guard panel == nil else { return }
        let frame = controller.takeoverFrame() ?? .zero
        let panel = NotchPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: TakeoverView(
            state: state,
            onSkip: { [weak self] in self?.finish() },
            onAddAgent: { [weak self] in self?.addAgent() },
            onDone: { [weak self] in self?.finish() }))
        panel.setFrame(frame, display: false)
        // Shown, then the notch's own windows go back on top of it.
        panel.orderFrontRegardless()
        controller.bringToFront()
        self.panel = panel

        // The story starts with the notch closed, on the notes face.
        if controller.ui.expanded { controller.toggle() }
        observe()
        state.stepStarted = Date()
        schedule(after: Design.Motion.reduced ? 0.8 : 3.6) { [weak self] in
            self?.advance(to: .clickNotch)
        }
    }

    /// Skip or Done: fade, then go.
    func finish() {
        guard !state.leaving else { return }
        pending?.cancel()
        withAnimation(Design.Motion.animation(.easeInOut(duration: 0.6))) {
            state.leaving = true
        }
        controller.chat.demoNextSend = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            self.panel?.orderOut(nil)
            self.panel = nil
            self.sinks.removeAll()
            self.onFinish?()
        }
    }

    func addAgent() {
        onOpenSettings?()
        finish()
    }

    // MARK: Watching the real app

    private func observe() {
        let ui = controller.ui
        ui.$expanded
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] expanded in self?.expandedChanged(expanded) }
            .store(in: &sinks)
        ui.$mode
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in self?.modeChanged(mode) }
            .store(in: &sinks)
        controller.store.$items
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in self?.itemsChanged(items) }
            .store(in: &sinks)
        controller.chat.$demoTurns
            .receive(on: DispatchQueue.main)
            .sink { [weak self] turns in self?.demoTurnsChanged(turns) }
            .store(in: &sinks)
    }

    private func refreshGeometry() {
        if let geo = controller.takeoverGeometry() { state.geometry = geo }
    }

    private func expandedChanged(_ expanded: Bool) {
        refreshGeometry()
        switch state.step {
        case .clickNotch where expanded:
            // The card may reopen on whichever face it was left on; the
            // story wants the note first.
            if controller.ui.mode != .notes { controller.setMode(.notes) }
            taskBaseline = filledTasks(controller.store.items)
            celebrate(then: .addTask)
        case .hide where !expanded:
            advance(to: .summon)
        case .summon where expanded:
            celebrate(then: .finale)
        default:
            break
        }
    }

    private func modeChanged(_ mode: VisorMode) {
        refreshGeometry()
        switch state.step {
        case .swapToChat where mode == .chat:
            controller.chat.demoNextSend = true
            demoBaseline = controller.chat.demoTurns
            celebrate(then: .ask)
        case .expandHUD where mode.isFullScreen:
            // Above the HUD so the guide reads over the glass; the scrim
            // thins for the same reason. Esc still reaches the HUD because
            // this panel is never key.
            schedule(after: Design.Motion.reduced ? 0.3 : 1.4) { [weak self] in
                guard let self else { return }
                self.panel?.orderFrontRegardless()
                self.advance(to: .backDown)
            }
        case .backDown where !mode.isFullScreen:
            controller.bringToFront()
            celebrate(then: .hide)
        default:
            break
        }
    }

    private func itemsChanged(_ items: [NoteItem]) {
        guard state.step == .addTask, filledTasks(items) > taskBaseline else { return }
        celebrate(then: .swapToChat)
    }

    private func demoTurnsChanged(_ turns: Int) {
        guard state.step == .ask, turns > demoBaseline else { return }
        celebrate(then: .expandHUD)
    }

    private func filledTasks(_ items: [NoteItem]) -> Int {
        items.filter { $0.isTask && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    // MARK: Advancing

    private func celebrate(then next: TakeoverState.Step) {
        state.bursts += 1
        state.lastBurst = Date()
        schedule(after: Design.Motion.reduced ? 0.2 : 1.0) { [weak self] in
            self?.advance(to: next)
        }
    }

    private func advance(to next: TakeoverState.Step) {
        guard !state.leaving, next.rawValue > state.step.rawValue else { return }
        refreshGeometry()
        withAnimation(Design.Motion.animation(.easeInOut(duration: 0.35))) {
            state.step = next
        }
        state.stepStarted = Date()
    }

    private func schedule(after seconds: TimeInterval, _ block: @escaping () -> Void) {
        pending?.cancel()
        let work = DispatchWorkItem(block: block)
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
