import Foundation

/// Which account a local CLI agent is signed in as.
///
/// This exists because the answer was invisible. A CLI agent uses whatever the
/// tool itself is logged in to — and the tool is logged in to one account for
/// the whole machine, chosen at some point in the past for some other purpose.
/// So an agent could quietly be spending a work subscription, and the only way
/// to find out was to ask it. That's a bad property for something billed to
/// someone: whose account a request lands on should be visible before the
/// request, not discoverable afterwards.
struct CLIAccount: Equatable {
    var loggedIn: Bool
    var email: String?
    var organisation: String?
    var subscription: String?
    var method: String?

    /// One line for the UI.
    var summary: String {
        guard loggedIn else { return "Not signed in" }
        let who = email ?? organisation ?? "signed in"
        guard let subscription, !subscription.isEmpty else { return who }
        return "\(who) · \(subscription)"
    }
}

/// Looks up and caches the account behind each CLI agent.
///
/// Cached because it costs a subprocess, and refreshed on demand rather than
/// polled — signing in happens outside Visor, so there's nothing to watch.
@MainActor
final class CLIAccounts: ObservableObject {
    static let shared = CLIAccounts()

    /// Keyed by agent name.
    @Published private(set) var accounts: [String: CLIAccount] = [:]
    @Published private(set) var checking: Set<String> = []

    private init() {}

    func account(for agent: AIProvider) -> CLIAccount? { accounts[agent.name] }

    func isChecking(_ agent: AIProvider) -> Bool { checking.contains(agent.name) }

    /// Ask the tool who it is. Only for tools that can answer.
    func refresh(_ agent: AIProvider) {
        guard CLICatalogue.reportsAccount(command: agent.command) else { return }
        guard !checking.contains(agent.name) else { return }
        checking.insert(agent.name)
        let name = agent.name
        let command = agent.command
        let configDir = agent.configDir
        Task {
            let result = await Self.status(command: command, configDir: configDir)
            await MainActor.run {
                self.checking.remove(name)
                if let result { self.accounts[name] = result }
            }
        }
    }

    /// Every CLI agent at once, for opening Settings.
    func refreshAll(_ agents: [AIProvider]) {
        for agent in agents where agent.isNotchCLI { refresh(agent) }
    }

    private static func status(command: String, configDir: String?) async -> CLIAccount? {
        guard let executable = CLIAgentRunner.resolve(command) else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = ["auth", "status", "--json"]

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = CLIAgentRunner.searchPath + ":" + (env["PATH"] ?? "")
        if let configDir, !configDir.isEmpty {
            env["CLAUDE_CONFIG_DIR"] = (configDir as NSString).expandingTildeInPath
        }
        task.environment = env

        let pipe = Pipe()
        task.standardOutput = pipe
        // Discarded: a warning on stderr isn't an answer, and mixing it into
        // the pipe would break the JSON.
        task.standardError = Pipe()

        do { try task.run() } catch { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return CLIAccount(
            loggedIn: object["loggedIn"] as? Bool ?? false,
            email: object["email"] as? String,
            organisation: object["orgName"] as? String,
            subscription: object["subscriptionType"] as? String,
            method: object["authMethod"] as? String)
    }
}
