import Foundation
import WebKit

/// Something an agent can do, beyond answering.
///
/// Deliberately small: a name, a JSON-schema description the model reads, and
/// a function. Anything more elaborate belongs in the tool, not the protocol.
@MainActor
protocol VisorTool {
    var name: String { get }
    var description: String { get }
    /// JSON Schema for the arguments, as the provider expects it.
    var parameters: [String: Any] { get }
    /// Whether running this without asking could cost money, change something
    /// outside Visor, or otherwise not be undoable.
    var needsApproval: Bool { get }
    func run(_ arguments: [String: Any]) async throws -> String
}

extension VisorTool {
    var needsApproval: Bool { false }

    /// The shape the chat API wants in its `tools` array.
    var schema: [String: Any] {
        ["type": "function",
         "function": ["name": name, "description": description, "parameters": parameters]]
    }
}

/// A tool defined inline, for the ones that are a closure over app state.
@MainActor
struct ClosureTool: VisorTool {
    let name: String
    let description: String
    let parameters: [String: Any]
    var needsApproval: Bool = false
    let body: ([String: Any]) async throws -> String

    func run(_ arguments: [String: Any]) async throws -> String {
        try await body(arguments)
    }
}

/// What the app offers its agents.
///
/// A registry rather than a hard-coded list so tools can be contributed by
/// whoever owns the state they touch — the note tools are registered by the
/// controller that owns the note store, instead of that store being reached
/// for from here.
@MainActor
final class ToolRegistry: ObservableObject {
    static let shared = ToolRegistry()

    private(set) var tools: [String: VisorTool] = [:]

    private init() {
        register(FetchURLTool())
    }

    func register(_ tool: VisorTool) {
        tools[tool.name] = tool
    }

    /// Schemas for the request. Sorted so the prompt prefix stays stable
    /// between turns, which matters for caching.
    var schemas: [[String: Any]] {
        tools.keys.sorted().compactMap { tools[$0]?.schema }
    }

    /// Run a call and return whatever the model should see. Errors come back
    /// as text rather than throwing: a failed tool is information the model
    /// can act on, where a thrown error would end the turn.
    func run(_ call: ToolCall) async -> String {
        guard let tool = tools[call.name] else {
            return "No tool named \(call.name)."
        }
        do {
            return try await tool.run(call.decodedArguments)
        } catch {
            return "\(call.name) failed: \(error.localizedDescription)"
        }
    }
}

/// Read a web page as text.
///
/// WKWebView rather than a plain fetch: most pages worth reading render their
/// content with JavaScript, so an HTTP GET returns an empty shell. This also
/// avoids a browser-automation dependency — no npm, no Playwright, nothing to
/// install — at the cost of being read-only for now. Clicking and filling
/// comes later, and needs an approval gate first.
@MainActor
final class FetchURLTool: NSObject, VisorTool, WKNavigationDelegate {
    let name = "fetch_url"
    let description = """
        Load a web page and return its visible text. Use this to look something \
        up, check a page, or read documentation. Returns text only — it cannot \
        click, fill forms, or log in.
        """
    let parameters: [String: Any] = [
        "type": "object",
        "properties": [
            "url": ["type": "string", "description": "The full URL, including https://"],
        ],
        "required": ["url"],
        "additionalProperties": false,
    ]

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeout: DispatchWorkItem?

    enum FetchError: LocalizedError {
        case badURL, timedOut, empty
        var errorDescription: String? {
            switch self {
            case .badURL:   return "That isn't a URL I can load"
            case .timedOut: return "The page took too long to load"
            case .empty:    return "The page loaded but had no readable text"
            }
        }
    }

    func run(_ arguments: [String: Any]) async throws -> String {
        guard let raw = arguments["url"] as? String,
              let url = URL(string: raw.trimmingCharacters(in: .whitespaces)),
              url.scheme?.hasPrefix("http") == true
        else { throw FetchError.badURL }

        let config = WKWebViewConfiguration()
        let view = WKWebView(frame: .init(x: 0, y: 0, width: 1280, height: 2000),
                             configuration: config)
        view.navigationDelegate = self
        webView = view

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            continuation = c
            // A page that never finishes loading would otherwise hang the turn
            // forever; 20s is generous for reading.
            let work = DispatchWorkItem { [weak self] in self?.resume(throwing: FetchError.timedOut) }
            timeout = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
            view.load(URLRequest(url: url))
        }

        // innerText rather than the HTML: the model wants what a reader sees,
        // and the markup is mostly tokens it has to pay for and ignore.
        let text = try await view.evaluateJavaScript(
            "document.body ? document.body.innerText : ''") as? String ?? ""
        webView = nil

        let cleaned = text
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw FetchError.empty }

        // Enough to answer from without spending the context window on one page.
        let limit = 12_000
        guard cleaned.count > limit else { return cleaned }
        return String(cleaned.prefix(limit)) + "\n\n[truncated]"
    }

    private func resume(throwing error: Error?) {
        timeout?.cancel()
        timeout = nil
        guard let c = continuation else { return }
        continuation = nil
        if let error { c.resume(throwing: error) } else { c.resume() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resume(throwing: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        resume(throwing: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        resume(throwing: error)
    }
}
