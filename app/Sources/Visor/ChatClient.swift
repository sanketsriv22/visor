import Foundation

/// A tool the model asked us to run.
struct ToolCall: Codable, Equatable, Hashable, Identifiable {
    /// The provider's id, echoed back so it can match the result to the call.
    var id: String
    var name: String
    /// Raw JSON, kept as a string because it arrives in fragments and is only
    /// complete once the stream ends.
    var arguments: String

    var decodedArguments: [String: Any] {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }
}

/// One turn in a conversation. Persisted verbatim, so this is also the on-disk
/// shape of a stored chat.
struct ChatMessage: Codable, Identifiable, Equatable, Hashable {
    enum Role: String, Codable { case system, user, assistant, tool }

    var id: UUID = UUID()
    var role: Role
    var content: String
    var createdAt: Date = Date()
    /// Which model produced an assistant turn. Nil for user turns, and for
    /// assistant turns from before this was recorded.
    var model: String?
    /// Tools the model wants run, on an assistant turn.
    var toolCalls: [ToolCall]?
    /// Which call this turn is the result of, on a tool turn.
    var toolCallID: String?
    /// Set while the user is being asked whether to allow a call.
    var awaitingApproval: Bool?
}

/// A failure worth showing a user. Every case is phrased as something they can
/// act on, because these strings land directly in the composer — the app has no
/// second place to explain itself.
enum ChatError: LocalizedError, Equatable {
    case noKey
    case http(status: Int, body: String?)
    case transport(String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .noKey:
            return "Add your OpenRouter key in Settings"
        case .http(401, _), .http(403, _):
            return "OpenRouter rejected that key — check it in Settings"
        case .http(402, _):
            return "OpenRouter says this account is out of credit"
        case .http(429, _):
            return "Rate limited by OpenRouter — try again in a moment"
        case .http(let status, let body):
            // OpenRouter puts a human-readable reason in the body; prefer it.
            if let body, !body.isEmpty { return "OpenRouter error \(status): \(body)" }
            return "OpenRouter error \(status)"
        case .transport(let message):
            return message
        case .malformedResponse:
            return "Couldn't read OpenRouter's response"
        }
    }
}

/// A model offered by OpenRouter, as listed by `/models`.
struct ORModel: Codable, Identifiable, Hashable {
    struct Pricing: Codable, Hashable {
        var prompt: String?
        var completion: String?
    }

    var id: String
    var name: String?
    var context_length: Int?
    var pricing: Pricing?
    /// What this model accepts — "reasoning", "tools", "temperature", and so
    /// on. OpenRouter publishes this per model, which is how the composer can
    /// hide controls a model can't use instead of showing dead ones.
    var supported_parameters: [String]?
    /// What the model can take in — OpenRouter reports "text", "image", etc.
    /// under architecture.input_modalities. Optional so models without it (and
    /// older cached decodes) decode unchanged.
    struct Architecture: Codable, Hashable {
        var input_modalities: [String]?
    }
    var architecture: Architecture?

    var supportsReasoning: Bool { supported_parameters?.contains("reasoning") ?? false }
    var supportsTools: Bool { supported_parameters?.contains("tools") ?? false }
    var supportsVision: Bool { architecture?.input_modalities?.contains("image") ?? false }

    /// What to show in a picker.
    var label: String { name ?? id }

    /// Prompt price in dollars per million tokens, when OpenRouter reports it.
    /// The API gives dollars per *token* as a string.
    var promptPerMillion: Double? {
        guard let p = pricing?.prompt, let v = Double(p) else { return nil }
        return v * 1_000_000
    }

    /// Completion price in dollars per million tokens, same source and units.
    var completionPerMillion: Double? {
        guard let c = pricing?.completion, let v = Double(c) else { return nil }
        return v * 1_000_000
    }
}

/// Talks to OpenRouter's OpenAI-compatible chat API.
///
/// OpenRouter is the one backend here because it fans out to essentially every
/// model behind a single key and a single request shape — adding Anthropic,
/// OpenAI or Google directly would mean three more auth flows and three more
/// response formats for no capability the user doesn't already have.
final class OpenRouterClient {
    /// Every OpenRouter-backed agent shares one key, so the user pastes it
    /// once no matter how many agents they name.
    static let sharedKeyAccount = "OpenRouter"

    private static let base = "https://openrouter.ai/api/v1"
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// The stored key, or nil if the user hasn't added one.
    static var key: String? {
        guard let k = Keychain.get(sharedKeyAccount)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !k.isEmpty else { return nil }
        return k
    }

    static var hasKey: Bool { key != nil }

    private func request(path: String, method: String = "POST") throws -> URLRequest {
        guard let key = Self.key else { throw ChatError.noKey }
        guard let url = URL(string: Self.base + path) else { throw ChatError.malformedResponse }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // OpenRouter attributes requests to an app with these; they show up on
        // the account's activity page, which makes a stray key easy to spot.
        req.setValue("https://kitalabs.com/visor", forHTTPHeaderField: "HTTP-Referer")
        req.setValue("Visor", forHTTPHeaderField: "X-Title")
        return req
    }

    private func body(messages: [ChatMessage], model: String, system: String?,
                      temperature: Double?, stream: Bool,
                      effort: String? = nil, fast: Bool = false,
                      tools: [[String: Any]] = []) -> [String: Any] {
        var wire: [[String: Any]] = []
        if let system, !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            wire.append(["role": "system", "content": system])
        }
        for message in messages {
            var entry: [String: Any] = ["role": message.role.rawValue,
                                        "content": message.content]
            if let calls = message.toolCalls, !calls.isEmpty {
                entry["tool_calls"] = calls.map { call in
                    ["id": call.id, "type": "function",
                     "function": ["name": call.name, "arguments": call.arguments]]
                }
            }
            // A tool result is only matched to its call by this id; without it
            // the provider rejects the whole request.
            if let id = message.toolCallID { entry["tool_call_id"] = id }
            wire.append(entry)
        }

        var body: [String: Any] = ["model": model, "messages": wire, "stream": stream]
        // Asked for explicitly, or the streaming response never mentions it.
        // It arrives as a final chunk with an empty `choices`, which is why
        // the parser has to look for it before it looks for a delta.
        body["usage"] = ["include": true]
        if let temperature { body["temperature"] = temperature }
        // Reasoning effort is ignored by models that don't reason, so it's
        // safe to send whenever the user has picked one.
        if let effort { body["reasoning"] = ["effort": effort] }
        // OpenRouter serves most models from several providers at different
        // speeds and prices; by default it optimises for price. This asks for
        // the fastest one instead.
        if fast { body["provider"] = ["sort": "throughput"] }
        if !tools.isEmpty { body["tools"] = tools }
        return body
    }

    /// Stream a completion, yielding content deltas as they arrive.
    ///
    /// Streaming rather than awaiting the whole reply is what makes the notch
    /// feel like a native surface instead of a form submission — the first
    /// token lands in a few hundred milliseconds.
    /// What a streamed response can produce.
    enum StreamEvent {
        case text(String)
        /// Emitted once, at the end, when the model wants tools run.
        case toolCalls([ToolCall])
        /// Tokens and cost for the request, as the provider accounts for them.
        case usage(tokensIn: Int, tokensOut: Int, costUSD: Double?)
    }

    func stream(messages: [ChatMessage], model: String, system: String? = nil,
                temperature: Double? = nil, effort: String? = nil,
                fast: Bool = false,
                tools: [[String: Any]] = []) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = try request(path: "/chat/completions")
                    req.httpBody = try JSONSerialization.data(
                        withJSONObject: body(messages: messages, model: model, system: system,
                                             temperature: temperature, stream: true,
                                             effort: effort, fast: fast, tools: tools))

                    let (bytes, response) = try await session.bytes(for: req)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        // The error body streams too; collect enough to explain.
                        var detail = ""
                        for try await line in bytes.lines where detail.count < 600 {
                            detail += line
                        }
                        throw ChatError.http(status: http.statusCode, body: Self.reason(from: detail))
                    }

                    // Tool calls stream in fragments: the id and name arrive
                    // once, then the arguments accumulate across many deltas,
                    // keyed by index. Nothing is usable until the stream ends.
                    var pending: [Int: ToolCall] = [:]

                    for try await line in bytes.lines {
                        // Server-sent events: payload lines start with "data: ";
                        // everything else (comments, blank keep-alives) is noise.
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        // Before the delta check: the usage chunk carries an
                        // empty `choices`, so looking for a delta first would
                        // skip straight past it.
                        if let report = obj["usage"] as? [String: Any] {
                            continuation.yield(.usage(
                                tokensIn: report["prompt_tokens"] as? Int ?? 0,
                                tokensOut: report["completion_tokens"] as? Int ?? 0,
                                costUSD: report["cost"] as? Double))
                        }

                        guard let choices = obj["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any]
                        else { continue }

                        if let chunk = delta["content"] as? String, !chunk.isEmpty {
                            continuation.yield(.text(chunk))
                        }

                        guard let calls = delta["tool_calls"] as? [[String: Any]] else { continue }
                        for call in calls {
                            let index = call["index"] as? Int ?? 0
                            var entry = pending[index] ?? ToolCall(id: "", name: "", arguments: "")
                            if let id = call["id"] as? String, !id.isEmpty { entry.id = id }
                            if let function = call["function"] as? [String: Any] {
                                if let name = function["name"] as? String, !name.isEmpty {
                                    entry.name = name
                                }
                                if let fragment = function["arguments"] as? String {
                                    entry.arguments += fragment
                                }
                            }
                            pending[index] = entry
                        }
                    }

                    if !pending.isEmpty {
                        let calls = pending.sorted { $0.key < $1.key }
                            .map(\.value)
                            .filter { !$0.name.isEmpty }
                        if !calls.isEmpty { continuation.yield(.toolCalls(calls)) }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as ChatError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: ChatError.transport(error.localizedDescription))
                }
            }
            // Stopping a reply mid-flight has to actually cancel the request,
            // or the tokens keep being billed.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Non-streaming completion, for short internal calls (titling a chat,
    /// summarising for memory) where partial output is useless.
    func complete(messages: [ChatMessage], model: String, system: String? = nil,
                  temperature: Double? = nil, fast: Bool = false,
                  maxTokens: Int? = nil) async throws -> String {
        var req = try request(path: "/chat/completions")
        var payload = body(messages: messages, model: model, system: system,
                           temperature: temperature, stream: false, fast: fast)
        // A ceiling on a rewrite task is a safety net, not a tuning knob: it
        // caps the damage when a model decides to answer the text instead of
        // correcting it.
        if let maxTokens { payload["max_tokens"] = maxTokens }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ChatError.http(status: http.statusCode,
                                 body: Self.reason(from: String(data: data, encoding: .utf8) ?? ""))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else { throw ChatError.malformedResponse }
        return content
    }

    /// The models this key can reach. Sorted by label so the picker is stable.
    func models() async throws -> [ORModel] {
        var req = try request(path: "/models", method: "GET")
        req.httpBody = nil
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ChatError.http(status: http.statusCode,
                                 body: Self.reason(from: String(data: data, encoding: .utf8) ?? ""))
        }
        struct Envelope: Codable { let data: [ORModel] }
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw ChatError.malformedResponse
        }
        return env.data.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    /// Pull the human-readable reason out of an error body, falling back to the
    /// raw text. OpenRouter nests it as `{"error": {"message": "…"}}`.
    private static func reason(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return body.isEmpty ? nil : String(body.prefix(300)) }
        if let error = obj["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        if let message = obj["message"] as? String { return message }
        return String(body.prefix(300))
    }
}
