import AppKit
import Foundation

/// Fires the open tasks at the local Devin CLI in autonomous mode and tracks
/// the run for the UI. Devin runs with `--permission-mode dangerous` so it can
/// use any tool and spin up whatever sub-agents/sessions it needs to finish.
final class DevinRunner: ObservableObject {
    enum Status: Equatable {
        case idle
        case running
        case done
        case failed(String)
    }

    @Published private(set) var status: Status = .idle

    /// Where Devin works. Tasks may span repos; it can navigate from here.
    private let workDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("repos")
    private let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("StickyNotes/devin-last.log")

    private var devinPath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/devin",
            "/opt/homebrew/bin/devin",
            "/usr/local/bin/devin",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func send(tasks: [String]) {
        guard status != .running else { return }
        guard !tasks.isEmpty else { return }
        guard let devin = devinPath else {
            status = .failed("Devin CLI not found")
            return
        }

        let list = tasks.map { "- \($0)" }.joined(separator: "\n")
        let prompt = """
        Here are my open tasks from my sticky note:

        \(list)

        Work through all of them. For each task, do whatever it takes to finish \
        it — you have my permission to run any tools and to spin up additional \
        agents or cloud sessions as needed. Make the actual changes (and open \
        PRs where that fits). When you complete a task, say so clearly. End with \
        a short summary of what you did and anything still blocked on me.
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: devin)
        process.arguments = ["--permission-mode", "dangerous", "-p", prompt]
        let dir = FileManager.default.fileExists(atPath: workDir.path)
            ? workDir
            : FileManager.default.homeDirectoryForCurrentUser
        process.currentDirectoryURL = dir

        // GUI apps inherit a bare PATH; give Devin the usual tool locations so
        // it can reach git/node/etc. while working.
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        process.environment = env

        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            process.standardOutput = handle
            process.standardError = handle
        }

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.status = proc.terminationStatus == 0 ? .done : .failed("exit \(proc.terminationStatus)")
            }
        }

        do {
            try process.run()
            status = .running
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Open the run log in the user's default viewer.
    func revealLog() {
        if FileManager.default.fileExists(atPath: logURL.path) {
            NSWorkspace.shared.open(logURL)
        }
    }
}
