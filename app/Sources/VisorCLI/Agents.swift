import Foundation

/// The agents the app knows, read from the same file it writes.
enum Agents {
    static func load() -> (agents: [AIProvider], defaultName: String?) {
        guard let data = try? Data(contentsOf: AIProvider.configURL),
              let cfg = try? JSONDecoder().decode(ProvidersConfig.self, from: data) else {
            return ([], nil)
        }
        let usable = cfg.providers.filter(\.isTerminalAgent)
        // The app's own defaults domain, read directly: a UserDefaults suite
        // named like an app's bundle id is refused with a warning.
        let chosen = CFPreferencesCopyAppValue(AIProvider.defaultProviderKey as CFString,
                                               AIProvider.defaultsSuite as CFString) as? String
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
