import Foundation

/// One conversation with one agent, in the terminal — the same turn loop
/// the app runs: stream the reply, run the tools it asks for (after asking
/// you, for the ones that can change something), go round again.
@MainActor
final class ChatEngine {
    struct PendingApproval {
        let calls: [ToolCall]
        let needing: [ToolCall]
        let round: Int
    }

    private(set) var agents: [AIProvider]
    private(set) var agent: AIProvider?
    private(set) var conversation: Conversation
    private(set) var isStreaming = false
    private(set) var pendingApproval: PendingApproval?
    private(set) var error: String?
    /// Fires on every change worth redrawing for.
    var onChange: () -> Void = {}

    let store: ChatStore
    let workDir: URL
    private let client = OpenRouterClient()
    private let tools: [CLITool]
    private var alwaysAllowed: Set<String> = []
    private var streamTask: Task<Void, Never>?
    private var cliRunner: CLIAgentRunner?

    static let defaultModel = "anthropic/claude-opus-5"
    private static let recentWindow = 20
    private static let maxToolRounds = 6

    init(workDir: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) {
        let loaded = Agents.load()
        agents = loaded.agents
        agent = loaded.agents.first { $0.name == loaded.defaultName } ?? loaded.agents.first
        store = ChatStore()
        self.workDir = workDir
        tools = CLITools.all(workDir: workDir)
        conversation = Conversation(title: "", agentName: agent?.name ?? "", model: agent?.model ?? Self.defaultModel)
        alwaysAllowed = Set(agent?.autoApprovedTools ?? [])
    }

    // MARK: Choosing

    func use(_ chosen: AIProvider) {
        agent = chosen
        alwaysAllowed = Set(chosen.autoApprovedTools ?? [])
        if conversation.messages.isEmpty {
            conversation.agentName = chosen.name
            conversation.model = chosen.model ?? Self.defaultModel
        }
        onChange()
    }

    func useModel(_ id: String) {
        guard var a = agent, a.isChat else { return }
        a.model = id
        agent = a
        conversation.model = id
        onChange()
    }

    var modelName: String {
        guard let agent else { return "" }
        if agent.isChat { return agent.model ?? Self.defaultModel }
        return agent.model ?? agent.command
    }

    func newChat() {
        stop()
        conversation = Conversation(title: "", agentName: agent?.name ?? "", model: modelName)
        error = nil
        onChange()
    }

    func open(_ id: UUID) {
        guard let chat = store.conversation(id) else { return }
        stop()
        conversation = chat
        if let owner = agents.first(where: { $0.name == chat.agentName }) { agent = owner }
        error = nil
        onChange()
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        cliRunner?.stop()
        cliRunner = nil
        if isStreaming {
            isStreaming = false
            if conversation.messages.last?.role == .assistant, conversation.messages.last?.content.isEmpty == true {
                conversation.messages.removeLast()
            }
            store.save(conversation)
            onChange()
        }
    }

    // MARK: Sending

    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming, pendingApproval == nil else { return }
        guard let agent else { error = "No agent. Add one in Visor → Settings → Agents."; onChange(); return }
        if let why = Agents.blocker(for: agent) { error = why; onChange(); return }
        error = nil
        let model = modelName
        conversation.messages.append(ChatMessage(role: .user, content: text))
        conversation.agentName = agent.name
        conversation.model = model
        if conversation.title.isEmpty { conversation.title = Self.title(from: text) }
        conversation.messages.append(ChatMessage(role: .assistant, content: "", model: model))
        isStreaming = true
        store.save(conversation)
        onChange()
        streamTask = Task { [weak self] in
            guard let self else { return }
            if agent.isChat {
                await self.runTurn(model: model, system: Self.system(for: agent, workDir: self.workDir), round: 0)
            } else {
                await self.runCLITurn(agent: agent, prompt: text)
            }
        }
    }

    private func appendToReply(_ chunk: String) {
        guard let i = conversation.messages.indices.last, conversation.messages[i].role == .assistant else { return }
        conversation.messages[i].content += chunk
        onChange()
    }

    private func finish() {
        isStreaming = false
        conversation.updatedAt = Date()
        store.save(conversation)
        onChange()
    }

    private func fail(_ error: Error) {
        if error is CancellationError { finish(); return }
        self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if conversation.messages.last?.role == .assistant, conversation.messages.last?.content.isEmpty == true {
            conversation.messages.removeLast()
        }
        finish()
    }

    private func runTurn(model: String, system: String?, round: Int) async {
        do {
            let history = Array(conversation.messages.dropLast().suffix(Self.recentWindow * 2))
            for try await event in client.stream(messages: history, model: model, system: system,
                                                 effort: agent?.effort, fast: agent?.fastMode ?? false,
                                                 tools: tools.map(\.schema)) {
                switch event {
                case .text(let chunk): appendToReply(chunk)
                case .toolCalls(let calls):
                    if let i = conversation.messages.indices.last { conversation.messages[i].toolCalls = calls }
                    onChange()
                case .usage(let tokensIn, let tokensOut, let cost):
                    UsageLedger.record(UsageEntry(agent: agent?.name ?? "", account: OpenRouterClient.sharedKeyAccount,
                                                  source: "openrouter", model: model,
                                                  input: tokensIn, output: tokensOut, costUSD: cost))
                }
            }
        } catch {
            fail(error); return
        }
        guard let last = conversation.messages.last, last.role == .assistant,
              let calls = last.toolCalls, !calls.isEmpty else { finish(); return }
        guard round < Self.maxToolRounds else {
            conversation.messages.append(ChatMessage(role: .assistant, content: "_Stopped after \(Self.maxToolRounds) rounds of tool calls._", model: model))
            finish(); return
        }
        let needing = calls.filter { call in
            (tools.first { $0.name == call.name }?.needsApproval ?? false) && !alwaysAllowed.contains(call.name)
        }
        if !needing.isEmpty {
            isStreaming = false
            pendingApproval = PendingApproval(calls: calls, needing: needing, round: round)
            store.save(conversation)
            onChange()
            return
        }
        await execute(calls, model: model, system: system, round: round)
    }

    private func execute(_ calls: [ToolCall], model: String, system: String?, round: Int) async {
        isStreaming = true
        onChange()
        for call in calls {
            let result: String
            if let tool = tools.first(where: { $0.name == call.name }) {
                result = await tool.run(call.decodedArguments)
            } else {
                result = "No tool called \(call.name)."
            }
            conversation.messages.append(ChatMessage(role: .tool, content: result, toolCallID: call.id))
            onChange()
        }
        store.save(conversation)
        conversation.messages.append(ChatMessage(role: .assistant, content: "", model: model))
        await runTurn(model: model, system: system, round: round + 1)
    }

    func approvePending(always: Bool) {
        guard let pending = pendingApproval else { return }
        pendingApproval = nil
        if always { for call in pending.needing { alwaysAllowed.insert(call.name) } }
        let model = modelName
        let system = agent.map { Self.system(for: $0, workDir: workDir) }
        streamTask = Task { [weak self] in
            await self?.execute(pending.calls, model: model, system: system, round: pending.round)
        }
    }

    func denyPending() {
        guard let pending = pendingApproval else { return }
        pendingApproval = nil
        for call in pending.calls {
            conversation.messages.append(ChatMessage(role: .tool, content: "The user declined to run this.", toolCallID: call.id))
        }
        conversation.messages.append(ChatMessage(role: .assistant, content: "", model: modelName))
        isStreaming = true
        onChange()
        let model = modelName
        let system = agent.map { Self.system(for: $0, workDir: workDir) }
        streamTask = Task { [weak self] in
            await self?.runTurn(model: model, system: system, round: pending.round + 1)
        }
    }

    // MARK: CLI agents

    private func runCLITurn(agent: AIProvider, prompt: String) async {
        let runner = CLIAgentRunner()
        cliRunner = runner
        let key = agent.apiKeyEnv.flatMap { name in Keychain.get(agent.keyAccount).map { (name: name, value: $0) } }
        var arguments = agent.args
        let isClaude = CLICatalogue.streamsJSON(command: agent.command)
        if isClaude {
            arguments += ["--append-system-prompt", Self.identity(for: agent, workDir: workDir)]
            if let session = conversation.cliSessionID {
                arguments += ["--resume", session]
            } else {
                let session = UUID().uuidString.lowercased()
                conversation.cliSessionID = session
                arguments += ["--session-id", session]
                if let model = agent.model, !model.isEmpty, !model.contains("/") { arguments += ["--model", model] }
                store.save(conversation)
            }
        }
        let structured = isClaude && !arguments.contains("--output-format")
        if structured { arguments += CLICatalogue.streamingArguments }
        var environment: [String: String] = [:]
        if let variable = CLICatalogue.configDirVariable(command: agent.command), let dir = agent.configDir, !dir.isEmpty {
            environment[variable] = (dir as NSString).expandingTildeInPath
        }
        for await event in runner.run(command: agent.command, arguments: arguments, prompt: prompt,
                                      directory: workDir, environmentKey: key,
                                      extraEnvironment: environment, structured: structured) {
            switch event {
            case .text(let chunk): appendToReply(chunk)
            case .usage(let used):
                UsageLedger.record(UsageEntry(agent: agent.name, account: agent.name,
                                              source: (agent.command as NSString).lastPathComponent,
                                              model: used.model ?? agent.model ?? "default",
                                              input: used.input, output: used.output,
                                              cacheRead: used.cacheRead, cacheWrite: used.cacheWrite, costUSD: used.costUSD))
            case .finished(let status):
                if status != 0, conversation.messages.last?.content.isEmpty ?? true {
                    appendToReply("_\(agent.name) exited with status \(status)._")
                }
            }
        }
        cliRunner = nil
        finish()
    }

    // MARK: Prompts

    static func identity(for agent: AIProvider, workDir: URL) -> String {
        """
        You are \(agent.name), an agent inside Visor, running in the user's terminal. \
        The current project folder is \(workDir.path). Asked your name, it's \(agent.name); \
        asked what you're built on, say so plainly. Be concise: this is a terminal, \
        and short answers read best. Markdown is fine.
        """
    }

    static func system(for agent: AIProvider, workDir: URL) -> String {
        var parts = [identity(for: agent, workDir: workDir)]
        if let persona = agent.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !persona.isEmpty {
            parts.append(persona)
        }
        return parts.joined(separator: "\n\n")
    }

    static func title(from text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > 48 else { return flat.isEmpty ? "New chat" : flat }
        let clipped = flat.prefix(48)
        if let space = clipped.lastIndex(of: " ") { return String(clipped[clipped.startIndex..<space]) + "…" }
        return String(clipped) + "…"
    }
}
