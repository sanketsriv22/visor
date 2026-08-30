import AppKit
import SwiftUI

/// Lets the app point Settings at one agent when it opens — used when a send
/// is blocked because that agent has no API key stored yet, so the user lands
/// on the field they need instead of hunting for it.
final class SettingsFocus: ObservableObject {
    static let shared = SettingsFocus()
    @Published var provider: String?
    private init() {}
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case agents, workspace, mcp, memory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .agents:    return "Agents"
        case .workspace: return "Workspace"
        case .mcp:       return "MCP"
        case .memory:    return "Memory"
        }
    }

    var symbol: String {
        switch self {
        case .agents:    return "person.2"
        case .workspace: return "folder"
        case .mcp:       return "app.connected.to.app.below.fill"
        case .memory:    return "brain"
        }
    }
}

/// Visor's settings.
///
/// This outgrew the menu-bar dropdown it used to live in: agents now have
/// names, models, personas and keys, and there's memory and MCP wiring on top.
/// A dropdown can hold a couple of toggles; it can't hold a form.
struct SettingsView: View {
    @ObservedObject var ai: AIRunner
    @ObservedObject var chat: ChatController
    @ObservedObject var pushToTalk: PushToTalk
    @StateObject private var catalog = ModelCatalog()
    @ObservedObject private var focus = SettingsFocus.shared
    @State private var tab: SettingsTab = .agents

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                pane
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 760, minHeight: 540)
        .task { await catalog.loadIfNeeded() }
        .onChange(of: focus.provider) { name in
            // Sent here to fix a key — that's always on the Agents tab.
            if name != nil { tab = .agents }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsTab.allCases) { candidate in
                Button {
                    tab = candidate
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: candidate.symbol)
                            .frame(width: 16)
                        Text(candidate.title)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(tab == candidate ? Color.accentColor.opacity(0.18) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("Visor \(AppInfo.version)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 9)
        }
        .padding(10)
        .frame(width: 168)
    }

    @ViewBuilder
    private var pane: some View {
        switch tab {
        case .agents:    AgentsPane(ai: ai, catalog: catalog, focus: focus,
                                    pushToTalk: pushToTalk)
        case .workspace: WorkspacePane(ai: ai)
        case .mcp:       MCPPane()
        case .memory:    MemoryPane(chat: chat, catalog: catalog)
        }
    }
}

// MARK: - Agents

private struct AgentsPane: View {
    @ObservedObject var ai: AIRunner
    @ObservedObject var catalog: ModelCatalog
    @ObservedObject var focus: SettingsFocus
    @ObservedObject var pushToTalk: PushToTalk

    @State private var keyDraft = ""
    @State private var voiceDraft = ""
    @State private var newAgentName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            openRouterKey

            Divider()

            voiceKey

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Your agents").font(.headline)
                    Spacer()
                    addMenu
                }
                if ai.providers.isEmpty {
                    Text("No agents yet.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(ai.providers) { provider in
                    AgentRow(ai: ai, catalog: catalog, provider: provider,
                             highlighted: focus.provider == provider.name)
                        .id(provider.name)
                    Divider()
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Agents").font(.title3).bold()
            Text("Name as many agents as you like. A chat agent answers in the notch and can run on any model OpenRouter offers; a CLI agent runs a local tool like Claude Code or Devin.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One key for every chat agent — they all sit on one OpenRouter account.
    private var openRouterKey: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("API key").font(.headline)
                if OpenRouterClient.hasKey {
                    Label("set", systemImage: "checkmark.circle.fill")
                        .font(.caption2).foregroundStyle(.green)
                }
            }
            HStack {
                SecureField(OpenRouterClient.hasKey
                            ? "•••••• (set) — type to replace"
                            : "paste your API key",
                            text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    Keychain.set(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                                 account: OpenRouterClient.sharedKeyAccount)
                    keyDraft = ""
                    focus.provider = nil
                    Task { await catalog.reload() }
                }
                .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Get a key") {
                    if let url = URL(string: "https://openrouter.ai/keys") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Text("Shared by every chat agent, and stored in your macOS Keychain — never in a file. Keys come from openrouter.ai, which reaches every model in the picker below.")
                .font(.caption).foregroundStyle(.secondary)
            if catalog.isLoading {
                Text("Loading models…").font(.caption2).foregroundStyle(.secondary)
            } else if let error = catalog.error {
                Text(error).font(.caption2).foregroundStyle(.orange)
            } else if !catalog.models.isEmpty {
                Text("\(catalog.models.count) models available")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// Dictation can't reuse the chat key: OpenRouter is a chat-completions
    /// gateway and doesn't proxy audio transcription.
    private var voiceKey: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Voice key").font(.headline)
                if VoiceInput.hasKey {
                    Label("set", systemImage: "checkmark.circle.fill")
                        .font(.caption2).foregroundStyle(.green)
                }
            }
            HStack {
                SecureField(VoiceInput.hasKey
                            ? "•••••• (set) — type to replace"
                            : "paste an OpenAI key",
                            text: $voiceDraft)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    Keychain.set(voiceDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                                 account: VoiceInput.keyAccount)
                    voiceDraft = ""
                }
                .disabled(voiceDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("⌘⇧V dictates into the composer using OpenAI's transcription API. This is a separate key because OpenRouter doesn't carry audio — leave it blank and dictation stays off.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text("Hold to talk").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { pushToTalk.trigger },
                    set: { pushToTalk.setTrigger($0) })) {
                        ForEach(PushToTalk.Trigger.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                if pushToTalk.trigger != .off && !pushToTalk.isTrusted {
                    Button("Grant access…") { pushToTalk.requestTrust() }
                        .font(.caption)
                }
            }
            Text("Hold the key to record and release to transcribe; double-tap it to toggle. This is the only part of Visor that needs Accessibility — a bare modifier press produces no key equivalent, so it can't use the permission-free shortcut mechanism everything else does.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var addMenu: some View {
        Menu("Add agent") {
            Button("Chat agent (OpenRouter)") { add(kind: .openRouter) }
            Button("Local CLI agent") { add(kind: .cli) }
        }
        .fixedSize()
    }

    private func add(kind: AIProvider.Kind) {
        let base = kind == .openRouter ? "New agent" : "New CLI agent"
        var name = base
        var n = 2
        while ai.providers.contains(where: { $0.name == name }) {
            name = "\(base) \(n)"; n += 1
        }
        ai.upsert(AIProvider(
            name: name,
            command: kind == .cli ? "claude" : "",
            args: kind == .cli ? ["--dangerously-skip-permissions", "-p"] : [],
            kind: kind,
            model: kind == .openRouter ? ChatController.defaultModel : nil))
        focus.provider = name
    }
}

/// One agent, editable in place.
///
/// Everything is always visible — no disclosure triangle. A freshly added
/// agent that showed only its name with nothing editable read as broken, and
/// there are few enough fields that hiding them bought nothing.
private struct AgentRow: View {
    @ObservedObject var ai: AIRunner
    @ObservedObject var catalog: ModelCatalog
    let provider: AIProvider
    let highlighted: Bool

    @State private var nameDraft: String = ""
    @State private var keyDraft = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: provider.isChat ? "bubble.left.and.bubble.right" : "terminal")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                // Committed on Return *and* on losing focus: requiring Return
                // meant a name typed and clicked away from was silently thrown
                // out.
                TextField("Agent name", text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .focused($nameFocused)
                    .onSubmit(commitRename)
                    .onChange(of: nameFocused) { focused in
                        if !focused { commitRename() }
                    }

                Text(provider.isChat ? "chat" : "CLI")
                    .font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(.secondary.opacity(0.18)))
                    .foregroundStyle(.secondary)

                if provider.name == ai.defaultProviderName {
                    Text("default")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(.orange.opacity(0.25)))
                        .foregroundStyle(.orange)
                } else {
                    Button("Make default") { ai.setDefault(provider.name) }
                        .buttonStyle(.borderless).font(.caption)
                }

                Spacer()

                Button(role: .destructive) { ai.remove(provider) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove this agent")
            }

            if provider.isChat { chatFields } else { cliFields }
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(highlighted ? Color.accentColor.opacity(0.12) : .clear))
        .animation(.easeInOut(duration: 0.2), value: highlighted)
        .onAppear { nameDraft = provider.name }
        .onChange(of: provider.name) { nameDraft = $0 }
    }

    // MARK: Chat

    private var chatFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                fieldLabel("Model")
                ModelPickerButton(catalog: catalog,
                                  selection: provider.model ?? ChatController.defaultModel) { id in
                    var copy = provider
                    copy.model = id
                    ai.upsert(copy)
                }
            }
            HStack(alignment: .top, spacing: 8) {
                fieldLabel("Persona")
                VStack(alignment: .leading, spacing: 2) {
                    TextEditor(text: Binding(
                        get: { provider.systemPrompt ?? "" },
                        set: { value in var p = provider; p.systemPrompt = value; ai.upsert(p) }))
                        .font(.system(size: 11))
                        .frame(height: 46)
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .stroke(.secondary.opacity(0.3), lineWidth: 1))
                    Text("Optional. Prepended to every conversation with this agent.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: CLI

    private var cliFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                fieldLabel("Command")
                TextField("claude", text: Binding(
                    get: { provider.command },
                    set: { value in var p = provider; p.command = value; ai.upsert(p) }))
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 8) {
                fieldLabel("Args")
                TextField("space-separated", text: Binding(
                    get: { provider.args.joined(separator: " ") },
                    set: { value in
                        var p = provider
                        p.args = value.split(separator: " ").map(String.init)
                        ai.upsert(p)
                    }))
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 8) {
                fieldLabel("Key env")
                TextField("e.g. OPENAI_API_KEY — optional", text: Binding(
                    get: { provider.apiKeyEnv ?? "" },
                    set: { value in
                        var p = provider
                        p.apiKeyEnv = value.isEmpty ? nil : value
                        ai.upsert(p)
                    }))
                    .textFieldStyle(.roundedBorder)
            }
            if provider.needsKey {
                HStack(spacing: 8) {
                    fieldLabel("Key")
                    SecureField(ai.hasKey(provider) ? "•••••• (set)" : "paste API key",
                                text: $keyDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        ai.setKey(keyDraft, for: provider)
                        keyDraft = ""
                    }
                    .disabled(keyDraft.isEmpty)
                }
            }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 62, alignment: .leading)
    }

    private func commitRename() {
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != provider.name else { return }
        // Put the old name back if the new one was empty or already taken,
        // rather than leaving a field showing a name that wasn't saved.
        if !ai.rename(provider, to: name) { nameDraft = provider.name }
    }
}

/// Model chooser with a search field.
///
/// OpenRouter lists several hundred models; a plain Picker made that a single
/// scrolling column with no way to jump to the one you wanted.
private struct ModelPickerButton: View {
    @ObservedObject var catalog: ModelCatalog
    let selection: String
    let onSelect: (String) -> Void

    @State private var showing = false
    @State private var query = ""

    private var matches: [String] {
        var ids = catalog.ids
        if !ids.contains(selection) { ids.insert(selection, at: 0) }
        return ModelSearch.filter(ids, query: query)
    }

    var body: some View {
        Button {
            showing = true
        } label: {
            HStack(spacing: 5) {
                Text(selection).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .frame(width: 320, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(.secondary.opacity(0.35), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                TextField("Search \(catalog.ids.count) models…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(8)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if matches.isEmpty {
                            Text("No model matches “\(query)”")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(10)
                        }
                        ForEach(matches, id: \.self) { id in
                            Button {
                                onSelect(id)
                                showing = false
                                query = ""
                            } label: {
                                HStack {
                                    Text(id).font(.system(size: 11)).lineLimit(1)
                                    Spacer(minLength: 0)
                                    if id == selection {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 9, weight: .bold))
                                    }
                                }
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 240)
            }
            .frame(width: 380)
        }
    }
}

// MARK: - Workspace

private struct WorkspacePane: View {
    @ObservedObject var ai: AIRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Workspace").font(.title3).bold()
                Text("Where local CLI agents run, and how you watch them.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Run CLI agents in").font(.headline)
                Picker("", selection: Binding(get: { ai.runMode }, set: { ai.setRunMode($0) })) {
                    ForEach(AIRunner.RunMode.allCases, id: \.self) { mode in
                        Text(mode.menuTitle).tag(mode)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
                Text("Chat agents ignore this — they always answer in the notch.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Project folder").font(.headline)
                HStack {
                    Text(ai.workDirDisplay)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Menu("Choose") {
                        ForEach(ai.availableRepos, id: \.self) { repo in
                            Button(repo.lastPathComponent) { ai.setProjectDir(repo) }
                        }
                        if !ai.availableRepos.isEmpty { Divider() }
                        Button("Browse…") { chooseFolder() }
                    }
                    .fixedSize()
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Shortcut").font(.headline)
                HStack(spacing: 6) {
                    Text("⌘⇧K").font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.secondary.opacity(0.18)))
                    Text("opens and closes the notch from any app.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("⌘⇧I swaps between notes and chat.")
                    Text("⌘⇧M expands chat into the full-screen HUD.")
                    Text("⌘⇧1–5 jump straight to an agent.")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose the local repo/folder agents should work in."
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("repos")
        if panel.runModal() == .OK, let url = panel.url { ai.setProjectDir(url) }
    }
}

// MARK: - Memory

private struct MemoryPane: View {
    @ObservedObject var chat: ChatController
    @ObservedObject var catalog: ModelCatalog
    @State private var voiceEntries: [VoiceEntry] = []
    // Mirrors of the graph's stored settings, purely so toggling one
    // re-renders this pane — the graph isn't the observed object here.
    @State private var graphOn = false
    @State private var graphModel = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Memory").font(.title3).bold()
                Text("Visor embeds your chats on-device so agents can recall what you've discussed before. Nothing is sent anywhere to do it, and there's no embedding bill.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !chat.memory.isAvailable {
                Label("macOS has no embedding model for your locale — chats still work, but without recall of older conversations.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 24) {
                stat("\(chat.store.summaries.count)", "chats")
                stat("\(chat.store.summaries.reduce(0) { $0 + $1.messageCount })", "messages")
                stat("\(voiceEntries.count)", "dictated")
            }

            Divider()

            graphSection

            Divider()

            voiceLogSection

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("On disk").font(.headline)
                Text(ChatStore.defaultRoot.appendingPathComponent("chats").path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [ChatStore.defaultRoot.appendingPathComponent("chats")])
                    }
                    Button("Rebuild index") { chat.store.rebuildIndex() }
                }
                Text("One JSON file per chat, next to your notes — so a corrupt chat costs that chat, not the archive.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Facts extracted from conversations.
    private var graphSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { chat.graph.isEnabled },
                set: { chat.graph.isEnabled = $0; graphOn = $0 })) {
                    Text("Build a knowledge graph").font(.headline)
                }
                .toggleStyle(.switch)

            Text("After each exchange, a cheap model pulls out durable facts — who people are, what projects exist, what you prefer — and stores them as connected claims. Recall then walks those connections instead of matching wording, so asking about someone surfaces what's true of them rather than sentences that sound similar.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if chat.graph.isEnabled {
                HStack(spacing: 8) {
                    Text("Extract with").font(.caption).foregroundStyle(.secondary)
                    ModelPickerButton(catalog: catalog,
                                      selection: chat.graph.extractionModel) { id in
                        chat.graph.extractionModel = id
                        graphModel = id
                    }
                }
                Text("Costs one extra request per exchange. Pick something cheap and fast — this wants to be quick, not clever.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 24) {
                    stat("\(chat.graph.nodes.count)", "things")
                    stat("\(chat.graph.edges.count)", "claims")
                }
                .padding(.top, 2)
            }
        }
    }

    /// Everything dictated, whether or not it ever reached a chat.
    private var voiceLogSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Voice log").font(.headline)
                Spacer()
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([VoiceLog.url])
                }
                .disabled(voiceEntries.isEmpty)
                Button("Refresh") { voiceEntries = VoiceLog.recent(limit: 30) }
            }
            if voiceEntries.isEmpty {
                Text("Nothing dictated yet. ⌘⇧V, or hold your push-to-talk key.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(voiceEntries) { entry in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.text)
                                    .font(.system(size: 11))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(Self.stamp.string(from: entry.date)
                                     + (entry.duration.map { String(format: " · %.1fs", $0) } ?? ""))
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
            Text("Appended one line per utterance to voice-log.jsonl, so writing the ten-thousandth costs the same as the first.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            voiceEntries = VoiceLog.recent(limit: 30)
            graphOn = chat.graph.isEnabled
            graphModel = chat.graph.extractionModel
        }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 22, weight: .semibold))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - MCP

private struct MCPPane: View {
    @State private var copied: String?

    /// Where the bundled server lives once the repo is built.
    private var serverPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("repos/visor/mcp-server/dist/index.js").path
    }

    private var clients: [(name: String, command: String)] {
        [
            ("Claude Code", "claude mcp add visor -- node \(serverPath)"),
            ("Codex", "codex mcp add visor -- node \(serverPath)"),
            ("Cursor", "cursor mcp add visor -- node \(serverPath)"),
            ("Devin", "devin mcp add visor -- node \(serverPath)"),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("MCP").font(.title3).bold()
                Text("Visor ships an MCP server, so any MCP-aware agent can read your notes and chats — and write back into them. Run one of these once per client.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(clients, id: \.name) { client in
                VStack(alignment: .leading, spacing: 4) {
                    Text(client.name).font(.headline)
                    HStack {
                        Text(client.command)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer()
                        Button(copied == client.name ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(client.command, forType: .string)
                            copied = client.name
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                if copied == client.name { copied = nil }
                            }
                        }
                        .fixedSize()
                    }
                }
                Divider()
            }

            Text("The server needs building once: cd ~/repos/visor/mcp-server && npm install && npm run build")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
