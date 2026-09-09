import AppKit
import SwiftUI

/// The Design Lab: the production views, rendered with scripted state to PNG.
///
///     Visor --design-lab <out-dir> [--scenario <name>] [--theme <name|all>]
///
/// Neither development machine can show the running app to Claude — the app
/// runs on a MacBook that is only reachable over SSH, and the SSH session
/// has no Screen Recording grant — so this is how UI work gets looked at.
/// Every scenario hosts the same views the notch draws (`StickyRootView`,
/// `HUDRootView`, `MenuBarPanel`, `AppearancePane`…) in an invisible window
/// and snapshots them at 2×.
///
/// Isolation is the whole point. Fixtures use their own stores under the
/// output folder, an `AIRunner` built from literal agents, a chat controller
/// marked offline, and a notes store that never writes UserDefaults. No
/// model call, no sync, no Keychain, no computer action. The lab also runs
/// before the single-instance check, so it works alongside the user's Visor.
///
/// What it cannot prove: window ordering, focus, key status, and the real
/// notch's alignment. Those need the regression scenarios in
/// `docs/design-brief.md` run on the hardware.
@MainActor
enum DesignLab {
    /// True if the arguments asked for the lab; the app must then do nothing
    /// else. Rendering starts on the next run-loop turn and the process
    /// exits when it's done.
    static func runIfRequested(_ args: [String]) -> Bool {
        guard let i = args.firstIndex(of: "--design-lab"), i + 1 < args.count else { return false }
        let out = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath, isDirectory: true)
        let only = value(after: "--scenario", in: args)
        let theme = value(after: "--theme", in: args)
        frames = Int(value(after: "--frames", in: args) ?? "") ?? 1
        every = (Double(value(after: "--every", in: args) ?? "") ?? 250) / 1000
        Task { @MainActor in
            run(out: out, only: only, theme: theme)
        }
        return true
    }

    /// Frame sequences: `--frames 12 --every 250` captures twelve frames a
    /// quarter-second apart of each chosen scenario, so a transition can be
    /// judged as motion rather than one still. Fixtures use live timing
    /// when more than one frame is asked for.
    static var frames = 1
    static var every: TimeInterval = 0.25
    static var liveTiming: Bool { frames > 1 }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    // MARK: - Scenarios

    struct Scenario {
        let name: String
        let size: CGSize
        /// Themed scenarios are rendered once per theme when `--theme all`.
        let themed: Bool
        let note: String
        let make: @MainActor (Fixtures) -> AnyView
        /// When set, the capture is of this real window's content view —
        /// built exactly as the app builds it — instead of a hosted view.
        var window: (@MainActor () -> NSWindow)? = nil
    }

    static func scenarios() -> [Scenario] {
        let stage = CGSize(width: 680, height: 430)
        let hud = CGSize(width: 1512, height: 982)
        return [
            Scenario(name: "notes", size: stage, themed: false,
                     note: "Notes face, a few tasks and a note, hover suppressed") { f in
                AnyView(f.compact(.notes, chat: f.chat(.complete)))
            },
            Scenario(name: "chat-empty", size: stage, themed: false,
                     note: "Chat face with an agent and no messages") { f in
                AnyView(f.compact(.chat, chat: f.chat(.empty)))
            },
            Scenario(name: "chat-no-agents", size: stage, themed: false,
                     note: "First-use state: no agents configured") { f in
                AnyView(f.compact(.chat, chat: f.chat(.noAgents)))
            },
            Scenario(name: "chat-waiting", size: stage, themed: false,
                     note: "Sent, waiting on the first token") { f in
                AnyView(f.compact(.chat, chat: f.chat(.waiting)))
            },
            Scenario(name: "chat-streaming", size: stage, themed: false,
                     note: "Mid-stream, partial Markdown (an unclosed list)") { f in
                AnyView(f.compact(.chat, chat: f.chat(.streaming)))
            },
            Scenario(name: "chat-complete", size: stage, themed: false,
                     note: "A short finished exchange") { f in
                AnyView(f.compact(.chat, chat: f.chat(.complete)))
            },
            Scenario(name: "chat-formatted", size: stage, themed: false,
                     note: "Long formatted answer: headings, lists, code, table, quote") { f in
                AnyView(f.compact(.chat, chat: f.chat(.formatted)))
            },
            Scenario(name: "chat-approval", size: stage, themed: false,
                     note: "Pending tool approval inside the compact card") { f in
                AnyView(f.compact(.chat, chat: f.chat(.approval)))
            },
            Scenario(name: "chat-error", size: stage, themed: false,
                     note: "A failed send") { f in
                AnyView(f.compact(.chat, chat: f.chat(.error)))
            },
            Scenario(name: "composer-multiline", size: stage, themed: false,
                     note: "Composer grown to its three-line limit") { f in
                AnyView(f.compact(.chat, chat: f.chat(.multiline)))
            },
            Scenario(name: "computer-use", size: stage, themed: false,
                     note: "Computer Use card, idle") { f in
                ComputerUseAgent.shared.previewState(running: false, status: "Type a task and press ⏎.", log: [])
                return AnyView(f.compact(.computerUse, chat: f.chat(.empty)))
            },
            Scenario(name: "computer-use-running", size: stage, themed: false,
                     note: "Computer Use mid-task: current action, steps so far, Stop") { f in
                ComputerUseAgent.shared.previewState(
                    running: true,
                    status: "Clicking “Displays” in the System Settings sidebar",
                    log: ["Opened System Settings", "Read the sidebar: 24 items", "Scrolled to Displays",
                          "Clicking “Displays”"])
                return AnyView(f.compact(.computerUse, chat: f.chat(.empty)))
            },
            Scenario(name: "computer-use-done", size: stage, themed: false,
                     note: "Computer Use finished: result and log") { f in
                ComputerUseAgent.shared.previewState(
                    running: false,
                    status: "Done — Night Shift is on, scheduled sunset to sunrise.",
                    log: ["Opened System Settings", "Scrolled to Displays", "Clicked “Displays”",
                          "Clicked “Night Shift…”", "Set Schedule to Sunset to Sunrise", "Closed the sheet"])
                return AnyView(f.compact(.computerUse, chat: f.chat(.empty)))
            },
            Scenario(name: "selector-models", size: CGSize(width: 440, height: 320), themed: false,
                     note: "The model selector: pinned models, sized to its rows") { f in
                AnyView(ZStack(alignment: .topLeading) {
                    Color.black
                    ModelSelector(chat: f.chat(.complete), query: .constant("")) { _ in }.padding(20)
                })
            },
            Scenario(name: "selector-options", size: CGSize(width: 340, height: 220), themed: false,
                     note: "Reasoning and speed") { f in
                AnyView(ZStack(alignment: .topLeading) {
                    Color.black
                    OptionsSelector(chat: f.chat(.complete)).padding(20)
                })
            },
            Scenario(name: "selector-agents", size: CGSize(width: 360, height: 260), themed: false,
                     note: "The agent selector's content, as it appears in its popover") { f in
                AnyView(ZStack(alignment: .topLeading) {
                    Color.black
                    AgentSelector(chat: f.chat(.complete), dismiss: {}).padding(20)
                })
            },
            Scenario(name: "composer-parts", size: CGSize(width: 520, height: 420), themed: false,
                     note: "The composer's controls in isolation, one variant per row") { f in
                AnyView(ComposerPartsProbe(chat: f.chat(.empty)))
            },
            Scenario(name: "hud", size: hud, themed: false,
                     note: "HUD with populated rails and a formatted reply") { f in
                AnyView(f.hud(chat: f.chat(.formatted)))
            },
            Scenario(name: "hud-streaming", size: hud, themed: false,
                     note: "HUD mid-stream") { f in
                AnyView(f.hud(chat: f.chat(.streaming)))
            },
            Scenario(name: "menu-panel", size: CGSize(width: 300, height: 360), themed: true,
                     note: "The menu-bar dropdown") { f in
                AnyView(f.menuPanel())
            },
            Scenario(name: "settings-appearance", size: CGSize(width: 620, height: 560), themed: true,
                     note: "Settings → Appearance") { _ in
                AnyView(AppearancePane()
                    .padding(24)
                    .frame(width: 620, height: 560, alignment: .topLeading)
                    .background(Design.Retro.bg)
                    .environment(\.colorScheme, VisorTheme.current.isDark ? .dark : .light))
            },
            Scenario(name: "takeover-boot", size: hud, themed: false,
                     note: "The reveal: mark risen from the notch, wordmark, sweep") { f in
                AnyView(f.takeover(.boot, chat: f.chat(.empty), expanded: false))
            },
            Scenario(name: "takeover-summon", size: hud, themed: false,
                     note: "01 The notch: ring, guide below; it opens itself a beat later") { f in
                AnyView(f.takeover(.summon, chat: f.chat(.empty), expanded: false))
            },
            Scenario(name: "takeover-open", size: hud, themed: false,
                     note: "The card opening under the takeover — capture with --frames") { f in
                AnyView(f.takeover(.summon, chat: f.chat(.empty), expanded: false, openAfter: 0.25))
            },
            Scenario(name: "takeover-agent", size: hud, themed: false,
                     note: "02 The one form: name, runs-on, key, Create") { f in
                AnyView(f.takeover(.agent, chat: f.chat(.empty), expanded: true, mode: .chat) { s in
                    s.cliFound = ("Claude Code", "claude", "signed in as sanket@kitalabs.dev")
                    s.connection = .cli
                })
            },
            Scenario(name: "takeover-agent-key", size: hud, themed: false,
                     note: "02 The form with no CLI found: the key path") { f in
                AnyView(f.takeover(.agent, chat: f.chat(.empty), expanded: true, mode: .chat) { s in
                    s.connection = .openRouter
                })
            },
            Scenario(name: "takeover-task", size: hud, themed: false,
                     note: "03 The tour typing the request into the composer") { f in
                AnyView(f.takeover(.firstTask, chat: f.chat(.multiline), expanded: true, mode: .chat) { s in
                    s.created = true
                })
            },
            Scenario(name: "takeover-approval", size: hud, themed: false,
                     note: "03 The approval card is up; the guide names it") { f in
                AnyView(f.takeover(.firstTask, chat: f.chat(.approval), expanded: true, mode: .chat) { s in
                    s.created = true; s.awaitingApproval = true
                })
            },
            Scenario(name: "takeover-trouble", size: hud, themed: false,
                     note: "03 The agent failed; the tour says so and runs the stand-in itself") { f in
                AnyView(f.takeover(.firstTask, chat: f.chat(.error), expanded: true, mode: .chat) { s in
                    s.created = true; s.trouble = "OpenRouter says this account is out of credit."; s.standIn = true
                })
            },
            Scenario(name: "takeover-milestone", size: hud, themed: false,
                     note: "The milestone flash after the first task") { f in
                AnyView(f.takeover(.firstTask, chat: f.chat(.complete), expanded: true, mode: .chat) { s in
                    s.created = true; s.taskDone = true; s.milestone = "First task, done"
                })
            },
            Scenario(name: "takeover-drive", size: hud, themed: false,
                     note: "04 Computer Use, Visor's own face, mid-demonstration; Stop asked for") { f in
                ComputerUseAgent.shared.previewState(
                    running: true, status: "Clicking “Displays”",
                    log: ["Opened System Settings", "Read the sidebar: 24 items", "Scrolled to Displays", "Clicked “Displays”"])
                ComputerUseAgent.shared.draft = "Turn on Night Shift in System Settings"
                return AnyView(f.takeover(.drive, chat: f.chat(.complete), expanded: true, mode: .computerUse) { s in
                    s.askStop = true
                })
            },
            Scenario(name: "takeover-stopped", size: hud, themed: false,
                     note: "04 Stopped between actions") { f in
                ComputerUseAgent.shared.previewState(
                    running: false, status: "Stopped — nothing further will happen.",
                    log: ["Opened System Settings", "Read the sidebar: 24 items", "Scrolled to Displays", "Clicked “Displays”"])
                return AnyView(f.takeover(.drive, chat: f.chat(.complete), expanded: true, mode: .computerUse) { s in
                    s.driveStopped = true
                })
            },
            Scenario(name: "takeover-finale", size: hud, themed: false,
                     note: "The return: cheat sheet and the way out") { f in
                AnyView(f.takeover(.finale, chat: f.chat(.complete), expanded: true, mode: .chat))
            },
            Scenario(name: "menu-panel", size: CGSize(width: 300, height: 360), themed: true,
                     note: "The menu-bar dropdown") { f in
                AnyView(f.menuPanel())
            },
            Scenario(name: "settings-appearance", size: CGSize(width: 620, height: 560), themed: true,
                     note: "Settings → Appearance") { _ in
                AnyView(AppearancePane()
                    .padding(24)
                    .frame(width: 620, height: 560, alignment: .topLeading)
                    .background(Design.Retro.bg)
                    .environment(\.colorScheme, VisorTheme.current.isDark ? .dark : .light))
            },
            Scenario(name: "takeover-boot", size: hud, themed: false,
                     note: "The reveal: mark risen from the notch, wordmark, sweep") { f in
                AnyView(f.takeover(.boot, chat: f.chat(.empty), expanded: false))
            },
            Scenario(name: "takeover-summon", size: hud, themed: false,
                     note: "01 Summon: ring around the notch, guide below") { f in
                AnyView(f.takeover(.summon, chat: f.chat(.empty), expanded: false))
            },
            Scenario(name: "takeover-open", size: hud, themed: false,
                     note: "The card opening under the takeover — capture with --frames to check the hole and the card move as one") { f in
                AnyView(f.takeover(.summon, chat: f.chat(.empty), expanded: false, openAfter: 0.25))
            },
            Scenario(name: "takeover-connect", size: hud, themed: false,
                     note: "02 Connect: a detected agent offered, the key path, skip") { f in
                AnyView(f.takeover(.connect, chat: f.chat(.empty), expanded: true, mode: .chat) { s in
                    s.options = [.init(name: "Claude Code", detail: "Signed in as sanket@kitalabs.dev", ready: true),
                                 .init(name: "Claude", detail: "Needs an OpenRouter key", ready: false)]
                })
            },
            Scenario(name: "takeover-task", size: hud, themed: false,
                     note: "03 First task: the composer pre-filled, ring on it") { f in
                AnyView(f.takeover(.firstTask, chat: f.chat(.multiline), expanded: true, mode: .chat) { s in
                    s.chosen = "Claude Code"
                })
            },
            Scenario(name: "takeover-approval", size: hud, themed: false,
                     note: "03 First task: the approval card is up; the guide names it") { f in
                AnyView(f.takeover(.firstTask, chat: f.chat(.approval), expanded: true, mode: .chat) { s in
                    s.chosen = "Claude Code"; s.awaitingApproval = true
                })
            },
            Scenario(name: "takeover-trouble", size: hud, themed: false,
                     note: "03 First task: the agent failed; the stand-in and skip are offered") { f in
                AnyView(f.takeover(.firstTask, chat: f.chat(.error), expanded: true, mode: .chat) { s in
                    s.chosen = "Claude"; s.trouble = "OpenRouter: 401 — the API key for Claude was rejected."
                })
            },
            Scenario(name: "takeover-milestone", size: hud, themed: false,
                     note: "The milestone flash after the first task") { f in
                AnyView(f.takeover(.firstTask, chat: f.chat(.complete), expanded: true, mode: .chat) { s in
                    s.chosen = "Claude Code"; s.taskDone = true; s.milestone = "First task, done"
                })
            },
            Scenario(name: "takeover-practice", size: hud, themed: false,
                     note: "04 Practice: the practice window under the card, beam from the notch, Run") { f in
                AnyView(f.takeover(.practice, chat: f.chat(.complete), expanded: true, mode: .chat,
                                   practice: true))
            },
            Scenario(name: "takeover-control", size: hud, themed: false,
                     note: "05 Control: mid-run, Stop offered") { f in
                AnyView(f.takeover(.control, chat: f.chat(.complete), expanded: true, mode: .chat,
                                   practice: true) { s in
                    s.practice.run()
                })
            },
            Scenario(name: "takeover-yours", size: hud, themed: false,
                     note: "06 Yours: suggestions, HUD and dictation mentioned") { f in
                AnyView(f.takeover(.yours, chat: f.chat(.empty), expanded: true, mode: .chat) { s in
                    s.chosen = "Claude Code"
                })
            },
            Scenario(name: "takeover-finale", size: hud, themed: false,
                     note: "The return: cheat sheet and the way out") { f in
                AnyView(f.takeover(.finale, chat: f.chat(.complete), expanded: true, mode: .chat) { s in
                    s.chosen = "Claude Code"
                })
            },
            Scenario(name: "practice-window", size: CGSize(width: 480, height: 300), themed: false,
                     note: "The practice workspace, mid-run") { _ in
                let driver = PracticeDriver()
                return AnyView(PracticeView(driver: driver).frame(width: 480, height: 300)
                    .onAppear { driver.run() })
            },
        ]
    }

    // MARK: - Driver

    private static func run(out: URL, only: String?, theme: String?) {
        let fm = FileManager.default
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        let fixturesRoot = out.appendingPathComponent(".fixtures", isDirectory: true)
        try? fm.removeItem(at: fixturesRoot)
        try? fm.createDirectory(at: fixturesRoot, withIntermediateDirectories: true)

        var log: [String] = []
        func note(_ s: String) { log.append(s); NSLog("[DesignLab] %@", s) }

        let all = scenarios()
        let chosen = only.map { name in all.filter { $0.name == name } } ?? all
        if chosen.isEmpty {
            note("no scenario named \(only ?? "")")
            note("available: " + all.map(\.name).joined(separator: ", "))
            finish(out: out, log: log)
            return
        }

        // Which themes to render. The theme is read from UserDefaults at
        // render time, so it's set in the volatile argument domain — highest
        // precedence, never persisted.
        let themes: [VisorTheme?]
        switch theme {
        case "all":                  themes = VisorTheme.allCases.map { Optional($0) }
        case let name? where VisorTheme(rawValue: name) != nil:
            themes = [VisorTheme(rawValue: name)]
        default:                     themes = [nil]
        }

        // (scenario, theme) pairs; unthemed scenarios render once.
        var queue: [(Scenario, VisorTheme?)] = []
        for scenario in chosen {
            if scenario.themed {
                for t in themes { queue.append((scenario, t)) }
            } else {
                queue.append((scenario, themes.first ?? nil))
            }
        }

        let fixtures = Fixtures(root: fixturesRoot)
        var manifest: [[String: String]] = []
        let started = Date()

        func next() {
            guard !queue.isEmpty else {
                note(String(format: "rendered %d captures in %.1fs", manifest.count,
                            Date().timeIntervalSince(started)))
                writeIndex(out: out, manifest: manifest)
                finish(out: out, log: log)
                return
            }
            let (scenario, theme) = queue.removeFirst()
            applyTheme(theme)
            let suffix = (scenario.themed && theme != nil) ? "-\(theme!.rawValue)" : ""
            let file = "\(scenario.name)\(suffix).png"
            let target = out.appendingPathComponent(file)
            let done: (Bool) -> Void = { ok in
                note("\(ok ? "ok  " : "FAIL") \(file)")
                manifest.append(["file": file, "scenario": scenario.name,
                                 "theme": theme?.rawValue ?? VisorTheme.current.rawValue,
                                 "size": "\(Int(scenario.size.width))×\(Int(scenario.size.height))",
                                 "note": scenario.note])
                next()
            }
            if let build = scenario.window {
                let window = build()
                window.alphaValue = 0
                window.orderFrontRegardless()
                snapshot(window.contentView, size: scenario.size, to: target) { ok in
                    window.orderOut(nil)
                    done(ok)
                }
            } else {
                render(scenario.make(fixtures), size: scenario.size, to: target, completion: done)
            }
        }
        next()
    }

    private static func applyTheme(_ theme: VisorTheme?) {
        var domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        if let theme {
            domain[VisorTheme.key] = theme.rawValue
        } else {
            domain.removeValue(forKey: VisorTheme.key)
        }
        // Pin the HUD rails so a capture never depends on — or shows — the
        // user's own layout or dictation log.
        domain["visor.hud.left"] = ["agents", "chats"]
        domain["visor.hud.right"] = ["tasks", "memory"]
        domain["visor.hud.collapsed"] = [String]()
        UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    }

    private static func writeIndex(out: URL, manifest: [[String: String]]) {
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]) {
            try? data.write(to: out.appendingPathComponent("manifest.json"))
        }
        var md = "# Visor Design Lab captures\n\n"
        md += "Build \(AppInfo.version) · \(ISO8601DateFormatter().string(from: Date()))\n\n"
        md += "| Capture | Scenario | Theme | Size | What to look at |\n|---|---|---|---|---|\n"
        for m in manifest {
            md += "| ![](\(m["file"]!)) `\(m["file"]!)` | \(m["scenario"]!) | \(m["theme"]!) | \(m["size"]!) | \(m["note"]!) |\n"
        }
        try? md.write(to: out.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
    }

    private static func finish(out: URL, log: [String]) {
        try? log.joined(separator: "\n").write(
            to: out.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: out.appendingPathComponent(".fixtures"))
        NSApp.terminate(nil)
    }

    // MARK: - Rendering

    /// Host the view in a window the user can't see and snapshot it at 2×.
    ///
    /// The window is ordered on screen at zero alpha rather than kept
    /// offscreen: AppKit only lays out and draws windows the window server
    /// knows about, and an offscreen hosting view returns an empty bitmap.
    /// Two run-loop turns are allowed for SwiftUI to settle its lazy stacks
    /// and the text view to report its height before the capture.
    private static func render(_ view: AnyView, size: CGSize, to url: URL,
                               completion: @escaping (Bool) -> Void) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.alphaValue = 0
        window.level = .normal
        window.ignoresMouseEvents = true
        window.appearance = NSAppearance(named: VisorTheme.current.isDark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        snapshot(host, size: size, to: url) { ok in
            window.orderOut(nil)
            completion(ok)
        }
    }

    /// Give SwiftUI a moment to settle, then draw the view into a 2× bitmap
    /// — once, or as a numbered sequence when frames were asked for.
    private static func snapshot(_ view: NSView?, size: CGSize, to url: URL,
                                 completion: @escaping (Bool) -> Void) {
        guard let view else { completion(false); return }
        view.layoutSubtreeIfNeeded()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: liveTiming ? 80_000_000 : 450_000_000)
            var ok = true
            for frame in 0..<max(1, frames) {
                view.layoutSubtreeIfNeeded()
                view.displayIfNeeded()
                let target: URL
                if frames > 1 {
                    let base = url.deletingPathExtension().lastPathComponent
                    target = url.deletingLastPathComponent()
                        .appendingPathComponent(String(format: "%@-f%02d.png", base, frame))
                } else {
                    target = url
                }
                ok = write(view, size: size, to: target) && ok
                if frame < frames - 1 {
                    try? await Task.sleep(nanoseconds: UInt64(every * 1_000_000_000))
                }
            }
            completion(ok)
        }
    }

    private static func write(_ view: NSView, size: CGSize, to url: URL) -> Bool {
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    // MARK: - Fixtures

    /// Everything a scenario can ask for, built once and never touching the
    /// user's data.
    @MainActor
    final class Fixtures {
        let root: URL
        let ai: AIRunner
        let noAgents: AIRunner
        let notes: NotesStore
        let notch = CGSize(width: 185, height: 37)

        init(root: URL) {
            self.root = root
            var claude = AIProvider(name: "Claude", command: "", args: [])
            claude.kind = .openRouter
            claude.model = "anthropic/claude-sonnet-5"
            claude.favouriteModels = ["anthropic/claude-sonnet-5", "anthropic/claude-opus-5",
                                      "openai/gpt-5", "google/gemini-3-pro"]
            var gpt = AIProvider(name: "Fast", command: "", args: [])
            gpt.kind = .openRouter
            gpt.model = "openai/gpt-5-mini"
            var cli = AIProvider(name: "Claude Code", command: "claude", args: ["-p"])
            cli.runsInNotch = true
            ai = AIRunner(fixtureProviders: [claude, gpt, cli])
            noAgents = AIRunner(fixtureProviders: [])

            notes = NotesStore(folder: root.appendingPathComponent("notes", isDirectory: true),
                               ephemeral: true)
            notes.title = "Today"
            notes.items = [
                NoteItem(text: "Ship the transcript follow guard", isTask: true, status: .doing),
                NoteItem(text: "Review the onboarding copy", isTask: true),
                NoteItem(text: "Book the dentist", isTask: true, status: .done),
                NoteItem(text: "Ideas for the HUD rails: a calendar strip, a clipboard history",
                         isTask: false),
            ]
        }

        enum ChatKind { case empty, noAgents, waiting, streaming, complete, formatted, approval,
                             error, multiline }

        private var counter = 0

        func chat(_ kind: ChatKind) -> ChatController {
            counter += 1
            let dir = root.appendingPathComponent("chat-\(counter)", isDirectory: true)
            let runner = kind == .noAgents ? noAgents : ai
            let agent = "Claude", model = "anthropic/claude-sonnet-5"

            func user(_ s: String) -> ChatMessage { ChatMessage(role: .user, content: s) }
            func bot(_ s: String) -> ChatMessage { ChatMessage(role: .assistant, content: s) }

            var convo = Conversation(title: "", agentName: agent, model: model)
            var streaming = false
            var pending: ChatController.PendingApproval?
            var error: String?
            var draft = ""

            switch kind {
            case .empty, .noAgents:
                break
            case .waiting:
                convo.title = "Notch geometry"
                convo.messages = [user("Why does the switcher sit off the notch rather than the card?"),
                                  bot("")]
                streaming = true
            case .streaming:
                convo.title = "Release checklist"
                convo.messages = [user("Give me a release checklist for a notarised Mac app."),
                                  bot(Self.partialReply)]
                streaming = true
            case .complete:
                convo.title = "Notch geometry"
                convo.messages = [
                    user("Why does the switcher sit off the notch rather than the card?"),
                    bot("Because the card's width animates between faces and the notch never moves. Anchoring to the card meant the icons slid sideways on every swap; anchoring to the notch keeps them still."),
                    user("Got it. And the shoulder width?"),
                    bot("Fixed at **106pt** — what the narrower card allows: 420 − (185 + 18) leaves 217 for two shoulders."),
                ]
            case .formatted:
                convo.title = "Markdown rendering"
                convo.messages = [user("Show me what a formatted answer looks like in here."),
                                  bot(Self.formattedReply)]
            case .approval:
                convo.title = "Repo housekeeping"
                let call = ToolCall(id: "call_1", name: "run_shell",
                                    arguments: #"{"command":"git branch --merged main | grep -v main | xargs git branch -d"}"#)
                convo.messages = [user("Delete every local branch that's already merged into main."),
                                  ChatMessage(role: .assistant, content: "", toolCalls: [call])]
                pending = .init(calls: [call], needing: [call], model: model, system: nil,
                                effort: nil, fast: false, round: 1)
            case .error:
                convo.title = "Notch geometry"
                convo.messages = [user("Why does the switcher sit off the notch rather than the card?")]
                error = "OpenRouter: 401 — the API key for Claude was rejected. Check Settings → Agents."
            case .multiline:
                convo.title = ""
                draft = "Rewrite the onboarding copy so it answers one question first:\nhow do I get Visor back after it disappears?\nKeep the summon shortcut in the first sentence,\nand mention the menu-bar mark."
            }

            let chat = ChatController.fixture(ai: runner, root: dir, conversation: convo,
                                              streaming: streaming, pending: pending,
                                              error: error, draft: draft)
            // A few past chats so the history list and the HUD rail have rows.
            for (title, preview) in [("Sparkle appcast", "The appcast needs the EdDSA signature…"),
                                     ("Transcript follow guard", "Follow only within 48pt of the end."),
                                     ("Departure Mono", "System font is the default now; pixel face stays for glyphs.")] {
                var past = Conversation(title: title, agentName: agent, model: model)
                past.messages = [user(title), bot(preview)]
                chat.store.save(past)
            }
            return chat
        }

        /// The compact card on a synthetic screen top: a menu-bar strip and a
        /// black notch in the right place, so alignment can be judged.
        func compact(_ mode: VisorMode, chat: ChatController) -> some View {
            let ui = UIState()
            ui.expanded = true
            ui.mode = mode
            ui.notchSize = notch
            ui.trueNotch = notch
            ui.settling = false
            return ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.30, green: 0.34, blue: 0.48),
                                        Color(red: 0.16, green: 0.18, blue: 0.28)],
                               startPoint: .top, endPoint: .bottom)
                Rectangle().fill(Color.black.opacity(0.28)).frame(height: notch.height)
                UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 10,
                                       bottomTrailingRadius: 10, topTrailingRadius: 0)
                    .fill(Color.black)
                    .frame(width: notch.width, height: notch.height)
                StickyRootView(store: notes, ui: ui, ai: ai, chat: chat,
                               onToggle: {}, onMode: { ui.mode = $0 })
            }
            .environment(\.colorScheme, .dark)
        }

        func hud(chat: ChatController) -> some View {
            let ui = UIState()
            ui.expanded = true
            ui.mode = .hud
            ui.notchSize = notch
            ui.trueNotch = notch
            return ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.36, green: 0.30, blue: 0.52),
                                        Color(red: 0.10, green: 0.12, blue: 0.22)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Rectangle().fill(Color.black.opacity(0.28)).frame(height: notch.height)
                UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 10,
                                       bottomTrailingRadius: 10, topTrailingRadius: 0)
                    .fill(Color.black)
                    .frame(width: notch.width, height: notch.height)
                HUDRootView(chat: chat, store: notes, ui: ui, onExit: {}, onClose: {})
            }
        }

        /// The takeover over a synthetic screen, stacked as the app orders
        /// it: the card and the practice window below, the takeover on top
        /// with holes cut for them.
        func takeover(_ step: TakeoverState.Step, chat: ChatController,
                      expanded: Bool, mode: VisorMode = .notes,
                      openAfter: TimeInterval? = nil,
                      configure: (TakeoverState) -> Void = { _ in }) -> some View {
            let bounds = CGRect(x: 0, y: 0, width: 1512, height: 982)
            let notchRect = CGRect(x: bounds.midX - notch.width / 2, y: bounds.maxY - notch.height,
                                   width: notch.width, height: notch.height)
            let size = NotchController.cardSize(for: mode)
            let card = CGRect(x: notchRect.midX - size.width / 2,
                              y: notchRect.minY - size.height,
                              width: size.width, height: size.height + notch.height)
            let distance = (notch.width + NotchController.notchClearance) / 2 + ModeSwitcher.width / 2
            let switcher = CGRect(x: notchRect.midX - distance - ModeSwitcher.width / 2,
                                  y: notchRect.minY, width: ModeSwitcher.width, height: notch.height)
            let state = TakeoverState(
                geometry: .init(bounds: bounds, notch: notchRect, card: card, switcher: switcher,
                                expanded: expanded),
                step: step)
            state.stepStarted = DesignLab.liveTiming ? Date() : Date(timeIntervalSinceNow: -30)
            configure(state)
            let ui = UIState()
            ui.expanded = expanded
            ui.mode = mode
            ui.notchSize = notch
            ui.trueNotch = notch
            return ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(red: 0.30, green: 0.34, blue: 0.48),
                                        Color(red: 0.16, green: 0.18, blue: 0.28)],
                               startPoint: .top, endPoint: .bottom)
                Rectangle().fill(Color.black.opacity(0.28)).frame(width: bounds.width, height: notch.height)
                UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 10,
                                       bottomTrailingRadius: 10, topTrailingRadius: 0)
                    .fill(Color.black)
                    .frame(width: notch.width, height: notch.height)
                    .offset(x: notchRect.minX)
                // Always mounted, as in the app: the root draws the card only
                // while `ui.expanded`, so an open captured with --frames shows
                // the card and the scrim's hole growing together.
                StickyRootView(store: notes, ui: ui, ai: ai, chat: chat,
                               onToggle: {}, onMode: { ui.mode = $0 })
                    .frame(width: bounds.width, height: bounds.height, alignment: .top)
                TakeoverView(state: state, actions: TakeoverActions())
            }
            .environment(\.colorScheme, .dark)
            .onAppear {
                guard let openAfter else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + openAfter) {
                    withAnimation(Design.Motion.surface) {
                        ui.expanded = true
                        state.geometry.expanded = true
                    }
                }
            }
        }

        func menuPanel() -> some View {
            ZStack(alignment: .topLeading) {
                Color.clear
                MenuBarPanel(version: AppInfo.version, computerUseOn: false,
                             onOpenVisor: {}, onComputerUse: {}, onDictate: {}, onSettings: {},
                             onWhatsNew: {}, onIntroduction: {}, onCheckUpdates: {}, onQuit: {})
                    .padding(12)
            }
        }

        static let partialReply = """
        Here's the order that avoids a rejected notarisation:

        1. **Archive** with the Developer ID Application certificate.
        2. Run `xcrun notarytool submit` and *wait* for the ticket.
        3. `xcrun stapler staple` the app **and** the DMG —
        """

        static let formattedReply = """
        ## Rendering check

        A reply can carry every block the renderer supports. Inline **bold**, *italics*, `code` and a [link](https://kitalabs.dev) should all read as one voice.

        ### A list

        - The notch is the origin for opening, expanding and returning.
        - Compact is for capture; the HUD is for sustained work.
          - Nested points indent, not shout.
        - Drafts and reading position survive a surface change.

        ### Code

        ```swift
        let clamped = min(max(height, metrics.minHeight), metrics.maxHeight)
        if abs(clamped - draftHeight) > 0.5 { draftHeight = clamped }
        ```

        ### A table

        | Transition | Curve | Origin |
        |---|---|---|
        | Closed → card | spring 0.34 / 0.95 | notch centre |
        | Chat → HUD | spring 0.52 / 0.86 | notch centre |
        | HUD → closed | spring 0.42 / 0.86 | notch centre |

        > Materials fade; content scales. A material being scaled is rasterised mid-animation and re-rendered sharp at the end.

        That's the lot — and a final paragraph to check the rhythm below a quote.
        """
    }
}


/// Each composer control on its own, so a rendering artefact can be pinned
/// to the layer that draws it: the chip with and without its Button, its
/// popover, and its pill modifier.
private struct ComposerPartsProbe: View {
    @ObservedObject var chat: ChatController
    @State private var never = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            row("A · InlineModelPicker as shipped") { InlineModelPicker(chat: chat) }
            row("B · Text + composerPill, no Button") {
                Text("claude-sonnet-5").composerPill(active: true)
            }
            row("C · Button(visorBare) + composerPill, no popover") {
                Button {} label: { Text("claude-sonnet-5").composerPill(active: true) }
                    .buttonStyle(.visorBare)
            }
            row("D · C + .popover(.constant(false))") {
                Button {} label: { Text("claude-sonnet-5").composerPill(active: true) }
                    .buttonStyle(.visorBare)
                    .popover(isPresented: $never) { Text("x") }
            }
            row("E · Button(visorBare) + Text, no pill") {
                Button {} label: { Text("claude-sonnet-5").padding(8) }
                    .buttonStyle(.visorBare)
            }
            row("F · ComposerOptions (plus) and DictationControl") {
                HStack(spacing: 8) {
                    ComposerOptions(chat: chat)
                    DictationControl(voice: chat.voice, onToggle: {}, size: 32, circular: true)
                }
            }
        }
        .padding(24)
        .frame(width: 520, height: 420, alignment: .topLeading)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }

    private func row<V: View>(_ label: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            content()
        }
    }
}
