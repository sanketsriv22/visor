import Foundation

/// The list of models the user's OpenRouter key can reach.
///
/// Fetched rather than hard-coded: model ids churn constantly, and a baked-in
/// list is wrong within weeks and silently offers models the user can't
/// actually run. Loaded once per Settings visit and cached in memory.
@MainActor
final class ModelCatalog: ObservableObject {
    @Published private(set) var models: [ORModel] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    private let client = OpenRouterClient()
    private var loaded = false

    /// A short list of sensible starting points, shown when there's no key yet
    /// (or the fetch failed) so the picker is never empty.
    static let fallbackModels = [
        "anthropic/claude-opus-5",
        "anthropic/claude-sonnet-5",
        "anthropic/claude-haiku-4.5",
        "openai/gpt-5",
        "google/gemini-2.5-pro",
    ]

    func loadIfNeeded() async {
        guard !loaded, !isLoading, OpenRouterClient.hasKey else { return }
        await reload()
    }

    func reload() async {
        isLoading = true
        error = nil
        do {
            models = try await client.models()
            loaded = true
        } catch {
            self.error = (error as? ChatError)?.localizedDescription ?? error.localizedDescription
        }
        isLoading = false
    }

    /// Model ids to offer, live list when we have one and the fallback when we
    /// don't.
    var ids: [String] {
        models.isEmpty ? Self.fallbackModels : models.map(\.id)
    }

    func label(for id: String) -> String {
        models.first { $0.id == id }?.label ?? id
    }
}
