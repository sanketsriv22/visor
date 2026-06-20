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

/// Owns notes as Markdown files in ~/Documents/Visor — one file per note, named
/// by its title. The active note is mirrored to ~/StickyNotes/sticky.md (a
/// symlink) so the MCP server and agents always read the current note.
final class NotesStore: ObservableObject {
    /// The note's name (also its filename). Stored as a leading `# title` line.
    @Published var title: String = "" {
        didSet { markDirty(); scheduleRename() }
    }

    @Published var items: [NoteItem] = [] {
        didSet { markDirty() }
    }

    /// Names of all saved notes, for the switcher.
    @Published private(set) var noteNames: [String] = []
    /// Filename stem of the note currently shown.
    @Published private(set) var activeName: String = "Untitled"
    /// Names of archived notes (kept in Documents/Visor/Archive), for the switcher.
    @Published private(set) var archivedNames: [String] = []

    /// How the switcher orders notes.
    enum NoteSort: String, CaseIterable {
        case name, updated, created
        var title: String {
            switch self {
            case .name:    return "Name (A–Z)"
            case .updated: return "Recently updated"
            case .created: return "Recently created"
            }
        }
    }
    @Published private(set) var noteSort: NoteSort = .name

    private func markDirty() {
        guard !suppressDirty else { return }
        dirty = true
        scheduleSave()
    }

    private let folder: URL   // ~/Documents/Visor
    private let mirror: URL   // ~/StickyNotes/sticky.md (symlink → active note)
    private let activeKey = "visor.activeNote"
    private let noteSortKey = "visor.noteSort"
    private var dirty = false
    private var suppressDirty = false
    private var saveTask: DispatchWorkItem?
    private var renameTask: DispatchWorkItem?
    private var watchTimer: Timer?
    private var lastMTime: Date?

    /// Serial queue for file I/O that doesn't need to block the UI (writing the
    /// outgoing note, repointing the mirror symlink). Keeps note switching snappy
    /// even when the Documents folder is slow (e.g. iCloud-backed).
    private let io = DispatchQueue(label: "com.kitalabs.visor.notes-io", qos: .userInitiated)

    /// Parsed notes kept in memory, keyed by name, so re-opening a note is
    /// instant — no disk read or markdown parse. Each entry remembers the file's
    /// modification date at the time it was cached; if the file later changes on
    /// disk (e.g. an agent edits it), the mtime won't match and the watch timer
    /// reloads it. Accessed on the main thread only.
    private var cache: [String: (title: String, items: [NoteItem], mtime: Date?)] = [:]

    /// Snapshot the active note into the cache so switching away and back is free.
    private func cacheActive() {
        cache[activeName] = (title, items, lastMTime)
    }

    private var activeURL: URL { folder.appendingPathComponent("\(activeName).md") }
    private var archiveFolder: URL { folder.appendingPathComponent("Archive", isDirectory: true) }

    var openTasks: [String] {
        items.filter { $0.isTask && !$0.done }
            .map { $0.text.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var openTaskCount: Int { openTasks.count }

    init() {
        folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Visor", isDirectory: true)
        if let env = ProcessInfo.processInfo.environment["STICKY_NOTES_FILE"] {
            mirror = URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        } else {
            mirror = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("StickyNotes/sticky.md")
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: archiveFolder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: mirror.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let raw = UserDefaults.standard.string(forKey: noteSortKey),
           let s = NoteSort(rawValue: raw) { noteSort = s }
        bootstrap()

        // Every tick: flush unsaved edits (so a crash/force-quit during
        // continuous typing loses at most ~1.5s), otherwise pick up external
        // edits (MCP server, agents).
        watchTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.dirty { self.saveNow() } else { self.reloadFromDiskIfClean() }
        }
    }

    // MARK: - Mutations

    /// Advance a task to its next state: open → doing → blocked → done → open.
    func cycle(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].status = items[i].status.next
    }

    /// Jump straight to done (or back to open if already done) — for a long-press.
    func toggleDone(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].status = items[i].status == .done ? .open : .done
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

    /// Move a task out of the current note and append it to another note's file.
    func moveTask(_ id: UUID, toNote name: String) {
        guard name != activeName,
              let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let moved = items.remove(at: idx) // removing triggers a save of this note

        let targetURL = folder.appendingPathComponent("\(name).md")
        var title = name
        var targetItems: [NoteItem] = []
        if let data = try? Data(contentsOf: targetURL),
           let s = String(data: data, encoding: .utf8) {
            let parsed = Self.parseDocument(s)
            if !parsed.title.isEmpty { title = parsed.title }
            targetItems = parsed.items
        }
        targetItems.append(moved)
        try? Self.serializeDocument(title: title, items: targetItems)
            .data(using: .utf8)?.write(to: targetURL, options: .atomic)
        cache.removeValue(forKey: name) // target file changed on disk — drop stale copy
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

    /// Pick up edits made by the MCP server (or anything else). Skipped if
    /// there are unsaved local edits — the user's in-progress typing wins.
    func reloadFromDiskIfClean() {
        guard !dirty else { return }
        let m = mtime(activeURL)
        if let m, m == lastMTime { return }
        lastMTime = m
        guard let data = try? Data(contentsOf: activeURL),
              let s = String(data: data, encoding: .utf8) else { return }
        let (parsedTitle, parsedItems) = Self.parseDocument(s)
        guard Self.serializeDocument(title: parsedTitle, items: parsedItems) != serialized else { return }
        suppressDirty = true
        title = parsedTitle
        items = parsedItems
        suppressDirty = false
        cacheActive()
    }

    func saveNow() {
        saveTask?.cancel()
        guard dirty || !FileManager.default.fileExists(atPath: activeURL.path) else { return }
        try? serialized.data(using: .utf8)?.write(to: activeURL, options: .atomic)
        dirty = false
        lastMTime = mtime(activeURL)
        cacheActive()
        ensureMirrorSymlink()
    }

    // MARK: - Notes (switch / create)

    /// Switch to another saved note. The outgoing note is persisted in the
    /// background and the incoming note is served from the in-memory cache when
    /// possible, so this returns immediately instead of blocking on disk.
    func switchTo(_ name: String) {
        guard name != activeName else { return }
        commitRenameNow()                 // handle a pending title rename (usually a no-op)
        guard name != activeName else { return } // …which may itself have changed activeName

        flushOutgoingAsync()              // write the outgoing note off the main thread + cache it
        activeName = name

        if let hit = cache[name] {
            // Instant: show the parsed note we already hold in memory.
            suppressDirty = true; title = hit.title; items = hit.items; suppressDirty = false
            lastMTime = hit.mtime
        } else {
            loadActive()                  // first open this session — read + parse once…
            cacheActive()                 // …then remember it
        }

        UserDefaults.standard.set(activeName, forKey: activeKey)

        // Repoint the mirror symlink (for the MCP server / agents) in the
        // background — the UI doesn't depend on it. Note switching no longer
        // rescans the notes directory: the set of notes is unchanged by a switch.
        let target = activeURL
        io.async { [weak self] in self?.ensureMirrorSymlink(for: target) }

        // The set of names is unchanged by a switch, but date-based sort orders
        // can shift (we just touched the outgoing note's mtime) — refresh those
        // off the main thread so the switcher stays correct without stalling.
        if noteSort != .name { refreshNoteNamesAsync() }
    }

    /// Persist the note we're leaving without blocking the UI. Its content is
    /// already in memory, so we snapshot it, cache it, and write on the I/O queue.
    private func flushOutgoingAsync() {
        saveTask?.cancel()
        let outgoing = activeName
        let snapTitle = title
        let snapItems = items
        guard dirty else {
            // Clean: on-disk copy already matches memory, just cache it.
            cache[outgoing] = (snapTitle, snapItems, lastMTime)
            return
        }
        let doc = serialized
        let url = activeURL
        dirty = false
        cache[outgoing] = (snapTitle, snapItems, lastMTime) // updated with real mtime once written
        io.async { [weak self] in
            try? doc.data(using: .utf8)?.write(to: url, options: .atomic)
            let m = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            DispatchQueue.main.async {
                guard let self else { return }
                if var entry = self.cache[outgoing] { entry.mtime = m; self.cache[outgoing] = entry }
                if self.activeName == outgoing { self.lastMTime = m }
            }
        }
    }

    /// Create a fresh, empty note and switch to it.
    func newNote() {
        commitRenameNow()
        saveNow()
        activeName = uniqueName("Untitled")
        suppressDirty = true; title = ""; items = []; suppressDirty = false
        dirty = true
        saveNow()
        UserDefaults.standard.set(activeName, forKey: activeKey)
        refreshNoteNames()
    }

    /// Move the current note into the Archive folder (hidden from the switcher
    /// but kept on disk), then switch to another note — or a fresh empty one if
    /// this was the last note.
    func archiveCurrent() {
        commitRenameNow()
        saveNow()
        let archivedName = activeName
        let src = activeURL
        cache.removeValue(forKey: archivedName)
        try? FileManager.default.createDirectory(at: archiveFolder, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: src.path) {
            try? FileManager.default.moveItem(at: src, to: uniqueArchiveURL(archivedName))
        }
        refreshNoteNames()
        if let next = noteNames.first(where: { $0 != archivedName }) {
            activeName = next
            loadActive()
        } else {
            // Archived the last note — start a fresh empty one so there's always
            // an active note to show.
            activeName = uniqueName("Untitled")
            suppressDirty = true; title = ""; items = []; suppressDirty = false
            dirty = true
            saveNow()
        }
        UserDefaults.standard.set(activeName, forKey: activeKey)
        ensureMirrorSymlink()
        refreshNoteNames()
        refreshArchivedNames()
    }

    /// Move an archived note back into the active set and switch to it.
    func restore(_ name: String) {
        let src = archiveFolder.appendingPathComponent("\(name).md")
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        commitRenameNow()
        saveNow()
        let target = uniqueName(name) // never clobber an existing active note
        let dest = folder.appendingPathComponent("\(target).md")
        try? FileManager.default.moveItem(at: src, to: dest)
        refreshNoteNames()
        refreshArchivedNames()
        activeName = target
        loadActive()
        UserDefaults.standard.set(activeName, forKey: activeKey)
        ensureMirrorSymlink()
    }

    /// Permanently delete a note's file. If it's the active note, switch to
    /// another (or a fresh empty one). Unlike archive, this is not recoverable.
    func deleteNote(_ name: String) {
        let url = folder.appendingPathComponent("\(name).md")
        cache.removeValue(forKey: name)
        if name == activeName {
            try? FileManager.default.removeItem(at: url)
            refreshNoteNames()
            if let next = noteNames.first(where: { $0 != name }) {
                activeName = next
                loadActive()
            } else {
                activeName = uniqueName("Untitled")
                suppressDirty = true; title = ""; items = []; suppressDirty = false
                dirty = true
                saveNow()
            }
            UserDefaults.standard.set(activeName, forKey: activeKey)
            ensureMirrorSymlink()
        } else {
            try? FileManager.default.removeItem(at: url)
        }
        refreshNoteNames()
    }

    /// Change how the switcher orders notes (persisted).
    func setNoteSort(_ sort: NoteSort) {
        noteSort = sort
        UserDefaults.standard.set(sort.rawValue, forKey: noteSortKey)
        refreshNoteNames()
    }

    /// Rename the active file to match the title now (e.g. on Return).
    func commitTitle() { commitRenameNow() }

    // MARK: - Internals

    private func bootstrap() {
        refreshNoteNames()
        refreshArchivedNames()
        if noteNames.isEmpty {
            // First run: migrate an existing single note if there is one.
            if let data = try? Data(contentsOf: mirror),
               let s = String(data: data, encoding: .utf8),
               !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let (t, it) = Self.parseDocument(s)
                suppressDirty = true; title = t.isEmpty ? "Sticky" : t; items = it; suppressDirty = false
                activeName = sanitize(title)
            } else {
                activeName = "Untitled"
                suppressDirty = true; title = ""; items = []; suppressDirty = false
            }
            dirty = true
            saveNow()
            refreshNoteNames()
        } else {
            let saved = UserDefaults.standard.string(forKey: activeKey)
            activeName = (saved != nil && noteNames.contains(saved!)) ? saved! : noteNames[0]
            loadActive()
        }
        UserDefaults.standard.set(activeName, forKey: activeKey)
        ensureMirrorSymlink()
    }

    private func loadActive() {
        suppressDirty = true
        if let data = try? Data(contentsOf: activeURL),
           let s = String(data: data, encoding: .utf8) {
            (title, items) = Self.parseDocument(s)
        } else {
            title = ""; items = []
        }
        suppressDirty = false
        lastMTime = mtime(activeURL)
        cacheActive()
    }

    private func refreshNoteNames() {
        noteNames = Self.scanNoteNames(in: folder, sort: noteSort)
    }

    /// Re-scan the notes directory off the main thread. Used after a switch when
    /// the sort depends on file dates (Recently updated/created) — switching can
    /// change those orders, but the directory scan is too slow to do inline.
    private func refreshNoteNamesAsync() {
        let folder = self.folder
        let sort = self.noteSort
        io.async { [weak self] in
            let names = Self.scanNoteNames(in: folder, sort: sort)
            DispatchQueue.main.async { self?.noteNames = names }
        }
    }

    /// List the `.md` note names in `folder`, ordered per `sort`. Pure (no
    /// instance state) so it's safe to run on a background queue.
    private static func scanNoteNames(in folder: URL, sort: NoteSort) -> [String] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey]
        let urls = ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys)) ?? [])
            .filter { $0.pathExtension == "md" }
        let sorted: [URL]
        switch sort {
        case .name:
            sorted = urls.sorted {
                $0.deletingPathExtension().lastPathComponent
                    .localizedCaseInsensitiveCompare($1.deletingPathExtension().lastPathComponent) == .orderedAscending
            }
        case .updated:
            sorted = urls.sorted { date($0, .contentModificationDateKey) > date($1, .contentModificationDateKey) }
        case .created:
            sorted = urls.sorted { date($0, .creationDateKey) > date($1, .creationDateKey) }
        }
        return sorted.map { $0.deletingPathExtension().lastPathComponent }
    }

    private static func date(_ url: URL, _ key: URLResourceKey) -> Date {
        let v = try? url.resourceValues(forKeys: [key])
        return v?.allValues[key] as? Date ?? .distantPast
    }

    private func refreshArchivedNames() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: archiveFolder, includingPropertiesForKeys: nil)) ?? []
        archivedNames = urls.filter { $0.pathExtension == "md" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// A free filename in the archive, suffixing " 2", " 3"… on collision.
    private func uniqueArchiveURL(_ base: String) -> URL {
        var name = base
        var n = 2
        while FileManager.default.fileExists(
            atPath: archiveFolder.appendingPathComponent("\(name).md").path) {
            name = "\(base) \(n)"; n += 1
        }
        return archiveFolder.appendingPathComponent("\(name).md")
    }

    private func sanitize(_ s: String) -> String {
        let cleaned = s.components(separatedBy: CharacterSet(charactersIn: "/\\:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    private func uniqueName(_ base: String) -> String {
        guard noteNames.contains(base) else { return base }
        var n = 2
        while noteNames.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Rename the active file to match the title (debounced so typing the name
    /// doesn't churn through intermediate files).
    private func scheduleRename() {
        guard !suppressDirty else { return }
        renameTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.commitRenameNow() }
        renameTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: task)
    }

    private func commitRenameNow() {
        renameTask?.cancel()
        let desired = sanitize(title)
        guard desired != activeName else { return }
        let previous = activeName
        saveNow() // flush content under the old name first
        let target = uniqueName(desired) // never clobber another note
        let newURL = folder.appendingPathComponent("\(target).md")
        if FileManager.default.fileExists(atPath: activeURL.path) {
            try? FileManager.default.moveItem(at: activeURL, to: newURL)
        }
        activeName = target
        cache.removeValue(forKey: previous) // file moved to the new name
        UserDefaults.standard.set(activeName, forKey: activeKey)
        lastMTime = mtime(activeURL)
        cacheActive()
        ensureMirrorSymlink()
        refreshNoteNames()
    }

    private func mtime(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Point the mirror (~/StickyNotes/sticky.md) at the active note so the MCP
    /// server and agents read whatever note is showing. `target` defaults to the
    /// active note's URL; pass it explicitly when calling off the main thread (so
    /// we don't read `activeName` from a background queue).
    private func ensureMirrorSymlink(for target: URL? = nil) {
        let dest = target ?? activeURL
        let fm = FileManager.default
        if let type = (try? fm.attributesOfItem(atPath: mirror.path))?[.type] as? FileAttributeType {
            if type == FileAttributeType.typeSymbolicLink,
               (try? fm.destinationOfSymbolicLink(atPath: mirror.path)) == dest.path {
                return // already pointing at the active note
            }
            try? fm.removeItem(at: mirror)
        }
        try? fm.createSymbolicLink(at: mirror, withDestinationURL: dest)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: task)
    }
}
