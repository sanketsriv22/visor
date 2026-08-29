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
    /// Dictation. Transcripts land in the draft rather than sending straight
    /// off, so a misheard word is editable before it costs a request.
    let voice = VoiceInput()
    private let client = OpenRouterClient()
    private unowned let ai: AIRunner
    private var streamTask: Task<Void, Never>?

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
        voice.onTranscript = { [weak self] text in
            guard let self else { return }
            // Appended, so dictation can extend something already typed.
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
        let system = Self.system(for: agent, recalled: memory.context(
            for: text, excluding: conversation.id))
        // Drop the empty assistant turn we just appended; the model gets the
        // history up to and including the question.
        let history = Array(conversation.messages.dropLast().suffix(Self.recentWindow))

        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await chunk in self.client.stream(
                    messages: history, model: model, system: system) {
                    self.appendToReply(chunk)
                }
                self.finish()
            } catch {
                self.fail(error)
            }
        }
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
           last.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            conversation.messages.removeLast()
        }
    }

    // MARK: - Prompt assembly

    private static func system(for agent: AIProvider, recalled: String?) -> String? {
        var parts: [String] = []
        if let persona = agent.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !persona.isEmpty {
            parts.append(persona)
        }
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
