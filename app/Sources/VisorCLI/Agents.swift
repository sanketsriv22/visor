import Foundation

/// The agents the app knows, read from the same file it writes.
enum Agents {
    static func load() -> (agents: [AIProvider], defaultName: String?) {
        guard let data = try? Data(contentsOf: AIProvider.configURL),
              let cfg = try? JSONDecoder().decode(ProvidersConfig.self, from: data) else {
            return ([], nil)
        }
        let usable = cfg.providers.filter(\.isTerminalAgent)
        let chosen = UserDefaults(suiteName: AIProvider.defaultsSuite)?
            .string(forKey: AIProvider.defaultProviderKey)
        let name = [chosen, cfg.default].compactMap { $0 }
            .first { n in usable.contains { $0.name == n } } ?? usable.first?.name
        return (usable, name)
    }

    /// Why an agent can't be used right now, or nil.
    static func blocker(for agent: AIProvider) -> String? {
        if agent.isChat, !OpenRouterClient.hasKey {
            return "No OpenRouter key. Add one in Visor → Settings → Agents."
        }
        if !agent.isChat, CLIAgentRunner.resolve(agent.command) == nil {
            return "\(agent.command) isn't installed on this machine."
        }
        return nil
    }
}
