import Foundation

/// Runs a local command-line agent and streams its output back as it arrives.
///
/// This is what makes Claude Code (or Codex, or anything else with a
/// `-p "prompt"` mode) a first-class agent *inside* Visor rather than something
/// Visor shells out to and loses sight of. The same composer, the same
/// transcript, the same history — it just happens to be a process on this
/// machine instead of a request to a model.
///
/// Streaming rather than waiting matters more here than for a chat model: a
/// coding agent can work for minutes, and a notch that shows nothing for two
/// of them looks broken.
///
/// Nothing here adds permission flags of its own. Whatever the agent is allowed
/// to do is whatever the user configured in its arguments — Visor doesn't
/// quietly widen that on their behalf.
final class CLIAgentRunner {
    /// Output as it appears, then a completion.
    enum Event {
        case text(String)
        /// What the turn cost, when the agent reports it.
        case usage(CLIUsage)
        case finished(status: Int32)
    }

    /// What a turn consumed, as the agent itself accounts for it.
    struct CLIUsage {
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheWrite = 0
        /// Nil for a subscription agent, which isn't billed per call.
        var costUSD: Double?
        var model: String?
    }

    private var process: Process?

    /// Where an agent's executable is likely to be. A GUI app inherits a bare
    /// PATH, so a bare command name would otherwise never resolve.
    static let searchPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    }()

    static func resolve(_ command: String) -> String? {
        if command.contains("/") {
            let path = (command as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }
        return searchPath
            .split(separator: ":")
            .map { "\($0)/\(command)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Run `command args… prompt`, yielding output as it's produced.
    ///
    /// `structured` says the agent emits newline-delimited JSON events rather
    /// than prose. That's how a reply arrives a token at a time instead of in
    /// one lump at the end — and it's the only way the agent tells us what the
    /// turn cost, since a subscription CLI has no billing endpoint to ask.
    func run(command: String, arguments: [String], prompt: String,
             directory: URL, environmentKey: (name: String, value: String)? = nil,
             extraEnvironment: [String: String] = [:],
             structured: Bool = false)
        -> AsyncStream<Event> {
        AsyncStream { continuation in
            guard let executable = Self.resolve(command) else {
                continuation.yield(.text("Couldn't find \(command) on this machine."))
                continuation.yield(.finished(status: 127))
                continuation.finish()
                return
            }

            let task = Process()
            task.executableURL = URL(fileURLWithPath: executable)
            task.arguments = arguments + [prompt]
            task.currentDirectoryURL = directory

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = Self.searchPath + ":" + (env["PATH"] ?? "")
            if let environmentKey { env[environmentKey.name] = environmentKey.value }
            for (name, value) in extraEnvironment { env[name] = value }
            task.environment = env

            // Separate pipes, because these carry different things. Agents
            // write their answer to stdout and their grumbling to stderr —
            // config warnings, deprecation notices, progress chatter. Merged,
            // all of that lands in the transcript as if the agent had said it.
            //
            // stderr is kept, not discarded: when a run fails it's usually the
            // only thing that explains why.
            let out = Pipe()
            let err = Pipe()
            task.standardOutput = out
            task.standardError = err
            self.process = task

            let stderrBuffer = StderrBuffer()
            let parser = structured ? EventParser() : nil

            // Read as it comes rather than waiting for exit — the whole point
            // is watching it work.
            out.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
                guard let parser else {
                    continuation.yield(.text(text))
                    return
                }
                for event in parser.consume(text) { continuation.yield(event) }
            }
            err.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
                stderrBuffer.append(text)
            }

            task.terminationHandler = { finished in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil

                // Anything buffered between the last read and exit.
                let rest = out.fileHandleForReading.availableData
                if !rest.isEmpty, let text = String(data: rest, encoding: .utf8) {
                    if let parser {
                        for event in parser.consume(text) { continuation.yield(event) }
                    } else {
                        continuation.yield(.text(text))
                    }
                }
                if let parser {
                    for event in parser.finish() { continuation.yield(event) }
                }
                let restErr = err.fileHandleForReading.availableData
                if !restErr.isEmpty, let text = String(data: restErr, encoding: .utf8) {
                    stderrBuffer.append(text)
                }

                // Only surface stderr when it's the only explanation going.
                let status = finished.terminationStatus
                if status != 0 {
                    let complaint = stderrBuffer.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !complaint.isEmpty {
                        continuation.yield(.text("\n\n_\(complaint)_"))
                    }
                }
                continuation.yield(.finished(status: status))
                continuation.finish()
            }

            do {
                try task.run()
            } catch {
                continuation.yield(.text("Couldn't start \(command): \(error.localizedDescription)"))
                continuation.yield(.finished(status: 126))
                continuation.finish()
            }

            // Stopping a reply has to stop the work, not just the display.
            continuation.onTermination = { _ in
                if task.isRunning { task.terminate() }
            }
        }
    }

    func stop() {
        if let process, process.isRunning { process.terminate() }
        process = nil
    }
}

/// Collects stderr off the reader thread.
///
/// The readability handler runs on a background queue, so the buffer it
/// appends to needs its own lock — a plain String would be a data race.
private final class StderrBuffer: @unchecked Sendable {
    private var storage = ""
    private let lock = NSLock()

    func append(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        // Bounded: a chatty agent shouldn't be able to hold megabytes of
        // warnings we only ever show a few lines of.
        guard storage.count < 8_000 else { return }
        storage += text
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}


/// Turns an agent's JSON event stream into text and a usage total.
///
/// Deliberately forgiving. The exact envelope belongs to the tool and changes
/// between its versions, so this reads several shapes and treats anything it
/// can't parse as prose rather than dropping it. A parser that silently
/// discards an unrecognised line would turn a format change into an agent that
/// answers with nothing — the worst possible failure, because it looks like the
/// model had nothing to say.
private final class EventParser: @unchecked Sendable {
    private var buffer = ""
    private var sawDelta = false
    private var emittedAnything = false
    private var usage = CLIAgentRunner.CLIUsage()
    private var sawUsage = false
    /// The whole reply, as reported at the end — used only if streaming it
    /// produced nothing.
    private var finalText: String?
    private let lock = NSLock()

    func consume(_ text: String) -> [CLIAgentRunner.Event] {
        lock.lock(); defer { lock.unlock() }
        buffer += text
        var events: [CLIAgentRunner.Event] = []
        // Whole lines only: a JSON object split across two reads isn't parseable
        // yet, and half of one is not prose either.
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<newline])
            buffer = String(buffer[buffer.index(after: newline)...])
            events += handle(line)
        }
        return events
    }

    /// Whatever is left when the process exits, plus the usage total.
    func finish() -> [CLIAgentRunner.Event] {
        lock.lock(); defer { lock.unlock() }
        var events: [CLIAgentRunner.Event] = []
        if !buffer.isEmpty {
            events += handle(buffer)
            buffer = ""
        }
        // The agent streamed nothing we understood but did report a result.
        // Better late than silent.
        if !emittedAnything, let finalText, !finalText.isEmpty {
            events.append(.text(finalText))
            emittedAnything = true
        }
        if sawUsage { events.append(.usage(usage)) }
        return events
    }

    private func handle(_ line: String) -> [CLIAgentRunner.Event] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // Not JSON: the tool printed a warning, or isn't speaking the
            // format we asked for. Either way the user should see it.
            emittedAnything = true
            return [.text(line + "\n")]
        }

        switch object["type"] as? String {
        case "stream_event":
            guard let event = object["event"] as? [String: Any],
                  event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  let text = delta["text"] as? String, !text.isEmpty
            else { return [] }
            sawDelta = true
            emittedAnything = true
            return [.text(text)]

        case "assistant":
            // The completed turn. Its text duplicates the deltas when partial
            // messages are on, so it only speaks when they weren't.
            guard let message = object["message"] as? [String: Any] else { return [] }
            absorb(usage: message["usage"] as? [String: Any], model: message["model"] as? String)
            guard !sawDelta, let blocks = message["content"] as? [[String: Any]] else { return [] }
            var text = ""
            for block in blocks where block["type"] as? String == "text" {
                text += block["text"] as? String ?? ""
            }
            guard !text.isEmpty else { return [] }
            emittedAnything = true
            return [.text(text)]

        case "result":
            if let cost = object["total_cost_usd"] as? Double {
                usage.costUSD = cost
                sawUsage = true
            }
            absorb(usage: object["usage"] as? [String: Any], model: nil)
            finalText = object["result"] as? String
            return []

        default:
            // Init banners, tool notices, anything new the tool starts sending.
            return []
        }
    }

    /// Usage is reported cumulatively per turn, so the largest report wins
    /// rather than the sum — adding them would count the same tokens once per
    /// message.
    private func absorb(usage report: [String: Any]?, model: String?) {
        guard let report else { return }
        sawUsage = true
        if let model { usage.model = model }
        usage.input = max(usage.input, report["input_tokens"] as? Int ?? 0)
        usage.output = max(usage.output, report["output_tokens"] as? Int ?? 0)
        usage.cacheRead = max(usage.cacheRead, report["cache_read_input_tokens"] as? Int ?? 0)
        usage.cacheWrite = max(usage.cacheWrite, report["cache_creation_input_tokens"] as? Int ?? 0)
    }
}
