import Foundation

/// A stored conversation. Chats live next to notes under ~/StickyNotes so
/// everything Visor owns is in one visible, backup-able place — the same
/// reasoning that keeps notes as plain markdown rather than a database.
struct Conversation: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// Derived from the first user turn, or renamed by the user.
    var title: String
    /// The agent that owns this chat, by name. Kept as a name (not an id) so a
    /// conversation survives an agent being deleted and recreated.
    var agentName: String
    var model: String
    var messages: [ChatMessage] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// One line for the conversation list.
    var preview: String {
        let source = messages.last(where: { $0.role != .system })?.content ?? ""
        return source
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Lightweight row for the conversation list, so opening the sidebar doesn't
/// read every chat off disk.
struct ConversationSummary: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var agentName: String
    var model: String
    var messageCount: Int
    var updatedAt: Date
    var preview: String
}

/// Reads and writes conversations, one JSON file per chat plus an index.
///
/// One file per conversation (rather than a single documents blob) means a
/// corrupt or hand-edited chat costs you that chat, not the archive — and it
/// makes the MCP server's job a directory listing.
final class ChatStore: ObservableObject {
    /// Newest first.
    @Published private(set) var summaries: [ConversationSummary] = []

    private let root: URL
    private var chatsDir: URL { root.appendingPathComponent("chats", isDirectory: true) }
    private var indexURL: URL { chatsDir.appendingPathComponent("index.json") }

    /// Serialises disk writes so a fast typist can't interleave two saves of
    /// the same file.
    private let io = DispatchQueue(label: "com.kitalabs.visor.chatstore")

    init(root: URL? = nil) {
        self.root = root ?? Self.defaultRoot
        try? FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)
        loadIndex()
    }

    /// Where Visor keeps its data. `VISOR_DATA_DIR` overrides it, matching how
    /// `STICKY_NOTES_FILE` already lets the note be relocated.
    static var defaultRoot: URL {
        if let custom = ProcessInfo.processInfo.environment["VISOR_DATA_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("StickyNotes", isDirectory: true)
    }

    private func url(for id: UUID) -> URL {
        chatsDir.appendingPathComponent("\(id.uuidString).json")
    }

    // MARK: - Reading

    func conversation(_ id: UUID) -> Conversation? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return try? Self.decoder.decode(Conversation.self, from: data)
    }

    // MARK: - Writing

    func save(_ conversation: Conversation) {
        var chat = conversation
        chat.updatedAt = Date()
        let target = url(for: chat.id)
        io.async {
            guard let data = try? Self.encoder.encode(chat) else { return }
            try? data.write(to: target, options: .atomic)
        }
        upsertSummary(for: chat)
    }

    func delete(_ id: UUID) {
        let target = url(for: id)
        io.async { try? FileManager.default.removeItem(at: target) }
        summaries.removeAll { $0.id == id }
        persistIndex()
    }

    func rename(_ id: UUID, to title: String) {
        guard var chat = conversation(id) else { return }
        chat.title = title
        save(chat)
    }

    private func upsertSummary(for chat: Conversation) {
        let summary = ConversationSummary(
            id: chat.id, title: chat.title, agentName: chat.agentName, model: chat.model,
            messageCount: chat.messages.count, updatedAt: chat.updatedAt, preview: chat.preview)
        if let i = summaries.firstIndex(where: { $0.id == chat.id }) {
            summaries[i] = summary
        } else {
            summaries.append(summary)
        }
        summaries.sort { $0.updatedAt > $1.updatedAt }
        persistIndex()
    }

    // MARK: - Index

    private func loadIndex() {
        if let data = try? Data(contentsOf: indexURL),
           let rows = try? Self.decoder.decode([ConversationSummary].self, from: data) {
            summaries = rows.sorted { $0.updatedAt > $1.updatedAt }
            return
        }
        // No index (first run, or it was deleted): rebuild from the chat files
        // themselves. The index is a cache, never the source of truth.
        rebuildIndex()
    }

    /// Re-derive the index from the chat files on disk.
    func rebuildIndex() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: chatsDir, includingPropertiesForKeys: nil)) ?? []
        summaries = files
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "index.json" }
            .compactMap { url -> ConversationSummary? in
                guard let data = try? Data(contentsOf: url),
                      let chat = try? Self.decoder.decode(Conversation.self, from: data)
                else { return nil }
                return ConversationSummary(
                    id: chat.id, title: chat.title, agentName: chat.agentName, model: chat.model,
                    messageCount: chat.messages.count, updatedAt: chat.updatedAt,
                    preview: chat.preview)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
        persistIndex()
    }

    private func persistIndex() {
        let rows = summaries
        let target = indexURL
        io.async {
            guard let data = try? Self.encoder.encode(rows) else { return }
            try? data.write(to: target, options: .atomic)
        }
    }

    // MARK: - Export

    /// Render a conversation as markdown. Used for both "copy as markdown" and
    /// file export, so the two can never drift.
    static func markdown(_ chat: Conversation) -> String {
        let stamp = DateFormatter.exportStamp.string(from: chat.createdAt)
        var out = """
        # \(chat.title)

        > \(chat.agentName) · `\(chat.model)` · \(stamp)

        """
        for message in chat.messages where message.role != .system {
            let who = message.role == .user ? "You" : chat.agentName
            out += "\n## \(who)\n\n\(message.content)\n"
        }
        return out
    }

    /// Write a conversation to `~/StickyNotes/exports/` and return the file.
    /// Markdown for reading, JSON for round-tripping into another tool.
    @discardableResult
    func export(_ chat: Conversation, as format: ExportFormat) throws -> URL {
        let dir = root.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = Self.safeFilename(chat.title)
        let stamp = DateFormatter.exportFilename.string(from: chat.updatedAt)
        let target = dir.appendingPathComponent("\(stamp)-\(base).\(format.rawValue)")
        switch format {
        case .markdown:
            try Self.markdown(chat).write(to: target, atomically: true, encoding: .utf8)
        case .json:
            try Self.encoder.encode(chat).write(to: target, options: .atomic)
        }
        return target
    }

    enum ExportFormat: String, CaseIterable {
        case markdown = "md"
        case json

        var menuTitle: String {
            switch self {
            case .markdown: return "Markdown"
            case .json:     return "JSON"
            }
        }
    }

    /// Titles become filenames, so strip anything a filesystem will argue about.
    private static func safeFilename(_ title: String) -> String {
        let cleaned = title
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
        return cleaned.isEmpty ? "chat" : String(cleaned.prefix(60)).lowercased()
    }

    // MARK: - Coding

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

private extension DateFormatter {
    static let exportStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// Sorts chronologically in Finder.
    static let exportFilename: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return f
    }()
}
