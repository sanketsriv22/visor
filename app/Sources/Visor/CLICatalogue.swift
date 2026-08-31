import Foundation

/// Model suggestions for local command-line agents.
///
/// Keyed by the command the agent runs, because the answer is entirely that
/// command's business: `claude` and `codex` share no model names, and neither
/// will share them with whatever gets added next. Anything unrecognised gets no
/// suggestions rather than a plausible-looking list of another tool's models —
/// a wrong suggestion here fails at session start, one turn later, and reads as
/// the agent misbehaving rather than the picker being wrong.
///
/// The names are read out of the installed binary, not remembered. That's a
/// snapshot of one version, which is why the picker always keeps a field for
/// typing something that isn't here.
enum CLICatalogue {
    struct Model: Identifiable, Hashable {
        let id: String
        let title: String
        var note: String?
    }

    struct Group: Identifiable, Hashable {
        let id: String
        let models: [Model]
    }

    /// Suggestions for `command`, which may be a path.
    static func groups(for command: String) -> [Group] {
        switch name(of: command) {
        case "claude": return claude
        default: return []
        }
    }

    /// How a model id reads as a name. Falls back to the id, which is right for
    /// anything typed by hand or belonging to a tool we have no list for.
    static func title(for id: String, command: String) -> String {
        let all = groups(for: command).flatMap(\.models)
        guard let known = all.first(where: { $0.id == id }) else { return id }
        if known.note == oneMillion { return "\(known.title) 1M" }
        return known.title
    }

    /// Whether this command has anything to suggest, so the picker can drop its
    /// section headers rather than render empty scaffolding around a text field.
    static func hasSuggestions(for command: String) -> Bool {
        !groups(for: command).isEmpty
    }

    /// Flags that turn a tool's output into a JSON event stream.
    ///
    /// `--verbose` isn't optional here: the CLI refuses stream-json in print
    /// mode without it.
    static let streamingArguments = [
        "--output-format", "stream-json", "--include-partial-messages", "--verbose",
    ]

    /// Whether this command understands those flags. Anything else is left
    /// alone — passing a tool flags it doesn't know makes it exit before it
    /// has said anything, which reads as the agent being broken.
    static func streamsJSON(command: String) -> Bool {
        name(of: command) == "claude"
    }

    /// The executable's own name, so `/opt/homebrew/bin/claude` and `claude`
    /// are the same agent.
    private static func name(of command: String) -> String {
        (command as NSString).lastPathComponent.lowercased()
    }

    private static let oneMillion = "1M context"

    private static let claude: [Group] = [
        Group(id: "Tracks the latest", models: [
            Model(id: "default", title: "Default", note: "whatever the CLI is set to"),
            Model(id: "best", title: "Best available"),
            Model(id: "opus", title: "Opus"),
            Model(id: "sonnet", title: "Sonnet"),
            Model(id: "haiku", title: "Haiku"),
            Model(id: "fable", title: "Fable"),
            Model(id: "opus[1m]", title: "Opus", note: oneMillion),
            Model(id: "sonnet[1m]", title: "Sonnet", note: oneMillion),
        ]),
        Group(id: "Claude 5", models: [
            Model(id: "claude-opus-5", title: "Opus 5"),
            Model(id: "claude-sonnet-5", title: "Sonnet 5"),
            Model(id: "claude-fable-5", title: "Fable 5"),
        ]),
        Group(id: "Claude 4", models: [
            Model(id: "claude-opus-4-8", title: "Opus 4.8"),
            Model(id: "claude-opus-4-7", title: "Opus 4.7"),
            Model(id: "claude-opus-4-6", title: "Opus 4.6"),
            Model(id: "claude-opus-4-5", title: "Opus 4.5"),
            Model(id: "claude-opus-4-1", title: "Opus 4.1"),
            Model(id: "claude-opus-4", title: "Opus 4"),
            Model(id: "claude-sonnet-4-6", title: "Sonnet 4.6"),
            Model(id: "claude-sonnet-4-5", title: "Sonnet 4.5"),
            Model(id: "claude-sonnet-4", title: "Sonnet 4"),
            Model(id: "claude-haiku-4-5", title: "Haiku 4.5"),
        ]),
        Group(id: "Earlier", models: [
            Model(id: "claude-3-7-sonnet", title: "Sonnet 3.7"),
            Model(id: "claude-3-5-sonnet-20241022", title: "Sonnet 3.5"),
            Model(id: "claude-3-5-haiku-20241022", title: "Haiku 3.5"),
        ]),
    ]
}
