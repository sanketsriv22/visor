import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    /// Show the introduction again — from the menu-bar panel or Settings.
    static let visorReplayIntroduction = Notification.Name("visor.replayIntroduction")
}

/// What the takeover is showing right now. Owned by `TakeoverGuide` in the
/// app and built by hand in the Design Lab, so the same view renders both.
@MainActor
final class TakeoverState: ObservableObject {
    /// The eight moments. Each advances when the real thing happens.
    enum Step: Int, CaseIterable {
        case boot, summon, connect, firstTask, practice, control, yours, finale
    }

    /// Screen geometry the guide draws around, in the panel's own
    /// coordinate space (origin bottom-left, like AppKit).
    struct Geometry {
        var bounds: CGRect
        var notch: CGRect
        var card: CGRect
        var switcher: CGRect
        var expanded = false
        var hud = false
        /// The practice window's frame while it is up.
        var practice: CGRect? = nil
    }

    /// An agent the connect step can offer.
    struct AgentOption: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let detail: String
        let ready: Bool
    }

    @Published var step: Step = .boot
    @Published var geometry: Geometry
    @Published var bursts = 0
    @Published var lastBurst = Date.distantPast
    @Published var leaving = false
    @Published var stepStarted = Date()

    /// Connect step.
    @Published var options: [AgentOption] = []
    @Published var hasKey = false
    @Published var chosen: String? = nil
    @Published var checking = false
    /// True once the user chose to go on without an agent; the first task
    /// runs on the scripted stand-in and says so.
    @Published var standIn = false

    /// First-task step.
    @Published var awaitingApproval = false
    @Published var taskDone = false

    /// Practice and control steps.
    let practice: PracticeDriver

    init(geometry: Geometry, step: Step = .boot, practice: PracticeDriver = PracticeDriver()) {
        self.geometry = geometry
        self.step = step
        self.practice = practice
    }

    struct Line {
        let kicker: String
        let title: String
        let body: String
    }

    var line: Line {
        let summon = ShortcutSettings.hint(.toggle)
        let hud = ShortcutSettings.hint(.hud)
        let dictate = ShortcutSettings.hint(.dictate)
        switch step {
        case .boot:
            return Line(kicker: "VISOR", title: "An agent lives in your notch.",
                        body: "Let's wake it up.")
        case .summon:
            return Line(kicker: "01 · SUMMON", title: "Press \(summon).",
                        body: "Or click the notch. Either brings Visor out, from anywhere, over anything.")
        case .connect:
            if chosen != nil {
                return Line(kicker: "02 · CONNECTED", title: "\(chosen ?? "Your agent") is on.",
                            body: "Its status dot lit up in the card. Next: give it something to do.")
            }
            if let ready = options.first(where: \.ready) {
                return Line(kicker: "02 · CONNECT", title: "\(ready.name) is on this Mac.",
                            body: "\(ready.detail). Use it, or add an OpenRouter key for any model.")
            }
            if hasKey {
                return Line(kicker: "02 · CONNECT", title: "You have an OpenRouter key.",
                            body: "That's any hosted model. Use it, or pick a local agent below.")
            }
            return Line(kicker: "02 · CONNECT", title: "Nothing connected yet.",
                        body: "Add an OpenRouter key for any model, or install Claude Code, Codex or Devin. Or keep going — the first task runs on a scripted stand-in.")
        case .firstTask:
            if taskDone {
                return Line(kicker: "03 · FIRST TASK", title: "That's a task, done.",
                            body: standIn ? "Scripted, but the shape is real: ask, approve, result. Now let it drive."
                                          : "It asked, you allowed, it answered. Now let it drive.")
            }
            if awaitingApproval {
                return Line(kicker: "03 · FIRST TASK", title: "It's asking first.",
                            body: "Nothing runs on your Mac until you say so. Press Allow.")
            }
            return Line(kicker: "03 · FIRST TASK", title: "Send it something.",
                        body: "This one's ready to go — edit it if you like, then press Return.")
        case .practice:
            return Line(kicker: "04 · COMPUTER USE", title: "Now let it drive.",
                        body: "A practice window opened below — nothing in it is real. Press Run and watch it read the report and fill in the total.")
        case .control:
            if practice.stopped {
                return Line(kicker: "05 · CONTROL", title: "Stopped. Nothing lost.",
                            body: "It halts between actions, so you can always step in. Press Continue to let it finish.")
            }
            if practice.isDone {
                return Line(kicker: "05 · CONTROL", title: "Total's in.",
                            body: "You watched every step and stopped it once. That's how every run works.")
            }
            return Line(kicker: "05 · CONTROL", title: "You're in charge.",
                        body: "While it works, press Stop.")
        case .yours:
            return Line(kicker: "06 · YOURS", title: "Your turn.",
                        body: "Ask something real, or pick one below. \(hud) expands into the HUD when it gets big; \(dictate) dictates.")
        case .finale:
            return Line(kicker: "THAT'S VISOR", title: "It lives in the notch.",
                        body: "\(summon) brings it back — anywhere, any time. So does clicking the notch, or the mark in the menu bar.")
        }
    }
}

/// The introduction as a screen takeover.
///
/// The Mac dims; Visor wakes from the notch outward; a guide draws on the
/// real screen and waits until the real thing happens: summon it, connect
/// an agent (or go on with a scripted stand-in), send a first task and
/// answer its approval, let a scripted agent drive a practice window and
/// stop it once, then ask something of your own. Every surface is the
/// product's own. Progress persists past connect, the first task and the
/// practice, so an excursion to Settings or a system dialog doesn't start
/// it over.
///
/// It is a panel at the notch's level, above the notch's windows, never
/// key, with real transparency cut out of its scrim where the card, the
/// notch and the practice window are, so clicks fall through to them.
@MainActor
final class TakeoverGuide {
    let state: TakeoverState
    let controller: NotchController
    var onOpenSettings: (() -> Void)?
    var onFinish: (() -> Void)?

    static let progressKey = "visor.intro.progress"

    private var panel: NotchPanel?
    private var practiceWindow: NSWindow?
    private var sinks = Set<AnyCancellable>()
    private var pending: DispatchWorkItem?
    private var settingsPoll: Timer?
    private var sentInTask = false
    private var messagesAtYours = 0

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
            actions: TakeoverActions(
                skip: { [weak self] in self?.finish() },
                back: { [weak self] in self?.back() },
                useAgent: { [weak self] name in self?.useAgent(named: name) },
                addKey: { [weak self] in self?.addKey() },
                skipAgent: { [weak self] in self?.skipAgent() },
                runPractice: { [weak self] in self?.runPractice() },
                stopPractice: { [weak self] in self?.state.practice.stop() },
                continuePractice: { [weak self] in self?.continuePractice() },
                done: { [weak self] in self?.advance(to: .finale) },
                finish: { [weak self] in self?.finish() },
                suggest: { [weak self] text in self?.controller.chat.draft = text })))
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        self.panel = panel

        detectAgents()
        observe()

        // Resume past what's already been done; the reveal always plays.
        let saved = TakeoverState.Step(rawValue: UserDefaults.standard.integer(forKey: Self.progressKey))
        if controller.ui.expanded { controller.toggle() }
        state.stepStarted = Date()
        schedule(after: Design.Motion.reduced ? 0.8 : 3.4) { [weak self] in
            guard let self else { return }
            if let saved, saved.rawValue >= TakeoverState.Step.connect.rawValue, saved != .finale {
                self.advance(to: .summon)
            } else {
                self.advance(to: .summon)
            }
        }
    }

    /// Skip or Done: fade, then go.
    func finish() {
        guard !state.leaving else { return }
        pending?.cancel()
        settingsPoll?.invalidate()
        withAnimation(Design.Motion.animation(.easeInOut(duration: 0.6))) { state.leaving = true }
        controller.chat.demoNextSend = false
        state.practice.reset()
        practiceWindow?.orderOut(nil)
        UserDefaults.standard.set(TakeoverState.Step.finale.rawValue, forKey: Self.progressKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            self.panel?.orderOut(nil)
            self.panel = nil
            self.practiceWindow = nil
            self.sinks.removeAll()
            self.onFinish?()
        }
    }

    func back() {
        guard let previous = TakeoverState.Step(rawValue: state.step.rawValue - 1),
              previous != .boot else { return }
        if state.step == .practice || state.step == .control { hidePractice() }
        move(to: previous)
    }

    // MARK: Connect

    private func detectAgents() {
        let chat = controller.chat
        state.hasKey = OpenRouterClient.hasKey
        state.checking = true
        let clis = chat.chatAgents.filter(\.isNotchCLI)
        CLIAccounts.shared.refreshAll(clis)
        // Accounts answer asynchronously; read them now and again shortly.
        refreshOptions()
        schedule(after: 1.5) { [weak self] in
            self?.refreshOptions()
            self?.state.checking = false
        }
    }

    private func refreshOptions() {
        let chat = controller.chat
        state.hasKey = OpenRouterClient.hasKey
        state.options = chat.chatAgents.map { agent in
            if agent.isNotchCLI {
                let account = CLIAccounts.shared.account(for: agent)
                let ready = account?.loggedIn ?? false
                return TakeoverState.AgentOption(
                    name: agent.name,
                    detail: ready ? "Signed in\(account?.email.map { " as \($0)" } ?? "")"
                                  : "Installed, not signed in — run `\(agent.command)` once in Terminal",
                    ready: ready)
            }
            return TakeoverState.AgentOption(
                name: agent.name,
                detail: state.hasKey ? "Any model through OpenRouter — key found"
                                     : "Needs an OpenRouter key",
                ready: state.hasKey)
        }
    }

    private func useAgent(named name: String) {
        guard let agent = controller.chat.chatAgents.first(where: { $0.name == name }) else { return }
        controller.chat.use(agent)
        state.chosen = name
        state.standIn = false
        celebrate(then: .firstTask)
    }

    /// Off to Settings for a key. The takeover hides — a status-bar-level
    /// scrim would sit over the Settings window — and comes back when
    /// Settings closes, re-checking what changed.
    private func addKey() {
        panel?.orderOut(nil)
        practiceWindow?.orderOut(nil)
        onOpenSettings?()
        settingsPoll?.invalidate()
        settingsPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let open = NSApp.windows.contains { $0.title == "Visor Settings" && $0.isVisible }
                if !open {
                    self.settingsPoll?.invalidate()
                    self.panel?.orderFrontRegardless()
                    self.refreshOptions()
                    if self.state.hasKey, let hosted = self.controller.chat.chatAgents.first(where: \.isChat) {
                        self.useAgent(named: hosted.name)
                    }
                }
            }
        }
    }

    private func skipAgent() {
        state.standIn = true
        state.chosen = nil
        advance(to: .firstTask)
    }

    // MARK: First task

    private func primeFirstTask() {
        let chat = controller.chat
        if controller.ui.mode != .chat { controller.setMode(.chat) }
        chat.draft = "What's the biggest file on my Desktop?"
        chat.demoNextSend = state.standIn || chat.agent == nil
        sentInTask = false
        state.taskDone = false
        state.awaitingApproval = false
    }

    // MARK: Practice

    private func showPractice() {
        if practiceWindow == nil {
            practiceWindow = PracticeWindow.make(driver: state.practice)
        }
        guard let window = practiceWindow, let frame = controller.takeoverFrame(),
              let screen = NSScreen.screens.first(where: { $0.frame == frame }) ?? NSScreen.main else { return }
        let cardBottom = state.geometry.card.minY
        PracticeWindow.place(window, on: screen, under: cardBottom)
        window.orderFrontRegardless()
        state.geometry.practice = window.frame
        panel?.orderFrontRegardless()
    }

    private func hidePractice() {
        practiceWindow?.orderOut(nil)
        state.geometry.practice = nil
        state.practice.reset()
    }

    private func runPractice() {
        state.practice.run()
        // Once it is visibly working, teach the stop.
        schedule(after: Design.Motion.reduced ? 0.4 : 1.6) { [weak self] in
            guard let self, self.state.step == .practice, self.state.practice.running else { return }
            self.advance(to: .control)
        }
    }

    private func continuePractice() {
        state.practice.run()
    }

    // MARK: Watching the real app

    private func observe() {
        let ui = controller.ui
        let chat = controller.chat
        ui.$expanded.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] on in self?.expandedChanged(on) }.store(in: &sinks)
        ui.$mode.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshGeometry() }.store(in: &sinks)
        chat.$pendingApproval.receive(on: DispatchQueue.main)
            .sink { [weak self] p in self?.approvalChanged(p != nil) }.store(in: &sinks)
        chat.$isStreaming.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] on in self?.streamingChanged(on) }.store(in: &sinks)
        chat.$conversation.map(\.messages.count).removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] n in self?.messageCountChanged(n) }.store(in: &sinks)
        state.practice.$phase.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.practiceChanged() }.store(in: &sinks)
        state.practice.$stops.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.practiceChanged() }.store(in: &sinks)
        CLIAccounts.shared.objectWillChange.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refreshOptions() } }.store(in: &sinks)
    }

    private func refreshGeometry() {
        var geo = controller.takeoverGeometry() ?? state.geometry
        geo.practice = practiceWindow?.isVisible == true ? practiceWindow?.frame : nil
        state.geometry = geo
        DispatchQueue.main.async { [weak self] in self?.panel?.orderFrontRegardless() }
    }

    private func expandedChanged(_ expanded: Bool) {
        refreshGeometry()
        if state.step == .summon, expanded {
            if controller.ui.mode != .chat { controller.setMode(.chat) }
            celebrate(then: .connect)
        }
    }

    private func approvalChanged(_ pending: Bool) {
        guard state.step == .firstTask else { return }
        state.awaitingApproval = pending
        if pending { state.bursts += 1; state.lastBurst = Date() }
    }

    private func streamingChanged(_ streaming: Bool) {
        guard state.step == .firstTask, sentInTask else { return }
        if !streaming, !state.awaitingApproval,
           let last = controller.chat.conversation.messages.last,
           last.role == .assistant, !last.content.isEmpty {
            state.taskDone = true
            state.bursts += 1; state.lastBurst = Date()
            UserDefaults.standard.set(TakeoverState.Step.practice.rawValue, forKey: Self.progressKey)
            schedule(after: Design.Motion.reduced ? 0.6 : 2.2) { [weak self] in self?.advance(to: .practice) }
        }
    }

    private func messageCountChanged(_ count: Int) {
        switch state.step {
        case .firstTask:
            if controller.chat.conversation.messages.last?.role == .user { sentInTask = true }
        case .yours:
            if count > messagesAtYours, controller.chat.conversation.messages.last?.role == .user {
                celebrate(then: .finale)
            }
        default:
            break
        }
    }

    private func practiceChanged() {
        switch state.step {
        case .control:
            if state.practice.isDone {
                state.bursts += 1; state.lastBurst = Date()
                UserDefaults.standard.set(TakeoverState.Step.yours.rawValue, forKey: Self.progressKey)
                schedule(after: Design.Motion.reduced ? 0.6 : 2.0) { [weak self] in
                    self?.hidePractice()
                    self?.advance(to: .yours)
                }
            }
        case .practice:
            if state.practice.isDone {
                // Finished before the user was asked to stop: still counts.
                advance(to: .control)
            }
        default:
            break
        }
    }

    // MARK: Advancing

    private func celebrate(then next: TakeoverState.Step) {
        state.bursts += 1
        state.lastBurst = Date()
        schedule(after: Design.Motion.reduced ? 0.2 : 1.0) { [weak self] in self?.advance(to: next) }
    }

    private func advance(to next: TakeoverState.Step) {
        guard !state.leaving, next.rawValue > state.step.rawValue else { return }
        move(to: next)
    }

    private func move(to next: TakeoverState.Step) {
        refreshGeometry()
        withAnimation(Design.Motion.animation(.easeInOut(duration: 0.35))) { state.step = next }
        state.stepStarted = Date()
        switch next {
        case .connect:
            refreshOptions()
            UserDefaults.standard.set(next.rawValue, forKey: Self.progressKey)
        case .firstTask:
            primeFirstTask()
            UserDefaults.standard.set(next.rawValue, forKey: Self.progressKey)
        case .practice:
            showPractice()
        case .yours:
            messagesAtYours = controller.chat.conversation.messages.count
            controller.chat.draft = ""
            if controller.ui.mode != .chat { controller.setMode(.chat) }
        case .finale:
            hidePractice()
        default:
            break
        }
    }

    private func schedule(after seconds: TimeInterval, _ block: @escaping () -> Void) {
        pending?.cancel()
        let work = DispatchWorkItem(block: block)
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

/// Everything the view can ask the guide to do.
struct TakeoverActions {
    var skip: () -> Void = {}
    var back: () -> Void = {}
    var useAgent: (String) -> Void = { _ in }
    var addKey: () -> Void = {}
    var skipAgent: () -> Void = {}
    var runPractice: () -> Void = {}
    var stopPractice: () -> Void = {}
    var continuePractice: () -> Void = {}
    var done: () -> Void = {}
    var finish: () -> Void = {}
    var suggest: (String) -> Void = { _ in }
}
