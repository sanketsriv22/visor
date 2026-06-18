import Foundation

/// A task's state. Clicking the checkbox cycles through these in order.
/// On disk each maps to a single character inside the markdown checkbox.
enum TaskStatus: Equatable {
    case open      // [ ]
    case doing     // [/]
    case blocked   // [!]
    case done      // [x]

    var marker: String {
        switch self {
        case .open: return " "
        case .doing: return "/"
        case .blocked: return "!"
        case .done: return "x"
        }
    }

    static func from(marker: Character) -> TaskStatus {
        switch Character(marker.lowercased()) {
        case "x": return .done
        case "/": return .doing
        case "!": return .blocked
        default: return .open
        }
    }

    var next: TaskStatus {
        switch self {
        case .open: return .doing
        case .doing: return .blocked
        case .blocked: return .done
        case .done: return .open
        }
    }
}

/// One line of the note: a checkbox task, or a plain line of text.
struct NoteItem: Identifiable, Equatable {
    let id: UUID
    var text: String
    var isTask: Bool
    var status: TaskStatus

    var done: Bool { status == .done }

    init(id: UUID = UUID(), text: String, isTask: Bool, status: TaskStatus = .open) {
        self.id = id
        self.text = text
        self.isTask = isTask
        self.status = status
    }
}

/// Owns the note as a list of items. The markdown file on disk
/// (`- [ ]` / `- [x]` for tasks, plain text otherwise) is the source of truth
/// shared with the MCP server; the app reads and writes that same format.
final class NotesStore: ObservableObject {
    /// The note's name, stored on disk as a leading `# title` line. Empty when
    /// the note is unnamed.
    @Published var title: String = "" {
        didSet { markDirty() }
    }

    @Published var items: [NoteItem] = [] {
        didSet { markDirty() }
    }

    private func markDirty() {
        guard !suppressDirty else { return }
        dirty = true
        scheduleSave()
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

    /// Advance a task to its next state: open → doing → blocked → done → open.
    func cycle(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].status = items[i].status.next
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

    /// Move the dragged item to just above the dropped-on item — matching the
    /// insertion line drawn at the top of the target row.
    func move(id draggedID: UUID, toIndexOf targetID: UUID) {
        guard draggedID != targetID,
              let from = items.firstIndex(where: { $0.id == draggedID }),
              let to = items.firstIndex(where: { $0.id == targetID }) else { return }
        // toOffset is the original index to insert *before*, so `to` lands the
        // item right above the target in both directions.
        items.move(fromOffsets: IndexSet(integer: from), toOffset: to)
    }

    // MARK: - Persistence

    private static let taskRE = try! NSRegularExpression(pattern: #"^\s*-\s*\[([ xX/!\-])\]\s?(.*)$"#)

    static func parse(_ s: String) -> [NoteItem] {
        var items = s.split(separator: "\n", omittingEmptySubsequences: false).map { sub -> NoteItem in
            let line = String(sub)
            let range = NSRange(line.startIndex..., in: line)
            if let m = taskRE.firstMatch(in: line, range: range),
               let markR = Range(m.range(at: 1), in: line),
               let textR = Range(m.range(at: 2), in: line) {
                let marker = line[markR].first ?? " "
                return NoteItem(text: String(line[textR]), isTask: true, status: .from(marker: marker))
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

    /// Split a document into its title (leading `# …` line, if any) and body
    /// items.
    static func parseDocument(_ s: String) -> (title: String, items: [NoteItem]) {
        var lines = s.components(separatedBy: "\n")
        var title = ""
        if let first = lines.first,
           let r = first.range(of: #"^#\s+"#, options: .regularExpression) {
            title = String(first[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            lines.removeFirst()
            if lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                lines.removeFirst() // drop the blank line after the title
            }
        }
        return (title, parse(lines.joined(separator: "\n")))
    }

    static func serializeDocument(title: String, items: [NoteItem]) -> String {
        var lines: [String] = []
        let t = title.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty {
            lines.append("# \(t)")
            lines.append("")
        }
        // Each item is one markdown line; collapse any embedded newlines to
        // spaces so a wrapped task can't split into bogus extra lines.
        lines += items.map { item -> String in
            let text = item.text.replacingOccurrences(of: "\n", with: " ")
            return item.isTask ? "- [\(item.status.marker)] \(text)" : text
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private var serialized: String { Self.serializeDocument(title: title, items: items) }

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
        let (parsedTitle, parsedItems) = Self.parseDocument(s)
        guard Self.serializeDocument(title: parsedTitle, items: parsedItems) != serialized else { return }
        suppressDirty = true
        title = parsedTitle
        items = parsedItems
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
            (title, items) = Self.parseDocument(s)
        } else {
            title = ""
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
