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
        case click(Double, Double), doubleClick(Double, Double)
        case type(String), key(String), scroll(Int)
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
            guard let action = await decide(instruction: instruction, png: cap.data,
                                            imageW: cap.w, imageH: cap.h, history: history) else {
                finish("The model didn't return a usable action."); return
            }
            if Task.isCancelled { break }

            switch action {
            case let .click(x, y):
                DesktopActuator.click(at: Self.map(x, y, ratio: cap.ratio, origin: frame.origin, scale: frame.scale))
                note("click (\(Int(x)), \(Int(y)))", &history)
            case let .doubleClick(x, y):
                DesktopActuator.doubleClick(at: Self.map(x, y, ratio: cap.ratio, origin: frame.origin, scale: frame.scale))
                note("double-click (\(Int(x)), \(Int(y)))", &history)
            case let .type(t):
                DesktopActuator.type(t)
                note("type \"\(t.prefix(40))\"", &history)
            case let .key(k):
                DesktopActuator.key(k)
                note("key \(k)", &history)
            case let .scroll(n):
                DesktopActuator.scroll(lines: n)
                note("scroll \(n)", &history)
            case let .openApp(name):
                Self.openApp(name)
                note("open \(name)", &history)
                // Apps take a beat to launch and come forward.
                try? await Task.sleep(nanoseconds: 1_100_000_000)
            case let .openURL(url):
                Self.openURL(url)
                note("open \(url)", &history)
                // The browser needs a moment to launch and load the page.
                try? await Task.sleep(nanoseconds: 1_400_000_000)
            case let .done(msg):
                finish("Done — \(msg)"); return
            case let .fail(msg):
                finish("Gave up — \(msg)"); return
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

    // MARK: Vision call

    private func decide(instruction: String, png: Data, imageW: Int, imageH: Int,
                        history: [String]) async -> Action? {
        guard let key = Keychain.get(OpenRouterClient.sharedKeyAccount) else { return nil }
        let system = """
        You operate a real macOS desktop to accomplish the user's task. Each turn \
        you get a SCREENSHOT that is exactly \(imageW)×\(imageH) pixels, origin \
        top-left. Reply with ONE JSON object and NOTHING else — the single next \
        action:
        {"action":"open","app":"Slack"}   (launch or switch to an app by name — ALWAYS prefer this over clicking Dock/Finder icons)
        {"action":"open_url","url":"https://example.com"}   (open a web address in the default browser — use this for ANY website/URL task)
        {"action":"click","x":<int>,"y":<int>}
        {"action":"double_click","x":<int>,"y":<int>}
        {"action":"type","text":"..."}
        {"action":"key","key":"return"}   (also: tab, escape, cmd+a, cmd+c, cmd+v, cmd+space, up, down, left, right)
        {"action":"scroll","lines":<int, + = down, - = up>}
        {"action":"done","summary":"..."}
        {"action":"fail","reason":"..."}
        Rules:
        - x,y are PIXELS within this \(imageW)×\(imageH) image (not percentages, not 0–1).
        - If the app you need for the task is not clearly visible on screen, your \
        FIRST action must be {"action":"open","app":"<name>"} — do NOT click around \
        Finder or the Desktop hunting for it, and do NOT give up just because the \
        screen shows the wrong app.
        - To enter text you MUST first click the target field, then on the NEXT \
        turn use "type".
        - Do one small step per turn and re-check the new screenshot. Only use \
        "fail" if the task is truly impossible, never just because the current \
        screen isn't the app you want.
        """
        let historyText = history.isEmpty ? "(nothing yet)" : history.suffix(10).joined(separator: "\n")
        let userText = "Task: \(instruction)\n\nActions you've already taken:\n\(historyText)\n\nHere is the current screen. Give the next single action as JSON."
        let dataURI = "data:image/png;base64," + png.base64EncodedString()

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 300,
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

    private static func parse(_ text: String) -> Action? {
        // Pull the first {...} out of the reply, tolerating prose or code fences.
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = o["action"] as? String
        else { return nil }
        func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
        func d(_ k: String) -> Double { num(o[k]) ?? 0 }
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
        case "click":        guard let c = coords() else { return nil }; return .click(c.0, c.1)
        case "double_click": guard let c = coords() else { return nil }; return .doubleClick(c.0, c.1)
        case "type":         return .type((o["text"] as? String) ?? "")
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
