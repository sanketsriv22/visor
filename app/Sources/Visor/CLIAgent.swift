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
        case finished(status: Int32)
    }

    private var process: Process?

    /// Where an agent's executable is likely to be. A GUI app inherits a bare
    /// PATH, so a bare command name would otherwise never resolve.
    private static let searchPath: String = {
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
    func run(command: String, arguments: [String], prompt: String,
             directory: URL, environmentKey: (name: String, value: String)? = nil)
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
            task.environment = env

            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            self.process = task

            // Read as it comes rather than waiting for exit — the whole point
            // is watching it work.
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                if let text = String(data: chunk, encoding: .utf8) {
                    continuation.yield(.text(text))
                }
            }

            task.terminationHandler = { finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                // Anything buffered between the last read and exit.
                let rest = pipe.fileHandleForReading.availableData
                if !rest.isEmpty, let text = String(data: rest, encoding: .utf8) {
                    continuation.yield(.text(text))
                }
                continuation.yield(.finished(status: finished.terminationStatus))
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
