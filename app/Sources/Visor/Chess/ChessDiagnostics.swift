import AppKit

/// Writes down what the finder saw, so a board that wasn't recognised can be
/// looked at rather than guessed about.
///
/// This exists because the loop for fixing detection is otherwise impossible:
/// the board is on someone else's screen, a screenshot can't be taken from
/// outside the app, and "it says the game is already in progress" is a symptom
/// with a dozen causes. A picture and the finder's own reasoning turn that into
/// something answerable.
enum ChessDiagnostics {
    /// One line per step of anything that acts on the screen, appended to a
    /// running log. Screenshots explain why a board wasn't found; this
    /// explains why a click didn't land, which is a question the screenshots
    /// can't answer and which was being answered by guesswork.
    static func trace(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\(stamp)  \(line)\n"
        let url = directory.appendingPathComponent("trace.log")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? entry.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static var directory: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Logs/Visor/chess", isDirectory: true)
    }

    /// Keep the screenshot and a summary. Returns the folder, for showing.
    @discardableResult
    static func record(shot: ChessScreen.Shot, found: ChessBoardFinder.Found?,
                       verdict: String) -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let folder = directory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let png = folder.appendingPathComponent("board-\(stamp).png")
        let rep = NSBitmapImageRep(cgImage: shot.image)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: png)
        }

        var report = """
            Visor chess detection — \(stamp)
            screen origin: \(shot.origin)
            image: \(shot.image.width)×\(shot.image.height)
            verdict: \(verdict)

            """
        if let found {
            report += """
                board: \(found.geometry.rect)
                square: \(found.geometry.square)
                playing: \(found.geometry.flipped ? "black" : "white")
                confidence: \(String(format: "%.2f", found.confidence))

                occupancy, rank 8 first — W white, b black, · empty:

                """
            for rank in stride(from: 7, through: 0, by: -1) {
                var row = "  "
                for file in 0..<8 {
                    guard let square = Square(file: file, rank: rank) else { continue }
                    switch found.occupancy[square] ?? nil {
                    case .white?: row += "W "
                    case .black?: row += "b "
                    case nil:     row += "· "
                    }
                }
                report += row + "\n"
            }
        }
        report += "\nreasoning:\n"
            + ChessBoardFinder.reasoning.map { "  " + $0 }.joined(separator: "\n") + "\n"

        try? report.write(to: folder.appendingPathComponent("board-\(stamp).txt"),
                          atomically: true, encoding: .utf8)
        prune(in: folder)
        return folder
    }

    /// Keep the last dozen. This is a debugging aid, not an archive, and a
    /// folder of screenshots is not a thing to grow without limit on someone
    /// else's disk.
    private static func prune(in folder: URL, keeping: Int = 12) {
        guard let all = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey])
        else { return }
        let stamps = Set(all.map { $0.deletingPathExtension().lastPathComponent }).sorted()
        guard stamps.count > keeping else { return }
        for stamp in stamps.prefix(stamps.count - keeping) {
            for ext in ["png", "txt"] {
                try? FileManager.default.removeItem(
                    at: folder.appendingPathComponent("\(stamp).\(ext)"))
            }
        }
    }
}
