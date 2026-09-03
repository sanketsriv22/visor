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
        for step in 1...maxSteps {
            if Task.isCancelled { break }
            guard let shot = try? await ChessScreen.capture(),
                  let (png, ratio) = Self.encode(shot.image) else {
                finish("Couldn't capture the screen — is Screen Recording granted?"); return
            }
            status = "Step \(step): looking…"
            guard let action = await decide(instruction: instruction, png: png,
                                            history: history) else {
                finish("The model didn't return a usable action."); return
            }
            if Task.isCancelled { break }

            switch action {
            case let .click(x, y):
                DesktopActuator.click(at: Self.map(x, y, ratio: ratio, shot: shot))
                note("click (\(Int(x)), \(Int(y)))", &history)
            case let .doubleClick(x, y):
                DesktopActuator.doubleClick(at: Self.map(x, y, ratio: ratio, shot: shot))
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
            case let .done(msg):
                finish("Done — \(msg)"); return
            case let .fail(msg):
                finish("Gave up — \(msg)"); return
            }
            // Let the screen settle before the next look.
            try? await Task.sleep(nanoseconds: 900_000_000)
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

    private func decide(instruction: String, png: Data, history: [String]) async -> Action? {
        guard let key = Keychain.get(OpenRouterClient.sharedKeyAccount) else { return nil }
        let system = """
        You control a macOS screen to accomplish the user's task. You are shown a \
        screenshot. Reply with ONE JSON object and nothing else, choosing the single \
        next action:
        {"action":"click","x":<px>,"y":<px>} — coordinates in screenshot pixels
        {"action":"double_click","x":<px>,"y":<px>}
        {"action":"type","text":"..."} — types at the current focus
        {"action":"key","key":"return|tab|escape|cmd+a|..."}
        {"action":"scroll","lines":<+down/-up>}
        {"action":"done","summary":"..."} — the task is complete
        {"action":"fail","reason":"..."} — it can't be done
        Take one small step at a time. Click a field before typing into it.
        """
        let historyText = history.isEmpty ? "(none yet)" : history.suffix(8).joined(separator: "\n")
        let userText = "Task: \(instruction)\n\nActions so far:\n\(historyText)\n\nThe screenshot follows. Give the next action as JSON."
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
        func d(_ k: String) -> Double { (o[k] as? Double) ?? Double(o[k] as? Int ?? 0) }
        switch action {
        case "click":        return .click(d("x"), d("y"))
        case "double_click": return .doubleClick(d("x"), d("y"))
        case "type":         return .type((o["text"] as? String) ?? "")
        case "key":          return .key((o["key"] as? String) ?? "")
        case "scroll":       return .scroll(Int(d("lines")))
        case "done":         return .done((o["summary"] as? String) ?? "")
        case "fail":         return .fail((o["reason"] as? String) ?? "")
        default:             return nil
        }
    }

    /// PNG of the capture, downscaled to a sane width, and the ratio from the
    /// scaled pixels the model sees back to the original image pixels.
    private static func encode(_ image: CGImage, maxWidth: CGFloat = 1400) -> (Data, CGFloat)? {
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
        return (data, ratio)
    }

    /// Model coordinates (scaled screenshot pixels) → a global screen point.
    private static func map(_ x: Double, _ y: Double, ratio: CGFloat,
                            shot: ChessScreen.Shot) -> CGPoint {
        let px = CGFloat(x) * ratio            // back to original image pixels
        let py = CGFloat(y) * ratio
        return CGPoint(x: shot.origin.x + px / shot.scale,
                       y: shot.origin.y + py / shot.scale)
    }
}
