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
    /// Optional per-task URL. Persisted as a hidden markdown comment so task text
    /// stays clean in the app while the note remains plain text on disk.
    var link: String?

    var done: Bool { status == .done }

    init(id: UUID = UUID(), text: String, isTask: Bool, status: TaskStatus = .open, link: String? = nil) {
        self.id = id
        self.text = text
        self.isTask = isTask
        self.status = status
        self.link = link
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

    /// Whether the active note is a live shared note — drives the share indicator.
    @Published private(set) var isActiveNoteShared = false
    /// People currently viewing the active shared note, including you (0 if not shared).
    @Published private(set) var presenceCount = 0

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

    /// Which note reopens next launch. Skipped for a fixture store.
    private func rememberActiveName() {
        if !ephemeral { UserDefaults.standard.set(activeName, forKey: activeKey) }
    }

    private func markDirty() {
        guard !suppressDirty else { return }
        dirty = true
        scheduleSave()
        pushIfShared()  // stream the edit live (the sync engine micro-batches it)
    }

    private let folder: URL   // ~/Documents/Visor
    private let mirror: URL   // ~/StickyNotes/sticky.md (symlink → active note)
    private let activeKey = "visor.activeNote"
    private let noteSortKey = "visor.noteSort"
    /// Maps a note name → its shared reference ("id/token"), so a note stays
    /// linked to its live document across relaunches. Nil-valued when sharing
    /// isn't configured.
    private let sharedRefsKey = "visor.sharedRefs"

    /// Real-time sharing backend, or nil when it isn't available (SDK not linked
    /// or no `GoogleService-Info.plist`). When nil, every share path falls back
    /// to the legacy offline copy and the app behaves exactly as before.
    private let sync: NoteSyncing? = NoteSyncFactory.make()
    /// True while we're applying a remote edit, so the resulting `items`/`title`
    /// mutations don't get pushed straight back out as a local change.
    private var applyingRemote = false
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

    /// True for a fixture store (the Design Lab): everything lives under the
    /// given folder and nothing is written to UserDefaults, so rendering a
    /// scenario can't change which note the real app opens next.
    private let ephemeral: Bool

    /// - Parameters:
    ///   - folder: where notes live. Defaults to `VISOR_DATA_DIR` if set (the
    ///     same override `ChatStore` honours — notes used to ignore it, so the
    ///     two stores could point at different places), else ~/Documents/Visor.
    ///   - ephemeral: keep every side effect inside `folder`.
    init(folder: URL? = nil, ephemeral: Bool = false) {
        self.ephemeral = ephemeral
        self.folder = folder ?? ChatStore.defaultRoot
        if ephemeral {
            mirror = self.folder.appendingPathComponent("sticky.md")
        } else if let env = ProcessInfo.processInfo.environment["STICKY_NOTES_FILE"] {
            mirror = URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        } else {
            mirror = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("StickyNotes/sticky.md")
        }
        try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
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

        // Remote edits to the active shared note flow in here. We apply them like
        // an external file edit: only when the user isn't mid-edit, so live typing
        // wins the moment-to-moment race (the merge is already safe in the CRDT).
        sync?.onRemoteMarkdown = { [weak self] markdown in
            self?.applyRemoteMarkdown(markdown)
        }
        sync?.onPresenceCount = { [weak self] count in
            self?.presenceCount = count
        }
        // If the note we restored is a shared one, start syncing it immediately.
        if let ref = sharedRef(for: activeName) {
            sync?.attach(ref: ref, localMarkdown: serialized)
        }
        refreshSharedState()
    }

    // MARK: - Mutations

    /// Advance a task to its next state: open → doing → blocked → done → open.
    /// Tap-cycle a task's status, skipping `done` — completing is long-press only
    /// (see `toggleDone`). So a tap goes open → doing → blocked → open, and tapping
    /// a finished task un-completes it back to open.
    func cycle(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        switch items[i].status {
        case .open:    items[i].status = .doing
        case .doing:   items[i].status = .blocked
        case .blocked: items[i].status = .open
        case .done:    items[i].status = .open
        }
        reflowCompleted()
    }

    /// Jump straight to done (or back to open if already done) — for a long-press.
    func toggleDone(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].status = items[i].status == .done ? .open : .done
        reflowCompleted()
    }

    /// Keep finished tasks sunk to the bottom: unfinished tasks and plain lines
    /// keep their relative order on top, completed tasks collect below (in their
    /// own order). Stable, so it only mutates `items` when something crossed the
    /// done boundary — avoiding needless churn (and sync pushes).
    func reflowCompleted() {
        let sunk = items.filter { !($0.isTask && $0.done) } + items.filter { $0.isTask && $0.done }
        if sunk.map(\.id) != items.map(\.id) { items = sunk }
    }

    /// Sort tasks top-to-bottom by progress: untouched → in-progress → blocked →
    /// finished. Stable within each group (and plain non-task lines stay on top).
    func sortByProgress() {
        func rank(_ it: NoteItem) -> Int {
            guard it.isTask else { return -1 }
            switch it.status {
            case .open: return 0
            case .doing: return 1
            case .blocked: return 2
            case .done: return 3
            }
        }
        // enumerate so the offset breaks ties — Swift's sort isn't stable on its own.
        let sorted = items.enumerated()
            .sorted { a, b in
                let ra = rank(a.element), rb = rank(b.element)
                return ra != rb ? ra < rb : a.offset < b.offset
            }
            .map(\.element)
        if sorted.map(\.id) != items.map(\.id) { items = sorted }
    }

    @discardableResult
    func addTask(_ text: String = "") -> UUID {
        let item = NoteItem(text: text, isTask: true)
        // New tasks land at the bottom of the *unfinished* group — above any
        // completed tasks, which stay sunk at the very bottom.
        let insertAt = items.firstIndex { $0.isTask && $0.done } ?? items.count
        items.insert(item, at: insertAt)
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

    /// Set a task's text. Used by editors outside the notch card — the HUD's
    /// task rail edits the very same items the notch does.
    func setText(_ text: String, for id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if items[i].text != text { items[i].text = text }
    }

    /// Attach, replace, or clear the browser link for one task.
    func setLink(_ link: String?, for id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = link?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        items[i].link = trimmed.isEmpty ? nil : trimmed
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

    /// Move a task out of the current note into a brand-new note, named after the
    /// task text. Stays on the current note; the new note appears in the switcher.
    func moveTaskToNewNote(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let moved = items.remove(at: idx) // removing triggers a save of this note
        let base = sanitize(String(moved.text.prefix(40)))
        let name = uniqueName(base == "Untitled" ? "Untitled" : base)
        let url = folder.appendingPathComponent("\(name).md")
        try? Self.serializeDocument(title: name, items: [moved])
            .data(using: .utf8)?.write(to: url, options: .atomic)
        cache.removeValue(forKey: name)
        refreshNoteNames()
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
    private static let linkRE = try! NSRegularExpression(pattern: #"\s*<!--\s*visor-link:\s*(.*?)\s*-->\s*$"#)

    static func parse(_ s: String) -> [NoteItem] {
        var items = s.split(separator: "\n", omittingEmptySubsequences: false).map { sub -> NoteItem in
            let line = String(sub)
            let range = NSRange(line.startIndex..., in: line)
            if let m = taskRE.firstMatch(in: line, range: range),
               let markR = Range(m.range(at: 1), in: line),
               let textR = Range(m.range(at: 2), in: line) {
                let marker = line[markR].first ?? " "
                let (text, link) = extractLink(from: String(line[textR]))
                return NoteItem(text: text, isTask: true, status: .from(marker: marker), link: link)
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

    private static func extractLink(from rawText: String) -> (text: String, link: String?) {
        let range = NSRange(rawText.startIndex..., in: rawText)
        guard let match = linkRE.firstMatch(in: rawText, range: range),
              let fullRange = Range(match.range(at: 0), in: rawText),
              let linkRange = Range(match.range(at: 1), in: rawText) else {
            return (rawText, nil)
        }
        let text = rawText[..<fullRange.lowerBound].trimmingCharacters(in: .whitespaces)
        let link = rawText[linkRange].trimmingCharacters(in: .whitespacesAndNewlines)
        return (String(text), link.isEmpty ? nil : String(link))
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
            if item.isTask {
                let link = item.link?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let suffix = link.isEmpty ? "" : " <!-- visor-link: \(link.replacingOccurrences(of: "-->", with: "%2D%2D%3E")) -->"
                return "- [\(item.status.marker)] \(text)\(suffix)"
            }
            return text
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

    /// Drop blank task rows — e.g. empty `- [ ]` lines left behind by pressing
    /// Return and not typing. `keepID` spares the row currently being edited, so we
    /// can prune the instant focus moves to another line without deleting the row
    /// you just moved into. Called on focus change and when leaving/hiding a note.
    func pruneEmptyTasks(except keepID: UUID? = nil) {
        let kept = items.filter { item in
            if item.id == keepID { return true }
            return !(item.isTask && item.text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if kept.count != items.count { items = kept }
    }

    /// Persist as the card hides: prune blank rows first, then save (which also
    /// discards the note entirely if pruning left it empty).
    func prepareToHide() {
        pruneEmptyTasks()
        saveNow()
    }

    /// A note with no title and no non-blank tasks — nothing worth keeping.
    private func contentIsEmpty(_ title: String, _ items: [NoteItem]) -> Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && items.allSatisfy { $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    func saveNow() {
        saveTask?.cancel()
        // Never persist an empty note — an untouched "New note" you click away from
        // shouldn't linger. (Shared notes are exempt: they have a remote identity.)
        if sharedRef(for: activeName) == nil, contentIsEmpty(title, items) {
            if FileManager.default.fileExists(atPath: activeURL.path) {
                try? FileManager.default.removeItem(at: activeURL)
                cache.removeValue(forKey: activeName)
                lastMTime = nil
                refreshNoteNames()
            }
            dirty = false
            return
        }
        guard dirty || !FileManager.default.fileExists(atPath: activeURL.path) else { return }
        try? serialized.data(using: .utf8)?.write(to: activeURL, options: .atomic)
        dirty = false
        lastMTime = mtime(activeURL)
        cacheActive()
        ensureMirrorSymlink()
        pushIfShared()
    }

    // MARK: - Notes (switch / create)

    /// Switch to another saved note. The outgoing note is persisted in the
    /// background and the incoming note is served from the in-memory cache when
    /// possible, so this returns immediately instead of blocking on disk.
    func switchTo(_ name: String) {
        guard name != activeName else { return }
        commitRenameNow()                 // handle a pending title rename (usually a no-op)
        guard name != activeName else { return } // …which may itself have changed activeName

        pruneEmptyTasks()                 // don't carry blank rows out of the note we're leaving
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

        rememberActiveName()
        attachSyncForActive()

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
        // Leaving an empty, unshared note discards it rather than persisting it.
        if sharedRef(for: outgoing) == nil, contentIsEmpty(snapTitle, snapItems) {
            cache.removeValue(forKey: outgoing)
            dirty = false
            let url = activeURL
            io.async { [weak self] in
                try? FileManager.default.removeItem(at: url)
                DispatchQueue.main.async { self?.refreshNoteNames() }
            }
            return
        }
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
        // Already sitting on an empty note? Reuse it instead of stacking another.
        if sharedRef(for: activeName) == nil, contentIsEmpty(title, items) { return }
        saveNow()
        activeName = uniqueName("Untitled")
        suppressDirty = true; title = ""; items = []; suppressDirty = false
        dirty = true
        saveNow()
        rememberActiveName()
        attachSyncForActive() // a fresh note isn't shared — detach any prior sync
        refreshNoteNames()
    }

    // MARK: - Beam (share a note via a link or a .visor file)

    /// Produce a shareable link for the current note and, when the sync backend
    /// is available, promote it to a *live* shared note so edits flow both ways.
    /// Network work runs off the main thread, so the result is delivered via the
    /// completion (on the main thread). Falls back to a legacy offline-copy link
    /// if sharing isn't configured or the share fails. Re-sharing an already
    /// shared note returns its existing link.
    func shareNote(completion: @escaping (String?) -> Void) {
        if let ref = sharedRef(for: activeName) {
            completion(BeamLink.sharedLink(for: ref))
            return
        }
        saveNow() // flush current edits so the shared seed is complete
        guard let sync else {
            completion(BeamLink.link(forMarkdown: serialized))
            return
        }
        let name = activeName
        let seed = serialized
        sync.share(markdown: seed, nameHint: name) { [weak self] ref in
            guard let self else { completion(nil); return }
            guard let ref else {
                completion(BeamLink.link(forMarkdown: seed)) // backend hiccup — offline copy
                return
            }
            self.setSharedRef(ref, for: name)
            if name == self.activeName { self.refreshSharedState() }
            completion(BeamLink.sharedLink(for: ref))
        }
    }

    /// Import a note received via a beam link. A *live* link joins the shared
    /// note and starts syncing; a *legacy* link drops a one-time copy. Returns
    /// false if the URL can't be decoded.
    @discardableResult
    func importBeamed(from url: URL) -> Bool {
        if let ref = BeamLink.sharedRef(fromURL: url) {
            joinShared(ref: ref)
            return true
        }
        guard let markdown = BeamLink.markdown(fromURL: url) else { return false }
        createNote(fromMarkdown: markdown, defaultName: "Beamed note")
        return true
    }

    /// Join a live shared note: switch to it if we already have it, otherwise
    /// create a local note and fill it from the remote seed, then keep it synced.
    private func joinShared(ref: BeamRef) {
        if let existing = noteNameForSharedRef(ref) {
            switchTo(existing)
            return
        }
        guard let sync else { return } // can't join without a backend
        commitRenameNow()
        saveNow()
        let name = uniqueName("Beamed note")
        activeName = name
        suppressDirty = true; title = ""; items = []; suppressDirty = false
        dirty = true
        saveNow()
        setSharedRef(ref, for: name)
        rememberActiveName()
        refreshNoteNames()
        refreshSharedState()
        sync.join(ref: ref) { [weak self] markdown in
            guard let self, let markdown, self.activeName == name else { return }
            self.applyRemoteMarkdown(markdown)
        }
    }

    /// Apply a remote edit to the active shared note. Treated like an external
    /// file edit: skipped while the user is mid-edit (the merge is already safe in
    /// the CRDT and will surface on the next clean tick), and written straight to
    /// disk *without* re-pushing it back out as a local change.
    private func applyRemoteMarkdown(_ markdown: String) {
        guard !dirty else { return }
        let (t, parsed) = Self.parseDocument(markdown)
        guard Self.serializeDocument(title: t, items: parsed) != serialized else { return }
        // Re-parsing mints fresh UUIDs for every line. Reuse the existing rows'
        // ids positionally so SwiftUI only re-renders the rows that actually
        // changed — otherwise the whole list (and every row's hover controls)
        // churns and flickers on each incoming keystroke from a peer.
        var it = parsed
        for i in it.indices where i < items.count {
            it[i] = NoteItem(id: items[i].id, text: it[i].text, isTask: it[i].isTask, status: it[i].status, link: it[i].link)
        }
        applyingRemote = true
        suppressDirty = true
        if title != t { title = t }
        items = it
        suppressDirty = false
        applyingRemote = false
        try? serialized.data(using: .utf8)?.write(to: activeURL, options: .atomic)
        dirty = false
        lastMTime = mtime(activeURL)
        cacheActive()
        ensureMirrorSymlink()
    }

    /// Attach the sync engine to the active note when it's shared, else detach.
    private func attachSyncForActive() {
        guard let sync else { refreshSharedState(); return }
        if let ref = sharedRef(for: activeName) {
            sync.attach(ref: ref, localMarkdown: serialized)
        } else {
            sync.detach()
        }
        refreshSharedState()
    }

    /// Recompute the published share state for the active note.
    private func refreshSharedState() {
        let shared = sharedRef(for: activeName) != nil
        if isActiveNoteShared != shared { isActiveNoteShared = shared }
        if !shared, presenceCount != 0 { presenceCount = 0 }
    }

    /// Push the active note's content if it's shared. Debounced inside the engine
    /// and a no-op when nothing changed, so it's cheap to call on every save.
    private func pushIfShared() {
        guard !applyingRemote, sharedRef(for: activeName) != nil else { return }
        sync?.pushLocal(markdown: serialized)
    }

    // MARK: - Shared-note references (name ↔ live document)

    private func sharedRefMap() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: sharedRefsKey) as? [String: String] ?? [:]
    }

    private func sharedRef(for name: String) -> BeamRef? {
        guard let raw = sharedRefMap()[name] else { return nil }
        // Accept legacy "id/token" entries too — the id is the first segment.
        let id = raw.split(separator: "/", maxSplits: 1).first.map(String.init) ?? raw
        return id.isEmpty ? nil : BeamRef(id: id)
    }

    private func setSharedRef(_ ref: BeamRef, for name: String) {
        var map = sharedRefMap()
        map[name] = ref.id
        if !ephemeral { UserDefaults.standard.set(map, forKey: sharedRefsKey) }
    }

    private func removeSharedRef(for name: String) {
        var map = sharedRefMap()
        map.removeValue(forKey: name)
        if !ephemeral { UserDefaults.standard.set(map, forKey: sharedRefsKey) }
    }

    private func moveSharedRef(from old: String, to new: String) {
        var map = sharedRefMap()
        guard let v = map.removeValue(forKey: old) else { return }
        map[new] = v
        if !ephemeral { UserDefaults.standard.set(map, forKey: sharedRefsKey) }
    }

    private func noteNameForSharedRef(_ ref: BeamRef) -> String? {
        sharedRefMap().first { $0.value == ref.id || $0.value.hasPrefix(ref.id + "/") }?.key
    }

    /// Import a note from a `.visor` file (e.g. received via AirDrop). Returns
    /// false if the file can't be read.
    @discardableResult
    func importNoteFile(from url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let markdown = String(data: data, encoding: .utf8) else { return false }
        createNote(fromMarkdown: markdown, defaultName: url.deletingPathExtension().lastPathComponent)
        return true
    }

    /// Create a new note from markdown and switch to it. Used by both beam links
    /// and `.visor` files. `defaultName` is the title to fall back on when the
    /// markdown has no `# heading`.
    private func createNote(fromMarkdown markdown: String, defaultName: String) {
        let (t, it) = Self.parseDocument(markdown)
        commitRenameNow()
        saveNow()
        activeName = uniqueName(sanitize(t.isEmpty ? defaultName : t))
        suppressDirty = true; title = t; items = it; suppressDirty = false
        dirty = true
        saveNow()
        rememberActiveName()
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
        rememberActiveName()
        ensureMirrorSymlink()
        attachSyncForActive() // sync the note we landed on (archived note's link is kept)
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
        moveSharedRef(from: name, to: target) // a restored shared note keeps its link
        refreshNoteNames()
        refreshArchivedNames()
        activeName = target
        loadActive()
        rememberActiveName()
        ensureMirrorSymlink()
        attachSyncForActive()
    }

    /// Permanently delete a note's file. If it's the active note, switch to
    /// another (or a fresh empty one). Unlike archive, this is not recoverable.
    func deleteNote(_ name: String) {
        let url = folder.appendingPathComponent("\(name).md")
        cache.removeValue(forKey: name)
        // Drop the local link mapping. (This stops syncing locally; it doesn't
        // remove us from the shared note's members or delete it remotely.)
        removeSharedRef(for: name)
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
            rememberActiveName()
            ensureMirrorSymlink()
            attachSyncForActive()
        } else {
            try? FileManager.default.removeItem(at: url)
        }
        refreshNoteNames()
    }

    /// Change how the switcher orders notes (persisted).
    func setNoteSort(_ sort: NoteSort) {
        noteSort = sort
        if !ephemeral { UserDefaults.standard.set(sort.rawValue, forKey: noteSortKey) }
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
        rememberActiveName()
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
        moveSharedRef(from: previous, to: target) // keep the live link tied to the note
        rememberActiveName()
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
