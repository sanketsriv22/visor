import Foundation

/// One dictated utterance.
struct VoiceEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var text: String
    var date: Date = Date()
    /// How long the recording ran, when we know.
    var duration: Double?
    /// Where it went, if anywhere — a chat id when it was dictated into one.
    var conversation: UUID?
}

/// Append-only log of everything dictated.
///
/// JSON Lines, not a JSON array: an array has to be read, parsed, mutated and
/// rewritten in full for every entry, which gets slower forever. A line is a
/// seek-to-end and a write, so appending costs the same on the ten-thousandth
/// utterance as the first — and a truncated write costs one line rather than
/// the whole log.
enum VoiceLog {
    static var url: URL {
        ChatStore.defaultRoot.appendingPathComponent("voice-log.jsonl")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        // One entry per line, so the format survives being appended to.
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static let io = DispatchQueue(label: "com.kitalabs.visor.voicelog")

    static func append(_ entry: VoiceEntry) {
        io.async {
            guard var line = try? encoder.encode(entry) else { return }
            line.append(0x0A)   // newline
            let target = url
            let fm = FileManager.default
            try? fm.createDirectory(at: target.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: target) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: target, options: .atomic)
            }
        }
    }

    /// Most recent entries, newest first. Reads the whole file — fine at the
    /// scale a person dictates, and the format is here so that a smarter
    /// tail-read can be dropped in without changing what's on disk.
    static func recent(limit: Int = 50) -> [VoiceEntry] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .reversed()
            .prefix(limit)
            // A half-written final line shouldn't take out the whole log.
            .compactMap { try? decoder.decode(VoiceEntry.self, from: Data($0.utf8)) }
    }

    static var count: Int {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: true).count
    }
}
