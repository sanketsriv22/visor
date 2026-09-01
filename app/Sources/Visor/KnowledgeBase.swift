import Foundation
import NaturalLanguage

/// One remembered turn, with enough context to be injected back into a prompt.
struct MemoryEntry: Codable, Equatable {
    var messageID: UUID
    var conversationID: UUID
    var conversationTitle: String
    var role: ChatMessage.Role
    var text: String
    var date: Date
}

/// Semantic memory over everything the user has said to their agents.
///
/// Embeddings come from Apple's `NLEmbedding`, which runs on-device: no
/// embedding API to pay for, nothing leaving the machine, and no key needed
/// before memory works. That matters more than the last few points of recall
/// quality for a personal notch app — a chat history is about as sensitive as
/// data gets.
///
/// Everything degrades to a no-op if the OS has no embedding model for the
/// user's locale: `recall` returns nothing and chats fall back to the recent
/// window, which is exactly how the app behaves today.
final class KnowledgeBase {
    /// Vectors are L2-normalised on the way in, so cosine similarity is a plain
    /// dot product at query time.
    private var entries: [MemoryEntry] = []
    private var vectors: [[Float]] = []

    private let root: URL
    private var indexDir: URL { root.appendingPathComponent(".chat-index", isDirectory: true) }
    private var entriesURL: URL { indexDir.appendingPathComponent("entries.json") }
    private var vectorsURL: URL { indexDir.appendingPathComponent("vectors.bin") }

    private let io = DispatchQueue(label: "com.kitalabs.visor.kb")

    /// Nil when the OS ships no sentence-embedding model for this locale.
    private let embedder = NLEmbedding.sentenceEmbedding(for: .english)
    private var dimension: Int { embedder?.dimension ?? 0 }

    var isAvailable: Bool { embedder != nil }

    init(root: URL? = nil) {
        self.root = root ?? ChatStore.defaultRoot
        try? FileManager.default.createDirectory(at: indexDir, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Indexing

    /// Remember a turn. Cheap enough to call on every message.
    func index(_ message: ChatMessage, in conversation: Conversation) {
        // System turns are our own scaffolding, and very short turns ("ok",
        // "thanks") only add noise to recall.
        guard message.role != .system,
              message.content.trimmingCharacters(in: .whitespacesAndNewlines).count >= 24,
              !entries.contains(where: { $0.messageID == message.id }),
              let vector = embed(message.content)
        else { return }

        entries.append(MemoryEntry(
            messageID: message.id,
            conversationID: conversation.id,
            conversationTitle: conversation.title,
            role: message.role,
            text: message.content,
            date: message.createdAt))
        vectors.append(vector)
        persist()
    }

    /// Drop a conversation's turns from memory when the chat is deleted, so
    /// "delete this chat" actually forgets it.
    func forget(conversation id: UUID) {
        let keep = entries.indices.filter { entries[$0].conversationID != id }
        guard keep.count != entries.count else { return }
        entries = keep.map { entries[$0] }
        vectors = keep.map { vectors[$0] }
        persist()
    }

    // MARK: - Recall

    /// The most relevant past turns for a query, newest-biased on ties.
    ///
    /// `excluding` is the conversation in progress: its recent turns are
    /// already in the prompt verbatim, so recalling them again just burns
    /// context.
    func recall(_ query: String, limit: Int = 6, excluding conversationID: UUID? = nil,
                minimumScore: Float = 0.35) -> [MemoryEntry] {
        guard !entries.isEmpty, let q = embed(query) else { return [] }
        var scored: [(index: Int, score: Float)] = []
        for i in vectors.indices {
            if let conversationID, entries[i].conversationID == conversationID { continue }
            let score = dot(q, vectors[i])
            if score >= minimumScore { scored.append((i, score)) }
        }
        return scored
            .sorted { $0.score == $1.score
                ? entries[$0.index].date > entries[$1.index].date
                : $0.score > $1.score }
            .prefix(limit)
            .map { entries[$0.index] }
    }

    /// Render recalled turns as a system-prompt block. Returns nil when there's
    /// nothing worth adding, so callers can skip the block entirely rather than
    /// send an empty heading.
    func context(for query: String, excluding conversationID: UUID? = nil) -> String? {
        let hits = recall(query, excluding: conversationID)
        guard !hits.isEmpty else { return nil }
        let body = hits.map { entry -> String in
            let who = entry.role == .user ? "The user" : "You"
            let when = DateFormatter.memoryStamp.string(from: entry.date)
            // Long turns are truncated: recall is for reminding the model that
            // something was discussed, not for replaying it in full.
            return "- [\(when), \"\(entry.conversationTitle)\"] \(who): \(entry.text.prefix(400))"
        }.joined(separator: "\n")

        return """
        Relevant excerpts from earlier conversations with this user. Use them \
        only if they bear on the current question; don't mention this list.

        \(body)
        """
    }

    // MARK: - Embedding

    /// Embed text, averaging over sentences so a long turn isn't represented by
    /// its first clause alone.
    private func embed(_ text: String) -> [Float]? {
        guard let embedder, dimension > 0 else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = trimmed
        var sum = [Float](repeating: 0, count: dimension)
        var count = 0
        tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { range, _ in
            guard let v = embedder.vector(for: String(trimmed[range])) else { return true }
            for i in 0..<min(dimension, v.count) { sum[i] += Float(v[i]) }
            count += 1
            // A very long turn contributes its first 40 sentences; beyond that
            // the average stops moving and we're just burning CPU.
            return count < 40
        }
        if count == 0, let v = embedder.vector(for: trimmed) {
            for i in 0..<min(dimension, v.count) { sum[i] += Float(v[i]) }
            count = 1
        }
        guard count > 0 else { return nil }
        return normalise(sum)
    }

    private func normalise(_ v: [Float]) -> [Float]? {
        var magnitude: Float = 0
        for x in v { magnitude += x * x }
        magnitude = magnitude.squareRoot()
        guard magnitude > 0, magnitude.isFinite else { return nil }
        return v.map { $0 / magnitude }
    }

    private func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var total: Float = 0
        for i in a.indices { total += a[i] * b[i] }
        return total
    }

    // MARK: - Persistence

    /// Vectors go to a packed Float32 blob rather than JSON: a 512-dim vector
    /// is 2 KB binary against roughly 6 KB as text, and the whole point of the
    /// index is that it stays cheap as history grows.
    private func persist() {
        let rows = entries
        let vecs = vectors
        let entriesTarget = entriesURL
        let vectorsTarget = vectorsURL
        io.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(rows) {
                try? data.write(to: entriesTarget, options: .atomic)
            }
            var blob = Data()
            blob.reserveCapacity(vecs.count * (vecs.first?.count ?? 0) * 4)
            for vector in vecs {
                for value in vector {
                    withUnsafeBytes(of: value.bitPattern.littleEndian) { blob.append(contentsOf: $0) }
                }
            }
            try? blob.write(to: vectorsTarget, options: .atomic)
        }
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let entriesData = try? Data(contentsOf: entriesURL),
              let rows = try? decoder.decode([MemoryEntry].self, from: entriesData),
              let blob = try? Data(contentsOf: vectorsURL),
              dimension > 0
        else { return }

        let stride = dimension * 4
        // A truncated or stale blob means the two files disagree; treating the
        // index as empty rebuilds it from new messages rather than serving
        // vectors that belong to the wrong entries.
        guard stride > 0, blob.count == rows.count * stride else { return }

        // One withUnsafeBytes over the whole blob: subscripting a Data slice
        // per value would both be far slower and assume a zero-based
        // startIndex, which a Data slice doesn't guarantee.
        let loaded: [[Float]] = blob.withUnsafeBytes { raw -> [[Float]] in
            var all: [[Float]] = []
            all.reserveCapacity(rows.count)
            for row in 0..<rows.count {
                var vector = [Float](repeating: 0, count: dimension)
                for i in 0..<dimension {
                    let bits = raw.loadUnaligned(
                        fromByteOffset: row * stride + i * 4, as: UInt32.self)
                    vector[i] = Float(bitPattern: UInt32(littleEndian: bits))
                }
                all.append(vector)
            }
            return all
        }
        entries = rows
        vectors = loaded
    }
}

private extension DateFormatter {
    static let memoryStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        return f
    }()
}
