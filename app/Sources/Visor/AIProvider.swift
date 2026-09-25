import Foundation

// The agent model, on its own so the terminal client (`visor`) shares it
// with the app: one file describes an agent, one file on disk holds them.

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
    /// Where this agent's CLI keeps its credentials.
    ///
    /// A tool signs in once for the whole machine, so without this every CLI
    /// agent shares one account — which is how a work subscription ends up
    /// answering personal questions with nothing on screen to say so. Pointing
    /// two agents at two directories makes them two accounts.
    var configDir: String?
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
    /// Tools this agent may run without asking each time.
    ///
    /// Per agent, not global: a research agent you let browse freely and an
    /// agent with shell access are not the same trust decision.
    var autoApprovedTools: [String]?

    /// Answer in the notch rather than a Terminal window. CLI agents only.
    var runsInNotch: Bool?

    /// Models this agent switches between often.
    ///
    /// OpenRouter lists several hundred; nobody picks from that in a notch.
    /// The picker shows these first and keeps the full catalogue behind a
    /// search, which is the difference between choosing and hunting.
    var favouriteModels: [String]?
    var id: String { name }

    var isDevinCloud: Bool { kind == .devinCloud }
    /// Runs a conversation in the notch rather than handing off to a CLI or
    /// the Devin API.
    var isChat: Bool { kind == .openRouter }

    /// A local CLI agent that answers in the notch instead of opening a
    /// Terminal — Claude Code and friends as first-class agents in the app.
    var isNotchCLI: Bool { (kind == nil || kind == .cli) && (runsInNotch ?? false) }

    /// Anything the composer can talk to.
    var isNotchAgent: Bool { isChat || isNotchCLI }
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

struct ProvidersConfig: Codable {
    var `default`: String
    var providers: [AIProvider]
}

extension AIProvider {
    /// The one file both the app and the terminal client read agents from.
    static let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("StickyNotes/ai-providers.json")
    /// The user's chosen default, in the app's defaults domain.
    static let defaultProviderKey = "visor.defaultProvider"
    static let defaultsSuite = "com.kitalabs.visor"

    /// Everything the terminal can talk to: hosted models, and local CLI
    /// agents whether or not the app runs them in the notch.
    var isTerminalAgent: Bool {
        isChat || ((kind == nil || kind == .cli) && !command.isEmpty)
    }
}
