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
    /// Seven moments, each paced by what the voice is saying.
    enum Step: Int, CaseIterable {
        case intro, notch, agent, task, hud, drive, finale
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
    /// Where the overlay accepts clicks (the one card, the chrome), in the
    /// overlay's top-left coordinates. Everywhere else passes through to the
    /// notch, the card and the scrim beneath.
    @Published var hitRects: [CGRect] = []
    /// The Design Lab's stand-in for `Spotlight`: control frames in the
    /// overlay's own top-left coordinates.
    @Published var spotlightOverride: [String: CGRect]? = nil

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

    /// Where the light is: the one thing on screen the moment is about, in
    /// screen coordinates. Nil lights the whole screen evenly.
    @Published var focus: CGRect? = nil
}

/// The sheet behind the tour: the Mac blurred, dimmed, and lit where it
/// matters. One radial gradient over the blur — dark everywhere except a
/// soft ellipse around the focus that glides between moments, so the eye
/// goes where the voice is pointing without being told.
final class ScrimView: NSView {
    private let blur = NSVisualEffectView()
    private let dim = CAGradientLayer()
    private var screenFrame: CGRect = .zero

    init(frame: NSRect, screen: CGRect) {
        screenFrame = screen
        super.init(frame: frame)
        wantsLayer = true
        blur.frame = bounds
        blur.autoresizingMask = [.width, .height]
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        // The blur takes the system appearance; in light mode over a light
        // wallpaper it went pale under white type. It is always dark here.
        blur.appearance = NSAppearance(named: .darkAqua)
        addSubview(blur)
        dim.type = .radial
        dim.frame = bounds
        dim.colors = [NSColor.black.withAlphaComponent(0.72).cgColor, NSColor.black.withAlphaComponent(0.72).cgColor,
                      NSColor.black.withAlphaComponent(0.72).cgColor]
        dim.locations = [0, 0.6, 1]
        dim.startPoint = CGPoint(x: 0.5, y: 0.5)
        dim.endPoint = CGPoint(x: 0.5, y: 0.5)
        layer?.addSublayer(dim)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dim.frame = bounds
        CATransaction.commit()
    }

    /// Light `rect` (screen coordinates), or the whole screen evenly.
    /// `inside`/`outside` are how dark it is under the light and away from it.
    /// The floor under the light is never lighter than 58% black: white type
    /// over a blurred white window needs at least that to read.
    func focus(_ rect: CGRect?, inside: CGFloat = 0.58, outside: CGFloat = 0.82, duration: TimeInterval = 0.8) {
        let inside = max(inside, 0.58)
        let outside = max(outside, inside + 0.15)
        let w = max(1, bounds.width), h = max(1, bounds.height)
        let colors: [CGColor]
        let start: CGPoint, end: CGPoint
        if let rect {
            let local = CGRect(x: rect.minX - screenFrame.minX, y: rect.minY - screenFrame.minY,
                               width: rect.width, height: rect.height)
            let rx = max(local.width * 0.9, 120), ry = max(local.height * 0.9, 90)
            start = CGPoint(x: local.midX / w, y: local.midY / h)
            end = CGPoint(x: (local.midX + rx) / w, y: (local.midY + ry) / h)
            colors = [NSColor.black.withAlphaComponent(inside).cgColor,
                      NSColor.black.withAlphaComponent((inside + outside) / 2).cgColor,
                      NSColor.black.withAlphaComponent(outside).cgColor]
        } else {
            start = CGPoint(x: 0.5, y: 0.5); end = CGPoint(x: 0.5, y: 0.5)
            colors = [NSColor.black.withAlphaComponent(outside).cgColor,
                      NSColor.black.withAlphaComponent(outside).cgColor,
                      NSColor.black.withAlphaComponent(outside).cgColor]
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(Design.Motion.reduced ? 0 : duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1))
        for (key, value) in [("colors", colors as Any), ("startPoint", NSValue(point: start)), ("endPoint", NSValue(point: end))] {
            let anim = CABasicAnimation(keyPath: key)
            anim.fromValue = dim.presentation()?.value(forKeyPath: key) ?? dim.value(forKeyPath: key)
            anim.toValue = value
            dim.add(anim, forKey: key)
            dim.setValue(value, forKeyPath: key)
        }
        CATransaction.commit()
    }
}

/// The introduction: Visor wakes up, and a voice walks you through it.
///
/// Two windows. A scrim — the Mac blurred and dimmed, lit where the moment
/// is — sits directly *beneath* the notch's window at the same level, so
/// the card, the switcher and the HUD draw over it exactly as themselves,
/// and nothing is cut out of anything. An overlay above the notch carries
/// the caption, the strokes, the one card and the chrome, and passes
/// clicks through wherever it draws nothing.
@MainActor
final class TakeoverGuide {
    let state: TakeoverState
    let controller: NotchController
    var onOpenSettings: (() -> Void)?
    var onFinish: (() -> Void)?

    static let progressKey = "visor.intro.progress"

    private var scrim: NSPanel?
    private var scrimView: ScrimView?
    private var panel: NSPanel?
    private var sinks = Set<AnyCancellable>()
    private var pending: DispatchWorkItem?
    private var typing: [DispatchWorkItem] = []
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

        let scrim = Self.makePanel(frame)
        let sheet = ScrimView(frame: NSRect(origin: .zero, size: frame.size), screen: frame)
        scrim.contentView = sheet
        scrim.alphaValue = 0
        scrim.orderFrontRegardless()
        controller.order(scrim, belowNotch: true)
        self.scrim = scrim
        self.scrimView = sheet
        // The intro's light: the middle of the screen, where the mark forms.
        let centre = CGRect(x: frame.midX - 260, y: frame.midY - 200, width: 520, height: 520)
        sheet.focus(centre, inside: 0.7, outside: 0.9, duration: 0)

        let panel = Self.makePanel(frame)
        let host = TakeoverHostingView(rootView: TakeoverView(
            state: state,
            actions: TakeoverActions(
                skip: { [weak self] in self?.finish() },
                videoEnded: { [weak self] in self?.videoEnded() },
                createAgent: { [weak self] in self?.createAgent() },
                stopDrive: { [weak self] in self?.stopDrive(byUser: true) },
                finish: { [weak self] in self?.finish() })))
        host.hitRects = { [weak state] in state?.hitRects ?? [] }
        panel.contentView = host
        panel.orderFrontRegardless()
        self.panel = panel

        detect()
        observe()
        Spotlight.shared.track(true)
        if controller.ui.expanded { controller.toggle() }
        state.stepStarted = Date()

        // The Mac dims first; nothing else moves until it has.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Design.Motion.reduced ? 0.3 : 1.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            scrim.animator().alphaValue = 1
        }

        if state.videoURL != nil { return }
        // The title sequence: the mark rises from the notch as the voice
        // introduces itself, then settles back in.
        schedule(after: 1.3) { [weak self] in
            guard let self else { return }
            self.narrator.play(.reveal)
            self.state.risen = true
            // The strands take two and a half seconds to become the knot;
            // the voice comes in as they settle.
            self.schedule(after: 1.8) { [weak self] in
                guard let self else { return }
                self.narrator.say(["intro.hi", "intro.notch"]) { [weak self] in
                    guard let self else { return }
                    // "…in the notch." — and it goes there.
                    self.state.risen = false
                    self.scrimView?.focus(self.state.geometry.notch.insetBy(dx: -60, dy: -40), inside: 0.58, outside: 0.86, duration: 1.0)
                    self.schedule(after: 1.2) { [weak self] in self?.advance(to: .notch) }
                }
            }
        }
    }

    private static func makePanel(_ frame: NSRect) -> NSPanel {
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
        panel.setFrame(frame, display: false)
        return panel
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
        Spotlight.shared.track(false)
        withAnimation(Design.Motion.animation(.easeInOut(duration: 0.7))) { state.leaving = true }
        if let scrim {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.7
                scrim.animator().alphaValue = 0
            }
        }
        scrimView = nil
        controller.chat.demoNextSend = false
        if ComputerUseAgent.shared.demonstrating { ComputerUseAgent.shared.stopDemo() }
        if controller.ui.mode == .computerUse || controller.ui.mode.isFullScreen { controller.setMode(.chat) }
        UserDefaults.standard.set(TakeoverState.Step.finale.rawValue, forKey: Self.progressKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            self.panel?.orderOut(nil)
            self.scrim?.orderOut(nil)
            self.panel = nil
            self.scrim = nil
            self.sinks.removeAll()
            self.onFinish?()
        }
    }

    // MARK: Notch

    private func runNotch() {
        narrator.say(["notch.press"]) { [weak self] in
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
        let lines: [Narration.Line]
        if let cli = state.cliFound {
            lines = [.init("agent.first"),
                     .init("agent.cli", text: "\(cli.name) is already on this Mac — one click. Or paste an OpenRouter key for any model."),
                     .init("agent.name")]
        } else {
            lines = [.init("agent.first"), .init("agent.key")]
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
        narrator.say([.init("agent.meet", text: "Nice to meet you, \(name).")]) { [weak self] in
            self?.advance(to: .task)
        }
    }

    // MARK: Task

    private func runTask() {
        let chat = controller.chat
        if controller.ui.mode != .chat { controller.setMode(.chat) }
        chat.draft = ""
        let standIn = state.standIn || chat.agent == nil
        chat.demoNextSend = standIn
        state.taskDone = false
        state.awaitingApproval = false
        narrator.say(["task.watch"]) { [weak self] in
            guard let self, self.state.step == .task else { return }
            self.type("What's the biggest file on my Desktop?", into: { chat.draft = $0 }) { [weak self] in
                guard let self, self.state.step == .task else { return }
                self.schedule(after: 0.5) { [weak self] in
                    guard let self, self.state.step == .task else { return }
                    self.sent = true
                    self.controller.chat.send()
                    if !standIn { self.armTaskTimeout() }
                }
            }
        }
    }

    /// The tour has sent its question (the real agent's or the stand-in's).
    private var sent = false

    private func armTaskTimeout() {
        taskTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state.step == .task, !self.state.taskDone,
                  !self.state.awaitingApproval else { return }
            self.fallBackToStandIn("No reply after thirty seconds.")
        }
        taskTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    /// The real agent failed — no key, no credit, no network, whatever it
    /// was — so the stand-in takes the same question. Always. The tour never
    /// waits on something that isn't coming.
    private func fallBackToStandIn(_ reason: String) {
        guard state.step == .task, !state.taskDone, !state.standIn else { return }
        taskTimeout?.cancel()
        pending?.cancel()
        typing.forEach { $0.cancel() }
        controller.chat.stop()
        controller.chat.dropPending()
        state.standIn = true
        state.awaitingApproval = false
        narrator.say(["task.fail", "task.standin"]) { [weak self] in
            self?.narrator.detail = nil
            self?.runTask()
        }
        narrator.detail = reason
    }

    // MARK: HUD

    /// The whole picture: the HUD opens on the same key, stays long enough
    /// to be seen, and folds back.
    private func runHUD() {
        narrator.say(["hud.bigger"]) { [weak self] in
            guard let self, self.state.step == .hud else { return }
            if !self.controller.ui.expanded { self.controller.toggle() }
            if self.controller.ui.mode != .chat { self.controller.setMode(.chat) }
            self.controller.toggleHUD()
            self.narrator.play(.reveal)
            self.narrator.say(["hud.expand"]) { [weak self] in
                guard let self, self.state.step == .hud else { return }
                self.schedule(after: 2.5) { [weak self] in
                    guard let self, self.state.step == .hud else { return }
                    if self.controller.ui.mode.isFullScreen { self.controller.toggleHUD() }
                    self.narrator.say(["hud.back"]) { [weak self] in
                        self?.schedule(after: 0.6) { [weak self] in self?.advance(to: .drive) }
                    }
                }
            }
        }
    }

    // MARK: Drive

    private func runDrive() {
        state.askStop = false
        state.driveStopped = false
        state.driveDone = false
        let agent = ComputerUseAgent.shared
        agent.draft = ""
        narrator.say(["drive.face"]) { [weak self] in
            guard let self, self.state.step == .drive else { return }
            self.controller.setMode(.computerUse)
            self.narrator.say(["drive.tell", "drive.steps"]) { [weak self] in
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
                        self.narrator.say(["drive.stop"]) { [weak self] in
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
        narrator.say([byUser ? "drive.stopped" : "drive.auto"]) { [weak self] in
            self?.advance(to: .finale)
        }
    }

    // MARK: Finale

    private func runFinale() {
        if controller.ui.mode == .computerUse { controller.setMode(.chat) }
        narrator.say(["finale.that", "finale.back", "finale.go"]) { [weak self] in
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
        chat.$error.receive(on: DispatchQueue.main)
            .sink { [weak self] e in self?.errorChanged(e) }.store(in: &sinks)
        ComputerUseAgent.shared.$demonstrating.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] on in self?.demoChanged(on) }.store(in: &sinks)
        CLIAccounts.shared.objectWillChange.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refreshDetection() } }.store(in: &sinks)
        Spotlight.shared.$frames.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshFocus() }.store(in: &sinks)
        state.$awaitingApproval.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshFocus() }.store(in: &sinks)
        state.$askStop.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshFocus() }.store(in: &sinks)
        state.$created.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshFocus() }.store(in: &sinks)
        // Whenever the notch's window comes forward (a click in the card makes
        // it key), the overlay goes back above it and the scrim back beneath.
        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reorder() }.store(in: &sinks)
    }

    private func reorder() {
        guard let panel, let scrim else { return }
        controller.order(scrim, belowNotch: true)
        panel.orderFrontRegardless()
    }

    /// Where the light goes for this moment: the notch, the card, the one
    /// control to press. Called whenever any of those changes.
    private func refreshFocus() {
        guard let scrimView, let screen = controller.takeoverFrame() else { return }
        let g = state.geometry
        let frames = Spotlight.shared.frames
        var rect: CGRect? = nil
        var inside: CGFloat = 0.58, outside: CGFloat = 0.82
        switch state.step {
        case .intro:
            rect = CGRect(x: screen.midX - 260, y: screen.midY - 200, width: 520, height: 520)
            inside = 0.7; outside = 0.9
        case .notch:
            rect = g.expanded ? g.card.insetBy(dx: -30, dy: -30) : g.notch.insetBy(dx: -60, dy: -40)
        case .agent:
            rect = state.created ? g.card.insetBy(dx: -30, dy: -30) : nil
            outside = 0.82
        case .task:
            rect = state.awaitingApproval ? frames["allow"]?.insetBy(dx: -50, dy: -36) ?? g.card : g.card.insetBy(dx: -30, dy: -30)
        case .hud:
            rect = nil; outside = 0.6
        case .drive:
            rect = state.askStop ? frames["stop"]?.insetBy(dx: -46, dy: -46) ?? g.card : g.card.insetBy(dx: -30, dy: -30)
        case .finale:
            rect = nil; outside = 0.8
        }
        if state.focus != rect { state.focus = rect }
        scrimView.focus(rect, inside: inside, outside: outside)
    }

    private func refreshGeometry() {
        state.geometry = controller.takeoverGeometry() ?? state.geometry
        DispatchQueue.main.async { [weak self] in self?.reorder(); self?.refreshFocus() }
    }

    private func expandedChanged(_ expanded: Bool) {
        var geo = controller.takeoverGeometry() ?? state.geometry
        geo.expanded = expanded
        state.geometry = geo
        DispatchQueue.main.async { [weak self] in self?.reorder(); self?.refreshFocus() }
        if state.step == .notch, expanded {
            if controller.ui.mode != .chat { controller.setMode(.chat) }
            narrator.play(.success)
            state.bursts += 1; state.lastBurst = Date()
            narrator.say(["notch.card"]) { [weak self] in
                self?.advance(to: .agent)
            }
        }
    }

    private func approvalChanged(_ pending: Bool) {
        guard state.step == .task, !state.taskDone else { return }
        state.awaitingApproval = pending
        if pending {
            taskTimeout?.cancel()
            state.bursts += 1; state.lastBurst = Date()
            narrator.say(["task.asking", "task.allow"]) {}
        } else if sent, !state.standIn {
            // The real agent is running its tool and asking again; give it
            // its thirty seconds anew.
            armTaskTimeout()
        }
    }

    private func errorChanged(_ error: String?) {
        guard state.step == .task, sent, !state.taskDone, let error, !error.isEmpty else { return }
        fallBackToStandIn(error)
    }

    private func streamingChanged(_ streaming: Bool) {
        guard state.step == .task, sent, !state.taskDone, !streaming, !state.awaitingApproval else { return }
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
                UserDefaults.standard.set(TakeoverState.Step.hud.rawValue, forKey: Self.progressKey)
                self.narrator.say(["task.answer"]) { [weak self] in
                    self?.schedule(after: 1.2) { [weak self] in self?.advance(to: .hud) }
                }
            } else if !self.state.standIn {
                self.fallBackToStandIn(self.controller.chat.error ?? "It didn't answer.")
            }
        }
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
            narrator.say(["drive.done"]) { [weak self] in
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
        refreshFocus()
        switch next {
        case .notch:  schedule(after: 0.6) { [weak self] in self?.runNotch() }
        case .agent:
            UserDefaults.standard.set(next.rawValue, forKey: Self.progressKey)
            refreshDetection()
            schedule(after: 0.5) { [weak self] in self?.runAgent() }
        case .task:
            UserDefaults.standard.set(next.rawValue, forKey: Self.progressKey)
            sent = false
            // A clean transcript: the first task is the first thing in it.
            controller.chat.newChat()
            schedule(after: 0.5) { [weak self] in self?.runTask() }
        case .hud:
            UserDefaults.standard.set(next.rawValue, forKey: Self.progressKey)
            schedule(after: 0.5) { [weak self] in self?.runHUD() }
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

/// The overlay's hosting view: it owns a click only inside the rects the
/// view reports (the tour card, the chrome). Everywhere else the click
/// falls through to the window beneath — the notch, the card, the scrim —
/// so the product stays fully usable under the tour.
final class TakeoverHostingView<Content: View>: NSHostingView<Content> {
    var hitRects: () -> [CGRect] = { [] }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let y = isFlipped ? local.y : bounds.height - local.y
        let p = CGPoint(x: local.x, y: y)
        guard hitRects().contains(where: { $0.insetBy(dx: -4, dy: -4).contains(p) }) else { return nil }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Everything the view can ask the guide to do.
struct TakeoverActions {
    var skip: () -> Void = {}
    var videoEnded: () -> Void = {}
    var createAgent: () -> Void = {}
    var stopDrive: () -> Void = {}
    var finish: () -> Void = {}
}
