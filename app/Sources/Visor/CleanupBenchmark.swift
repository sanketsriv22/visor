import Foundation

/// Runs the dictation cleanup prompt against several models and reports what
/// each one costs you in time and returns in text.
///
/// There are well over a hundred models on OpenRouter cheap enough for this
/// job, and the two things that decide between them — how long they take from
/// where you are, and whether they punctuate rather than answer — are both
/// absent from the catalogue. Price is published; latency is not, and quality
/// on *this* task certainly isn't.
///
/// So it's measured rather than argued about: same prompt, same transcript,
/// your key, your network, one after another. Sequentially, because running
/// them at once measures how well your connection parallelises rather than how
/// quick each model is.
@MainActor
final class CleanupBenchmark: ObservableObject {
    struct Result: Identifiable {
        var id: String { model }
        let model: String
        var seconds: Double?
        var output: String?
        var error: String?
    }

    @Published private(set) var results: [Result] = []
    @Published private(set) var running = false

    /// A spread across the cheap end rather than a top-three, so the shape of
    /// the tradeoff is visible: if the cheapest is as good and as quick as the
    /// dearest, that's worth seeing rather than being told.
    static let candidates = [
        "mistralai/mistral-nemo",
        "meta-llama/llama-3.1-8b-instruct",
        "google/gemma-3-4b-it",
        "qwen/qwen3.7-flash",
        "openai/gpt-oss-20b",
        "mistralai/ministral-3b-2512",
        "google/gemini-2.5-flash-lite",
        "openai/gpt-5-nano",
    ]

    /// Messy on purpose, in the ways speech actually is: no punctuation, a
    /// filler word, a homophone, and a sentence that could be misread as a
    /// question to answer rather than text to correct.
    static let sample = """
        so i was thinking we should probably um move the meeting to tuesday \
        instead because their going to be travelling on monday and then what \
        do you think about pushing the launch back a week
        """

    private let client = OpenRouterClient()

    func run(on transcript: String? = nil) {
        guard !running else { return }
        running = true
        let text = (transcript?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? Self.sample
        results = Self.candidates.map { Result(model: $0) }

        Task {
            for (index, model) in Self.candidates.enumerated() {
                let started = Date()
                do {
                    let reply = try await client.complete(
                        messages: [ChatMessage(role: .user, content: text)],
                        model: model,
                        system: VoiceInput.cleanupPrompt,
                        fast: true,
                        maxTokens: max(64, text.count / 2))
                    update(index) {
                        $0.seconds = Date().timeIntervalSince(started)
                        $0.output = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                } catch {
                    // A model that errors is a result too — it's one you can't
                    // use, which is worth knowing before you pick it.
                    update(index) {
                        $0.seconds = Date().timeIntervalSince(started)
                        $0.error = (error as? ChatError)?.localizedDescription
                            ?? error.localizedDescription
                    }
                }
            }
            running = false
        }
    }

    private func update(_ index: Int, _ change: (inout Result) -> Void) {
        guard results.indices.contains(index) else { return }
        change(&results[index])
    }
}
