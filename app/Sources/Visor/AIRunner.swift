import AppKit
import Foundation

/// One AI target: a CLI command the tasks are handed to. The prompt is
/// appended as the final argument (e.g. Devin: `devin … -p "<prompt>"`).
struct AIProvider: Codable, Identifiable, Equatable {
    /// How a send reaches the agent: run a local CLI, or POST to the Devin
    /// cloud API and open the resulting session.
    /// - cli: run a local command-line agent
    /// - devinCloud: POST to Devin's REST API and open the session
    /// - openRouter: talk to a model directly, in the notch
    enum Kind: String, Codable { case cli, devinCloud, openRouter }

    var name: String          // shown in the UI, e.g. "Devin"
    var command: String       // executable name or absolute path, e.g. "devin"
    var args: [String]        // fixed args; the prompt is appended after these
    var apiKeyEnv: String?    // env var the CLI reads its key from, if any (e.g. "OPENAI_API_KEY")
    var interactiveArgs: [String]?  // args used in Terminal mode instead of `args`, to run the
                                    // CLI interactively (e.g. claude with no -p). Falls back to `args`.
    var kind: Kind?           // nil / .cli = local CLI; .devinCloud = Devin REST API
    /// OpenRouter model id for `.openRouter` agents, e.g. "anthropic/claude-sonnet-4".
    var model: String?
    /// Optional persona prepended to every conversation with this agent.
    var systemPrompt: String?
    /// How hard the model should think, for models that support it:
    /// "low" / "medium" / "high". Nil leaves it to the provider's default.
    var effort: String?
    /// Route to the fastest provider serving this model rather than the
    /// cheapest. Costs more per token; worth it for short interactive turns.
    var fastMode: Bool?
    var id: String { name }

    var isDevinCloud: Bool { kind == .devinCloud }
    /// Runs a conversation in the notch rather than handing off to a CLI or
    /// the Devin API.
    var isChat: Bool { kind == .openRouter }
    /// Whether this provider authenticates with a stored key (env var or Bearer token).
    var needsKey: Bool { apiKeyEnv != nil || isDevinCloud || isChat }

    /// Which Keychain account holds this agent's key.
    ///
    /// Every OpenRouter agent shares one entry: a user who names five agents
    /// pointing at five models has one OpenRouter account behind all of them,
    /// and should paste the key once. CLI and Devin agents keep their own.
    var keyAccount: String {
        isChat ? OpenRouterClient.sharedKeyAccount : name
    }
}

private struct ProvidersConfig: Codable {
    var `default`: String
    var providers: [AIProvider]
}

/// Sends tasks to a configurable AI CLI and tracks the run for the UI.
/// Providers live in an editable JSON file so the user can add their own.
final class AIRunner: ObservableObject {
    enum RunResult: Equatable { case none, done, failed(String) }

    /// Where a send runs: in a real Terminal window you can watch and follow up
    /// in, or silently in the background with output captured to a log file.
    enum RunMode: String, CaseIterable {
        case terminal, background
        var menuTitle: String {
            switch self {
            case .terminal:   return "Terminal — watch it run"
            case .background: return "Background — logged silently"
            }
        }
    }

    /// How many agent runs are in flight (multiple tasks can run at once).
    @Published private(set) var runningCount = 0
    /// In-flight run count per task id, for the per-row "agent running" spinner.
    @Published private(set) var runningTaskIDs: [UUID: Int] = [:]
    /// Outcome of the most recently finished run.
    @Published private(set) var lastResult: RunResult = .none
    /// For a Devin Cloud send, the created session's URL (so the footer can
    /// offer to reopen it); nil for local CLI runs.
    @Published private(set) var lastSessionURL: URL?
    /// Whether sends open a Terminal window or run silently in the background.
    @Published private(set) var runMode: RunMode = .terminal
    /// User-chosen local repo/folder agents run in (nil → default ~/repos).
    @Published private(set) var projectDir: URL?

    func isRunning(_ id: UUID) -> Bool { (runningTaskIDs[id] ?? 0) > 0 }
    @Published private(set) var providers: [AIProvider] = []
    @Published private(set) var defaultProviderName = ""
    /// Name of the provider for the most recent run, for status labels.
    @Published private(set) var lastProviderName = ""

    var isBusy: Bool { runningCount > 0 }
    private var lastLogURL: URL?

    /// How long a finished run's status stays in the note footer before it
    /// clears itself.
    private static let resultLinger: TimeInterval = 12
    /// Pending auto-clear of `lastResult`, cancelled if a new run starts first.
    private var resultClear: DispatchWorkItem?

    /// Publish a run outcome, then clear it after `resultLinger`.
    ///
    /// A run outcome is transient status, not a standing condition. Assigning
    /// `lastResult` directly used to park the result under the user's tasks
    /// until the *next* send — so a single failure read as a permanently
    /// broken app. Nothing in the footer is permanent any more.
    private func setResult(_ result: RunResult) {
        resultClear?.cancel()
        resultClear = nil
        lastResult = result
        guard result != .none else { return }
        let work = DispatchWorkItem { [weak self] in
            // A run that started in the meantime owns the footer now.
            guard let self, self.runningCount == 0 else { return }
            self.lastResult = .none
        }
        resultClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resultLinger, execute: work)
    }

    private var homeDir: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Where agents run: the user-chosen project folder if set and present,
    /// else ~/repos, else home. A sent task works inside whatever local repo the
    /// user picked, with access to all of its code.
    private var workDir: URL {
        let fm = FileManager.default
        if let p = projectDir, fm.fileExists(atPath: p.path) { return p }
        let repos = homeDir.appendingPathComponent("repos")
        if fm.fileExists(atPath: repos.path) { return repos }
        return homeDir
    }

    /// The working directory shown to the user, with home abbreviated to ~.
    var workDirDisplay: String {
        let p = workDir.path, h = homeDir.path
        return p.hasPrefix(h) ? "~" + p.dropFirst(h.count) : p
    }

    /// Git repos directly under ~/repos, for quick selection in the menu/Settings.
    var availableRepos: [URL] {
        let fm = FileManager.default
        let repos = homeDir.appendingPathComponent("repos")
        let subs = (try? fm.contentsOfDirectory(
            at: repos, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return subs.filter { url in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return false }
            return fm.fileExists(atPath: url.appendingPathComponent(".git").path)
        }.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }
    private let logsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("StickyNotes/visor-logs", isDirectory: true)
    private let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("StickyNotes/ai-providers.json")

    private static let defaults = ProvidersConfig(
        default: "Devin",
        providers: [
            AIProvider(name: "Devin", command: "devin", args: ["--permission-mode", "dangerous", "-p"]),
            // In Terminal mode Claude runs interactively (no -p): you see it work
            // and can follow up. Background mode still uses -p (headless).
            AIProvider(name: "Claude Code", command: "claude", args: ["--dangerously-skip-permissions", "-p"], interactiveArgs: ["--dangerously-skip-permissions"]),
            // Creates a session via the Devin REST API and opens it in the Devin
            // app/web. Needs a Devin API key (stored in the Keychain).
            AIProvider(name: "Devin (Cloud)", command: "", args: [], kind: .devinCloud),
        ]
    )

    private let defaultKey = "visor.defaultProvider"
    private let runModeKey = "visor.runMode"
    private let projectDirKey = "visor.projectDir"

    init() {
        loadProviders()
        if let raw = UserDefaults.standard.string(forKey: runModeKey),
           let mode = RunMode(rawValue: raw) {
            runMode = mode
        }
        if let p = UserDefaults.standard.string(forKey: projectDirKey), !p.isEmpty {
            projectDir = URL(fileURLWithPath: p)
        }
    }

    var defaultProvider: AIProvider? {
        providers.first { $0.name == defaultProviderName } ?? providers.first
    }

    /// Choose which agent the send buttons target (set from the menu-bar
    /// settings). Persisted so it sticks across launches.
    func setDefault(_ name: String) {
        guard providers.contains(where: { $0.name == name }) else { return }
        defaultProviderName = name
        UserDefaults.standard.set(name, forKey: defaultKey)
    }

    /// Choose whether sends open a Terminal window or run in the background.
    func setRunMode(_ mode: RunMode) {
        runMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: runModeKey)
    }

    /// Choose the local repo/folder agents run in (nil resets to the default).
    func setProjectDir(_ url: URL?) {
        projectDir = url
        if let url { UserDefaults.standard.set(url.path, forKey: projectDirKey) }
        else { UserDefaults.standard.removeObject(forKey: projectDirKey) }
    }

    func sendToDefault(tasks: [String], taskIDs: [UUID] = []) {
        guard let provider = defaultProvider else { return }
        send(tasks: tasks, provider: provider, taskIDs: taskIDs)
    }

    func send(tasks: [String], provider: AIProvider, taskIDs: [UUID] = []) {
        guard !tasks.isEmpty else { return } // no single-run guard: runs are concurrent
        lastSessionURL = nil
        setResult(.none)   // a new send supersedes whatever the footer showed
        if provider.isChat {
            // Chat agents answer in the notch: hand the tasks to the composer
            // rather than opening a Terminal or a browser tab.
            lastProviderName = provider.name
            NotificationCenter.default.post(
                name: .visorRunInNotch, object: nil,
                userInfo: ["provider": provider.name,
                           "prompt": buildPrompt(tasks, style: .plain)])
            return
        }
        if provider.isDevinCloud {
            sendToDevinCloud(tasks: tasks, provider: provider, taskIDs: taskIDs)
            return
        }
        guard let exe = resolveExecutable(provider.command) else {
            lastProviderName = provider.name
            setResult(.failed("\(provider.name) not found (\(provider.command))"))
            return
        }
        lastProviderName = provider.name
        // Local CLI agents run in the chosen project folder, so the prompt frames
        // the task for that repo. Devin Cloud works in its own sandbox, so it omits
        // the local working-directory line.
        let prompt = buildPrompt(tasks, style: .coding, includeWorkdir: true)
        switch runMode {
        case .terminal:   runInTerminal(exe: exe, provider: provider, prompt: prompt)
        case .background: runInBackground(exe: exe, provider: provider, prompt: prompt, taskIDs: taskIDs)
        }
    }

    /// How a task is framed for the agent receiving it.
    private enum PromptStyle {
        /// A coding agent with a checkout and a shell.
        case coding
        /// A conversation. No repo, no tools, no PRs.
        case plain
    }

    /// Turn selected tasks into a prompt.
    ///
    /// The framing has to match the agent, which it previously didn't: every
    /// send got the coding preamble, so "order hand soap" arrived at a chat
    /// model as a task for a repository, with permission to spin up sessions
    /// and open pull requests. That reads as a broken app, and it drags the
    /// model's answer somewhere useless.
    ///
    /// A conversation gets the task close to verbatim. A single task is sent
    /// exactly as written — the user already said what they wanted, and
    /// wrapping it only gives the model something else to respond to.
    private func buildPrompt(_ tasks: [String], style: PromptStyle,
                             includeWorkdir: Bool = false) -> String {
        let list = tasks.map { "- \($0)" }.joined(separator: "\n")

        switch style {
        case .plain:
            guard tasks.count > 1 else { return tasks[0] }
            return """
            Help me with these:

            \(list)
            """

        case .coding:
            let context = includeWorkdir
                ? "\nYou're working in \(workDirDisplay) (the current directory) — treat these "
                  + "as tasks for that project, and you have access to all of its code.\n"
                : ""
            return """
            Here are tasks from my sticky note:

            \(list)
            \(context)
            Work through them. For each task, do whatever it takes to finish it — you \
            have my permission to run any tools and to spin up additional agents or \
            sessions as needed. Make the actual changes (and open PRs where that fits). \
            When you complete a task, say so clearly. End with a short summary.
            """
        }
    }

    /// Create a Devin cloud session via the REST API and open it in the Devin
    /// app/web. Auth is a Devin API key stored in the Keychain (per provider).
    private func sendToDevinCloud(tasks: [String], provider: AIProvider, taskIDs: [UUID]) {
        lastProviderName = provider.name
        guard let key = Keychain.get(provider.name), !key.isEmpty else {
            // Not a failure — the agent was simply never configured. Open
            // Settings on it rather than leaving a warning in the note.
            setResult(.none)
            NotificationCenter.default.post(
                name: .visorProviderNeedsKey, object: nil,
                userInfo: ["provider": provider.name])
            return
        }
        guard let url = URL(string: "https://api.devin.ai/v1/sessions") else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["prompt": buildPrompt(tasks, style: .coding)]
        if let first = tasks.first?.trimmingCharacters(in: .whitespaces), !first.isEmpty {
            body["title"] = String(first.prefix(60))
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        // Reuse the in-flight indicators while the POST is outstanding.
        runningCount += 1
        for id in taskIDs { runningTaskIDs[id, default: 0] += 1 }

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.runningCount = max(0, self.runningCount - 1)
                for id in taskIDs {
                    let n = (self.runningTaskIDs[id] ?? 0) - 1
                    if n <= 0 { self.runningTaskIDs[id] = nil } else { self.runningTaskIDs[id] = n }
                }
                self.lastProviderName = provider.name
                if let error {
                    self.setResult(.failed(error.localizedDescription))
                    return
                }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(code) else {
                    self.setResult(.failed("Devin API error \(code)"))
                    return
                }
                if let data,
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let urlStr = obj["url"] as? String, let sessionURL = URL(string: urlStr) {
                    self.lastSessionURL = sessionURL
                    NSWorkspace.shared.open(sessionURL)
                }
                self.setResult(.done)
            }
        }.resume()
    }

    /// Run the agent silently; stdout/stderr go to a per-run log file and the
    /// row shows a spinner while the run is in flight.
    private func runInBackground(exe: String, provider: AIProvider, prompt: String, taskIDs: [UUID]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = provider.args + [prompt]
        process.currentDirectoryURL = workDir

        // GUI apps inherit a bare PATH; give the CLI the usual tool locations.
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        // If this agent authenticates via an API key, inject it from the Keychain.
        if let keyEnv = provider.apiKeyEnv, let key = Keychain.get(provider.name) {
            env[keyEnv] = key
        }
        process.environment = env

        // Each concurrent run gets its own log so they don't interleave.
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let logURL = logsDir.appendingPathComponent("\(safeName(provider.name))-\(UUID().uuidString.prefix(8)).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            process.standardOutput = handle
            process.standardError = handle
        }

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                self.runningCount = max(0, self.runningCount - 1)
                for id in taskIDs {
                    let n = (self.runningTaskIDs[id] ?? 0) - 1
                    if n <= 0 { self.runningTaskIDs[id] = nil } else { self.runningTaskIDs[id] = n }
                }
                self.setResult(proc.terminationStatus == 0 ? .done : .failed("exit \(proc.terminationStatus)"))
                self.lastProviderName = provider.name
                self.lastLogURL = logURL
            }
        }

        do {
            try process.run()
            runningCount += 1
            for id in taskIDs { runningTaskIDs[id, default: 0] += 1 }
            lastLogURL = logURL
        } catch {
            setResult(.failed(error.localizedDescription))
        }
    }

    /// Run the agent in a Terminal window the user can watch and follow up in.
    /// We write a tiny `.command` script (PATH + any Keychain key + the
    /// configured command, with the prompt read from a sibling file so no
    /// shell-escaping can go wrong) and open it, which Terminal.app executes.
    /// The window stays open after the agent exits until a key is pressed, so
    /// the output isn't lost.
    private func runInTerminal(exe: String, provider: AIProvider, prompt: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let runsDir = home.appendingPathComponent("StickyNotes/visor-runs", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: runsDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        cleanOldRuns(runsDir)

        let stamp = "\(safeName(provider.name))-\(UUID().uuidString.prefix(8))"
        let promptURL = runsDir.appendingPathComponent("\(stamp).prompt.txt")
        let scriptURL = runsDir.appendingPathComponent("\(stamp).command")
        do {
            try prompt.write(to: promptURL, atomically: true, encoding: .utf8)
        } catch {
            setResult(.failed("couldn't stage prompt: \(error.localizedDescription)"))
            return
        }

        let path = "\(home.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let workdir = workDir.path
        // Terminal mode prefers interactiveArgs (e.g. claude with no -p) so the
        // agent runs as a live session you can watch and follow up in.
        let runArgs = provider.interactiveArgs ?? provider.args
        let argv = ([exe] + runArgs).map(Self.shq).joined(separator: " ")

        var lines = [
            "#!/bin/bash",
            "export PATH=\(Self.shq(path)):\"$PATH\"",
        ]
        // If this agent authenticates via an API key, inject it from the Keychain.
        if let keyEnv = provider.apiKeyEnv, let key = Keychain.get(provider.name) {
            lines.append("export \(keyEnv)=\(Self.shq(key))")
        }
        lines += [
            "cd \(Self.shq(workdir)) 2>/dev/null || cd \"$HOME\"",
            "clear",
            "printf '\\033[1m▶ Visor → %s\\033[0m\\n\\n' \(Self.shq(provider.name))",
            "\(argv) \"$(cat \(Self.shq(promptURL.path)))\"",
            "status=$?",
            "printf '\\n\\033[2m— %s exited (%s). Press any key to close. —\\033[0m' \(Self.shq(provider.name)) \"$status\"",
            "read -n 1 -s",
        ]
        let script = lines.joined(separator: "\n") + "\n"
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        } catch {
            setResult(.failed("couldn't stage run: \(error.localizedDescription)"))
            return
        }

        NSWorkspace.shared.open(scriptURL) // a .command file → Terminal executes it
        lastProviderName = provider.name

        // The prompt/script are consumed at launch; remove them shortly after so
        // a Keychain-injected key isn't left sitting on disk.
        let urls = [promptURL, scriptURL]
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Drop stale run scripts/prompts (older than an hour) as a backstop in case
    /// a delayed cleanup didn't run (e.g. the app quit before its timer fired).
    private func cleanOldRuns(_ dir: URL) {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for url in items {
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let mod, mod < cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Quote a string as a single safe POSIX shell word.
    private static func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func safeName(_ name: String) -> String {
        name.components(separatedBy: CharacterSet(charactersIn: "/\\: ")).joined(separator: "-")
    }

    /// Open the most recent run's result: a Devin session URL if the last send
    /// was a cloud one, otherwise the local log file.
    func revealLog() {
        if let url = lastSessionURL {
            NSWorkspace.shared.open(url)
            return
        }
        if let url = lastLogURL, FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Open the providers JSON so the user can add/edit AI targets.
    func editConfig() {
        if !FileManager.default.fileExists(atPath: configURL.path) { saveConfig(Self.defaults) }
        NSWorkspace.shared.open(configURL)
    }

    // MARK: - Editing providers + keys (used by the Settings window)

    /// Add or replace a provider (matched by name) and persist.
    func upsert(_ provider: AIProvider) {
        if let i = providers.firstIndex(where: { $0.name == provider.name }) {
            providers[i] = provider
        } else {
            providers.append(provider)
        }
        persist()
    }

    /// Rename an agent in place.
    ///
    /// Not remove-then-add: that dropped the agent to the end of the list,
    /// cleared its Keychain entry when no other agent shared the account, and
    /// lost its default status — so renaming a CLI agent silently deleted its
    /// key. The name is the identity everywhere else, so the key and the
    /// default move with it.
    @discardableResult
    func rename(_ provider: AIProvider, to newName: String) -> Bool {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != provider.name,
              !providers.contains(where: { $0.name == name }),
              let i = providers.firstIndex(where: { $0.name == provider.name })
        else { return false }

        var renamed = provider
        renamed.name = name
        // Carry the key across when it was stored under the old name (CLI and
        // Devin agents); chat agents share one account, so there's nothing to
        // move.
        if provider.keyAccount == provider.name, let key = Keychain.get(provider.name) {
            Keychain.set(key, account: renamed.keyAccount)
            Keychain.delete(provider.name)
        }
        providers[i] = renamed
        if defaultProviderName == provider.name { defaultProviderName = name }
        UserDefaults.standard.set(defaultProviderName, forKey: defaultKey)
        persist()
        return true
    }

    func remove(_ provider: AIProvider) {
        providers.removeAll { $0.name == provider.name }
        // Only drop the key if no remaining agent shares that account — chat
        // agents all point at the one OpenRouter entry.
        if !providers.contains(where: { $0.keyAccount == provider.keyAccount }) {
            Keychain.delete(provider.keyAccount)
        }
        if defaultProviderName == provider.name { defaultProviderName = providers.first?.name ?? "" }
        persist()
    }

    /// Whether a key has been stored for an agent that needs one.
    func hasKey(_ provider: AIProvider) -> Bool {
        provider.needsKey && Keychain.has(provider.keyAccount)
    }

    /// Save (or clear, if empty) an agent's API key in the Keychain.
    func setKey(_ value: String, for provider: AIProvider) {
        Keychain.set(value.trimmingCharacters(in: .whitespacesAndNewlines),
                     account: provider.keyAccount)
        objectWillChange.send()
    }

    private func persist() {
        saveConfig(ProvidersConfig(default: defaultProviderName, providers: providers))
        objectWillChange.send()
    }

    // MARK: - Config

    private func loadProviders() {
        if let data = try? Data(contentsOf: configURL),
           let cfg = try? JSONDecoder().decode(ProvidersConfig.self, from: data),
           !cfg.providers.isEmpty {
            providers = cfg.providers
            defaultProviderName = cfg.default
        } else {
            providers = Self.defaults.providers
            defaultProviderName = Self.defaults.default
            saveConfig(Self.defaults)
        }
        // Migrate older configs: Claude Code should run interactively in Terminal
        // mode (no -p) so you watch it work and can follow up. Add it if missing.
        var migrated = false
        for i in providers.indices
        where (providers[i].command == "claude" || providers[i].command.hasSuffix("/claude"))
            && providers[i].interactiveArgs == nil {
            providers[i].interactiveArgs = []
            migrated = true
        }
        // Add the Devin Cloud target if the config predates it.
        if !providers.contains(where: { $0.isDevinCloud }) {
            providers.append(AIProvider(name: "Devin (Cloud)", command: "", args: [], kind: .devinCloud))
            migrated = true
        }
        if migrated { saveConfig(ProvidersConfig(default: defaultProviderName, providers: providers)) }
        // The user's saved choice (from settings) wins over the file default.
        if let saved = UserDefaults.standard.string(forKey: defaultKey),
           providers.contains(where: { $0.name == saved }) {
            defaultProviderName = saved
        }
    }

    private func saveConfig(_ cfg: ProvidersConfig) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? enc.encode(cfg).write(to: configURL)
    }

    /// Resolve a command name to an executable path (or use it as-is if it's a path).
    private func resolveExecutable(_ command: String) -> String? {
        if command.contains("/") {
            let path = (command as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        return dirs.map { "\($0)/\(command)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

extension Notification.Name {
    /// Posted around anything that raises a system prompt (microphone,
    /// Accessibility). The notch sits above the menu bar, which means it also
    /// sits above those dialogs — so it steps down while one is up.
    /// userInfo: "showing" (Bool).
    static let visorSystemPrompt = Notification.Name("visor.systemPrompt")

    /// Posted from the notch to open the Settings window. The notch has no
    /// menu bar of its own, so this is how a dead end there ("no agents yet")
    /// offers a way out.
    static let visorOpenSettings = Notification.Name("visor.openSettings")

    /// Posted when tasks are sent to a chat agent, which answers in the notch.
    /// userInfo: "provider" (agent name), "prompt".
    static let visorRunInNotch = Notification.Name("visor.runInNotch")

    /// Posted when a send can't proceed because that agent has no API key
    /// stored yet. The app opens Settings on the agent; the note stays clean.
    static let visorProviderNeedsKey = Notification.Name("visor.providerNeedsKey")
}
