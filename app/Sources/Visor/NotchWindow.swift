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
    case notes, chat, hud, computerUse

    var id: String { rawValue }

    /// The faces the ⌘⌃ swap key cycles through — notes and chat only. HUD is
    /// entered from chat, and Computer Use runs a task, so neither belongs in a
    /// blind keyboard cycle.
    static var switchable: [VisorMode] { [.notes, .chat] }

    /// The faces the on-screen switcher offers as clickable icons. Computer Use
    /// is here — you can click straight to it — but it's deliberately not in
    /// `switchable`, so the swap key still only flips notes/chat.
    static var pickable: [VisorMode] { [.notes, .chat, .computerUse] }

    /// HUD covers the screen, so the window has to be resized for it rather
    /// than sharing the fixed union the other two live in.
    var isFullScreen: Bool { self == .hud }

    var title: String {
        switch self {
        case .notes:       return "Notes"
        case .chat:        return "Chat"
        case .hud:         return "HUD"
        case .computerUse: return "Computer Use"
        }
    }

    var symbol: String {
        switch self {
        // Not "checklist": the note is a note that happens to hold tasks, and
        // the generic checklist glyph read as clip-art next to the chat bubble.
        case .notes:       return "note.text"
        case .chat:        return "bubble.left.and.bubble.right"
        case .hud:         return "rectangle.inset.filled.and.person.filled"
        case .computerUse: return "cursorarrow.rays"
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
    static let chatCardHeight: CGFloat = 372
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
    static let listeningPillWidth: CGFloat = 96
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
        // Computer Use: a wide card — narrower than chat — with a task field, a
        // status line, and a readable, copyable step log. Stays inside the
        // window union so nothing resizes.
        case .computerUse: return CGSize(width: 516, height: 232)
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
    /// Watches for clicks on the notch while the HUD is covering it.
    private var hudClickMonitor: Any?
    private let modeKey = "visor.mode"
    /// Whether the notch was showing the HUD when it was last put away, so
    /// reopening returns you to where you were rather than one level below it.
    private let hudResumeKey = "visor.resumeHUD"
    /// When set, the primary macro opens the HUD directly rather than the notch
    /// card. A Settings switch, off by default. Read live from UserDefaults so
    /// the toggle takes effect on the next keypress without any wiring.
    private let hudOnlyKey = "visor.hudOnlyMode"
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
    /// Pending show/hide of the two windows. Cancelled on every mode change:
    /// switching quickly used to leave a stale timer from the previous switch
    /// still due, which then ordered a window away mid-animation.
    private var panelWork: DispatchWorkItem?
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
        // Left at the default (false) deliberately.
        //
        // Set true, AppKit only hands the panel key status when the clicked
        // view answers `needsPanelToBecomeKey`. An NSHostingView doesn't — it
        // has no idea what SwiftUI put under the cursor — so once the panel
        // lost key to another app, clicking the composer never got it back.
        // The caret went nowhere and the field looked dead, for every agent,
        // because it has nothing to do with agents.
        //
        // It reads like the cautious setting and isn't: the panel is
        // nonactivating, so becoming key doesn't activate Visor or disturb the
        // app in front. It just means a click in a text field lands in it.
        panel.becomesKeyOnlyIfNeeded = false

        registerNoteTools()
        registerShellTool()
        CLIAccounts.shared.refreshAll(ai.providers)

        chat.isComposerVisible = { [weak self] in
            guard let self else { return false }
            // Focused, not merely open. A visible composer you aren't typing
            // in is not where dictation belongs — you're working somewhere
            // else, and that's where the words should land.
            return self.ui.expanded && self.ui.mode != .notes
                && (self.panel.isKeyWindow || self.hudPanel?.isKeyWindow == true)
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
                    // opening didn't. Raised with the slower collapse curve —
                    // this delay has to outlast the animation, not match it.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { [weak self] in
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
        withAnimation(Design.Motion.animation(curve)) { ui.mode = mode }
        if mode.isFullScreen { showHUD() } else { hideHUD() }
    }

    /// Bring up the Computer Use face and leave it up. It stays visible for the
    /// whole task — the agent drives other apps while this card reports each
    /// step — until you close it or switch faces.
    ///
    /// This expands straight into the computer-use card rather than going
    /// through `toggle()`, deliberately: in HUD-only mode `toggle()` resumes
    /// into the HUD, which is why Computer Use wasn't appearing there.
    func openComputerUse() {
        UserDefaults.standard.set(VisorMode.computerUse.rawValue, forKey: modeKey)
        if ui.expanded {
            setMode(.computerUse)
            return
        }
        applyFrame(expanded: true)
        ui.settling = true
        withAnimation(Design.Motion.animation(.spring(response: 0.34, dampingFraction: 0.95))) {
            ui.mode = .computerUse
            ui.expanded = true
        }
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.ui.settling = false
        }
    }

    /// Menu-bar entry point.
    ///
    /// - If Computer Use is already the notch face, put it away.
    /// - If the dynamic island is up, put it away.
    /// - If some *other* interface is already open (a card face or the HUD),
    ///   don't clobber it — run Computer Use as a dynamic island alongside it.
    /// - Otherwise (nothing open, HUD-only mode included) bring it up as the
    ///   notch face.
    func toggleComputerUse() {
        // While a task is running the card is display-only (it can't swallow the
        // agent's input), so the menu-bar entry is how you stop it.
        if ComputerUseAgent.shared.running { ComputerUseAgent.shared.stop(); return }
        if ComputerUseUI.shared.isVisible { ComputerUseUI.shared.hide(); return }
        if ui.expanded && ui.mode == .computerUse { toggle(); return }
        if ui.expanded { ComputerUseUI.shared.show(); return }
        openComputerUse()
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
                rootView: HUDRootView(
                    chat: chat, store: store, ui: ui,
                    onExit: { [weak self] in self?.exitHUD() },
                    onClose: { [weak self] in self?.toggle() }))
            hudPanel = panel
            watchForNotchClicks()
        }
        hudPanel?.setFrame(screen.frame, display: false)
        hudPanel?.makeKeyAndOrderFront(nil)
        // The card's window goes *after* the card has retracted into the notch,
        // not at the same moment. Ordering it out immediately cut the animation
        // off at frame one, which is why the switch felt abrupt however the
        // HUD side was tuned.
        panelWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.ui.mode.isFullScreen else { return }
            self.panel.orderOut(nil)
        }
        panelWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42, execute: work)
    }

    /// Catch clicks on the notch while the HUD is up.
    ///
    /// Done in AppKit rather than SwiftUI because SwiftUI wasn't winning the
    /// click. A transparent hit target over the notch, however it was layered,
    /// competed with a full-screen glass panel and the HUD's own gestures, and
    /// lost — leaving the notch either inert or falling through to the
    /// collapse button's behaviour, which drops you onto the chat card.
    ///
    /// A window-level monitor has no such competition: it sees the event
    /// before any view does, checks one rectangle, and either handles it or
    /// passes it along untouched. The notch means "put this away" at every
    /// size, and putting the HUD away should bring the HUD back.
    private func watchForNotchClicks() {
        guard hudClickMonitor == nil else { return }
        hudClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] event in
            guard let self,
                  let panel = self.hudPanel,
                  event.window === panel,
                  self.ui.mode.isFullScreen,
                  let screen = self.targetScreen
            else { return event }

            let point = panel.convertPoint(toScreen: event.locationInWindow)
            // The clearance either side, so it matches the strip you see rather
            // than the hardware exactly — people aim at the black, and the
            // cursor is invisible inside it.
            let target = self.stripRect(on: screen)
                .insetBy(dx: -Self.notchClearance / 2, dy: 0)
            guard target.contains(point) else { return event }

            self.toggle()
            // Swallowed: it was for the notch, not for whatever is underneath.
            return nil
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
        panelWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.ui.mode.isFullScreen else { return }
            self.hudPanel?.orderOut(nil)
        }
        panelWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.62, execute: work)
    }

    /// Toggle the full-screen HUD, which only chat can reach.
    ///
    /// The HUD *is* the conversation at another scale — there's nothing to
    /// expand a note into, and going notes → chat → HUD is two mode changes
    /// for one keystroke, which reads as the app deciding where you wanted
    /// to be. From notes the key does nothing.
    func toggleHUD() {
        // In HUD-only mode the HUD is the whole app — there's no chat card to
        // step down to, so ⌘⌃M does exactly what ⌘⌃K does: open it, or put it
        // away. Dropping to the chat face here is the bug that let the card back
        // in with HUD-only on.
        if hudOnlyMode { macroToggle(); return }
        guard ui.expanded else { return }
        if ui.mode.isFullScreen {
            setMode(.chat)
        } else if ui.mode == .chat {
            setMode(.hud)
        }
    }

    /// Flip to the other face, only when the notch is already open.
    ///
    /// Deliberately a no-op when closed: ⌘⌃K is the key that opens the notch,
    /// and having a second one that also opens it makes the two shortcuts feel
    /// like the same key. Swapping a surface nobody is looking at isn't a swap.
    func swapMode() {
        // Nothing to swap to in HUD-only mode — the notes and chat faces aren't
        // reachable, so the swap key is inert.
        if hudOnlyMode { return }
        guard ui.expanded else { return }
        // Not from the HUD.
        //
        // It used to drop you onto the note card, which is two moves in one
        // key: leaving a full-screen surface *and* changing face. Leaving is
        // its own decision — ⌘⌃M puts the HUD away, ⌘⌃K puts everything away —
        // and a swap key that also closes things is a swap key you can't
        // press without thinking first.
        guard !ui.mode.isFullScreen else { return }
        setMode(ui.mode == .notes ? .chat : .notes)
    }

    /// Select the nth agent, without moving you somewhere you didn't ask to go.
    ///
    /// It used to force the chat face, which threw you out of the HUD — where
    /// the agent list is right there and switching is the obvious thing to do.
    /// The face only changes when there isn't one showing an agent already.
    func selectAgent(_ index: Int) {
        if hudOnlyMode {
            // Stay in the HUD (or bring it up) — never the chat card.
            showHUDNow()
            chat.useAgent(at: index)
            return
        }
        if !ui.expanded || ui.mode == .notes {
            setMode(.chat)
            showNote()
        }
        chat.useAgent(at: index)
    }

    /// Open the notch on the chat face with a prompt already running — how
    /// tasks sent to a chat agent surface.
    func runInNotch(prompt: String, agentName: String?) {
        if hudOnlyMode {
            showHUDNow()
        } else {
            setMode(.chat)
            showNote()
        }
        chat.seed(prompt: prompt, agentName: agentName)
    }

    /// Whether the primary macro opens the HUD rather than the notch card.
    private var hudOnlyMode: Bool { UserDefaults.standard.bool(forKey: hudOnlyKey) }

    /// Bring the HUD up without ever passing through a card — the HUD-only
    /// route for anything that would otherwise open chat or notes.
    private func showHUDNow() {
        if ui.expanded {
            if !ui.mode.isFullScreen { setMode(.hud) }
        } else {
            expandIntoHUD()
        }
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

    /// The primary macro (⌘⌃K).
    ///
    /// In HUD-only mode (a Settings switch, off by default) opening Visor lands
    /// on the HUD and nothing else — one key that shows the HUD and puts it
    /// away again, no notes or chat face to switch through first. With the
    /// switch off it behaves the way it always did: the key opens the notch
    /// card, and the HUD keeps its own key. The card faces stay reachable
    /// either way — from the menu bar, a re-launch, or a task sent to an agent.
    /// Open the HUD — the four-finger swipe-down action. Always the HUD,
    /// regardless of the HUD-only setting; a no-op if it's already up.
    func showHUDGesture() {
        guard !(ui.expanded && ui.mode.isFullScreen) else { return }
        if ui.expanded { setMode(.hud) } else { expandIntoHUD() }
    }

    /// Close the HUD — the four-finger swipe-up action; a no-op if it isn't up.
    func hideHUDGesture() {
        guard ui.expanded, ui.mode.isFullScreen else { return }
        collapseFromHUD()
    }

    /// Toggle the HUD — the four-finger swipe-down action. Down opens it, down
    /// again closes it, so there's no up-swipe to compete with Mission Control.
    func toggleHUDGesture() {
        if ui.expanded, ui.mode.isFullScreen { hideHUDGesture() } else { showHUDGesture() }
    }

    func macroToggle() {
        guard UserDefaults.standard.bool(forKey: hudOnlyKey) else {
            toggle()
            return
        }
        if ui.expanded {
            if ui.mode.isFullScreen {
                collapseFromHUD()
            } else {
                // On a card that some other path opened — take it up to the
                // HUD rather than closing, so the key always means "the HUD".
                setMode(.hud)
            }
        } else {
            expandIntoHUD()
        }
    }

    /// Leave the HUD via its own "back" affordance. In HUD-only mode that means
    /// all the way to the notch; otherwise it steps back to the chat card it
    /// came from, as it used to.
    func exitHUD() {
        if UserDefaults.standard.bool(forKey: hudOnlyKey) {
            collapseFromHUD()
        } else {
            setMode(.chat)
        }
    }

    func toggle() {
        // From the HUD this puts everything away, in one movement.
        //
        // It used to step down to the chat card instead, which made closing a
        // two-key affair: one to leave the HUD, another to close what was
        // underneath. The reason it did that was mechanical — collapsing left
        // the HUD's window up while ui.expanded went false, which silently
        // disabled every shortcut that guards on the notch being open. That's
        // fixed by taking the HUD down as part of the collapse rather than by
        // refusing to collapse.
        if ui.mode.isFullScreen {
            collapseFromHUD()
            return
        }
        if ui.expanded {
            // A collapse from anywhere else is a collapse from chat or notes,
            // so there's nothing to resume into.
            UserDefaults.standard.set(false, forKey: hudResumeKey)
            hudPanel?.orderOut(nil)
            store.prepareToHide()  // prune blank rows + save (discards the note if now empty)
            // Suppress the notch hover popup until the collapse + window resize
            // settle, so it doesn't reflow right-to-left under a resting cursor.
            ui.settling = true
            withAnimation(Design.Motion.animation(.spring(response: 0.3, dampingFraction: 0.85))) {
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
                    withAnimation(Design.Motion.animation(.easeInOut(duration: 0.2))) { self.ui.settling = false }
                }
            }
        } else if UserDefaults.standard.bool(forKey: hudResumeKey) {
            store.reloadFromDiskIfClean()
            expandIntoHUD()
        } else {
            store.reloadFromDiskIfClean()
            applyFrame(expanded: true)
            ui.settling = true
            // Higher damping so the card settles at its resting spot instead
            // of overshooting (dropping too low) before springing back.
            withAnimation(Design.Motion.animation(.spring(response: 0.34, dampingFraction: 0.95))) {
                ui.expanded = true
            }
            panel.makeKeyAndOrderFront(nil)
            // Let the slide finish before hover affordances can appear.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.ui.settling = false
            }
        }
    }

    /// Collapse straight from the HUD into the notch.
    ///
    /// The mode and the expansion change inside one animation, so the card
    /// underneath never appears: it would be a face flashing into view for a
    /// third of a second on its way to being hidden, which is the sort of
    /// thing that reads as a glitch even when you can't say what you saw.
    private func collapseFromHUD() {
        UserDefaults.standard.set(true, forKey: hudResumeKey)
        // Chat is what's under the HUD, and what a plain reopen should land
        // on if the resume flag is ever cleared.
        UserDefaults.standard.set(VisorMode.chat.rawValue, forKey: modeKey)
        panelWork?.cancel()
        store.prepareToHide()

        // The strip first, so there's a notch for the HUD to retract into
        // rather than an empty gap where it used to be. The card window was
        // ordered out when the HUD came up.
        applyFrame(expanded: false)
        panel.orderFront(nil)

        ui.settling = true
        withAnimation(Design.Motion.animation(.spring(response: 0.42, dampingFraction: 0.86))) {
            ui.mode = .chat
            ui.expanded = false
        }
        // Once it has finished shrinking, not before — ordering the window out
        // early cuts the animation off at frame one.
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.ui.expanded else { return }
            self.hudPanel?.orderOut(nil)
            withAnimation(Design.Motion.animation(.easeInOut(duration: 0.2))) { self.ui.settling = false }
        }
        panelWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.62, execute: work)
    }

    /// Reopen into the HUD, because that's where you were.
    ///
    /// One animation rather than expanding to chat and then expanding again:
    /// the HUD flows out of the notch directly, the same movement in reverse.
    private func expandIntoHUD() {
        UserDefaults.standard.set(VisorMode.hud.rawValue, forKey: modeKey)
        applyFrame(expanded: true)
        ui.settling = true
        withAnimation(Design.Motion.animation(.spring(response: 0.55, dampingFraction: 0.78))) {
            ui.mode = .hud
            ui.expanded = true
        }
        showHUD()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.ui.settling = false
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
            // While dictating, the notch widens on *both* sides.
            //
            // It grew only to the right, which made a symmetrical piece of
            // hardware lopsided for the duration — the eye reads the notch as
            // centred, so a one-sided extension looks like the whole thing has
            // shifted rather than widened.
            // And, for a game that needs the room, downward: the pill hangs
            // from the notch, so extra height is taken off the bottom edge.
            let extra = NotchVisuals.shared.extraHeight
            frame = ui.listening
                ? NSRect(x: hit.minX - Self.listeningPillWidth, y: hit.minY - extra,
                         width: hit.width + Self.listeningPillWidth * 2,
                         height: hit.height + extra)
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
