import AppKit
import Foundation

/// One AI target: a CLI command the tasks are handed to. The prompt is
/// appended as the final argument (e.g. Devin: `devin … -p "<prompt>"`).
struct AIProvider: Codable, Identifiable, Equatable {
    var name: String          // shown in the UI, e.g. "Devin"
    var command: String       // executable name or absolute path, e.g. "devin"
    var args: [String]        // fixed args; the prompt is appended after these
    var apiKeyEnv: String?    // env var the CLI reads its key from, if any (e.g. "OPENAI_API_KEY")
    var interactiveArgs: [String]?  // args used in Terminal mode instead of `args`, to run the
                                    // CLI interactively (e.g. claude with no -p). Falls back to `args`.
    var id: String { name }
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
    /// Whether sends open a Terminal window or run silently in the background.
    @Published private(set) var runMode: RunMode = .terminal

    func isRunning(_ id: UUID) -> Bool { (runningTaskIDs[id] ?? 0) > 0 }
    @Published private(set) var providers: [AIProvider] = []
    @Published private(set) var defaultProviderName = ""
    /// Name of the provider for the most recent run, for status labels.
    @Published private(set) var lastProviderName = ""

    var isBusy: Bool { runningCount > 0 }
    private var lastLogURL: URL?

    private let workDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("repos")
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
            AIProvider(name: "Claude Code", command: "claude", args: ["-p"], interactiveArgs: []),
        ]
    )

    private let defaultKey = "visor.defaultProvider"
    private let runModeKey = "visor.runMode"

    init() {
        loadProviders()
        if let raw = UserDefaults.standard.string(forKey: runModeKey),
           let mode = RunMode(rawValue: raw) {
            runMode = mode
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

    func sendToDefault(tasks: [String], taskIDs: [UUID] = []) {
        guard let provider = defaultProvider else { return }
        send(tasks: tasks, provider: provider, taskIDs: taskIDs)
    }

    func send(tasks: [String], provider: AIProvider, taskIDs: [UUID] = []) {
        guard !tasks.isEmpty else { return } // no single-run guard: runs are concurrent
        guard let exe = resolveExecutable(provider.command) else {
            lastProviderName = provider.name
            lastResult = .failed("\(provider.name) not found (\(provider.command))")
            return
        }
        lastProviderName = provider.name
        let prompt = buildPrompt(tasks)
        switch runMode {
        case .terminal:   runInTerminal(exe: exe, provider: provider, prompt: prompt)
        case .background: runInBackground(exe: exe, provider: provider, prompt: prompt, taskIDs: taskIDs)
        }
    }

    private func buildPrompt(_ tasks: [String]) -> String {
        let list = tasks.map { "- \($0)" }.joined(separator: "\n")
        return """
        Here are tasks from my sticky note:

        \(list)

        Work through them. For each task, do whatever it takes to finish it — you \
        have my permission to run any tools and to spin up additional agents or \
        sessions as needed. Make the actual changes (and open PRs where that fits). \
        When you complete a task, say so clearly. End with a short summary.
        """
    }

    /// Run the agent silently; stdout/stderr go to a per-run log file and the
    /// row shows a spinner while the run is in flight.
    private func runInBackground(exe: String, provider: AIProvider, prompt: String, taskIDs: [UUID]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = provider.args + [prompt]
        process.currentDirectoryURL = FileManager.default.fileExists(atPath: workDir.path)
            ? workDir
            : FileManager.default.homeDirectoryForCurrentUser

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
                self.lastResult = proc.terminationStatus == 0 ? .done : .failed("exit \(proc.terminationStatus)")
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
            lastResult = .failed(error.localizedDescription)
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
            lastResult = .failed("couldn't stage prompt: \(error.localizedDescription)")
            return
        }

        let path = "\(home.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let workdir = FileManager.default.fileExists(atPath: workDir.path) ? workDir.path : home.path
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
            lastResult = .failed("couldn't stage run: \(error.localizedDescription)")
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

    /// Open the most recent run's log in the user's default viewer.
    func revealLog() {
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

    func remove(_ provider: AIProvider) {
        providers.removeAll { $0.name == provider.name }
        Keychain.delete(provider.name)
        if defaultProviderName == provider.name { defaultProviderName = providers.first?.name ?? "" }
        persist()
    }

    /// Whether a key has been stored for an agent that needs one.
    func hasKey(_ provider: AIProvider) -> Bool {
        provider.apiKeyEnv != nil && Keychain.has(provider.name)
    }

    /// Save (or clear, if empty) an agent's API key in the Keychain.
    func setKey(_ value: String, for provider: AIProvider) {
        Keychain.set(value.trimmingCharacters(in: .whitespacesAndNewlines), account: provider.name)
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
