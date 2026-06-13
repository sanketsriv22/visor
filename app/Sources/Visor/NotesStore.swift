import Foundation

/// Owns the sticky note text. The markdown file on disk is the source of
/// truth shared with the MCP server; the app is just an editor for it.
final class NotesStore: ObservableObject {
    @Published var text: String = "" {
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

    var openTaskCount: Int {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- [ ]") }
            .count
    }

    init() {
        if let env = ProcessInfo.processInfo.environment["STICKY_NOTES_FILE"] {
            fileURL = URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        } else {
            fileURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("StickyNotes/sticky.md")
        }
        loadOrCreate()
    }

    /// Pick up edits made by the MCP server (or anything else) while the
    /// panel was collapsed. Skipped if there are unsaved local edits —
    /// last writer wins, and the user's in-progress typing wins locally.
    func reloadFromDiskIfClean() {
        guard !dirty else { return }
        guard let data = try? Data(contentsOf: fileURL),
              let s = String(data: data, encoding: .utf8),
              s != text else { return }
        suppressDirty = true
        text = s
        suppressDirty = false
    }

    func saveNow() {
        saveTask?.cancel()
        guard dirty || !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try? text.data(using: .utf8)?.write(to: fileURL, options: .atomic)
        dirty = false
    }

    private func loadOrCreate() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        suppressDirty = true
        if let data = try? Data(contentsOf: fileURL),
           let s = String(data: data, encoding: .utf8) {
            text = s
        } else {
            text = "# Stickies\n\n- [ ] click the notch again to hide this\n"
        }
        suppressDirty = false

        if !FileManager.default.fileExists(atPath: fileURL.path) {
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
