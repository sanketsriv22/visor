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
    /// Where the reader is in the transcript, shared by the notch card and the
    /// HUD so a surface change lands on the same message. Not published: the
    /// transcript writes these on every scroll and nothing else needs to
    /// re-render for it.
    var transcriptFollowing = true
    var readingAnchor: UUID?
    /// A tool run waiting on the user. While this is set the turn is paused —
    /// nothing runs and no request is in flight.
    @Published private(set) var pendingApproval: PendingApproval?

    /// Everything needed to resume a turn once the user decides.
    struct PendingApproval: Equatable {
        let calls: [ToolCall]
        let needing: [ToolCall]
        let model: String
        let system: String?
        let effort: String?
        let fast: Bool
        let round: Int
    }

    let store: ChatStore
    let memory: KnowledgeBase
    /// Live model list, so the notch's picker offers everything the key can
    /// reach rather than a hard-coded handful.
    let catalog = ModelCatalog()
    /// Facts extracted from conversations, for recall by traversal rather than
    /// by similarity.
    let graph: KnowledgeGraph
    /// True for a fixture (the Design Lab): no model catalogue fetch, no
    /// network at all.
    var offline = false
    /// Dictation. Transcripts land in the draft rather than sending straight
    /// off, so a misheard word is editable before it costs a request.
    let voice = VoiceInput()
    private let client = OpenRouterClient()
    private unowned let ai: AIRunner
    private var streamTask: Task<Void, Never>?
    private var agentObserver: AnyCancellable?
    private var storeObserver: AnyCancellable?
    private var graphObserver: AnyCancellable?
    private var cliRunner: CLIAgentRunner?
    /// Set by the notch controller: is the composer on screen right now?
    var isComposerVisible: (() -> Bool)?

    /// Send one task line to the default agent — the same thing the notch's
    /// task rows do, exposed here so the HUD's task rail can reach it without
    /// threading the AIRunner through every view between them.
    func sendTaskToDefault(_ text: String, id: UUID) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        ai.sendToDefault(tasks: [t], taskIDs: [id])
    }

    /// Whether a task line the rail sent is still running.
    func isSendingTask(_ id: UUID) -> Bool { ai.isRunning(id) }

    /// Recent turns sent verbatim. Older context arrives through recall
    /// instead, which is what keeps a long history from growing the bill on
    /// every single message.
    private static let recentWindow = 20

    /// What a new agent points at until the user picks a model. The Settings
    /// picker fetches the live list from OpenRouter, so this is only ever a
    /// starting point.
    static let defaultModel = "anthropic/claude-opus-5"

    /// `graph` is optional rather than defaulted: KnowledgeGraph is main-actor
    /// isolated and a default argument is evaluated outside the actor.
    init(ai: AIRunner, store: ChatStore = ChatStore(), memory: KnowledgeBase = KnowledgeBase(),
         graph: KnowledgeGraph? = nil) {
        self.ai = ai
        self.store = store
        self.memory = memory
        self.graph = graph ?? KnowledgeGraph()
        self.conversation = Self.blank(agent: nil)
        self.conversation = Self.blank(agent: chatAgents.first)
        // Model, effort and fast are stored on the agent, which lives in
        // AIRunner — so changing one published from there and the composer,
        // which observes this object, never re-rendered. That's why the
        // controls looked dead.
        agentObserver = ai.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        // Same reason, and the reason deleting a chat looked broken: the views
        // observe this controller, not the store inside it. Removing a chat
        // updated store.summaries and nothing told SwiftUI, so the row stayed
        // on screen even though the file was already gone.
        storeObserver = store.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        graphObserver = self.graph.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        voice.currentConversation = { [weak self] in self?.conversation.id }
        voice.polish = { [weak self] raw in
            guard let self else { return raw }
            return await Self.tidy(raw, client: self.client)
        }

        voice.onTranscript = { [weak self] text in
            guard let self else { return }
            // Where the words go depends on where you were looking.
            //
            // The composer only wins when it's on screen *and* focused. A
            // global shortcut fires from anywhere, so most of the time you're
            // mid-sentence in another app — and putting the transcript in
            // Visor's composer then means going to find it and moving it by
            // hand, which is most of the point gone.
            if self.isComposerVisible?() ?? false {
                self.draft = self.draft.isEmpty
                    ? text
                    : self.draft.trimmingCharacters(in: .whitespaces) + " " + text
                return
            }
            // Otherwise into the app dictation started in. Whatever happens,
            // the user is told where the words went — the outcome used to be
            // discarded, so a transcript that couldn't be typed simply
            // vanished from view and had to be recovered from the voice log.
            Task { @MainActor [weak self] in
                let outcome = await TextInsertion.insert(text)
                if let notice = outcome.notice { self?.voice.report(notice) }
            }
        }
    }

    /// Start or stop dictating into the composer.
    func toggleDictation() { voice.toggle() }

    /// Clean up a raw transcript: punctuation, casing, obvious mishearings.
    ///
    /// Three things make this cheap and quick rather than just correct.
    ///
    /// The instruction is a *system* prompt and only the transcript is the user
    /// message, so the expensive half of the request is byte-identical every
    /// time and can be served from the provider's prompt cache. Routing asks
    /// for throughput rather than the lowest price, because this sits between
    /// you speaking and the words appearing — a cheaper provider that takes
    /// two seconds is the wrong trade here even though it's the right one for
    /// a long generation. And max_tokens is capped relative to the input,
    /// since a correct rewrite is never much longer than what went in.
    ///
    /// Anything that goes wrong returns the original. A tidy-up that loses
    /// words is far worse than one that doesn't happen.
    private static func tidy(_ raw: String, client: OpenRouterClient) async -> String {
        // Nothing to correct in "yes" or "stop" — and the round trip would be
        // longer than the utterance.
        guard raw.count >= 12 else { return raw }

        // The user's, not ours. Kept as a *system* prompt so it stays
        // byte-identical between dictations and can be served from the
        // provider's cache — which is most of why this is quick.
        let system = VoiceInput.cleanupPrompt

        let result: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                try? await client.complete(
                    messages: [ChatMessage(role: .user, content: raw)],
                    model: VoiceInput.cleanupModel,
                    system: system,
                    temperature: 0,
                    fast: true,
                    maxTokens: max(64, raw.count / 2))
            }
            // Past this the pause is worse than the typos it would fix.
            group.addTask {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        guard var cleaned = result?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cleaned.isEmpty else { return raw }
        // Models sometimes wrap the answer in quotes it was never given.
        if cleaned.count > 1, cleaned.hasPrefix("\""), cleaned.hasSuffix("\"") {
            cleaned = String(cleaned.dropFirst().dropLast())
        }
        // A rewrite this much longer than the input isn't a rewrite.
        guard cleaned.count < max(40, raw.count * 2) else { return raw }
        return cleaned
    }

    // MARK: - Agents

    /// Agents that answer in the notch, in config order — models reached
    /// through OpenRouter and local CLI agents alike.
    var chatAgents: [AIProvider] { ai.providers.filter(\.isNotchAgent) }

    /// The agent this conversation belongs to, falling back to the first
    /// configured one if it was renamed or deleted mid-chat.
    var agent: AIProvider? {
        chatAgents.first { $0.name == conversation.agentName } ?? chatAgents.first
    }

    /// Select the nth configured agent (⌘⌃1…5). Ignored when there aren't
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

    func loadModels() async {
        guard !offline else { return }
        await catalog.loadIfNeeded()
    }

    /// A controller in a chosen state, for the Design Lab. Same object the
    /// real card uses; only the state is scripted. `private(set)` is why this
    /// lives here rather than in the lab.
    static func fixture(ai: AIRunner, root: URL, conversation: Conversation,
                        streaming: Bool = false, pending: PendingApproval? = nil,
                        error: String? = nil, draft: String = "") -> ChatController {
        let chat = ChatController(ai: ai, store: ChatStore(root: root),
                                  memory: KnowledgeBase(root: root),
                                  graph: KnowledgeGraph(root: root))
        chat.offline = true
        chat.conversation = conversation
        chat.isStreaming = streaming
        chat.pendingApproval = pending
        chat.error = error
        chat.draft = draft
        return chat
    }

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
    var supportsEffort: Bool {
        // A local CLI agent has its own settings; Visor shouldn't imply it can
        // dial them from here.
        guard agent?.isChat ?? false else { return false }
        return catalog.supportsReasoning(conversation.model)
    }

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
    /// Models pinned on this agent, current one always included.
    var favouriteModels: [String] {
        var ids = agent?.favouriteModels ?? []
        let current = conversation.model
        if !current.isEmpty, !ids.contains(current) { ids.insert(current, at: 0) }
        return ids
    }

    func isFavourite(_ id: String) -> Bool {
        agent?.favouriteModels?.contains(id) ?? false
    }

    func toggleFavourite(_ id: String) {
        guard var agent else { return }
        var favourites = agent.favouriteModels ?? []
        if let index = favourites.firstIndex(of: id) {
            favourites.remove(at: index)
        } else {
            favourites.append(id)
        }
        agent.favouriteModels = favourites
        ai.upsert(agent)
    }

    /// Whether the composer should offer a CLI model chip.
    var isCLIAgent: Bool { agent?.isNotchCLI ?? false }

    /// The command backing the running CLI agent, for looking up suggestions.
    var cliCommand: String { agent?.command ?? "" }

    /// Suggestion groups for this agent, filtered by a search term, with
    /// whatever the user has pinned brought to the front.
    ///
    /// Pinning is stored on the agent, exactly as it is for a hosted one — the
    /// mechanism was never model-specific, only the picker that used it was.
    /// A future Codex or Gemini agent inherits it by existing.
    func cliGroups(matching query: String) -> [CLICatalogue.Group] {
        let term = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = CLICatalogue.groups(for: cliCommand)

        var groups: [CLICatalogue.Group] = []
        if term.isEmpty {
            let pinned = cliFavourites
            if !pinned.isEmpty {
                groups.append(CLICatalogue.Group(id: "Pinned", models: pinned))
            }
        }
        for group in all {
            let models = term.isEmpty ? group.models : group.models.filter {
                $0.id.lowercased().contains(term) || $0.title.lowercased().contains(term)
            }
            if !models.isEmpty {
                groups.append(CLICatalogue.Group(id: group.id, models: models))
            }
        }
        return groups
    }

    /// Pinned models, as entries — including ones typed by hand, which have no
    /// catalogue entry and are shown under their own id.
    var cliFavourites: [CLICatalogue.Model] {
        var out: [CLICatalogue.Model] = []
        let known = CLICatalogue.groups(for: cliCommand).flatMap(\.models)
        for id in agent?.favouriteModels ?? [] {
            if let match = known.first(where: { $0.id == id }) {
                out.append(match)
            } else {
                out.append(CLICatalogue.Model(id: id, title: id))
            }
        }
        return out
    }

    /// The id currently set, "default" when the agent has none.
    var cliModelID: String {
        let name = agent?.model ?? ""
        return name.isEmpty ? "default" : name
    }

    /// How that reads in the composer: a name, not an id. "Opus 4.8" is what
    /// you chose; "claude-opus-4-8" is how it's spelled to the CLI, and a chip
    /// this narrow has room for one of them.
    var cliModelName: String {
        CLICatalogue.title(for: cliModelID, command: cliCommand)
    }

    /// Point a CLI agent at a different model.
    ///
    /// This has to start a new chat. The CLI binds a model when a session is
    /// created and ignores `--model` on resume, so changing it mid-session
    /// would leave the chip showing one model while the session kept running
    /// the other — the picker would look like it worked and wouldn't have.
    func useCLIModel(_ name: String) {
        guard var agent, agent.isNotchCLI else { return }
        let chosen = name == "default" ? "" : name.trimmingCharacters(in: .whitespaces)
        guard chosen != (agent.model ?? "") else { return }
        agent.model = chosen
        ai.upsert(agent)
        if !conversation.messages.isEmpty {
            store.save(conversation)
            stop()
            error = nil
            conversation = Self.blank(agent: agent)
        }
    }

    /// Point a hosted agent at a different OpenRouter model.
    ///
    /// Refuses on a local CLI agent, which runs on its own tool's account and
    /// its own tool's models. Nothing should be able to write `openai/gpt-…`
    /// onto a Claude Code agent: the run guard would drop it, silently, and
    /// the picker would keep showing a model that was never used. A control
    /// being hidden isn't the same as a value being impossible — the HUD
    /// composer proved that by offering the whole catalogue for a build.
    func useModel(_ id: String) {
        guard agent?.isChat ?? false else { return }
        conversation.model = id
        if var agent {
            agent.model = id
            ai.upsert(agent)
        }
        if !conversation.messages.isEmpty { store.save(conversation) }
    }

    /// Switch the active agent, starting a new chat if this one has run.
    ///
    /// Keeping the transcript looked like continuity and wasn't. A local CLI
    /// agent holds its own session on its own side, and Visor resumes it by
    /// id: hand that conversation to a hosted model and it answers from a
    /// transcript the CLI never had, hand a hosted conversation to the CLI and
    /// it starts blank while the screen still shows the history. Either way
    /// the visible chat and the agent's actual context disagree, which is the
    /// one thing a transcript must never do.
    ///
    /// So a used chat is saved and a new one opens. The old one is one click
    /// away in history, still attached to the agent that can actually continue
    /// it.
    func use(_ agent: AIProvider) {
        guard agent.name != conversation.agentName else { return }
        if !conversation.messages.isEmpty {
            store.save(conversation)
            stop()
            error = nil
            draft = ""
            conversation = Self.blank(agent: agent)
            return
        }
        conversation.agentName = agent.name
        conversation.model = agent.model ?? Self.defaultModel
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
        // Only the hosted agents need a key; a local CLI agent brings its own
        // auth, or none.
        if agent.isChat, !OpenRouterClient.hasKey {
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
            if agent.isNotchCLI {
                await self.runCLITurn(agent: agent, prompt: text)
            } else {
                await self.runTurn(model: model, system: system, effort: effort,
                                   fast: fast, round: 0)
            }
        }
    }

    /// Stream a local CLI agent's output into the transcript, in a conversation
    /// that actually continues.
    ///
    /// These agents keep their own history, so continuity is a matter of
    /// pointing each Visor chat at one session on their side and resuming it —
    /// not replaying our transcript at them, which would be both wrong and
    /// expensive. The first message claims a session id; every message after
    /// resumes it.
    ///
    /// Per conversation, so two Visor chats with the same agent don't end up
    /// talking into one session. Starting a new chat gets a new session.
    private func runCLITurn(agent: AIProvider, prompt: String) async {
        let runner = CLIAgentRunner()
        cliRunner = runner
        let key = agent.apiKeyEnv.flatMap { name in
            Keychain.get(agent.keyAccount).map { (name: name, value: $0) }
        }

        var arguments = agent.args

        // The CLI has its own system prompt and its own idea of what it is;
        // this appends rather than replaces, so it keeps every capability it
        // came with and merely learns what it's called in here.
        arguments += ["--append-system-prompt", Self.identity(for: agent)]

        if let session = conversation.cliSessionID {
            arguments += ["--resume", session]
            // Deliberately no --model here. Passing it on every turn overrode
            // whatever /model set inside the session, so changing model in the
            // conversation appeared to work and was undone by the next message.
            // The session owns its model once it exists.
        } else {
            let session = UUID().uuidString.lowercased()
            conversation.cliSessionID = session
            arguments += ["--session-id", session]
            // Only on the first turn, and only if it's a name this CLI could
            // understand. A slash means an OpenRouter id — which a CLI agent
            // has never heard of, and which it rejects on every single turn.
            if let model = agent.model, !model.isEmpty, !model.contains("/") {
                arguments += ["--model", model]
            }
            store.save(conversation)
        }

        // Structured output, so the reply arrives as it's written rather than
        // in one lump when the process exits. `-p` on its own buffers the whole
        // turn — which is why a CLI agent used to sit silent for a minute and
        // then produce everything at once, while a hosted agent streamed.
        //
        // Only when the tool is known to speak it, and never on top of a
        // format the user has chosen themselves in the agent's arguments.
        let structured = CLICatalogue.streamsJSON(command: agent.command)
            && !arguments.contains("--output-format")
        if structured { arguments += CLICatalogue.streamingArguments }

        // Which account this agent runs as, when it has been given one of its
        // own. Without it the tool uses whatever it was last signed in to,
        // machine-wide.
        var environment: [String: String] = [:]
        if let variable = CLICatalogue.configDirVariable(command: agent.command),
           let dir = agent.configDir, !dir.isEmpty {
            environment[variable] = (dir as NSString).expandingTildeInPath
        }

        for await event in runner.run(command: agent.command,
                                      arguments: arguments,
                                      prompt: prompt,
                                      directory: ai.workDirURL,
                                      environmentKey: key,
                                      extraEnvironment: environment,
                                      structured: structured) {
            switch event {
            case .text(let chunk):
                appendToReply(chunk)
            case .usage(let used):
                UsageLedger.record(UsageEntry(
                    agent: agent.name,
                    account: agent.name,
                    source: (agent.command as NSString).lastPathComponent,
                    model: used.model ?? agent.model ?? "default",
                    input: used.input, output: used.output,
                    cacheRead: used.cacheRead, cacheWrite: used.cacheWrite,
                    costUSD: used.costUSD))
            case .finished(let status):
                if status != 0, conversation.messages.last?.content.isEmpty ?? true {
                    appendToReply("_\(agent.name) exited with status \(status)._")
                }
            }
        }
        cliRunner = nil
        finish()
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
                case .usage(let tokensIn, let tokensOut, let cost):
                    // Against the key, not the agent: five agents can sit
                    // behind one OpenRouter key, and "what am I spending" is a
                    // question about the key.
                    UsageLedger.record(UsageEntry(
                        agent: agent?.name ?? "",
                        account: agent?.keyAccount ?? OpenRouterClient.sharedKeyAccount,
                        source: "openrouter",
                        model: model,
                        input: tokensIn, output: tokensOut,
                        costUSD: cost))
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

        // Anything that could spend money, change something outside Visor, or
        // not be undoable stops here and asks. Checked before *any* of the
        // batch runs, so a permitted call can't quietly execute alongside one
        // the user is about to refuse.
        let approved = agent?.autoApprovedTools ?? []
        let needing = calls.filter { call in
            (ToolRegistry.shared.tools[call.name]?.needsApproval ?? false)
                && !approved.contains(call.name)
        }
        guard needing.isEmpty else {
            isStreaming = false
            pendingApproval = PendingApproval(
                calls: calls, needing: needing, model: model, system: system,
                effort: effort, fast: fast, round: round)
            store.save(conversation)
            return
        }

        await execute(calls, model: model, system: system, effort: effort,
                      fast: fast, round: round)
    }

    /// Run a batch of calls and hand the results back to the model.
    private func execute(_ calls: [ToolCall], model: String, system: String?,
                         effort: String?, fast: Bool, round: Int) async {
        isStreaming = true
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

    /// Let the pending calls run. `always` adds them to this agent's standing
    /// permissions.
    func approvePending(always: Bool) {
        guard let pending = pendingApproval else { return }
        pendingApproval = nil
        if always, var agent {
            var allowed = agent.autoApprovedTools ?? []
            for call in pending.needing where !allowed.contains(call.name) {
                allowed.append(call.name)
            }
            agent.autoApprovedTools = allowed
            ai.upsert(agent)
        }
        streamTask = Task { [weak self] in
            await self?.execute(pending.calls, model: pending.model, system: pending.system,
                                effort: pending.effort, fast: pending.fast, round: pending.round)
        }
    }

    /// Refuse the pending calls.
    ///
    /// The refusal is fed back as each call's result rather than the turn
    /// simply ending — otherwise the model is left waiting on tools that never
    /// answer, and can't say what it would have done instead.
    func denyPending() {
        guard let pending = pendingApproval else { return }
        pendingApproval = nil
        for call in pending.calls {
            conversation.messages.append(ChatMessage(
                role: .tool,
                content: "The user declined to run \(call.name).",
                toolCallID: call.id))
        }
        conversation.messages.append(ChatMessage(role: .assistant, content: "",
                                                 model: pending.model))
        streamTask = Task { [weak self] in
            await self?.runTurn(model: pending.model, system: pending.system,
                                effort: pending.effort, fast: pending.fast,
                                round: pending.round + 1)
        }
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
        cliRunner?.stop()
        cliRunner = nil
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

    /// Who the agent is, in its own words.
    ///
    /// Without this there was no system message at all unless the user had
    /// written a persona, so an agent named Visor introduced itself as
    /// whatever model was answering — ask it its name and it said "Claude
    /// Code". The agent's name is a fact about the setup that only Visor
    /// knows; nothing else in the request carries it.
    ///
    /// It states identity, it doesn't hide provenance: the model is told what
    /// it's called and where it's running, and told to answer plainly about
    /// what it's built on. Naming an agent isn't a licence to make it lie
    /// about what it is.
    static func identity(for agent: AIProvider) -> String {
        """
        You are \(agent.name), an agent inside Visor — a macOS app that lives \
        in the notch at the top of the screen. Visor is the app; \(agent.name) \
        is you. Asked your name, it's \(agent.name). Asked what you're built \
        on, say so plainly — being called \(agent.name) doesn't make the \
        underlying model a secret.
        """
    }

    private static func system(for agent: AIProvider, recalled: String?,
                               known: String?) -> String? {
        var parts: [String] = [identity(for: agent)]
        if let persona = agent.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !persona.isEmpty {
            // After the identity, so a persona the user wrote can reshape it.
            parts.append(persona)
        }
        // Facts first: they're compact and specific, where recalled excerpts
        // are long and only maybe relevant.
        if let known { parts.append(known) }
        if let recalled { parts.append(recalled) }
        return parts.joined(separator: "\n\n")
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
