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

    /// A vision-capable model; the user can change it, but this reads the
    /// screenshot, so it must accept images.
    var model = "anthropic/claude-sonnet-5"
    let maxSteps = 25

    private var task: Task<Void, Never>?
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
        var history: [String] = []
        var misses = 0   // consecutive turns with no usable action

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
            let frontApp = NSWorkspace.shared.frontmostApplication
            let elements = (AXScanner.trusted && frontApp != nil)
                ? AXScanner.snapshot(pid: frontApp!.processIdentifier)
                : []

            // Spot a stall: the same action three times running, or a run of
            // clicks with no typing, means it's flailing rather than making
            // progress — tell it to change tack instead of repeating itself.
            let hint = Self.stuckHint(history)
            guard let action = await decide(instruction: instruction, png: cap.data,
                                            imageW: cap.w, imageH: cap.h,
                                            appName: frontApp?.localizedName,
                                            elements: elements,
                                            history: history, hint: hint) else {
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
                // Press by reference when we can (no mouse movement, more
                // reliable); otherwise click its centre.
                if !AXScanner.press(node) { DesktopActuator.click(at: node.center) }
                note("Clicked \(Self.name(node))", &history)
            case let .typeElement(eid, t, submit):
                guard let node = elements.first(where: { $0.id == eid }) else {
                    note("Couldn't find element #\(eid) — it may have changed", &history); break
                }
                // Focus the field with a click, then type as real key events so
                // the app's search/handlers fire.
                DesktopActuator.click(at: node.center)
                try? await Task.sleep(nanoseconds: 160_000_000)
                DesktopActuator.type(t)
                if submit {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    DesktopActuator.key("return")
                }
                note("Typed \"\(t.prefix(30))\" into \(Self.name(node))\(submit ? " and pressed Return" : "")", &history)
            case let .click(x, y):
                DesktopActuator.click(at: Self.map(x, y, ratio: cap.ratio, origin: frame.origin, scale: frame.scale))
                note("Clicked at (\(Int(x)), \(Int(y)))", &history)
            case let .doubleClick(x, y):
                DesktopActuator.doubleClick(at: Self.map(x, y, ratio: cap.ratio, origin: frame.origin, scale: frame.scale))
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
            // A short beat for the screen to settle before the next look.
            try? await Task.sleep(nanoseconds: 450_000_000)
        }
        finish(Task.isCancelled ? "Stopped." : "Reached the \(maxSteps)-step limit.")
    }

    private func note(_ what: String, _ history: inout [String]) {
        history.append(what)
        log.append(what)
        status = "Working… (\(log.count))"
    }

    private func finish(_ message: String) {
        running = false
        task = nil
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
                        history: [String], hint: String?) async -> Action? {
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
        - TO MESSAGE / DM A PERSON (Slack, Discord, Teams, Messages): open the \
        quick-switcher or new-message compose — usually ⌘K (Slack/Discord) or ⌘N \
        (Messages) — NOT the message-search box (⌘F searches text, not people). \
        Then type the person's name and PRESS RETURN (or Down then Return) to open \
        the conversation with the top match — do not wait for a clickable result. \
        Then click the message input, type the message, and press Return to send. \
        The fastest form is {"action":"type","id":<search field>,"text":"<name>","submit":true}.
        - After typing a query, the result often does NOT appear as its own \
        element. If you typed and nothing changed, PRESS RETURN — do not click the \
        search field again.
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
                ["role": "system", "content": system],
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
        else { return nil }
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
    private static func encode(_ image: CGImage, maxWidth: CGFloat = 1200)
        -> (data: Data, ratio: CGFloat, w: Int, h: Int)? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let ratio = w > maxWidth ? w / maxWidth : 1
        let outW = Int(w / ratio), outH = Int(h / ratio)
        guard let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
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
