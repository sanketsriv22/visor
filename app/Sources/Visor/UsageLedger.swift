import Foundation

/// One request's worth of consumption.
struct UsageEntry: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    /// The agent as the user named it.
    var agent: String
    /// What's actually being billed. Several agents share one OpenRouter key,
    /// so this is the number that matters when you're asking "what am I
    /// spending" rather than "which agent did I use".
    var account: String
    /// "openrouter" or the CLI's command.
    var source: String
    var model: String
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    /// Nil where nothing is billed per call — a CLI agent on a subscription
    /// consumes tokens but isn't charged for them, and showing $0.00 there
    /// would be a different claim from showing nothing.
    var costUSD: Double?
}

/// A running total per account, for display.
struct UsageTotal: Identifiable {
    var id: String { account }
    var account: String
    var source: String
    var requests = 0
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var costUSD: Double = 0
    /// False when nothing in the group reported a cost, so the column can say
    /// "subscription" instead of implying it was free.
    var billed = false
    var agents: Set<String> = []
}

/// Append-only record of what every agent has consumed.
///
/// Per account rather than per agent, because that's the question being asked:
/// several agents can sit behind one OpenRouter key, and a local CLI agent is
/// billed by whoever the user signed in to it as — not by Visor at all. Keeping
/// them in one file with the account named on every line means the split is a
/// grouping rather than two separate systems that have to agree.
///
/// One JSON object per line, like the voice log: appending costs the same on
/// the ten-thousandth entry as the first, and a truncated write loses one line
/// rather than the file.
enum UsageLedger {
    static var url: URL {
        ChatStore.defaultRoot.appendingPathComponent("usage.jsonl")
    }

    /// How far back a total covers.
    enum Window: String, CaseIterable, Identifiable {
        case today = "Today"
        case week = "7 days"
        case month = "30 days"
        case all = "All time"

        var id: String { rawValue }

        var start: Date? {
            let now = Date()
            switch self {
            case .today: return Calendar.current.startOfDay(for: now)
            case .week:  return now.addingTimeInterval(-7 * 86_400)
            case .month: return now.addingTimeInterval(-30 * 86_400)
            case .all:   return nil
            }
        }
    }

    static func record(_ entry: UsageEntry) {
        // Nothing consumed is nothing to record — an empty line here would
        // inflate the request count for turns that never reached a model.
        guard entry.input + entry.output + entry.cacheRead + entry.cacheWrite > 0
                || entry.costUSD != nil
        else { return }
        guard var line = try? JSONEncoder().encode(entry) else { return }
        line.append(0x0A)
        append(line)
    }

    static func entries() -> [UsageEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        var out: [UsageEntry] = []
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            // One unreadable line shouldn't cost the whole history.
            if let entry = try? decoder.decode(UsageEntry.self, from: Data(line)) {
                out.append(entry)
            }
        }
        return out
    }

    /// Totals per account over `window`, biggest spend first.
    static func totals(in window: Window) -> [UsageTotal] {
        let cutoff = window.start
        var grouped: [String: UsageTotal] = [:]
        for entry in entries() {
            if let cutoff, entry.date < cutoff { continue }
            var total = grouped[entry.account]
                ?? UsageTotal(account: entry.account, source: entry.source)
            total.requests += 1
            total.input += entry.input
            total.output += entry.output
            total.cacheRead += entry.cacheRead
            total.cacheWrite += entry.cacheWrite
            total.agents.insert(entry.agent)
            if let cost = entry.costUSD {
                total.costUSD += cost
                total.billed = true
            }
            grouped[entry.account] = total
        }
        return grouped.values.sorted {
            if $0.billed != $1.billed { return $0.billed }
            if $0.costUSD != $1.costUSD { return $0.costUSD > $1.costUSD }
            return $0.output > $1.output
        }
    }

    /// Forget everything. Offered because a usage log is a record of what
    /// someone has been doing, and that should be theirs to delete.
    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    private static func append(_ line: Data) {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try? manager.createDirectory(at: url.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
            try? line.write(to: url)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }
}
