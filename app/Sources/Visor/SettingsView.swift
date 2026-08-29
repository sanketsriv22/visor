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
        case .agents:    AgentsPane(ai: ai, catalog: catalog, focus: focus)
        case .workspace: WorkspacePane(ai: ai)
        case .mcp:       MCPPane()
        case .memory:    MemoryPane(chat: chat)
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

/// One agent, editable in place. Renaming rewrites the entry rather than
/// editing it, because the name is the identity everywhere else.
private struct AgentRow: View {
    @ObservedObject var ai: AIRunner
    @ObservedObject var catalog: ModelCatalog
    let provider: AIProvider
    let highlighted: Bool

    @State private var nameDraft = ""
    @State private var keyDraft = ""
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: provider.isChat ? "bubble.left.and.bubble.right" : "terminal")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                TextField("Agent name", text: Binding(
                    get: { nameDraft.isEmpty ? provider.name : nameDraft },
                    set: { nameDraft = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
                    .onSubmit(commitRename)

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

                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)

                Button(role: .destructive) { ai.remove(provider) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove this agent")
            }

            if provider.isChat {
                modelPicker
            }

            if expanded { details }
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(highlighted ? Color.accentColor.opacity(0.12) : .clear))
        .animation(.easeInOut(duration: 0.2), value: highlighted)
    }

    private var modelPicker: some View {
        HStack(spacing: 8) {
            Text("Model").font(.caption).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
            Picker("", selection: Binding(
                get: { provider.model ?? ChatController.defaultModel },
                set: { value in
                    var copy = provider
                    copy.model = value
                    ai.upsert(copy)
                })) {
                    // A model the user already picked may not be in the live
                    // list (no key yet, or it was retired); keep it selectable
                    // so opening Settings never silently rewrites their choice.
                    ForEach(modelOptions, id: \.self) { id in
                        Text(catalog.label(for: id)).tag(id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 340)
        }
    }

    @ViewBuilder
    private var details: some View {
        if provider.isChat {
            VStack(alignment: .leading, spacing: 4) {
                Text("Persona").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: Binding(
                    get: { provider.systemPrompt ?? "" },
                    set: { value in var p = provider; p.systemPrompt = value; ai.upsert(p) }))
                    .font(.system(size: 11))
                    .frame(height: 60)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(.secondary.opacity(0.3), lineWidth: 1))
                Text("Prepended to every conversation with this agent.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Command").font(.caption).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
                    TextField("claude", text: Binding(
                        get: { provider.command },
                        set: { value in var p = provider; p.command = value; ai.upsert(p) }))
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("Args").font(.caption).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
                    TextField("space-separated", text: Binding(
                        get: { provider.args.joined(separator: " ") },
                        set: { value in
                            var p = provider
                            p.args = value.split(separator: " ").map(String.init)
                            ai.upsert(p)
                        }))
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("Key env").font(.caption).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
                    TextField("e.g. OPENAI_API_KEY — optional", text: Binding(
                        get: { provider.apiKeyEnv ?? "" },
                        set: { value in
                            var p = provider
                            p.apiKeyEnv = value.isEmpty ? nil : value
                            ai.upsert(p)
                        }))
                        .textFieldStyle(.roundedBorder)
                }
                if provider.needsKey && !provider.isChat {
                    HStack {
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
    }

    private var modelOptions: [String] {
        var ids = catalog.ids
        if let current = provider.model, !ids.contains(current) { ids.insert(current, at: 0) }
        return ids
    }

    private func commitRename() {
        let name = nameDraft.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != provider.name,
              !ai.providers.contains(where: { $0.name == name }) else { return }
        var copy = provider
        copy.name = name
        ai.remove(provider)
        ai.upsert(copy)
        nameDraft = ""
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
                Text("⌘1 and ⌘2 switch between notes and chat while it's open.")
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
