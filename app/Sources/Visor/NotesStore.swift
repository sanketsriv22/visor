import Foundation

/// One line of the note: a checkbox task, or a plain line of text.
struct NoteItem: Identifiable, Equatable {
    let id: UUID
    var text: String
    var isTask: Bool
    var done: Bool

    init(id: UUID = UUID(), text: String, isTask: Bool, done: Bool = false) {
        self.id = id
        self.text = text
        self.isTask = isTask
        self.done = done
    }
}

/// Owns the note as a list of items. The markdown file on disk
/// (`- [ ]` / `- [x]` for tasks, plain text otherwise) is the source of truth
/// shared with the MCP server; the app reads and writes that same format.
final class NotesStore: ObservableObject {
    @Published var items: [NoteItem] = [] {
        didSet {
            guard !suppressDirty else { return }
            dirty = true
            scheduleSave()
        }
    }

    private let fileURL: URL
    private var dirty = false
    private var suppressDirty = false
    private var saveTask: DispatchWorkItem?
    private var watchTimer: Timer?
    private var lastMTime: Date?

    var openTasks: [String] {
        items.filter { $0.isTask && !$0.done }
            .map { $0.text.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var openTaskCount: Int { openTasks.count }

    init() {
        if let env = ProcessInfo.processInfo.environment["STICKY_NOTES_FILE"] {
            fileURL = URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        } else {
            fileURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("StickyNotes/sticky.md")
        }
        loadOrCreate()

        // Poll for external edits (MCP server, Devin, git) so we reflect them
        // live and never save a stale copy over a newer write. Reloads only
        // when there are no unsaved local edits.
        watchTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.reloadFromDiskIfClean()
        }
    }

    // MARK: - Mutations

    func toggle(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].done.toggle()
    }

    @discardableResult
    func addTask(_ text: String = "") -> UUID {
        let item = NoteItem(text: text, isTask: true)
        items.append(item)
        return item.id
    }

    @discardableResult
    func insertTask(after id: UUID) -> UUID {
        let item = NoteItem(text: "", isTask: true)
        if let i = items.firstIndex(where: { $0.id == id }) {
            items.insert(item, at: i + 1)
        } else {
            items.append(item)
        }
        return item.id
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    // MARK: - Persistence

    private static let taskRE = try! NSRegularExpression(pattern: #"^\s*-\s*\[( |x|X)\]\s?(.*)$"#)

    static func parse(_ s: String) -> [NoteItem] {
        var items = s.split(separator: "\n", omittingEmptySubsequences: false).map { sub -> NoteItem in
            let line = String(sub)
            let range = NSRange(line.startIndex..., in: line)
            if let m = taskRE.firstMatch(in: line, range: range),
               let markR = Range(m.range(at: 1), in: line),
               let textR = Range(m.range(at: 2), in: line) {
                return NoteItem(text: String(line[textR]), isTask: true, done: line[markR].lowercased() == "x")
            }
            return NoteItem(text: line, isTask: false)
        }
        // Drop stray trailing blank lines so the file's final newline doesn't
        // show up as an empty editable row.
        while let last = items.last, !last.isTask, last.text.trimmingCharacters(in: .whitespaces).isEmpty {
            items.removeLast()
        }
        return items
    }

    static func serialize(_ items: [NoteItem]) -> String {
        items.map { $0.isTask ? "- [\($0.done ? "x" : " ")] \($0.text)" : $0.text }
            .joined(separator: "\n") + "\n"
    }

    private var serialized: String { Self.serialize(items) }

    /// Pick up edits made by the MCP server (or anything else) while the
    /// panel was collapsed. Skipped if there are unsaved local edits —
    /// last writer wins, and the user's in-progress typing wins locally.
    func reloadFromDiskIfClean() {
        guard !dirty else { return }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
        if let mtime, mtime == lastMTime { return } // unchanged since we last saw it
        lastMTime = mtime
        guard let data = try? Data(contentsOf: fileURL),
              let s = String(data: data, encoding: .utf8) else { return }
        let parsed = Self.parse(s)
        guard Self.serialize(parsed) != serialized else { return }
        suppressDirty = true
        items = parsed
        suppressDirty = false
    }

    func saveNow() {
        saveTask?.cancel()
        guard dirty || !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try? serialized.data(using: .utf8)?.write(to: fileURL, options: .atomic)
        dirty = false
        lastMTime = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }

    private func loadOrCreate() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        suppressDirty = true
        if let data = try? Data(contentsOf: fileURL),
           let s = String(data: data, encoding: .utf8) {
            items = Self.parse(s)
        } else {
            items = []
        }
        suppressDirty = false

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            dirty = true
            saveNow()
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: task)
    }
}
