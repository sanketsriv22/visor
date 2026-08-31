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
    case agents, voice, usage, workspace, mcp, memory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .agents:    return "Agents"
        case .voice:     return "Voice"
        case .usage:     return "Usage"
        case .workspace: return "Workspace"
        case .mcp:       return "MCP"
        case .memory:    return "Memory"
        }
    }

    var symbol: String {
        switch self {
        case .agents:    return "person.2"
        case .voice:     return "waveform"
        case .usage:     return "chart.bar"
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
                    .background(RoundedRectangle(cornerRadius: Design.Radius.control)
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
        case .agents:    AgentsPane(ai: ai, catalog: catalog, focus: focus)
        case .voice:     VoicePane(chat: chat, catalog: catalog, pushToTalk: pushToTalk)
        case .usage:     UsagePane()
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

    @State private var keyDraft = ""
    @State private var newAgentName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            openRouterKey

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
        .background(RoundedRectangle(cornerRadius: Design.Radius.pill)
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
                        .overlay(RoundedRectangle(cornerRadius: Design.Radius.control)
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
                fieldLabel("Model")
                TextField("optional — passed as --model, e.g. opus or claude-opus-5", text: Binding(
                    get: { provider.model ?? "" },
                    set: { value in
                        var p = provider
                        p.model = value.isEmpty ? nil : value
                        ai.upsert(p)
                    }))
                    .textFieldStyle(.roundedBorder)
            }
            Text("Free text, not OpenRouter's list — a CLI agent names its own models. Leave blank to use whatever it defaults to.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            CLIAccountRow(provider: provider, ai: ai)

            Toggle(isOn: Binding(
                get: { provider.runsInNotch ?? false },
                set: { value in var p = provider; p.runsInNotch = value; ai.upsert(p) })) {
                    Text("Answer in the notch").font(.caption)
                }
                .toggleStyle(.switch)
            Text("Makes this a first-class agent in the composer — pick it like any other, and its output streams into the chat instead of opening a Terminal.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
            .overlay(RoundedRectangle(cornerRadius: Design.Radius.control)
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
    @ObservedObject private var shortcuts = ShortcutSettings.shared

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

            VStack(alignment: .leading, spacing: 6) {
                Text("Shortcuts").font(.headline)
                Text("Click one and press the keys you want. Every combination macOS leaves free is claimed by *some* app, and a global shortcut wins over whatever's in front — so a clash breaks that app, not Visor. Better to set them than to guess.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(ShortcutSettings.Action.allCases) { action in
                    ShortcutRecorder(action: action)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Notes").font(.headline)
                HStack(spacing: 6) {
                    Text(ShortcutSettings.hint(.toggle)).font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: Design.Radius.control).fill(.secondary.opacity(0.18)))
                    Text("opens and closes the notch from any app.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(ShortcutSettings.hint(.swapMode)) swaps between notes and chat.")
                    Text("\(ShortcutSettings.hint(.hud)) expands chat into the full-screen HUD.")
                    Text("\(ShortcutSettings.agentHint(0))–\(ShortcutSettings.agentHint(4)) jump straight to an agent.")
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
            }

            Divider()

            graphSection

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
        .onAppear {
            graphOn = chat.graph.isEnabled
            graphModel = chat.graph.extractionModel
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


// MARK: - Usage

/// What each key has actually been used for.
///
/// Grouped by account rather than by agent, because that's the question: five
/// agents can sit behind one OpenRouter key, and the bill doesn't care which
/// of them ran. A local CLI agent is billed by whoever the user signed in to
/// that tool as — not by Visor, and not against the OpenRouter key — so it gets
/// its own row and says "subscription" rather than a cost, since a $0.00 there
/// would be a claim rather than an absence.
private struct UsagePane: View {
    @State private var window: UsageLedger.Window = .week
    /// Bumped to re-read the file, which is appended to from outside this view.
    @State private var refresh = 0
    @State private var confirmingClear = false

    private var totals: [UsageTotal] {
        _ = refresh
        return UsageLedger.totals(in: window)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("", selection: $window) {
                    ForEach(UsageLedger.Window.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 300)
                Spacer()
                Button("Refresh") { refresh += 1 }
                    .font(.caption)
            }

            if totals.isEmpty {
                Text("Nothing recorded in this period. Usage is written as each reply finishes.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.top, 4)
            } else {
                ForEach(totals) { total in
                    UsageRow(total: total)
                }
                Divider()
                summary
            }

            Spacer()

            HStack(spacing: 8) {
                // A usage log is a record of what someone has been doing, so
                // deleting it is theirs to do.
                Button(confirmingClear ? "Delete history?" : "Clear history") {
                    if confirmingClear {
                        UsageLedger.clear()
                        confirmingClear = false
                        refresh += 1
                    } else {
                        confirmingClear = true
                    }
                }
                .font(.caption)
                .foregroundStyle(confirmingClear ? Color.red : .secondary)
                if confirmingClear {
                    Button("Cancel") { confirmingClear = false }.font(.caption)
                }
                Spacer()
            }

            Text("Counted from what each provider reports for the request — not estimated. Cached input is listed separately because it's billed at a different rate.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .onAppear { refresh += 1 }
    }

    private var summary: some View {
        let billed = totals.filter(\.billed)
        let cost = billed.reduce(0) { $0 + $1.costUSD }
        let requests = totals.reduce(0) { $0 + $1.requests }
        return HStack {
            Text("\(requests) request\(requests == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if !billed.isEmpty {
                Text(UsageFormat.money(cost))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
            }
        }
    }
}

private struct UsageRow: View {
    let total: UsageTotal

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: total.source == "openrouter" ? "globe" : "terminal")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(total.account).font(.system(size: 12, weight: .medium))
                Text(subtitle)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 2) {
                if total.billed {
                    Text(UsageFormat.money(total.costUSD))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                } else {
                    Text("subscription")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text(tokens)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
    }

    private var subtitle: String {
        let names = total.agents.sorted().joined(separator: ", ")
        let count = total.requests
        return "\(count) request\(count == 1 ? "" : "s") · \(names)"
    }

    private var tokens: String {
        var parts = ["\(UsageFormat.count(total.input)) in",
                     "\(UsageFormat.count(total.output)) out"]
        if total.cacheRead > 0 { parts.append("\(UsageFormat.count(total.cacheRead)) cached") }
        return parts.joined(separator: " · ")
    }
}

private enum UsageFormat {
    /// Fractions of a cent are the normal case for a single request, so the
    /// usual two decimal places would show most of this history as $0.00.
    static func money(_ amount: Double) -> String {
        if amount == 0 { return "$0" }
        if amount < 0.01 { return String(format: "$%.4f", amount) }
        if amount < 1 { return String(format: "$%.3f", amount) }
        return String(format: "$%.2f", amount)
    }

    static func count(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        return "\(value)"
    }
}


/// Watches whether Visor has Accessibility, so the warning can go away by
/// itself.
///
/// It used to be read once while the view was built, which meant granting the
/// permission and coming back to a panel still insisting it was off — the
/// setting was right and the screen was wrong, and there's no way to tell those
/// apart from the outside.
@MainActor
private final class AccessibilityTrust: ObservableObject {
    @Published private(set) var granted = TextInsertion.isTrusted
    private var timer: Timer?

    init() {
        // There is no reliable notification for this, so it's polled — slowly,
        // and only while something is looking at it.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = TextInsertion.isTrusted
                if now != self.granted { self.granted = now }
            }
        }
    }

    deinit { timer?.invalidate() }
}


// MARK: - Voice

/// Everything to do with dictation, in one place.
///
/// It was spread across two panes: the transcription key under Agents, next to
/// an unrelated OpenRouter key, and the log of what you'd said under Memory,
/// which is about what agents remember rather than what you dictated. Neither
/// is where you'd look. Voice is its own feature with its own key, its own
/// permission, its own shortcut and its own history, so it gets its own tab.
private struct VoicePane: View {
    @ObservedObject var chat: ChatController
    @ObservedObject var catalog: ModelCatalog
    @ObservedObject var pushToTalk: PushToTalk

    @State private var voiceDraft = ""
    @State private var cleanupOn = VoiceInput.cleanupEnabled
    @State private var cleanupModel = VoiceInput.cleanupModel
    @State private var insertOn = TextInsertion.insertIntoFocusedApp
    @State private var clipboardOn = TextInsertion.clipboardFallback
    @State private var voiceEntries: [VoiceEntry] = []
    @State private var promptDraft = VoiceInput.cleanupPrompt
    @StateObject private var trust = AccessibilityTrust()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Voice").font(.title3).bold()
                Text("Dictate anywhere on your Mac. The words land at the caret in whatever you were typing in, and every transcript is kept here whether or not it reached a chat.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            voiceKey

            Divider()

            voiceLogSection
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
            Toggle(isOn: Binding(
                get: { VoiceInput.cleanupEnabled },
                set: { VoiceInput.cleanupEnabled = $0; cleanupOn = $0 })) {
                    Text("Clean up dictation before it lands").font(.caption)
                }
                .toggleStyle(.switch)
            if cleanupOn {
                HStack(spacing: 8) {
                    Text("using").font(.caption).foregroundStyle(.secondary)
                    ModelPickerButton(catalog: catalog, selection: VoiceInput.cleanupModel) { id in
                        VoiceInput.cleanupModel = id
                        cleanupModel = id
                    }
                }
                suggestedModels
                cleanupPromptEditor
            }
            Text("Speech-to-text returns what you said, not what you meant to write: no punctuation, \"um\"s left in, and the occasional wrong homophone. With this on, the raw transcript is passed through the model below to punctuate and clean it before it's inserted — a fraction of a cent per dictation, and about a second. Off, you get the transcript exactly as heard.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("\(ShortcutSettings.hint(.dictate)) dictates into the composer using OpenAI's transcription API. This is a separate key because OpenRouter doesn't carry audio — leave it blank and dictation stays off.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: Binding(
                get: { TextInsertion.clipboardFallback },
                set: { TextInsertion.clipboardFallback = $0; clipboardOn = $0 })) {
                    Text("Fall back to the clipboard if it can't be inserted").font(.caption)
                }
                .toggleStyle(.switch)
            Text("Off by default. A transcript on the clipboard is one you still have to paste, and it takes over something you may have been using. Every transcript is in the log below regardless.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: Binding(
                get: { TextInsertion.insertIntoFocusedApp },
                set: { TextInsertion.insertIntoFocusedApp = $0; insertOn = $0 })) {
                    Text("Type dictation into the app you're using").font(.caption)
                }
                .toggleStyle(.switch)
            Text("When the composer isn't focused, the transcript is inserted at the caret in the app you were in when you started speaking. Your clipboard is left alone — it's only used if the text can't be inserted at all.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Stated, not discovered. Without Accessibility this feature
            // degrades to a clipboard copy, and a silent degradation is
            // indistinguishable from the feature being broken.
            if insertOn && !trust.granted {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Accessibility is off, so dictation can only reach the clipboard.")
                            .font(.caption2)
                        Button("Open Settings") {
                            guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                            else { return }
                            NSWorkspace.shared.open(url)
                        }
                        .font(.caption2)
                        .buttonStyle(.borderless)
                    }
                    // Said here because the alternative is someone opening
                    // that pane, seeing Visor already switched on, and
                    // reasonably concluding the app is broken.
                    Text("If Visor is already switched on there, switch it off and on again. macOS ties the permission to the exact build it was granted to, and every update is a new one — the pane keeps showing the app as enabled either way, because it's listing the entry rather than checking it still matches.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

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

    /// Three that suit this job, with what they cost.
    ///
    /// The job is narrow — a couple of hundred tokens in, the same out, and it
    /// sits between you speaking and the words appearing. Instruction-following
    /// matters more than size here: a model that decides to *answer* your
    /// dictation instead of punctuating it has destroyed what you said, and at
    /// these prices the difference between the cheapest and the best of them is
    /// a rounding error.
    ///
    /// Avoid anything ending in `:batch`. Those are queued rather than
    /// answered, which is the opposite of what this needs.
    private static let suggestions: [(id: String, note: String)] = [
        ("google/gemini-2.5-flash-lite", "fast, follows instructions closely"),
        ("openai/gpt-5-nano", "cheaper out, still precise"),
        ("qwen/qwen3.7-flash", "cheapest of the three"),
    ]

    var suggestedModels: some View {
        HStack(spacing: 6) {
            Text("try").font(.caption2).foregroundStyle(.secondary)
            ForEach(Self.suggestions, id: \.id) { suggestion in
                Button {
                    VoiceInput.cleanupModel = suggestion.id
                    cleanupModel = suggestion.id
                } label: {
                    Text(suggestion.id.split(separator: "/").last.map(String.init) ?? suggestion.id)
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("\(suggestion.id) — \(suggestion.note)")
            }
            Spacer(minLength: 0)
        }
    }

    /// The instruction the cleanup model runs on.
    var cleanupPromptEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Instruction").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if promptDraft != VoiceInput.defaultCleanupPrompt {
                    Button("Reset") {
                        promptDraft = VoiceInput.defaultCleanupPrompt
                        VoiceInput.cleanupPrompt = promptDraft
                    }
                    .font(.caption2).buttonStyle(.borderless)
                }
            }
            TextEditor(text: $promptDraft)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 74)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: Design.Radius.control)
                    .fill(Color.primary.opacity(0.05)))
                // The single-argument form: Visor targets macOS 13, and the
                // two-argument onChange arrived in 14.
                .onChange(of: promptDraft) { value in
                    VoiceInput.cleanupPrompt = value
                }
            Text("Sent as the system prompt, with only the raw transcript as the message. It stays identical between dictations, so the provider serves it from cache — which is most of why this is quick. Saying what not to do matters more than what to do: a small model handed dictation will happily answer it, and that loses what you said.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                Button("Clear all") {
                    VoiceLog.clear()
                    voiceEntries = []
                }
                .disabled(voiceEntries.isEmpty)
            }
            if voiceEntries.isEmpty {
                Text("Nothing dictated yet. ⌘⌃V, or hold your push-to-talk key.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(voiceEntries) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.text)
                                        .font(.system(size: 11))
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(VoicePane.stamp.string(from: entry.date)
                                         + (entry.duration.map { String(format: " · %.1fs", $0) } ?? ""))
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 0)
                                Button {
                                    VoiceLog.delete(entry.id)
                                    voiceEntries.removeAll { $0.id == entry.id }
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help("Delete this entry")
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
        .onAppear { voiceEntries = VoiceLog.recent(limit: 30) }
    }
}

extension VoicePane {
    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}


/// Which account a CLI agent is actually signed in as, and how to change it.
///
/// Shown because it was invisible. The tool signs in once for the whole
/// machine, so an agent can spend a work subscription on personal questions
/// with nothing on screen saying so — the only way to find out was to ask the
/// agent, which is not a thing anyone should have to think to do about their
/// own billing.
private struct CLIAccountRow: View {
    let provider: AIProvider
    @ObservedObject var ai: AIRunner
    @ObservedObject private var accounts = CLIAccounts.shared
    @State private var showingProfile = false

    private var account: CLIAccount? { accounts.account(for: provider) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                fieldLabel("Account")
                if accounts.isChecking(provider) {
                    Text("checking…").font(.caption).foregroundStyle(.secondary)
                } else if let account {
                    Image(systemName: account.loggedIn
                          ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(account.loggedIn ? Color.green : Color.orange)
                    Text(account.summary).font(.caption)
                } else {
                    Text("unknown").font(.caption).foregroundStyle(.secondary)
                }
                Button("Check") { accounts.refresh(provider) }
                    .font(.caption2).buttonStyle(.borderless)
                Spacer(minLength: 0)
                Button(showingProfile ? "Hide profile" : "Use a different account") {
                    showingProfile.toggle()
                }
                .font(.caption2).buttonStyle(.borderless)
            }

            if showingProfile {
                HStack(spacing: 8) {
                    fieldLabel("Profile")
                    TextField("~/.claude — leave blank for the default", text: Binding(
                        get: { provider.configDir ?? "" },
                        set: { value in
                            var p = provider
                            p.configDir = value.isEmpty ? nil : value
                            ai.upsert(p)
                        }))
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { chooseDirectory() }
                        .font(.caption2)
                }
                // Said plainly, because the sign-in itself has to happen in a
                // terminal: it opens a browser and waits, which is not
                // something to run inside a notch.
                Text("A separate directory is a separate login, so one agent can be your personal account and another your work one. Point it somewhere new, then sign that profile in:")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(signInCommand)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: Design.Radius.control)
                            .fill(Color.primary.opacity(0.06)))
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(signInCommand, forType: .string)
                    }
                    .font(.caption2).buttonStyle(.borderless)
                }
            }
        }
        .onAppear { if account == nil { accounts.refresh(provider) } }
    }


    private var signInCommand: String {
        let dir = provider.configDir?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !dir.isEmpty else { return "\(provider.command) auth login" }
        return "CLAUDE_CONFIG_DIR=\(dir) \(provider.command) auth login"
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var updated = provider
        updated.configDir = url.path
        ai.upsert(updated)
        accounts.refresh(updated)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .frame(width: 64, alignment: .leading)
    }
}
