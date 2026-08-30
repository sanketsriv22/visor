import AppKit
import Combine
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
    case notes, chat, hud

    var id: String { rawValue }

    /// The two faces the switcher offers. HUD is entered from chat rather than
    /// picked from a list — it's the same conversation at another scale, not a
    /// third sibling.
    static var switchable: [VisorMode] { [.notes, .chat] }

    /// HUD covers the screen, so the window has to be resized for it rather
    /// than sharing the fixed union the other two live in.
    var isFullScreen: Bool { self == .hud }

    var title: String {
        switch self {
        case .notes: return "Notes"
        case .chat:  return "Chat"
        case .hud:   return "HUD"
        }
    }

    var symbol: String {
        switch self {
        // Not "checklist": the note is a note that happens to hold tasks, and
        // the generic checklist glyph read as clip-art next to the chat bubble.
        case .notes: return "note.text"
        case .chat:  return "bubble.left.and.bubble.right"
        case .hud:   return "rectangle.inset.filled.and.person.filled"
        }
    }
}

final class UIState: ObservableObject {
    @Published var expanded = false
    /// Restored on launch, so the notch reopens on whichever face you left it.
    @Published var mode: VisorMode = .notes
    @Published var notchSize = CGSize(width: 200, height: 32)
    /// The physical notch, without the forgiving click band added underneath
    /// it. Anything that has to line up with the hardware uses this — the
    /// collapsed hit rect is 8pt taller, and drawing to that height makes an
    /// extension that visibly overhangs the notch it's meant to continue.
    @Published var trueNotch = CGSize(width: 200, height: 32)
    /// True briefly while the card animates open. Rows pass under the cursor
    /// during the slide, so hover affordances are suppressed until it settles.
    @Published var settling = false
    /// True while dictation is recording or transcribing. Drives the listening
    /// pill beside the notch, independently of whether the card is open.
    @Published var listening = false
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

    /// Width of each shoulder in the top band, and the clearance kept around
    /// the physical notch.
    ///
    /// Fixed, deliberately. Deriving the shoulder from the card width meant
    /// every icon in the band slid sideways whenever the card changed size
    /// between modes — the band was anchored to the card's edges, and those
    /// edges move. Anchoring to the notch instead (which never moves) keeps
    /// the controls in one place. 106 is what the narrower card allows:
    /// 420 - (185 + 18) leaves 217 for two shoulders.
    static let shoulderWidth: CGFloat = 106
    static let notchClearance: CGFloat = 18

    /// How far the notch grows to the right while dictating. Wide enough for
    /// the level meter and a little breathing room, narrow enough that it
    /// still reads as the notch rather than a panel.
    static let listeningPillWidth: CGFloat = 66
    /// How far the extension reaches back under the notch strip.
    ///
    /// `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` are the *usable*
    /// menu-bar regions, and macOS insets them a few points from the physical
    /// notch so menu items don't touch it. The rect derived from them is
    /// therefore slightly wider than the hardware, which left the extension
    /// starting a few points clear of where the black actually ends — a thin
    /// gap that no amount of corner-rounding could close. Overlapping backwards
    /// is black drawn over black, so it's invisible and can't leave a seam
    /// regardless of how much padding a given machine uses.
    static let listeningPillOverlap: CGFloat = 12

    static func cardSize(for mode: VisorMode) -> CGSize {
        switch mode {
        case .notes: return CGSize(width: cardWidth, height: cardHeight)
        case .chat:  return CGSize(width: chatCardWidth, height: chatCardHeight)
        // The HUD is a separate window; the card underneath keeps its chat
        // size so returning from the HUD lands on a card that's already there,
        // rather than one animating up from nothing.
        case .hud:   return CGSize(width: chatCardWidth, height: chatCardHeight)
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
    /// The HUD gets its own window.
    ///
    /// Making the card's panel screen-sized fixed the transition — nothing
    /// resizes mid-flight — but a transparent panel at .statusBar level then
    /// lies across the *whole* menu bar, and the menu titles of whatever app
    /// is behind it flicker as macOS re-decides who owns that strip. Two
    /// windows keeps both properties: the card's panel stays card-width and
    /// off the menu bar, and the HUD's is created at full size and never
    /// resized.
    private var hudPanel: NotchPanel?
    private var screenObserver: Any?
    private var voiceObserver: AnyCancellable?
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

        registerNoteTools()
        registerShellTool()

        chat.isComposerVisible = { [weak ui] in
            guard let ui else { return false }
            return ui.expanded && ui.mode != .notes
        }

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
            guard let self else { return event }
            // Clicks land on the HUD's window while it's up, so the card's
            // panel never sees them. Catch the notch there too, or the notch
            // simply stops working in the HUD.
            if let hud = self.hudPanel, event.window === hud, self.ui.mode.isFullScreen {
                let inTopBand = event.locationInWindow.y >= hud.frame.height - self.ui.trueNotch.height
                let dxFromCentre = abs(event.locationInWindow.x - hud.frame.width / 2)
                if inTopBand && dxFromCentre <= self.ui.trueNotch.width / 2 {
                    self.setMode(.chat)
                    return nil
                }
                return event
            }
            guard event.window === self.panel else { return event }
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
            // In the HUD the click is our own window's, so the local monitor
            // has it; acting here as well would toggle twice.
            if self.ui.mode.isFullScreen { return }
            if self.ui.expanded {
                // Close when the notch is clicked. The very top of the notch
                // routes to the menu bar, so the local monitor never sees it —
                // this catches that strip up to the screen's top edge.
                if self.notchHitRect(on: screen).contains(loc) { self.toggle() }
            } else if self.collapsedHitTestRect(on: screen).contains(loc) {
                self.toggle()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .visorSystemPrompt, object: nil, queue: .main
        ) { [weak self] note in
            self?.suppressForSystemPrompt(note.userInfo?["showing"] as? Bool ?? false)
        }

        // Dictation grows the notch sideways even when the card is shut, so the
        // window has to be resized for it.
        voiceObserver = chat.voice.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                let listening = state.isBusy
                guard listening != self.ui.listening else { return }
                // Grow before showing, shrink after hiding — same reason as the
                // HUD: the window must never be smaller than what's animating
                // inside it.
                // Only the collapsed window changes size for the pill. While
                // the card is open it already covers this area and the pill
                // isn't drawn, so reframing did nothing except force a redraw
                // of the whole panel — which flashed the top of the card and
                // showed the desktop through it for a frame.
                // The extension is the indicator in both states — with the
                // card open there was previously no sign at all that the mic
                // was live. Only the *collapsed* window has to grow for it;
                // when the card is open the panel is already wide enough for
                // the notch plus the extension, so nothing resizes and nothing
                // can flash.
                // Tracked in both states: collapsed it drives the window
                // size, expanded it tells the note card's band to make room.
                let needsResize = !self.ui.expanded
                if listening && needsResize {
                    self.ui.listening = true
                    self.applyFrame(expanded: false)
                }
                // Set plainly, with no withAnimation. A global animation
                // transaction animates *every* view that changes as a result,
                // not just the one being shown — which is why starting
                // dictation flashed the whole card in chat mode and flickered
                // the task count in notes mode. The pill scopes its own
                // animation to this value instead.
                self.ui.listening = listening
                if !listening && needsResize {
                    // Long enough for the spring to settle. Shrinking the
                    // window while the extension is still retracting clips it
                    // mid-flight, which is what made closing feel abrupt where
                    // opening didn't.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
                        guard let self, !self.ui.listening, !self.ui.expanded else { return }
                        self.applyFrame(expanded: false)
                    }
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

    /// Give agents the note, since this is where the store lives.
    ///
    /// Registered here rather than inside ToolRegistry so the registry never
    /// has to reach for app state it doesn't own — whoever holds the state
    /// contributes the tool.
    private func registerNoteTools() {
        let store = self.store
        let registry = ToolRegistry.shared

        registry.register(ClosureTool(
            name: "list_tasks",
            toolDescription: "List the user's current tasks with their status (open, doing, blocked, done).",
            parameters: ["type": "object", "properties": [:], "additionalProperties": false]
        ) { _ in
            let items = store.items.filter(\.isTask)
            guard !items.isEmpty else { return "The note has no tasks." }
            return items.map { "- [\($0.status.marker)] \($0.text)" }.joined(separator: "\n")
        })

        registry.register(ClosureTool(
            name: "add_task",
            toolDescription: "Add a task to the user's note.",
            parameters: [
                "type": "object",
                "properties": ["text": ["type": "string", "description": "The task"]],
                "required": ["text"],
                "additionalProperties": false,
            ]
        ) { arguments in
            guard let text = (arguments["text"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return "No task text given."
            }
            _ = store.addTask(text)
            store.saveNow()
            return "Added: \(text)"
        })

        registry.register(ClosureTool(
            name: "complete_task",
            toolDescription: "Mark a task done. Matches on the task's text, case-insensitively.",
            parameters: [
                "type": "object",
                "properties": ["text": ["type": "string", "description": "Text of the task to complete"]],
                "required": ["text"],
                "additionalProperties": false,
            ]
        ) { arguments in
            guard let needle = (arguments["text"] as? String)?.lowercased(), !needle.isEmpty else {
                return "No task text given."
            }
            guard let match = store.items.first(where: {
                $0.isTask && !$0.done && $0.text.lowercased().contains(needle)
            }) else {
                return "No open task matching \"\(needle)\"."
            }
            store.toggleDone(match.id)
            store.saveNow()
            return "Completed: \(match.text)"
        })
    }

    /// Shell access for agents, gated on the user approving each run.
    ///
    /// Registered here because the working directory belongs to AIRunner. This
    /// is the first tool that can do something irreversible, which is why the
    /// approval gate had to exist before it did — `needsApproval` is what makes
    /// ChatController pause the turn and ask.
    private func registerShellTool() {
        let ai = self.ai
        registerDelegationTool()
        ToolRegistry.shared.register(ClosureTool(
            name: "run_shell",
            toolDescription: """
                Run a shell command in the user's project folder and return its \
                output. Use it to read files, search, or run builds and tests. \
                The user is asked before anything runs.
                """,
            parameters: [
                "type": "object",
                "properties": [
                    "command": ["type": "string", "description": "The command to run"],
                ],
                "required": ["command"],
                "additionalProperties": false,
            ],
            needsApproval: true
        ) { arguments in
            guard let command = (arguments["command"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
                return "No command given."
            }
            return await Self.runCommand(command, in: ai.workDirURL)
        })
    }

    /// Let one agent hand work to another.
    ///
    /// Deliberately general rather than a Claude-Code-shaped hole: it routes to
    /// whatever the user has configured, by name, so a fast conversational
    /// model can pass a repository task to a coding agent and keep talking —
    /// and the same mechanism works for any pair.
    ///
    /// Visor adds no arguments of its own. A delegated agent runs exactly as
    /// the user set it up, because widening another agent's permissions on
    /// someone's behalf isn't Visor's decision. Every delegation goes through
    /// the approval gate, showing which agent and what task.
    private func registerDelegationTool() {
        let ai = self.ai
        let client = OpenRouterClient()
        ToolRegistry.shared.register(ClosureTool(
            name: "ask_agent",
            toolDescription: """
                Hand a task to one of the user's other agents and return what it \
                says. Use it when another agent is better suited — a coding \
                agent for anything needing the repository, for instance. Call \
                list_agents first if you don't know what's available.
                """,
            parameters: [
                "type": "object",
                "properties": [
                    "agent": ["type": "string", "description": "Name of the agent to ask"],
                    "task": ["type": "string", "description": "What it should do, in one instruction"],
                ],
                "required": ["agent", "task"],
                "additionalProperties": false,
            ],
            needsApproval: true
        ) { arguments in
            guard let name = arguments["agent"] as? String,
                  let task = (arguments["task"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty else {
                return "Need both an agent name and a task."
            }
            guard let agent = ai.providers.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else {
                let known = ai.providers.map(\.name).joined(separator: ", ")
                return "No agent called \"\(name)\". Available: \(known)."
            }

            if agent.isChat {
                guard let reply = try? await client.complete(
                    messages: [ChatMessage(role: .user, content: task)],
                    model: agent.model ?? ChatController.defaultModel,
                    system: agent.systemPrompt)
                else { return "\(agent.name) couldn't be reached." }
                return reply
            }

            // A local CLI agent, run exactly as configured.
            let key = agent.apiKeyEnv.flatMap { env in
                Keychain.get(agent.keyAccount).map { (name: env, value: $0) }
            }
            var collected = ""
            for await event in CLIAgentRunner().run(
                command: agent.command, arguments: agent.args, prompt: task,
                directory: ai.workDirURL, environmentKey: key) {
                if case .text(let chunk) = event { collected += chunk }
            }
            let trimmed = collected.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "\(agent.name) produced no output." : trimmed
        })

        ToolRegistry.shared.register(ClosureTool(
            name: "list_agents",
            toolDescription: "List the user's other agents, so you know who you can hand work to.",
            parameters: ["type": "object", "properties": [:], "additionalProperties": false]
        ) { _ in
            let rows = ai.providers.map { agent -> String in
                let what = agent.isChat ? (agent.model ?? "model")
                                        : "local: \(agent.command)"
                return "- \(agent.name) (\(what))"
            }
            return rows.isEmpty ? "No agents configured." : rows.joined(separator: "\n")
        })
    }

    /// Execute one command, capped in both time and output.
    ///
    /// Both caps matter. A command that never returns would hang the turn
    /// indefinitely, and one that prints a gigabyte would exhaust the context
    /// window and the user's credit with it.
    private static func runCommand(_ command: String, in directory: URL) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/bin/zsh")
                task.arguments = ["-lc", command]
                task.currentDirectoryURL = directory

                // A GUI app inherits a bare PATH; give it the usual locations.
                var env = ProcessInfo.processInfo.environment
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:"
                    + (env["PATH"] ?? "")
                task.environment = env

                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = pipe

                do {
                    try task.run()
                } catch {
                    continuation.resume(returning: "Couldn't run it: \(error.localizedDescription)")
                    return
                }

                let deadline = DispatchWorkItem { if task.isRunning { task.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: deadline)

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                deadline.cancel()

                let output = String(data: data, encoding: .utf8) ?? ""
                let limit = 20_000
                let body = output.count > limit
                    ? String(output.prefix(limit)) + "\n[output truncated]"
                    : output
                continuation.resume(returning: body.isEmpty
                    ? "Exited \(task.terminationStatus) with no output."
                    : "Exited \(task.terminationStatus).\n\n\(body)")
            }
        }
    }

    func saveNow() { store.saveNow() }

    /// Step the panel below ordinary windows while a system dialog is up.
    ///
    /// The notch has to sit at `.statusBar` to draw over the menu bar, but that
    /// also puts it above permission prompts — so the dialog asking to use your
    /// microphone opens *behind* the app asking for it, which reads as the app
    /// having hung.
    func suppressForSystemPrompt(_ showing: Bool) {
        panel.level = showing ? .normal : .statusBar
    }

    /// Switch faces, animating the card between the two widths. No-op if we're
    /// already there, so a repeated ⌘1 doesn't restart the spring.
    func setMode(_ mode: VisorMode) {
        guard ui.mode != mode else { return }
        let leavingFullScreen = ui.mode.isFullScreen && !mode.isFullScreen
        UserDefaults.standard.set(mode.rawValue, forKey: modeKey)


        // The HUD travels the whole screen, so it gets a longer, softer spring
        // than the card morph — the same 0.42 curve over that distance reads
        // as a snap rather than an expansion. Collapsing is quicker than
        // opening, which is how things that fall back into place behave.
        let curve: Animation
        if mode.isFullScreen {
            curve = .spring(response: 0.55, dampingFraction: 0.78)
        } else if leavingFullScreen {
            curve = .spring(response: 0.42, dampingFraction: 0.86)
        } else {
            curve = .spring(response: 0.42, dampingFraction: 0.82)
        }
        // Neither window changes size here. The HUD has its own, built at
        // full screen and simply shown or hidden, so the transition is pure
        // SwiftUI on both sides.
        withAnimation(curve) { ui.mode = mode }
        if mode.isFullScreen { showHUD() } else { hideHUD() }
    }

    /// Start or stop dictating.
    ///
    /// Deliberately doesn't open the notch. Dictation is meant to be usable
    /// without looking at anything — the listening pill beside the notch is the
    /// whole feedback you need — and having a voice key throw a card over your
    /// work every time is exactly the interruption it exists to avoid. If the
    /// notch is already open it stays open, on whichever face you left it.
    func toggleDictation() { chat.toggleDictation() }

    /// Begin a hold-to-talk recording. Like `toggleDictation`, this never opens
    /// the notch.
    func beginDictation() { chat.voice.start() }

    /// End a hold-to-talk recording and transcribe it.
    func endDictation() { chat.voice.finish() }

    /// Show the HUD's window, built at full size before it is ever displayed.
    private func showHUD() {
        guard let screen = targetScreen else { return }
        if hudPanel == nil {
            let panel = NotchPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false)
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                        .stationary, .ignoresCycle]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isMovable = false
            panel.hidesOnDeactivate = false
            panel.contentView = FirstMouseHostingView(
                rootView: HUDRootView(chat: chat, store: store, ui: ui,
                                      onExit: { [weak self] in self?.setMode(.chat) }))
            hudPanel = panel
        }
        hudPanel?.setFrame(screen.frame, display: false)
        hudPanel?.makeKeyAndOrderFront(nil)
        // The card's window goes *after* the card has retracted into the notch,
        // not at the same moment. Ordering it out immediately cut the animation
        // off at frame one, which is why the switch felt abrupt however the
        // HUD side was tuned.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { [weak self] in
            guard let self, self.ui.mode.isFullScreen else { return }
            self.panel.orderOut(nil)
        }
    }

    /// Hide it once the collapse has finished, so it isn't cut off mid-flight.
    private func hideHUD() {
        guard ui.expanded else { return }
        // The card comes back first and takes key, so the composer is typeable
        // the moment the HUD starts shrinking rather than after it's gone.
        panel.makeKeyAndOrderFront(nil)
        // Long enough for the rails to leave and the centre to shrink back
        // into the notch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) { [weak self] in
            guard let self, !self.ui.mode.isFullScreen else { return }
            self.hudPanel?.orderOut(nil)
        }
    }

    /// Toggle the full-screen HUD. Entering from notes goes through chat,
    /// since the HUD is that conversation at another scale.
    func toggleHUD() {
        guard ui.expanded else { return }
        setMode(ui.mode.isFullScreen ? .chat : .hud)
    }

    /// Flip to the other face, only when the notch is already open.
    ///
    /// Deliberately a no-op when closed: ⌘⇧K is the key that opens the notch,
    /// and having a second one that also opens it makes the two shortcuts feel
    /// like the same key. Swapping a surface nobody is looking at isn't a swap.
    func swapMode() {
        guard ui.expanded else { return }
        // From the HUD, swapping means coming back down to the note.
        setMode(ui.mode == .notes ? .chat : .notes)
    }

    /// Select the nth agent and show the chat face — the notch's whole point
    /// is not having to go looking for a window first.
    func selectAgent(_ index: Int) {
        setMode(.chat)
        showNote()
        chat.useAgent(at: index)
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
        // From the HUD, the notch closes the HUD rather than the card
        // underneath it.
        //
        // Collapsing instead left the two out of step: the HUD's window stayed
        // up while ui.expanded went false, which silently disabled ⌘⇧M, ⌘⇧I and
        // the mode switcher — all of which guard on the notch being open — and
        // made the card panel take key focus back off the HUD.
        if ui.mode.isFullScreen {
            setMode(.chat)
            return
        }
        if ui.expanded {
            // Whatever the reason for collapsing, the HUD can't outlive it.
            if ui.mode.isFullScreen {
                ui.mode = .chat
                UserDefaults.standard.set(VisorMode.chat.rawValue, forKey: modeKey)
            }
            hudPanel?.orderOut(nil)
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

    private func applyFrame(expanded: Bool, mode: VisorMode? = nil) {
        guard let screen = targetScreen else { return }
        let notch = stripRect(on: screen)
        let mode = mode ?? ui.mode

        let frame: NSRect
        ui.trueNotch = notch.size
        if expanded {
            // Screen-sized for every open state, not just the HUD.
            //
            // Every flash chased in this file came from the window changing
            // size or origin while SwiftUI still held content laid out for the
            // old one. No ordering of those two events avoids it: the window
            // moves in AppKit, the content reflows in SwiftUI, and they run on
            // different clocks. Resizing first painted the old card at the new
            // size; swapping first painted new content at the old origin,
            // which is why the HUD appeared top-left; blanking between them
            // replaced both with the card vanishing.
            //
            // Sizing once, when the notch opens, removes the class of bug
            // rather than another instance of it — notes, chat and the HUD then
            // animate inside a window that never moves.
            //
            // Safe because transparent SwiftUI content doesn't hit-test, so
            // everything outside the card passes clicks through, and the panel
            // still shrinks to the notch strip on collapse.
            ui.notchSize = notch.size
            frame = screen.frame
        } else {
            let hit = collapsedHitRect(on: screen)
            ui.notchSize = hit.size
            // While dictating, the strip extends to the right of the notch for
            // the level meter.
            frame = ui.listening
                ? NSRect(x: hit.minX, y: hit.minY,
                         width: hit.width + Self.listeningPillWidth, height: hit.height)
                : hit
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
