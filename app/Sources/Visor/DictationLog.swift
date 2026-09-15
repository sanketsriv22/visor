import Foundation

/// Every step of a dictation, to ~/Library/Logs/Visor/dictation.log —
/// key, microphone, stream, upload, delivery — so a transcript that
/// goes missing leaves a trail instead of a mystery.
enum DictationLog {
    private static let handle: FileHandle? = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Visor")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("dictation.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let h = try? FileHandle(forWritingTo: url)
        h?.seekToEndOfFile()
        return h
    }()
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let queue = DispatchQueue(label: "visor.dictation.log")

    static func note(_ line: String) {
        let text = "\(stamp.string(from: Date())) \(line)\n"
        queue.async { handle?.write(text.data(using: .utf8)!) }
    }
}
