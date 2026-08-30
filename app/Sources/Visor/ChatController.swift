import Combine
import Foundation
import SwiftUI

/// Drives one conversation in the notch: composing, streaming, remembering it,
/// and writing it to disk.
@MainActor
final class ChatController: ObservableObject {
    /// The chat on screen. A conversation with no messages is a scratch chat
    /// and is never persisted, so opening the composer and closing it again
    /// doesn't litter the history with empties.
    @Published private(set) var conversation: Conversation
    @Published var draft = ""
    @Published private(set) var isStreaming = false
    /// Set when a send fails. Shown in the composer and cleared on the next
    /// attempt — this is the app's only channel for explaining itself.
    @Published private(set) var error: String?
    @Published var showingHistory = false

    let store: ChatStore
    let memory: KnowledgeBase
    /// Live model list, so the notch's picker offers everything the key can
    /// reach rather than a hard-coded handful.
    let catalog = ModelCatalog()
    /// Facts extracted from conversations, for recall by traversal rather than
    /// by similarity.
    let graph = KnowledgeGraph()
    /// Dictation. Transcripts land in the draft rather than sending straight
    /// off, so a misheard word is editable before it costs a request.
    let voice = VoiceInput()
    private let client = OpenRouterClient()
    private unowned let ai: AIRunner
    private var streamTask: Task<Void, Never>?
    private var agentObserver: AnyCancellable?
    /// Set by the notch controller: is the composer on screen right now?
    var isComposerVisible: (() -> Bool)?

    /// Recent turns sent verbatim. Older context arrives through recall
    /// instead, which is what keeps a long history from growing the bill on
    /// every single message.
    private static let recentWindow = 20

    /// What a new agent points at until the user picks a model. The Settings
    /// picker fetches the live list from OpenRouter, so this is only ever a
    /// starting point.
    static let defaultModel = "anthropic/claude-opus-5"

    init(ai: AIRunner, store: ChatStore = ChatStore(), memory: KnowledgeBase = KnowledgeBase()) {
        self.ai = ai
        self.store = store
        self.memory = memory
        self.conversation = Self.blank(agent: nil)
        self.conversation = Self.blank(agent: chatAgents.first)
        // Model, effort and fast are stored on the agent, which lives in
        // AIRunner — so changing one published from there and the composer,
        // which observes this object, never re-rendered. That's why the
        // controls looked dead.
        agentObserver = ai.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        voice.currentConversation = { [weak self] in self?.conversation.id }
        voice.onTranscript = { [weak self] text in
            guard let self else { return }
            // Only fill the composer when it's actually on screen. Dictating
            // with the notch shut is a note to self, not a message being
            // written — piling those into a draft you can't see means finding
            // ten unrelated utterances stacked up next time you open chat.
            // Either way it's already in the voice log.
            guard self.isComposerVisible?() ?? false else { return }
            self.draft = self.draft.isEmpty
                ? text
                : self.draft.trimmingCharacters(in: .whitespaces) + " " + text
        }
    }

    /// Start or stop dictating into the composer.
    func toggleDictation() { voice.toggle() }

    // MARK: - Agents

    /// Agents that answer in the notch, in config order.
    var chatAgents: [AIProvider] { ai.providers.filter(\.isChat) }

    /// The agent this conversation belongs to, falling back to the first
    /// configured one if it was renamed or deleted mid-chat.
    var agent: AIProvider? {
        chatAgents.first { $0.name == conversation.agentName } ?? chatAgents.first
    }

    /// Select the nth configured agent (⌘⇧1…5). Ignored when there aren't
    /// that many, so the shortcut is harmless rather than surprising.
    func useAgent(at index: Int) {
        guard chatAgents.indices.contains(index) else { return }
        use(chatAgents[index])
    }

    /// Models offered in the notch's picker: everything the key can reach,
    /// with the current choice guaranteed present even if it's been retired.
    var modelOptions: [String] {
        var ids = catalog.ids
        if let current = agent?.model, !ids.contains(current) { ids.insert(current, at: 0) }
        return ids
    }

    func loadModels() async { await catalog.loadIfNeeded() }

    /// Model id minus the vendor prefix — the full id doesn't fit in a notch.
    var shortModelName: String {
        let id = conversation.model.isEmpty ? Self.defaultModel : conversation.model
        return id.contains("/") ? String(id.split(separator: "/").last!) : id
    }

    /// Effort levels offered in the composer. Nil is "whatever the provider
    /// does by default", which is the right choice for models that don't
    /// reason at all.
    static let effortLevels: [String?] = [nil, "low", "medium", "high"]

    var effort: String? { agent?.effort }
    var isFast: Bool { agent?.fastMode ?? false }

    /// Whether the running model takes a reasoning setting at all.
    var supportsEffort: Bool { catalog.supportsReasoning(conversation.model) }

    func useEffort(_ level: String?) {
        guard var agent else { return }
        agent.effort = level
        ai.upsert(agent)
    }

    func toggleFast() {
        guard var agent else { return }
        agent.fastMode = !(agent.fastMode ?? false)
        ai.upsert(agent)
    }

    /// Point this agent (and this chat) at a different model.
    func useModel(_ id: String) {
        conversation.model = id
        if var agent {
            agent.model = id
            ai.upsert(agent)
        }
        if !conversation.messages.isEmpty { store.save(conversation) }
    }

    /// Switch the active agent. An in-progress chat keeps its history — the
    /// new agent simply answers the next turn.
    func use(_ agent: AIProvider) {
        conversation.agentName = agent.name
        conversation.model = agent.model ?? Self.defaultModel
        if !conversation.messages.isEmpty { store.save(conversation) }
    }

    // MARK: - Conversation lifecycle

    private static func blank(agent: AIProvider?) -> Conversation {
        Conversation(
            title: "",
            agentName: agent?.name ?? "",
            model: agent?.model ?? defaultModel)
    }

    func newChat() {
        stop()
        error = nil
        draft = ""
        conversation = Self.blank(agent: agent ?? chatAgents.first)
    }

    func open(_ id: UUID) {
        guard let chat = store.conversation(id) else { return }
        stop()
        error = nil
        conversation = chat
        showingHistory = false
    }

    func delete(_ id: UUID) {
        store.delete(id)
        memory.forget(conversation: id)   // "delete this chat" should actually forget it
        graph.forget(conversation: id)
        if conversation.id == id { newChat() }
    }

    @discardableResult
    func export(_ format: ChatStore.ExportFormat) -> URL? {
        guard !conversation.messages.isEmpty else { return nil }
        return try? store.export(conversation, as: format)
    }

    var markdown: String { ChatStore.markdown(conversation) }

    /// Start a chat pre-filled with a prompt — used when tasks are sent to a
    /// chat agent from the note, so the agent runs in the notch.
    func seed(prompt: String, agentName: String?) {
        newChat()
        if let agentName, let match = chatAgents.first(where: { $0.name == agentName }) {
            use(match)
        }
        draft = prompt
        send()
    }

    // MARK: - Sending

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        guard let agent else {
            error = "Add an agent in Settings first"
            return
        }
        guard OpenRouterClient.hasKey else {
            error = ChatError.noKey.localizedDescription
            NotificationCenter.default.post(
                name: .visorProviderNeedsKey, object: nil,
                userInfo: ["provider": agent.name])
            return
        }

        error = nil
        draft = ""

        let model = agent.model ?? Self.defaultModel
        let question = ChatMessage(role: .user, content: text)
        conversation.agentName = agent.name
        conversation.model = model
        conversation.messages.append(question)
        if conversation.title.isEmpty { conversation.title = Self.title(from: text) }

        // The empty assistant turn is what the view streams into.
        conversation.messages.append(ChatMessage(role: .assistant, content: "", model: model))
        isStreaming = true
        store.save(conversation)
        memory.index(question, in: conversation)

        // Recall runs against the question before the reply exists, and skips
        // this conversation — its recent turns are already going verbatim.
        let system = Self.system(
            for: agent,
            recalled: memory.context(for: text, excluding: conversation.id),
            known: graph.context(for: text))
        // Drop the empty assistant turn we just appended; the model gets the
        // history up to and including the question.
        let history = Array(conversation.messages.dropLast().suffix(Self.recentWindow))
        let effort = agent.effort
        let fast = agent.fastMode ?? false

        streamTask = Task { [weak self] in
            guard let self else { return }
            await self.runTurn(model: model, system: system, effort: effort,
                               fast: fast, round: 0)
        }
    }

    /// How many times a single send may hand control back to the model after
    /// running tools. A model that keeps calling tools without concluding
    /// would otherwise loop until the user's credit ran out.
    private static let maxToolRounds = 6

    /// Stream one assistant turn, run any tools it asked for, and — if it did —
    /// go round again so it can use the results.
    private func runTurn(model: String, system: String?, effort: String?,
                         fast: Bool, round: Int) async {
        do {
            // The assistant turn being streamed into is already appended, so
            // history stops before it.
            let history = Array(conversation.messages.dropLast().suffix(Self.recentWindow * 2))

            for try await event in client.stream(
                messages: history, model: model, system: system,
                effort: effort, fast: fast, tools: ToolRegistry.shared.schemas) {
                switch event {
                case .text(let chunk):
                    appendToReply(chunk)
                case .toolCalls(let calls):
                    attachToolCalls(calls)
                }
            }
        } catch {
            fail(error)
            return
        }

        guard let last = conversation.messages.last, last.role == .assistant,
              let calls = last.toolCalls, !calls.isEmpty else {
            finish()
            return
        }

        guard round < Self.maxToolRounds else {
            // Say so in the transcript rather than stopping silently — a turn
            // that just ends looks like a bug.
            conversation.messages.append(ChatMessage(
                role: .assistant,
                content: "_Stopped after \(Self.maxToolRounds) rounds of tool calls._",
                model: model))
            finish()
            return
        }

        for call in calls {
            let result = await ToolRegistry.shared.run(call)
            conversation.messages.append(ChatMessage(
                role: .tool, content: result, toolCallID: call.id))
        }
        store.save(conversation)

        // Fresh assistant turn for the model's response to the results.
        conversation.messages.append(ChatMessage(role: .assistant, content: "", model: model))
        await runTurn(model: model, system: system, effort: effort,
                      fast: fast, round: round + 1)
    }

    private func attachToolCalls(_ calls: [ToolCall]) {
        guard let last = conversation.messages.indices.last,
              conversation.messages[last].role == .assistant else { return }
        conversation.messages[last].toolCalls = calls
    }

    /// Cancel an in-flight reply. Cancelling the task tears down the URLSession
    /// request too, so a stopped reply stops being billed.
    func stop() {
        streamTask?.cancel()
        streamTask = nil
        guard isStreaming else { return }
        isStreaming = false
        trimEmptyReply()
    }

    // MARK: - Streaming plumbing

    private func appendToReply(_ chunk: String) {
        guard let last = conversation.messages.indices.last,
              conversation.messages[last].role == .assistant else { return }
        conversation.messages[last].content += chunk
    }

    private func finish() {
        isStreaming = false
        streamTask = nil
        trimEmptyReply()
        guard let reply = conversation.messages.last, reply.role == .assistant,
              !reply.content.isEmpty else { return }
        store.save(conversation)
        memory.index(reply, in: conversation)

        // After the reply lands, never during it: extraction is a second
        // request and must not delay what the user is reading.
        let exchange = Array(conversation.messages.suffix(4))
        let id = conversation.id
        let client = self.client
        Task { [weak self] in
            await self?.graph.learn(from: exchange, conversation: id, client: client)
        }
    }

    private func fail(_ error: Error) {
        isStreaming = false
        streamTask = nil
        self.error = (error as? ChatError)?.localizedDescription ?? error.localizedDescription
        trimEmptyReply()
        if !conversation.messages.isEmpty { store.save(conversation) }
    }

    /// A reply that never produced a token would otherwise persist as a blank
    /// bubble.
    private func trimEmptyReply() {
        if let last = conversation.messages.last, last.role == .assistant,
           last.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           // An empty turn that carries tool calls is doing work, not nothing.
           (last.toolCalls?.isEmpty ?? true) {
            conversation.messages.removeLast()
        }
    }

    // MARK: - Prompt assembly

    private static func system(for agent: AIProvider, recalled: String?,
                               known: String?) -> String? {
        var parts: [String] = []
        if let persona = agent.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !persona.isEmpty {
            parts.append(persona)
        }
        // Facts first: they're compact and specific, where recalled excerpts
        // are long and only maybe relevant.
        if let known { parts.append(known) }
        if let recalled { parts.append(recalled) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// A chat's title is its first question, shortened at a word boundary.
    /// Deriving it costs nothing and is instant; asking a model to name the
    /// chat would add a round trip before the first reply even renders.
    private static func title(from text: String) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > 48 else { return flat.isEmpty ? "New chat" : flat }
        let clipped = flat.prefix(48)
        if let space = clipped.lastIndex(of: " ") {
            return String(clipped[clipped.startIndex..<space]) + "…"
        }
        return String(clipped) + "…"
    }
}
