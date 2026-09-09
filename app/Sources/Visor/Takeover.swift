import AppKit
import AVFoundation
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
    /// Six moments, each paced by what the voice is saying.
    enum Step: Int, CaseIterable {
        case intro, notch, agent, task, drive, finale
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

    @Published var step: Step = .intro
    @Published var geometry: Geometry
    @Published var bursts = 0
    @Published var lastBurst = Date.distantPast
    @Published var leaving = false
    @Published var stepStarted = Date()
    @Published var milestone: String? = nil
    /// 0…1 along the whole tour, for the thin bar at the bottom.
    @Published var progress: Double = 0
    /// The welcome video, when one is bundled; the title sequence otherwise.
    let videoURL: URL?
    /// The mark has risen from the notch (title sequence).
    @Published var risen = false

    /// Agent form.
    @Published var agentName = "Claude"
    @Published var connection: Connection = .openRouter
    @Published var keyInput = ""
    @Published var hasKey = false
    @Published var cliFound: (name: String, command: String, detail: String)? = nil
    @Published var creating = false
    @Published var created = false
    @Published var formError: String? = nil
    /// The form is shown (after the voice has asked for it).
    @Published var formVisible = false

    /// Task.
    @Published var awaitingApproval = false
    @Published var taskDone = false
    @Published var standIn = false

    /// Drive.
    @Published var askStop = false
    @Published var driveStopped = false
    @Published var driveDone = false
    /// The finale's cheat sheet is shown (after the voice has said goodbye).
    @Published var sheetVisible = false

    let narrator: Narrator

    init(geometry: Geometry, step: Step = .intro, narrator: Narrator? = nil, videoURL: URL? = nil) {
        self.geometry = geometry
        self.step = step
        self.narrator = narrator ?? Narrator()
        self.videoURL = videoURL
    }

    var canCreate: Bool {
        let name = agentName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !creating else { return false }
        switch connection {
        case .cli:        return cliFound != nil
        case .openRouter: return hasKey || !keyInput.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
}

/// The introduction: Visor wakes up, and a voice walks you through it.
///
/// Built on what a good one actually does — HeyClicky's, opened up: a
/// welcome video if the founder has recorded one, then a narrated,
/// hands-on tour where the voice says what is about to happen while the
/// product does it, a quiet cue marks each moment, and the only things
/// asked of you are your agent's name, its connection, one Allow and, if
/// you like, one Stop. Everything else the tour does itself, on the real
/// surfaces, at the speed of speech.
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
    private var narrator: Narrator { state.narrator }

    init?(controller: NotchController) {
        guard let geo = controller.takeoverGeometry() else { return nil }
        self.controller = controller
        let video = Bundle.main.resourceURL?.appendingPathComponent("intro.mp4")
        self.state = TakeoverState(geometry: geo, narrator: Narrator(),
                                   videoURL: video.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
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
                summon: { [weak self] in self?.summon() },
                videoEnded: { [weak self] in self?.videoEnded() },
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

        if state.videoURL != nil {
            // The welcome video plays; the tour begins when it ends.
            return
        }
        // The title sequence: the mark rises from the notch as the voice
        // introduces itself, then settles back in.
        schedule(after: 0.9) { [weak self] in
            guard let self else { return }
            self.narrator.play(.reveal)
            withAnimation(Design.Motion.animation(.spring(response: 0.9, dampingFraction: 0.78))) { self.state.risen = true }
            self.narrator.say(["Hi. I'm Visor.", "I live up here, in the notch."]) { [weak self] in
                guard let self else { return }
                withAnimation(Design.Motion.animation(Design.Motion.hud)) { self.state.risen = false }
                self.schedule(after: 0.9) { [weak self] in self?.advance(to: .notch) }
            }
        }
    }

    /// The notch was clicked while the scrim covers it.
    private func summon() {
        guard state.step == .notch, !controller.ui.expanded else { return }
        controller.toggle()
    }

    private func videoEnded() {
        guard state.step == .intro else { return }
        advance(to: .notch)
    }

    func finish() {
        guard !state.leaving else { return }
        pending?.cancel()
        taskTimeout?.cancel()
        typing.forEach { $0.cancel() }
        narrator.stop()
        withAnimation(Design.Motion.animation(.easeInOut(duration: 0.7))) { state.leaving = true }
        controller.chat.demoNextSend = false
        if ComputerUseAgent.shared.demonstrating { ComputerUseAgent.shared.stopDemo() }
        if controller.ui.mode == .computerUse { controller.setMode(.chat) }
        UserDefaults.standard.set(TakeoverState.Step.finale.rawValue, forKey: Self.progressKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            self.panel?.orderOut(nil)
            self.panel = nil
            self.sinks.removeAll()
            self.onFinish?()
        }
    }

    // MARK: Notch

    private func runNotch() {
        narrator.say(["Press control, command, K — and I'm there, over anything you're doing."]) { [weak self] in
            guard let self, self.state.step == .notch else { return }
            if !self.controller.ui.expanded { self.controller.toggle() }
        }
    }

    // MARK: Agent

    private func detect() {
        state.hasKey = OpenRouterClient.hasKey
        let clis = controller.chat.chatAgents.filter(\.isNotchCLI)
        CLIAccounts.shared.refreshAll(clis)
        refreshDetection()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refreshDetection() }
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

    private func runAgent() {
        let lines: [String]
        if let cli = state.cliFound {
            lines = ["First, let's make you an agent.",
                     "\(cli.name) is already on this Mac — one click. Or paste an OpenRouter key for any model.",
                     "Give it a name."]
        } else {
            lines = ["First, let's make you an agent.",
                     "It talks to any model through OpenRouter. Paste a key, give it a name, and it's yours."]
        }
        narrator.say(lines) { [weak self] in
            guard let self, self.state.step == .agent else { return }
            withAnimation(Design.Motion.animation(Design.Motion.surface)) { self.state.formVisible = true }
        }
        // Don't wait for the whole speech before showing the form.
        schedule(after: 2.4) { [weak self] in
            guard let self, self.state.step == .agent else { return }
            withAnimation(Design.Motion.animation(Design.Motion.surface)) { self.state.formVisible = true }
        }
    }

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
        controller.ai.upsert(provider)
        if let agent = controller.chat.chatAgents.first(where: { $0.name == name }) {
            controller.chat.use(agent)
        }
        state.creating = false
        state.standIn = false
        narrator.stop()
        withAnimation(Design.Motion.animation(Design.Motion.surface)) {
            state.created = true
            state.formVisible = false
        }
        NSApp.deactivate()
        narrator.play(.success)
        state.bursts += 1; state.lastBurst = Date()
        narrator.say(["Nice to meet you, \(name)."]) { [weak self] in
            self?.advance(to: .task)
        }
    }

    // MARK: Task

    private func runTask() {
        let chat = controller.chat
        if controller.ui.mode != .chat { controller.setMode(.chat) }
        chat.draft = ""
        chat.demoNextSend = state.standIn || chat.agent == nil
        sentInTask = false
        state.taskDone = false
        state.awaitingApproval = false
        narrator.say(["Now watch. I'll ask it something for you."]) { [weak self] in
            guard let self, self.state.step == .task else { return }
            self.type("What's the biggest file on my Desktop?", into: { chat.draft = $0 }) { [weak self] in
                guard let self, self.state.step == .task else { return }
                self.schedule(after: 0.5) { [weak self] in
                    guard let self, self.state.step == .task else { return }
                    self.narrator.play(.beat)
                    self.controller.chat.send()
                }
            }
        }
    }

    private func fallBackToStandIn(_ reason: String) {
        guard state.step == .task, !state.taskDone, !state.standIn else { return }
        taskTimeout?.cancel()
        controller.chat.stop()
        state.standIn = true
        narrator.say(["Your agent couldn't answer — \(reason)",
                      "So I'll show you the shape of it with a stand-in."]) { [weak self] in
            self?.runTask()
        }
    }

    // MARK: Drive

    private func runDrive() {
        state.askStop = false
        state.driveStopped = false
        state.driveDone = false
        let agent = ComputerUseAgent.shared
        agent.draft = ""
        narrator.say(["There's a third face. Computer Use."]) { [weak self] in
            guard let self, self.state.step == .drive else { return }
            self.controller.setMode(.computerUse)
            self.narrator.play(.beat)
            self.narrator.say(["Tell it what you want done, and it drives — reading the screen, clicking, typing.",
                               "Watch the steps come in."]) { [weak self] in
                guard let self, self.state.step == .drive else { return }
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
                    ], final: "Done — Night Shift is on, sunset to sunrise.", every: 1.5)
                    self.schedule(after: 4.2) { [weak self] in
                        guard let self, self.state.step == .drive, agent.demonstrating else { return }
                        withAnimation(Design.Motion.animation(Design.Motion.standard)) { self.state.askStop = true }
                        self.narrator.say(["You can stop it any time. Try it — press Stop."]) { [weak self] in
                            guard let self, self.state.step == .drive, agent.demonstrating else { return }
                            self.schedule(after: 4.0) { [weak self] in
                                guard let self, self.state.step == .drive, agent.demonstrating else { return }
                                self.stopDrive(byUser: false)
                            }
                        }
                    }
                }
            }
        }
    }

    private func stopDrive(byUser: Bool) {
        guard state.step == .drive, ComputerUseAgent.shared.demonstrating else { return }
        pending?.cancel()
        narrator.stop()
        ComputerUseAgent.shared.stopDemo()
        narrator.play(.stop)
        withAnimation(Design.Motion.animation(Design.Motion.standard)) {
            state.askStop = false
            state.driveStopped = true
        }
        state.bursts += 1; state.lastBurst = Date()
        UserDefaults.standard.set(TakeoverState.Step.finale.rawValue, forKey: Self.progressKey)
        narrator.say([byUser ? "Stopped, between actions. Nothing else happens. You're always the one in charge."
                             : "I'll do it. Stopped, between actions — nothing else happens. That's always your call."]) { [weak self] in
            self?.advance(to: .finale)
        }
    }

    // MARK: Finale

    private func runFinale() {
        if controller.ui.mode == .computerUse { controller.setMode(.chat) }
        narrator.say(["That's Visor.", "Control, command, K brings me back — anywhere, any time.", "Go make something."]) { [weak self] in
            guard let self else { return }
            withAnimation(Design.Motion.animation(Design.Motion.surface)) { self.state.sheetVisible = true }
            self.schedule(after: 12) { [weak self] in self?.finish() }
        }
        schedule(after: 3.5) { [weak self] in
            guard let self, self.state.step == .finale else { return }
            withAnimation(Design.Motion.animation(Design.Motion.surface)) { self.state.sheetVisible = true }
        }
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
        if state.step == .notch, expanded {
            if controller.ui.mode != .chat { controller.setMode(.chat) }
            narrator.play(.success)
            state.bursts += 1; state.lastBurst = Date()
            narrator.say(["That's the card. Chat, notes, and the agent you're about to make."]) { [weak self] in
                self?.advance(to: .agent)
            }
        }
    }

    private func approvalChanged(_ pending: Bool) {
        guard state.step == .task else { return }
        state.awaitingApproval = pending
        if pending {
            taskTimeout?.cancel()
            narrator.play(.beat)
            state.bursts += 1; state.lastBurst = Date()
            narrator.say(["It's asking before it touches your Mac.", "That's always your call. Press Allow."]) {}
        }
    }

    private func errorChanged(_ error: String?) {
        guard state.step == .task, !state.taskDone, let error, !error.isEmpty else { return }
        fallBackToStandIn(error)
    }

    private func streamingChanged(_ streaming: Bool) {
        guard state.step == .task, sentInTask, !state.taskDone else { return }
        if !streaming, !state.awaitingApproval {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, self.state.step == .task, !self.state.taskDone,
                      !self.state.awaitingApproval, !self.controller.chat.isStreaming else { return }
                let last = self.controller.chat.conversation.messages.last
                if last?.role == .assistant, !(last?.content.isEmpty ?? true) {
                    self.taskTimeout?.cancel()
                    self.state.taskDone = true
                    self.narrator.play(.success)
                    self.state.bursts += 1; self.state.lastBurst = Date()
                    self.celebrateMilestone("First task, done")
                    UserDefaults.standard.set(TakeoverState.Step.drive.rawValue, forKey: Self.progressKey)
                    self.narrator.say(["And there's your first answer."]) { [weak self] in
                        self?.schedule(after: 1.2) { [weak self] in self?.advance(to: .drive) }
                    }
                } else if !self.state.standIn {
                    self.fallBackToStandIn(self.controller.chat.error ?? "it didn't answer.")
                }
            }
        }
    }

    private func messagesChanged() {
        guard state.step == .task, controller.chat.conversation.messages.last?.role == .user else { return }
        sentInTask = true
        taskTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state.step == .task, !self.state.taskDone,
                  !self.state.awaitingApproval else { return }
            self.fallBackToStandIn("no reply after thirty seconds.")
        }
        taskTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    private func demoChanged(_ demonstrating: Bool) {
        guard state.step == .drive, !demonstrating, !state.driveStopped else { return }
        if ComputerUseAgent.shared.status.hasPrefix("Done") {
            pending?.cancel()
            withAnimation(Design.Motion.animation(Design.Motion.standard)) { state.driveDone = true }
            narrator.play(.success)
            state.bursts += 1; state.lastBurst = Date()
            celebrateMilestone("It drove your Mac")
            UserDefaults.standard.set(TakeoverState.Step.finale.rawValue, forKey: Self.progressKey)
            narrator.say(["Done. A real run asks for Accessibility first, then does exactly that."]) { [weak self] in
                self?.advance(to: .finale)
            }
        }
    }

    // MARK: Advancing

    private func celebrateMilestone(_ text: String) {
        withAnimation(Design.Motion.animation(Design.Motion.surface)) { state.milestone = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + (Design.Motion.reduced ? 0.8 : 2.0)) { [weak self] in
            withAnimation(Design.Motion.animation(Design.Motion.standard)) { self?.state.milestone = nil }
        }
    }

    private func advance(to next: TakeoverState.Step) {
        guard !state.leaving, next.rawValue > state.step.rawValue else { return }
        state.geometry = controller.takeoverGeometry() ?? state.geometry
        withAnimation(Design.Motion.animation(.easeInOut(duration: 0.4))) {
            state.step = next
            state.progress = Double(next.rawValue) / Double(TakeoverState.Step.finale.rawValue)
        }
        state.stepStarted = Date()
        narrator.play(.beat)
        switch next {
        case .notch:  schedule(after: 0.6) { [weak self] in self?.runNotch() }
        case .agent:
            UserDefaults.standard.set(next.rawValue, forKey: Self.progressKey)
            refreshDetection()
            schedule(after: 0.5) { [weak self] in self?.runAgent() }
        case .task:
            UserDefaults.standard.set(next.rawValue, forKey: Self.progressKey)
            schedule(after: 0.5) { [weak self] in self?.runTask() }
        case .drive:
            UserDefaults.standard.set(next.rawValue, forKey: Self.progressKey)
            schedule(after: 0.5) { [weak self] in self?.runDrive() }
        case .finale:
            schedule(after: 0.4) { [weak self] in self?.runFinale() }
        default: break
        }
    }

    private func schedule(after seconds: TimeInterval, _ block: @escaping () -> Void) {
        pending?.cancel()
        let work = DispatchWorkItem(block: block)
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func type(_ text: String, into set: @escaping (String) -> Void, done: @escaping () -> Void) {
        typing.forEach { $0.cancel() }
        typing.removeAll()
        if Design.Motion.reduced { set(text); done(); return }
        let chars = Array(text)
        for i in 0..<chars.count {
            let work = DispatchWorkItem { set(String(chars[0...i])) }
            typing.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(i + 1), execute: work)
        }
        let end = DispatchWorkItem(block: done)
        typing.append(end)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(chars.count + 1) + 0.25, execute: end)
    }
}

/// Everything the view can ask the guide to do.
struct TakeoverActions {
    var skip: () -> Void = {}
    var summon: () -> Void = {}
    var videoEnded: () -> Void = {}
    var createAgent: () -> Void = {}
    var stopDrive: () -> Void = {}
    var finish: () -> Void = {}
}
