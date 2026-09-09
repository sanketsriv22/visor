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
    /// Six moments. The story drives itself; the person's only inputs are
    /// naming and connecting their agent, allowing the one thing it asks
    /// to run, and — if they like — pressing Stop.
    enum Step: Int, CaseIterable {
        case boot, summon, agent, firstTask, drive, finale
    }

    struct Geometry {
        var bounds: CGRect
        var notch: CGRect
        var card: CGRect
        var switcher: CGRect
        var expanded = false
        var hud = false
    }

    enum Connection: Equatable { case cli, openRouter }

    @Published var step: Step = .boot
    @Published var geometry: Geometry
    @Published var bursts = 0
    @Published var lastBurst = Date.distantPast
    @Published var leaving = false
    @Published var stepStarted = Date()
    @Published var milestone: String? = nil

    /// Agent step — the one form in the tour.
    @Published var agentName = "Claude"
    @Published var connection: Connection = .openRouter
    @Published var keyInput = ""
    @Published var hasKey = false
    /// A signed-in local CLI found on this Mac, if any.
    @Published var cliFound: (name: String, command: String, detail: String)? = nil
    @Published var creating = false
    @Published var created = false
    @Published var formError: String? = nil

    /// First-task step.
    @Published var awaitingApproval = false
    @Published var taskDone = false
    @Published var standIn = false
    @Published var trouble: String? = nil

    /// Drive step.
    @Published var driveStopped = false
    @Published var driveDone = false
    @Published var askStop = false

    init(geometry: Geometry, step: Step = .boot) {
        self.geometry = geometry
        self.step = step
    }

    var canCreate: Bool {
        let name = agentName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !creating else { return false }
        switch connection {
        case .cli:        return cliFound != nil
        case .openRouter: return hasKey || !keyInput.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    struct Line {
        let kicker: String
        let title: String
        let body: String
    }

    var line: Line {
        let summon = ShortcutSettings.hint(.toggle)
        switch step {
        case .boot:
            return Line(kicker: "VISOR", title: "An agent lives in your notch.",
                        body: "Let's wake it up.")
        case .summon:
            return Line(kicker: "01 · THE NOTCH", title: "This is where it lives.",
                        body: "\(summon) brings it out from anywhere, over anything. So does clicking the notch.")
        case .agent:
            if created {
                return Line(kicker: "02 · YOUR AGENT", title: "\(agentName) is on.",
                            body: "Its status dot lit up in the card. Now watch it take a task.")
            }
            return Line(kicker: "02 · YOUR AGENT", title: "Name your agent.",
                        body: cliFound != nil
                            ? "\(cliFound!.name) is already on this Mac, \(cliFound!.detail). Use it, or paste an OpenRouter key for any model."
                            : "It talks to any model through OpenRouter. Paste a key and it's yours.")
        case .firstTask:
            if taskDone {
                return Line(kicker: "03 · A TASK", title: "That's a task, done.",
                            body: standIn ? "Scripted this time, but the shape is real: ask, approve, result."
                                          : "It asked, you allowed, it answered.")
            }
            if let trouble {
                return Line(kicker: "03 · A TASK", title: "Your agent couldn't answer.",
                            body: "\(trouble) So this one runs on a scripted stand-in — same shape, no model.")
            }
            if awaitingApproval {
                return Line(kicker: "03 · A TASK", title: "It's asking first.",
                            body: "Nothing runs on your Mac until you say so. Press Allow.")
            }
            return Line(kicker: "03 · A TASK", title: "Watch it take a task.",
                        body: "It's typing the request for you and sending it. This is exactly what you'll do.")
        case .drive:
            if driveStopped {
                return Line(kicker: "04 · CONTROL", title: "Stopped between actions.",
                            body: "That's how every run halts — instantly, cleanly. You're always the one in charge.")
            }
            if driveDone {
                return Line(kicker: "04 · DRIVING", title: "Done.",
                            body: "A real run asks for Accessibility first, then clicks and types just like that.")
            }
            if askStop {
                return Line(kicker: "04 · CONTROL", title: "Press Stop.",
                            body: "Right there in the card. It halts between actions, and nothing else happens.")
            }
            return Line(kicker: "04 · DRIVING", title: "Now it drives.",
                        body: "Computer Use is the third face of the notch. This run is a demonstration — every step shows here as it happens.")
        case .finale:
            return Line(kicker: "THAT'S VISOR", title: "It lives in the notch.",
                        body: "\(summon) brings it back — anywhere, any time. So does clicking the notch, or the mark in the menu bar.")
        }
    }
}

/// The introduction as a screen takeover that tells its own story.
///
/// The Mac dims; Visor wakes from the notch outward and opens itself. The
/// person names and connects an agent — the tour's one form — then watches
/// that agent take a task the tour types and sends for them, allowing the
/// one thing it asks to run. Then Computer Use, Visor's own third face,
/// drives a demonstration run step by step in its real card, and Stop is
/// there to press (the tour presses it if they don't). Then the way back.
///
/// A panel at the notch's level, above the notch's windows, with real
/// transparency cut out of its scrim for the card, so the card stays live.
@MainActor
final class TakeoverGuide {
    let state: TakeoverState
    let controller: NotchController
    var onOpenSettings: (() -> Void)?
    var onFinish: (() -> Void)?

    static let progressKey = "visor.intro.progress"

    private var panel: NotchPanel?
    private var sinks = Set<AnyCancellable>()
    private var pending: DispatchWorkItem?
    private var typing: [DispatchWorkItem] = []
    private var sentInTask = false
    private var taskTimeout: DispatchWorkItem?

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
                summon: { [weak self] in self?.summonNow() },
                createAgent: { [weak self] in self?.createAgent() },
                stopDrive: { [weak self] in self?.stopDrive(byUser: true) },
                finish: { [weak self] in self?.finish() })))
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        self.panel = panel

        detect()
        observe()

        if controller.ui.expanded { controller.toggle() }
        state.stepStarted = Date()
        schedule(after: Design.Motion.reduced ? 0.8 : 3.6) { [weak self] in
            self?.advance(to: .summon)
        }
    }

    func finish() {
        guard !state.leaving else { return }
        pending?.cancel()
        taskTimeout?.cancel()
        typing.forEach { $0.cancel() }
        withAnimation(Design.Motion.animation(.easeInOut(duration: 0.6))) { state.leaving = true }
        controller.chat.demoNextSend = false
        if ComputerUseAgent.shared.demonstrating { ComputerUseAgent.shared.stopDemo() }
        UserDefaults.standard.set(TakeoverState.Step.finale.rawValue, forKey: Self.progressKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            self.panel?.orderOut(nil)
            self.panel = nil
            self.sinks.removeAll()
            self.onFinish?()
        }
    }

    // MARK: Summon

    /// The story opens the notch itself, a beat after showing where it is.
    private func summonNow() {
        guard state.step == .summon, !controller.ui.expanded else { return }
        controller.toggle()
    }

    // MARK: Agent

    private func detect() {
        state.hasKey = OpenRouterClient.hasKey
        let clis = controller.chat.chatAgents.filter(\.isNotchCLI)
        CLIAccounts.shared.refreshAll(clis)
        refreshDetection()
        schedule(after: 1.5) { [weak self] in self?.refreshDetection() }
    }

    private func refreshDetection() {
        state.hasKey = OpenRouterClient.hasKey
        let clis = controller.chat.chatAgents.filter(\.isNotchCLI)
        if let ready = clis.first(where: { CLIAccounts.shared.account(for: $0)?.loggedIn == true }) {
            let account = CLIAccounts.shared.account(for: ready)
            state.cliFound = (ready.name, ready.command,
                              "signed in\(account?.email.map { " as \($0)" } ?? "")")
            if state.connection == .openRouter, !state.hasKey { state.connection = .cli }
        }
    }

    /// The tour's one form: a name, and a way to reach a model.
    private func createAgent() {
        guard state.canCreate else { return }
        let name = state.agentName.trimmingCharacters(in: .whitespaces)
        state.creating = true
        state.formError = nil
        var provider: AIProvider
        switch state.connection {
        case .cli:
            provider = AIProvider(name: name, command: state.cliFound?.command ?? "claude",
                                  args: ["--dangerously-skip-permissions", "-p"],
                                  interactiveArgs: ["--dangerously-skip-permissions"], kind: .cli)
            provider.runsInNotch = true
        case .openRouter:
            let key = state.keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { Keychain.set(key, account: OpenRouterClient.sharedKeyAccount) }
            guard OpenRouterClient.hasKey else {
                state.creating = false
                state.formError = "The key didn't save. Paste it again."
                return
            }
            provider = AIProvider(name: name, command: "", args: [], kind: .openRouter,
                                  model: ChatController.defaultModel)
        }
        // A name that already exists is that agent, updated — not a twin.
        controller.ai.upsert(provider)
        if let agent = controller.chat.chatAgents.first(where: { $0.name == name }) {
            controller.chat.use(agent)
        }
        state.creating = false
        state.created = true
        state.standIn = false
        NSApp.deactivate()
        celebrate(then: .firstTask, after: 1.6)
    }

    // MARK: First task

    private func runFirstTask() {
        let chat = controller.chat
        if controller.ui.mode != .chat { controller.setMode(.chat) }
        chat.draft = ""
        chat.demoNextSend = state.standIn || chat.agent == nil
        sentInTask = false
        state.taskDone = false
        state.awaitingApproval = false
        // Typed, then sent, on the person's behalf: they watch the shape of
        // it rather than perform it.
        type("What's the biggest file on my Desktop?", into: { chat.draft = $0 }) { [weak self] in
            self?.schedule(after: 0.5) { [weak self] in
                guard let self, self.state.step == .firstTask else { return }
                self.controller.chat.send()
            }
        }
    }

    /// The agent failed or went quiet: say so and run the stand-in, without
    /// asking anything.
    private func fallBackToStandIn(_ reason: String) {
        guard state.step == .firstTask, !state.taskDone, !state.standIn else { return }
        taskTimeout?.cancel()
        controller.chat.stop()
        withAnimation(Design.Motion.animation(Design.Motion.standard)) {
            state.trouble = reason
            state.standIn = true
        }
        schedule(after: 1.8) { [weak self] in self?.runFirstTask() }
    }

    // MARK: Drive

    private func runDrive() {
        controller.setMode(.computerUse)
        state.driveStopped = false
        state.driveDone = false
        state.askStop = false
        let agent = ComputerUseAgent.shared
        agent.draft = ""
        schedule(after: 0.9) { [weak self] in
            guard let self else { return }
            self.type("Turn on Night Shift in System Settings", into: { agent.draft = $0 }) { [weak self] in
                guard let self, self.state.step == .drive else { return }
                agent.demoRun(steps: [
                    ("Opening System Settings", "Opened System Settings"),
                    ("Reading the sidebar", "Read the sidebar: 24 items"),
                    ("Scrolling to Displays", "Scrolled to Displays"),
                    ("Clicking “Displays”", "Clicked “Displays”"),
                    ("Looking for Night Shift", "Found “Night Shift…” below the display list"),
                    ("Clicking “Night Shift…”", "Clicked “Night Shift…”"),
                    ("Setting the schedule", "Set Schedule to Sunset to Sunrise"),
                ], final: "Done — Night Shift is on, sunset to sunrise.")
                // A few steps in, the ask; a few seconds later, the tour
                // presses Stop itself if they haven't.
                self.schedule(after: 3.6) { [weak self] in
                    guard let self, self.state.step == .drive, agent.demonstrating else { return }
                    withAnimation(Design.Motion.animation(Design.Motion.standard)) { self.state.askStop = true }
                    self.schedule(after: 4.5) { [weak self] in
                        guard let self, self.state.step == .drive, agent.demonstrating else { return }
                        self.stopDrive(byUser: false)
                    }
                }
            }
        }
    }

    private func stopDrive(byUser: Bool) {
        guard state.step == .drive, ComputerUseAgent.shared.demonstrating else { return }
        ComputerUseAgent.shared.stopDemo()
        withAnimation(Design.Motion.animation(Design.Motion.standard)) {
            state.askStop = false
            state.driveStopped = true
        }
        state.bursts += 1; state.lastBurst = Date()
        celebrateMilestone(byUser ? "You're in control" : "Stopped, cleanly")
        UserDefaults.standard.set(TakeoverState.Step.finale.rawValue, forKey: Self.progressKey)
        schedule(after: Design.Motion.reduced ? 1.0 : 3.0) { [weak self] in self?.advance(to: .finale) }
    }

    // MARK: Watching the real app

    private func observe() {
        let ui = controller.ui
        let chat = controller.chat
        ui.$expanded.removeDuplicates()
            .sink { [weak self] on in self?.expandedChanged(on) }.store(in: &sinks)
        ui.$mode.removeDuplicates()
            .sink { [weak self] _ in self?.refreshGeometry() }.store(in: &sinks)
        chat.$pendingApproval.receive(on: DispatchQueue.main)
            .sink { [weak self] p in self?.approvalChanged(p != nil) }.store(in: &sinks)
        chat.$isStreaming.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] on in self?.streamingChanged(on) }.store(in: &sinks)
        chat.$conversation.map(\.messages.count).removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.messagesChanged() }.store(in: &sinks)
        chat.$error.receive(on: DispatchQueue.main)
            .sink { [weak self] e in self?.errorChanged(e) }.store(in: &sinks)
        ComputerUseAgent.shared.$demonstrating.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] on in self?.demoChanged(on) }.store(in: &sinks)
        CLIAccounts.shared.objectWillChange.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refreshDetection() } }.store(in: &sinks)
    }

    private func refreshGeometry() {
        state.geometry = controller.takeoverGeometry() ?? state.geometry
        DispatchQueue.main.async { [weak self] in self?.panel?.orderFrontRegardless() }
    }

    private func expandedChanged(_ expanded: Bool) {
        var geo = controller.takeoverGeometry() ?? state.geometry
        geo.expanded = expanded
        state.geometry = geo
        DispatchQueue.main.async { [weak self] in self?.panel?.orderFrontRegardless() }
        if state.step == .summon, expanded {
            if controller.ui.mode != .chat { controller.setMode(.chat) }
            celebrate(then: .agent, after: 1.4)
        }
    }

    private func approvalChanged(_ pending: Bool) {
        guard state.step == .firstTask else { return }
        state.awaitingApproval = pending
        if pending {
            taskTimeout?.cancel()
            state.bursts += 1; state.lastBurst = Date()
        }
    }

    private func errorChanged(_ error: String?) {
        guard state.step == .firstTask, !state.taskDone, let error, !error.isEmpty else { return }
        fallBackToStandIn(error)
    }

    private func streamingChanged(_ streaming: Bool) {
        guard state.step == .firstTask, sentInTask, !state.taskDone else { return }
        if !streaming, !state.awaitingApproval {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, self.state.step == .firstTask, !self.state.taskDone,
                      !self.state.awaitingApproval, !self.controller.chat.isStreaming else { return }
                let last = self.controller.chat.conversation.messages.last
                if last?.role == .assistant, !(last?.content.isEmpty ?? true) {
                    self.taskTimeout?.cancel()
                    self.state.taskDone = true
                    self.state.bursts += 1; self.state.lastBurst = Date()
                    self.celebrateMilestone("First task, done")
                    UserDefaults.standard.set(TakeoverState.Step.drive.rawValue, forKey: Self.progressKey)
                    self.schedule(after: Design.Motion.reduced ? 0.8 : 3.0) { [weak self] in self?.advance(to: .drive) }
                } else if self.state.trouble == nil {
                    self.fallBackToStandIn(self.controller.chat.error ?? "It didn't answer.")
                }
            }
        }
    }

    private func messagesChanged() {
        guard state.step == .firstTask, controller.chat.conversation.messages.last?.role == .user else { return }
        sentInTask = true
        taskTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state.step == .firstTask, !self.state.taskDone,
                  !self.state.awaitingApproval else { return }
            self.fallBackToStandIn("No reply after thirty seconds.")
        }
        taskTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    private func demoChanged(_ demonstrating: Bool) {
        guard state.step == .drive, !demonstrating, !state.driveStopped else { return }
        // Ran to the end without a stop: still a success.
        if ComputerUseAgent.shared.status.hasPrefix("Done") {
            withAnimation(Design.Motion.animation(Design.Motion.standard)) { state.driveDone = true }
            state.bursts += 1; state.lastBurst = Date()
            celebrateMilestone("It drove your Mac")
            UserDefaults.standard.set(TakeoverState.Step.finale.rawValue, forKey: Self.progressKey)
            schedule(after: 3.0) { [weak self] in self?.advance(to: .finale) }
        }
    }

    // MARK: Advancing

    private func celebrate(then next: TakeoverState.Step, after: TimeInterval = 1.0) {
        state.bursts += 1
        state.lastBurst = Date()
        schedule(after: Design.Motion.reduced ? 0.2 : after) { [weak self] in self?.advance(to: next) }
    }

    private func celebrateMilestone(_ text: String) {
        withAnimation(Design.Motion.animation(Design.Motion.surface)) { state.milestone = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + (Design.Motion.reduced ? 0.8 : 1.7)) { [weak self] in
            withAnimation(Design.Motion.animation(Design.Motion.standard)) { self?.state.milestone = nil }
        }
    }

    private func advance(to next: TakeoverState.Step) {
        guard !state.leaving, next.rawValue > state.step.rawValue else { return }
        state.geometry = controller.takeoverGeometry() ?? state.geometry
        withAnimation(Design.Motion.animation(.easeInOut(duration: 0.35))) { state.step = next }
        state.stepStarted = Date()
        switch next {
        case .summon:
            // A beat to read where it lives, then it opens itself.
            schedule(after: Design.Motion.reduced ? 0.6 : 1.6) { [weak self] in self?.summonNow() }
        case .agent:
            UserDefaults.standard.set(next.rawValue, forKey: Self.progressKey)
            refreshDetection()
        case .firstTask:
            UserDefaults.standard.set(next.rawValue, forKey: Self.progressKey)
            schedule(after: 0.8) { [weak self] in self?.runFirstTask() }
        case .drive:
            UserDefaults.standard.set(next.rawValue, forKey: Self.progressKey)
            schedule(after: 0.6) { [weak self] in self?.runDrive() }
        case .finale:
            if controller.ui.mode == .computerUse { controller.setMode(.chat) }
            schedule(after: 12) { [weak self] in self?.finish() }
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

    /// Types text a character at a time into a setter, then calls `done`.
    private func type(_ text: String, into set: @escaping (String) -> Void, done: @escaping () -> Void) {
        typing.forEach { $0.cancel() }
        typing.removeAll()
        if Design.Motion.reduced { set(text); done(); return }
        let chars = Array(text)
        for i in 0..<chars.count {
            let work = DispatchWorkItem { set(String(chars[0...i])) }
            typing.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.045 * Double(i + 1), execute: work)
        }
        let end = DispatchWorkItem(block: done)
        typing.append(end)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.045 * Double(chars.count + 1) + 0.2, execute: end)
    }
}

/// Everything the view can ask the guide to do.
struct TakeoverActions {
    var skip: () -> Void = {}
    var summon: () -> Void = {}
    var createAgent: () -> Void = {}
    var stopDrive: () -> Void = {}
    var finish: () -> Void = {}
}
