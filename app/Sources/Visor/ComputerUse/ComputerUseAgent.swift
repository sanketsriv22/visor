import AppKit
import CoreGraphics
import Foundation

/// Generalized computer use: you type what you want done ("find me 5 LinkedIn
/// jobs that match…") and the agent looks at the screen, decides one action,
/// does it, and looks again — a screenshot → vision model → single action loop.
///
/// Deliberately conservative. It runs only from an explicit task you start, one
/// step at a time with a visible log, caps out after `maxSteps`, and stops the
/// instant you ask. It is not a background automation and never acts without a
/// running task.
@MainActor
final class ComputerUseAgent: ObservableObject {
    static let shared = ComputerUseAgent()

    @Published private(set) var running = false
    @Published private(set) var status = "Type a task and press ⏎."
    @Published private(set) var log: [String] = []

    /// The vision model, chosen in the card. It must accept images. Defaults to
    /// a fast one — with the Accessibility element list doing the grounding, the
    /// model just picks an id, so it doesn't need to be a heavyweight.
    static let modelKey = "visor.cu.model"
    static let defaultModel = "anthropic/claude-haiku-4.5"
    /// The fast vision models offered in the picker (label, OpenRouter id).
    static let models: [(name: String, id: String)] = [
        ("Gemini 2.5 Flash-Lite · fastest", "google/gemini-2.5-flash-lite"),
        ("Gemini 2.5 Flash · fast", "google/gemini-2.5-flash"),
        ("Haiku 4.5 · fast + reliable", "anthropic/claude-haiku-4.5"),
        ("GPT-4o mini · fast", "openai/gpt-4o-mini"),
        ("Sonnet · most accurate", "anthropic/claude-sonnet-5"),
    ]
    var model: String { UserDefaults.standard.string(forKey: Self.modelKey) ?? Self.defaultModel }
    let maxSteps = 25

    private var task: Task<Void, Never>?
    private var trace: CUTrace?
    private let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    private enum Action {
        case clickElement(Int), typeElement(Int, String, Bool)   // by Accessibility element (submit?)
        case click(Double, Double), doubleClick(Double, Double)   // by pixel (fallback)
        case type(String, Bool), key(String), scroll(Int)        // type (submit?)
        case openApp(String), openURL(String)
        case done(String), fail(String)
    }

    func start(_ instruction: String) {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !running else { return }
        guard Keychain.has(OpenRouterClient.sharedKeyAccount) else {
            status = "Set your OpenRouter key in Settings → Secrets first."
            return
        }
        running = true
        log = []
        status = "Working…"
        task = Task { await run(text) }
    }

    func stop() {
        task?.cancel()
        task = nil
        running = false
        status = "Stopped."
    }

    private func run(_ instruction: String) async {
        // Hand focus back to the user's real app. Visor is frontmost right now
        // because you just typed the task into its card — if we don't step aside,
        // the agent scans and clicks Visor's OWN window (it was clicking its own
        // COPY button). Deactivating brings the previously-active app forward
        // without hiding the card.
        NSApplication.shared.deactivate()
        try? await Task.sleep(nanoseconds: 350_000_000)

        trace = CUTrace(task: instruction)
        var history: [String] = []
        var misses = 0            // consecutive turns with no usable action
        var lastSig: String?      // fingerprint of last step's element list
        var lastActed: String?    // the action we took last step
        var ineffective: [String] = []   // actions that changed nothing — don't repeat

        // One persistent capture for the whole task — the screen-recording
        // indicator stays steadily lit instead of blinking each step, and each
        // grab is just reading the latest delivered frame.
        let capture = DesktopCapture()
        do {
            try await capture.start()
        } catch {
            finish("Couldn't start screen capture — is Screen Recording granted?")
            return
        }
        defer { capture.stop() }
        // Let the stream deliver its first frame before we look.
        try? await Task.sleep(nanoseconds: 500_000_000)

        for step in 1...maxSteps {
            if Task.isCancelled { break }
            // Prefer the live stream frame; fall back to a one-shot if the first
            // frame hasn't landed yet. (Kept out of `??` — its right side is a
            // synchronous autoclosure and can't hold an `await`.)
            var frame = capture.grab()
            if frame == nil, let shot = try? await ChessScreen.capture() {
                frame = DesktopCapture.Frame(image: shot.image, origin: shot.origin, scale: shot.scale)
            }
            guard let frame, let cap = Self.encode(frame.image) else {
                finish("Couldn't capture the screen — is Screen Recording granted?"); return
            }
            status = "Step \(step) — looking at the screen…"

            // Read the real UI: the frontmost app's Accessibility tree gives us
            // exact elements and frames, so the model picks a real element by id
            // instead of guessing pixel coordinates. This is what makes it stop
            // click-looping. Falls back gracefully to pixels if AX is empty.
            // The target app — never Visor itself. If Visor is somehow frontmost
            // (you clicked its card), fall back to the topmost window behind it.
            var frontApp = NSWorkspace.shared.frontmostApplication
            if frontApp == nil || frontApp?.bundleIdentifier == Bundle.main.bundleIdentifier {
                frontApp = Self.topmostAppExcludingVisor()
            }
            let elements = (AXScanner.trusted && frontApp != nil)
                ? AXScanner.snapshot(pid: frontApp!.processIdentifier)
                : []
            let inBrowser = Self.isBrowser(frontApp?.bundleIdentifier)

            // No-progress detector: if the screen's elements are identical to
            // last step after we clicked/typed, that action did NOTHING — record
            // it so we can tell the model to stop repeating it. This is what
            // breaks the "click Sign Up 17 times" loop the hint alone couldn't.
            let sig = elements.map { "\($0.role)|\($0.label)" }.joined(separator: "\n")
            if let lastSig, lastSig == sig, let lastActed,
               lastActed.hasPrefix("Clicked") || lastActed.hasPrefix("Typed"),
               !ineffective.contains(lastActed) {
                ineffective.append(lastActed)
            }

            // Spot a stall and fold in the do-not-repeat list.
            var hints = [Self.stuckHint(history)].compactMap { $0 }
            if !ineffective.isEmpty {
                hints.append("These actions changed NOTHING and are dead ends — do NOT do them again: "
                    + ineffective.suffix(6).joined(separator: "; ")
                    + ". Try a DIFFERENT element, SCROLL to reveal more, or use a keyboard shortcut.")
            }
            // Repeated-target detector: the same click 3+ times is a loop even
            // when the page scrolled a little between tries (which defeats the
            // identical-screen check above). Common on marketing pages whose nav
            // links just scroll.
            let repeated = Self.repeatedTargets(history)
            if !repeated.isEmpty {
                hints.append("You have already tried these 3+ times and they are NOT working: "
                    + repeated.joined(separator: "; ")
                    + ". They are dead ends — STOP clicking them. Do something completely different: "
                    + "SCROLL down to look for a form, open a likely signup/login URL with open_url "
                    + "(e.g. an app./login. subdomain), or if there is genuinely no signup here, use fail.")
            }
            let hint = hints.isEmpty ? nil : hints.joined(separator: "\n")
            guard let action = await decide(instruction: instruction, png: cap.data,
                                            imageW: cap.w, imageH: cap.h,
                                            appName: frontApp?.localizedName,
                                            elements: elements,
                                            history: history, hint: hint, step: step) else {
                // A single empty/unparseable reply shouldn't end the whole task —
                // it's usually a transient hiccup. Retry a few times before
                // giving up.
                misses += 1
                if misses >= 4 { finish("The model kept returning nothing usable — stopped."); return }
                status = "Step \(step) — retrying…"
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            misses = 0
            if Task.isCancelled { break }

            switch action {
            case let .clickElement(eid):
                guard let node = elements.first(where: { $0.id == eid }) else {
                    note("Couldn't find element #\(eid) — it may have changed", &history); break
                }
                // In a browser, always use a real mouse click: AXPress on web
                // links/buttons frequently does NOT navigate. In native apps,
                // AXPress first (no mouse movement, works off-screen). Real
                // clicks go through clickThrough so they reach the page, not
                // Visor's own card sitting over the top of the screen.
                if inBrowser {
                    await clickThrough { DesktopActuator.click(at: node.center) }
                } else if !AXScanner.press(node) {
                    await clickThrough { DesktopActuator.click(at: node.center) }
                }
                note("Clicked \(Self.name(node))", &history)
            case let .typeElement(eid, t, submit):
                guard let node = elements.first(where: { $0.id == eid }) else {
                    note("Couldn't find element #\(eid) — it may have changed", &history); break
                }
                // Focus the field with a click, then type as real key events so
                // the app's search/handlers fire.
                await clickThrough { DesktopActuator.click(at: node.center) }
                try? await Task.sleep(nanoseconds: 160_000_000)
                DesktopActuator.type(t)
                if submit {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    DesktopActuator.key("return")
                }
                note("Typed \"\(t.prefix(30))\" into \(Self.name(node))\(submit ? " and pressed Return" : "")", &history)
            case let .click(x, y):
                let p = Self.map(x, y, ratio: cap.ratio, origin: frame.origin, scale: frame.scale)
                await clickThrough { DesktopActuator.click(at: p) }
                note("Clicked at (\(Int(x)), \(Int(y)))", &history)
            case let .doubleClick(x, y):
                let p = Self.map(x, y, ratio: cap.ratio, origin: frame.origin, scale: frame.scale)
                await clickThrough { DesktopActuator.doubleClick(at: p) }
                note("Double-clicked at (\(Int(x)), \(Int(y)))", &history)
            case let .type(t, submit):
                DesktopActuator.type(t)
                if submit {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    DesktopActuator.key("return")
                }
                note("Typed \"\(t.prefix(40))\"\(submit ? " and pressed Return" : "")", &history)
            case let .key(k):
                DesktopActuator.key(k)
                note("Pressed \(Self.keyLabel(k))", &history)
            case let .scroll(n):
                DesktopActuator.scroll(lines: n)
                note("Scrolled \(n > 0 ? "down" : "up")", &history)
            case let .openApp(name):
                Self.openApp(name)
                note("Opened \(name)", &history)
                // Apps take a beat to launch and come forward.
                try? await Task.sleep(nanoseconds: 1_100_000_000)
            case let .openURL(url):
                Self.openURL(url)
                note("Opened \(url)", &history)
                // The browser needs a moment to launch and load the page.
                try? await Task.sleep(nanoseconds: 1_400_000_000)
            case let .done(msg):
                finish(msg.isEmpty ? "Done." : "Done — \(msg)"); return
            case let .fail(msg):
                finish(msg.isEmpty ? "Couldn't finish this one." : "Couldn't finish — \(msg)"); return
            }
            // Remember what we just did and the screen it acted on, so next step
            // can tell whether it changed anything.
            trace?.action(step, history.last ?? "(no action)")
            lastActed = history.last
            lastSig = sig
            // Let the screen settle before the next look — longer in a browser,
            // where a click often triggers a page load.
            try? await Task.sleep(nanoseconds: inBrowser ? 900_000_000 : 550_000_000)
        }
        finish(Task.isCancelled ? "Stopped." : "Reached the \(maxSteps)-step limit.")
    }

    /// Post a synthetic pointer action with Visor's own overlay windows made
    /// click-through, so the click lands on the app underneath rather than on
    /// Visor's Computer Use card. The card floats at top-centre — right where a
    /// website's nav bar sits — so without this, clicks on top-of-page targets
    /// hit Visor and do nothing. Restored right after the event is hit-tested.
    private func clickThrough(_ body: () -> Void) async {
        let overlays = NSApp.windows.filter {
            $0.isVisible && $0.level.rawValue >= NSWindow.Level.floating.rawValue
        }
        overlays.forEach { $0.ignoresMouseEvents = true }
        body()
        try? await Task.sleep(nanoseconds: 140_000_000)
        overlays.forEach { $0.ignoresMouseEvents = false }
    }

    private func note(_ what: String, _ history: inout [String]) {
        history.append(what)
        log.append(what)
        status = "Working… (\(log.count))"
    }

    private func finish(_ message: String) {
        running = false
        task = nil
        trace?.finish(message)
        trace = nil
        status = message
    }

    /// A nudge when the recent actions show a stall — the same action repeated,
    /// or a run of clicks with nothing typed — so the model breaks out of the
    /// loop and searches instead of grinding on the same wrong target.
    private static func stuckHint(_ history: [String]) -> String? {
        let recent = Array(history.suffix(3))
        guard recent.count == 3 else { return nil }
        let allClicks = recent.allSatisfy { $0.hasPrefix("Clicked") || $0.hasPrefix("Double") }
        if Set(recent).count == 1 || allClicks {
            return "You're stuck — three actions with no progress. STOP repeating that. To reach a PERSON or conversation, open the quick-switcher / new-message (⌘K in Slack or Discord, ⌘N in Messages), TYPE the name, then press Return to open it — do NOT use message search (⌘F), which searches text, not people. If you already typed a query and nothing happened, press Return (or Down then Return) to pick the top result instead of clicking the search field again."
        }
        return nil
    }

    /// Targets clicked/typed 3+ times across the whole run, normalised so
    /// slightly different labels for the same thing collapse together. These are
    /// loops even when the page scrolled between tries.
    private static func repeatedTargets(_ history: [String]) -> [String] {
        func norm(_ s: String) -> String {
            String(s.lowercased().filter { $0 != "\"" }.prefix(26))
        }
        var counts: [String: (n: Int, label: String)] = [:]
        for h in history where h.hasPrefix("Clicked") || h.hasPrefix("Typed") {
            let key = norm(h)
            counts[key] = (( counts[key]?.n ?? 0) + 1, h)
        }
        return counts.values.filter { $0.n >= 3 }.map { $0.label }
    }

    /// The app owning the topmost on-screen normal window that isn't Visor —
    /// i.e. what's actually behind our card. Uses the window list because it's
    /// z-ordered front-to-back, unlike `runningApplications`.
    private static func topmostAppExcludingVisor() -> NSRunningApplication? {
        let mine = ProcessInfo.processInfo.processIdentifier
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for info in infos {
            guard let pidNum = info[kCGWindowOwnerPID as String] as? NSNumber else { continue }
            let pid = pidNum.int32Value
            if pid == mine { continue }
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            if layer != 0 { continue }   // normal window layer only (skip menus, HUDs)
            if let app = NSRunningApplication(processIdentifier: pid),
               app.activationPolicy == .regular {
                return app
            }
        }
        return nil
    }

    private static func isBrowser(_ bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        return ["safari", "chrome", "firefox", "edge", "arc", "brave", "thebrowser",
                "vivaldi", "opera", "orion"].contains { id.contains($0) }
    }

    /// A human-readable name for an element, for the step log.
    private static func name(_ node: AXScanner.Node) -> String {
        if !node.label.isEmpty { return "\"\(node.label)\"" }
        return node.role.hasPrefix("AX") ? String(node.role.dropFirst(2)).lowercased() : node.role
    }

    /// A key combo written the way a person reads it: ⌘K, Return, Esc.
    private static func keyLabel(_ k: String) -> String {
        let map = ["cmd": "⌘", "command": "⌘", "shift": "⇧", "opt": "⌥", "option": "⌥",
                   "alt": "⌥", "ctrl": "⌃", "control": "⌃", "return": "Return", "enter": "Return",
                   "escape": "Esc", "esc": "Esc", "tab": "Tab", "space": "Space"]
        return k.split(separator: "+").map { map[$0.lowercased()] ?? $0.uppercased() }.joined()
    }

    // MARK: Vision call

    private func decide(instruction: String, png: Data, imageW: Int, imageH: Int,
                        appName: String?, elements: [AXScanner.Node],
                        history: [String], hint: String?, step: Int) async -> Action? {
        guard let key = Keychain.get(OpenRouterClient.sharedKeyAccount) else { return nil }
        let system = """
        You operate a real macOS desktop to accomplish the user's task, one action \
        per turn.

        You are given: the frontmost app, a numbered list of that app's real, \
        interactive UI ELEMENTS read from macOS Accessibility (each has an id, a \
        role, and a label), and a screenshot for visual context \
        (\(imageW)×\(imageH) pixels, top-left origin).

        PREFER acting on elements by id — they are exact, so you never have to \
        guess coordinates. Reply with ONE JSON object and NOTHING else. Keep \
        "reason" to ONE short sentence so the action is never cut off, then the \
        action fields:
        {"reason":"...","action":"click","id":<id>}                    (click/press an element: buttons, links, results, fields)
        {"reason":"...","action":"type","id":<id>,"text":"...","submit":true}  (focus that field, type, and — if submit is true — press Return)
        {"reason":"...","action":"key","key":"cmd+k"}                   (also: return, tab, escape, cmd+a, cmd+c, cmd+v, cmd+f, cmd+n, up, down, left, right)
        {"reason":"...","action":"scroll","lines":<int, + down / - up>}
        {"reason":"...","action":"open","app":"Slack"}                 (launch/switch to an app — works across Spaces; prefer over hunting for it)
        {"reason":"...","action":"open_url","url":"https://..."}       (open a web address in the default browser)
        {"reason":"...","action":"done","summary":"..."}
        {"reason":"why it can't be done","action":"fail"}

        If — and only if — what you need is NOT in the element list, you may click \
        by pixel: {"reason":"...","action":"click","x":<int>,"y":<int>} on the \
        \(imageW)×\(imageH) screenshot (aim at the target's centre).

        Rules:
        - If the app you need isn't frontmost, your FIRST action is \
        {"action":"open","app":"<name>"}. Never give up because the wrong app shows.
        - FIND THINGS BY SEARCHING, NOT SCANNING. To reach a person, conversation, \
        file, message, or setting, use search, TYPE the name, then select the \
        result. Do not click around hoping to spot it.
        - TO MESSAGE / DM A PERSON, do EXACTLY these steps and do not click around:
          1) Open the quick-switcher with the KEY, not a click: \
        {"action":"key","key":"cmd+k"} (Slack/Discord) or "cmd+n" (Messages). Do \
        NOT pixel-click looking for a search box.
          2) Into the switcher field, type ONLY the person's NAME and submit: \
        {"action":"type","id":<field>,"text":"Ian","submit":true}. Type the NAME \
        here — NEVER the message text.
          3) That opens their conversation. Now type the MESSAGE into the message \
        input and send: {"action":"type","id":<message field>,"text":"<the message>","submit":true}.
          Keep them separate: the NAME goes in the switcher, the MESSAGE goes in \
        the message box. Never use message search (⌘F — it searches text, not people).
        - After typing a query, the result often does NOT appear as its own \
        element. If you typed and nothing changed, PRESS RETURN — do not click the \
        search field again.
        - PREFER keyboard shortcuts (key actions) and element ids over pixel \
        clicks. Only click by pixel x,y when there is no matching element AND no \
        shortcut — and NEVER pixel-click the same spot twice.
        - ON THE WEB: to go to a site use {"action":"open_url",...} — do NOT press \
        ⌘T or open tabs yourself. A click that leaves the element list unchanged \
        did nothing or the page is still loading: WAIT a step, or SCROLL down to \
        reveal the real control, or pick a DIFFERENT element — never click the \
        same label again. Sign-up / login / "Get started" buttons usually load a \
        NEW page; after clicking one, re-read before deciding, and if a form (name, \
        email, password fields) appears, fill THOSE.
        - Do ONE step per turn, then re-read the fresh element list.
        - Be DECISIVE: every turn output exactly one action that moves the task \
        forward. Never reply with only prose or a reason and no action, and never \
        just re-observe without acting.
        - When you have reached the target (e.g. the person's conversation is \
        open), DO THE NEXT REAL STEP immediately — click the message field, type \
        the message, press Return — don't stop to look again.
        - NEVER repeat an action that didn't change anything — pick a different \
        element or search instead.
        - Use "fail" only if the task is truly impossible.
        """
        let elementText = elements.isEmpty
            ? "(none read — Accessibility may be off; use the screenshot and pixel clicks)"
            : elements.map { e in
                let role = e.role.hasPrefix("AX") ? String(e.role.dropFirst(2)) : e.role
                let val = e.value.map { " = \"\($0.prefix(40))\"" } ?? ""
                return "[\(e.id)] \(role) \"\(e.label)\"\(val)"
            }.joined(separator: "\n")
        let historyText = history.isEmpty ? "(nothing yet)" : history.suffix(10).joined(separator: "\n")
        var userText = """
        Task: \(instruction)

        Frontmost app: \(appName ?? "unknown")

        Interactive elements (pick by id):
        \(elementText)

        Actions you've already taken:
        \(historyText)

        Give the next single action as JSON.
        """
        if let hint { userText += "\n\n⚠️ \(hint)" }
        let dataURI = "data:image/png;base64," + png.base64EncodedString()

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 700,
            "messages": [
                // Cache the big static system prompt so every turn after the
                // first reuses it instead of re-processing it — faster and cheaper.
                ["role": "system", "content": [
                    ["type": "text", "text": system, "cache_control": ["type": "ephemeral"]],
                ]],
                ["role": "user", "content": [
                    ["type": "text", "text": userText],
                    ["type": "image_url", "image_url": ["url": dataURI]],
                ]],
            ],
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            trace?.turn(step, png: png, appName: appName ?? "?", model: model,
                        elements: elementText, request: userText,
                        response: "(no response — network or decode error)")
            return nil
        }
        trace?.turn(step, png: png, appName: appName ?? "?", model: model,
                    elements: elementText, request: userText, response: content)
        return Self.parse(content)
    }

    // MARK: Parsing + geometry

    /// Pull the first complete JSON object out of the reply, brace-matched so a
    /// trailing example or prose (or the "reason" text's own braces) can't break
    /// it — the old first-`{`-to-last-`}` grab did. Tolerates ``` fences.
    private static func extractJSON(_ raw: String) -> [String: Any]? {
        let text = raw.replacingOccurrences(of: "```json", with: "")
                      .replacingOccurrences(of: "```", with: "")
        let chars = Array(text)
        guard let start = chars.firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, escaped = false, end: Int?
        for i in start..<chars.count {
            let c = chars[i]
            if escaped { escaped = false; continue }
            if c == "\\" { escaped = true; continue }
            if c == "\"" { inString.toggle(); continue }
            if inString { continue }
            if c == "{" { depth += 1 }
            else if c == "}" { depth -= 1; if depth == 0 { end = i; break } }
        }
        let slice: String
        if let end { slice = String(chars[start...end]) }
        else if let last = chars.lastIndex(of: "}"), last > start { slice = String(chars[start...last]) }
        else { return nil }
        guard let data = slice.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return o
    }

    private static func parse(_ text: String) -> Action? {
        guard let o = extractJSON(text),
              let action = (o["action"] as? String)?.lowercased()
        else { return nil }
        func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
        func d(_ k: String) -> Double { num(o[k]) ?? 0 }
        func elementID() -> Int? { (o["id"] as? NSNumber)?.intValue ?? (o["element"] as? NSNumber)?.intValue }
        func flag(_ k: String) -> Bool { (o[k] as? NSNumber)?.boolValue ?? (o[k] as? Bool) ?? false }
        // Coordinates in whatever shape the model used: x/y fields, or an
        // array under coordinate/point/etc. Missing coords → no click, rather
        // than the (0,0) corner it was hitting every time.
        func coords() -> (Double, Double)? {
            if let x = num(o["x"]), let y = num(o["y"]) { return (x, y) }
            for k in ["coordinate", "coordinates", "point", "pos", "xy", "location"] {
                if let a = o[k] as? [Any], a.count >= 2, let x = num(a[0]), let y = num(a[1]) {
                    return (x, y)
                }
            }
            return nil
        }
        switch action {
        case "open_url", "goto", "url", "navigate":
            let u = (o["url"] as? String) ?? (o["text"] as? String) ?? (o["app"] as? String) ?? ""
            return u.isEmpty ? nil : .openURL(u)
        case "open", "open_app", "launch":
            // A URL under "open" (models do this) goes to the browser.
            let name = (o["app"] as? String) ?? (o["name"] as? String) ?? (o["url"] as? String) ?? (o["text"] as? String) ?? ""
            let looksURL = name.contains("://") || name.hasPrefix("www.")
                || (name.contains(".") && !name.contains(" ") && !name.lowercased().hasSuffix(".app"))
            if looksURL { return .openURL(name) }
            return name.isEmpty ? nil : .openApp(name)
        case "click", "press", "tap":
            if let eid = elementID() { return .clickElement(eid) }
            guard let c = coords() else { return nil }; return .click(c.0, c.1)
        case "double_click":
            if let eid = elementID() { return .clickElement(eid) }
            guard let c = coords() else { return nil }; return .doubleClick(c.0, c.1)
        case "type":
            let text = (o["text"] as? String) ?? ""
            let submit = flag("submit") || flag("enter") || flag("press_return") || flag("return")
            if let eid = elementID() { return .typeElement(eid, text, submit) }
            return .type(text, submit)
        case "key":          return .key((o["key"] as? String) ?? "")
        case "scroll":       return .scroll(Int(d("lines")))
        case "done":         return .done((o["summary"] as? String) ?? "")
        case "fail":         return .fail((o["reason"] as? String) ?? "")
        default:             return nil
        }
    }

    /// Launch or switch to an app by name. Prefer this over clicking Dock/Finder
    /// icons — it works no matter which Space or app is currently in front.
    private static func openApp(_ name: String) {
        let ws = NSWorkspace.shared
        let clean = name.replacingOccurrences(of: ".app", with: "")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        // Already running? Just bring it forward.
        if let app = ws.runningApplications.first(where: {
            $0.localizedName?.caseInsensitiveCompare(clean) == .orderedSame
        }) {
            app.activate(options: [.activateIgnoringOtherApps])
            return
        }
        // Otherwise find the bundle in the usual places and launch it.
        for dir in ["/Applications", "/System/Applications",
                    ("~/Applications" as NSString).expandingTildeInPath] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(clean).app")
            if FileManager.default.fileExists(atPath: url.path) {
                ws.openApplication(at: url, configuration: config, completionHandler: nil)
                return
            }
        }
    }

    /// Open a web address in the user's default browser. Accepts bare hosts
    /// ("xyz.com") as well as full URLs.
    private static func openURL(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s) else { return }
        NSWorkspace.shared.open(url)
    }

    /// PNG of the capture, downscaled to a sane width, and the ratio from the
    /// scaled pixels the model sees back to the original image pixels.
    private static func encode(_ image: CGImage, maxWidth: CGFloat = 960)
        -> (data: Data, ratio: CGFloat, w: Int, h: Int)? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let ratio = w > maxWidth ? w / maxWidth : 1
        let outW = Int(w / ratio), outH = Int(h / ratio)
        guard let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        guard let scaled = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: scaled)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        return (data, ratio, outW, outH)
    }

    /// Model coordinates (scaled screenshot pixels) → a global screen point.
    private static func map(_ x: Double, _ y: Double, ratio: CGFloat,
                            origin: CGPoint, scale: CGFloat) -> CGPoint {
        let px = CGFloat(x) * ratio            // back to original image pixels
        let py = CGFloat(y) * ratio
        return CGPoint(x: origin.x + px / scale, y: origin.y + py / scale)
    }
}
