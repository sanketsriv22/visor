import AppKit
import Foundation

/// One AI target: a CLI command the tasks are handed to. The prompt is
/// appended as the final argument (e.g. Devin: `devin … -p "<prompt>"`).
struct AIProvider: Codable, Identifiable, Equatable {
    var name: String       // shown in the UI, e.g. "Devin"
    var command: String    // executable name or absolute path, e.g. "devin"
    var args: [String]     // fixed args; the prompt is appended after these
    var id: String { name }
}

private struct ProvidersConfig: Codable {
    var `default`: String
    var providers: [AIProvider]
}

/// Sends tasks to a configurable AI CLI and tracks the run for the UI.
/// Providers live in an editable JSON file so the user can add their own.
final class AIRunner: ObservableObject {
    enum Status: Equatable { case idle, running, done, failed(String) }

    @Published private(set) var status: Status = .idle
    @Published private(set) var providers: [AIProvider] = []
    @Published private(set) var defaultProviderName = ""
    /// Name of the provider for the most recent run, for status labels.
    @Published private(set) var lastProviderName = ""

    var isBusy: Bool { status == .running }

    private let workDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("repos")
    private let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("StickyNotes/ai-last.log")
    private let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("StickyNotes/ai-providers.json")

    private static let defaults = ProvidersConfig(
        default: "Devin",
        providers: [
            AIProvider(name: "Devin", command: "devin", args: ["--permission-mode", "dangerous", "-p"]),
            AIProvider(name: "Claude Code", command: "claude", args: ["-p"]),
        ]
    )

    private let defaultKey = "visor.defaultProvider"

    init() { loadProviders() }

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

    func sendToDefault(tasks: [String]) {
        guard let provider = defaultProvider else { return }
        send(tasks: tasks, provider: provider)
    }

    func send(tasks: [String], provider: AIProvider) {
        guard status != .running, !tasks.isEmpty else { return }
        guard let exe = resolveExecutable(provider.command) else {
            status = .failed("\(provider.name) not found (\(provider.command))")
            return
        }
        lastProviderName = provider.name

        let list = tasks.map { "- \($0)" }.joined(separator: "\n")
        let prompt = """
        Here are tasks from my sticky note:

        \(list)

        Work through them. For each task, do whatever it takes to finish it — you \
        have my permission to run any tools and to spin up additional agents or \
        sessions as needed. Make the actual changes (and open PRs where that fits). \
        When you complete a task, say so clearly. End with a short summary.
        """

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
        process.environment = env

        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            process.standardOutput = handle
            process.standardError = handle
        }

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.status = proc.terminationStatus == 0 ? .done : .failed("exit \(proc.terminationStatus)")
            }
        }

        do {
            try process.run()
            status = .running
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Open the run log in the user's default viewer.
    func revealLog() {
        if FileManager.default.fileExists(atPath: logURL.path) {
            NSWorkspace.shared.open(logURL)
        }
    }

    /// Open the providers JSON so the user can add/edit AI targets.
    func editConfig() {
        if !FileManager.default.fileExists(atPath: configURL.path) { saveConfig(Self.defaults) }
        NSWorkspace.shared.open(configURL)
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
