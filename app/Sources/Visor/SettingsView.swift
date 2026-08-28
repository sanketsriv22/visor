import SwiftUI
import AppKit

/// Lets the app point Settings at one agent when it opens — used when a send
/// is blocked because that agent has no API key stored yet, so the user lands
/// on the field they need instead of hunting for it.
final class SettingsFocus: ObservableObject {
    static let shared = SettingsFocus()
    @Published var provider: String?
    private init() {}
}

/// Visor settings: manage the agent CLIs tasks are sent to, and securely store
/// an API key for any agent that authenticates with one.
struct SettingsView: View {
    @ObservedObject var ai: AIRunner
    @ObservedObject private var focus = SettingsFocus.shared

    @State private var keyDraft: [String: String] = [:]
    @State private var newName = ""
    @State private var newCommand = ""
    @State private var newArgs = ""
    @State private var newKeyEnv = ""
    @State private var newKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Run agents in").font(.headline)
                Picker("", selection: Binding(get: { ai.runMode }, set: { ai.setRunMode($0) })) {
                    ForEach(AIRunner.RunMode.allCases, id: \.self) { mode in
                        Text(mode.menuTitle).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("Terminal opens each send in a window you can watch and follow up in. Background runs it silently and captures output to a log.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                Text("Agents run in this folder, and the task is framed as a task for that project. Pick a git repo under ~/repos or browse to any folder.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("AI Agents").font(.title3).bold()
                Text("Agents run as local CLIs and do the work. Add an API key only if the CLI needs one to authenticate (e.g. OPENAI_API_KEY for codex). Keys are stored in your macOS Keychain, never in a file.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(ai.providers) { provider in
                            providerRow(provider).id(provider.name)
                            Divider()
                        }
                    }
                }
                .onChange(of: focus.provider) { name in
                    guard let name else { return }
                    withAnimation { proxy.scrollTo(name, anchor: .center) }
                }
            }

            addAgentForm
        }
        .padding(18)
        .frame(width: 500, height: 480)
    }

    private func providerRow(_ p: AIProvider) -> some View {
        let wanted = focus.provider == p.name
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 6) {
                    Text(p.name).font(.headline)
                    if p.name == ai.defaultProviderName {
                        Text("default")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(.orange.opacity(0.25)))
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                Button(role: .destructive) { ai.remove(p) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove this agent")
            }

            commandLines(p)

            if p.needsKey {
                HStack(spacing: 8) {
                    Text(p.apiKeyEnv ?? "API key")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    SecureField(ai.hasKey(p) ? "•••••• (set) — type to replace" : "paste API key",
                                text: keyBinding(p.name))
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        ai.setKey(keyDraft[p.name] ?? "", for: p)
                        keyDraft[p.name] = ""
                        if focus.provider == p.name { focus.provider = nil }
                    }
                    .disabled((keyDraft[p.name] ?? "").isEmpty)
                }
                if wanted && !ai.hasKey(p) {
                    Text("Add a key here to send tasks to \(p.name).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(wanted ? Color.accentColor.opacity(0.12) : .clear))
        .animation(.easeInOut(duration: 0.25), value: wanted)
    }

    private var addAgentForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add an agent").font(.headline)
            HStack {
                TextField("Name", text: $newName).frame(width: 110)
                TextField("command (e.g. codex)", text: $newCommand).frame(width: 150)
                TextField("args (space-separated)", text: $newArgs)
            }
            .textFieldStyle(.roundedBorder)
            HStack {
                TextField("key env var — optional (e.g. OPENAI_API_KEY)", text: $newKeyEnv)
                SecureField("API key — optional", text: $newKey)
                Button("Add", action: addAgent)
                    .disabled(newName.isEmpty || newCommand.isEmpty)
            }
            .textFieldStyle(.roundedBorder)
        }
    }

    /// Show the actual command each run mode uses. When a provider runs
    /// differently in Terminal mode (e.g. Claude without -p), show both so it's
    /// clear the Terminal/Background toggle — not this row — picks which runs.
    @ViewBuilder
    private func commandLines(_ p: AIProvider) -> some View {
        let bgCmd = ([p.command] + p.args).joined(separator: " ") + " <prompt>"
        if p.isDevinCloud {
            Text("Creates a Devin cloud session via the API and opens it in Devin")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if let ia = p.interactiveArgs, ia != p.args {
            let termCmd = ([p.command] + ia).joined(separator: " ") + " <prompt>"
            VStack(alignment: .leading, spacing: 3) {
                modeCommand("Terminal", termCmd)
                modeCommand("Background", bgCmd)
            }
        } else {
            Text(bgCmd)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func modeCommand(_ mode: String, _ cmd: String) -> some View {
        HStack(spacing: 6) {
            Text(mode)
                .font(.caption2)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(.secondary.opacity(0.18)))
                .foregroundStyle(.secondary)
            Text(cmd)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
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

    private func keyBinding(_ name: String) -> Binding<String> {
        Binding(get: { keyDraft[name] ?? "" }, set: { keyDraft[name] = $0 })
    }

    private func addAgent() {
        let env = newKeyEnv.trimmingCharacters(in: .whitespaces)
        let provider = AIProvider(
            name: newName.trimmingCharacters(in: .whitespaces),
            command: newCommand.trimmingCharacters(in: .whitespaces),
            args: newArgs.split(separator: " ").map(String.init),
            apiKeyEnv: env.isEmpty ? nil : env
        )
        ai.upsert(provider)
        if !newKey.isEmpty { ai.setKey(newKey, for: provider) }
        newName = ""; newCommand = ""; newArgs = ""; newKeyEnv = ""; newKey = ""
    }
}
