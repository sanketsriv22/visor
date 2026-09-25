import Foundation

/// What the terminal client lets an agent do. Small on purpose, and the
/// same shape the app uses, so a model behaves the same in both.
struct CLITool {
    let name: String
    let description: String
    let parameters: [String: Any]
    let needsApproval: Bool
    let run: ([String: Any]) async -> String

    var schema: [String: Any] {
        ["type": "function",
         "function": ["name": name, "description": description, "parameters": parameters]]
    }
}

enum CLITools {
    static func all(workDir: URL) -> [CLITool] {
        [
            CLITool(
                name: "run_shell",
                description: "Run a shell command in the current project folder and return its output. Use it to read files, search, or run builds and tests. The user is asked before anything runs.",
                parameters: ["type": "object",
                             "properties": ["command": ["type": "string", "description": "The command to run"]] as [String: Any],
                             "required": ["command"], "additionalProperties": false] as [String: Any],
                needsApproval: true
            ) { args in
                guard let command = (args["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !command.isEmpty else { return "No command given." }
                return await shell(command, in: workDir)
            },
            CLITool(
                name: "fetch_url",
                description: "Fetch a web page and return its readable text.",
                parameters: ["type": "object",
                             "properties": ["url": ["type": "string", "description": "The address to load"]] as [String: Any],
                             "required": ["url"], "additionalProperties": false] as [String: Any],
                needsApproval: false
            ) { args in
                guard let raw = args["url"] as? String, let url = URL(string: raw) else { return "That isn't a URL I can load." }
                return await fetch(url)
            },
        ]
    }

    static func shell(_ command: String, in dir: URL) async -> String {
        await withCheckedContinuation { continuation in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/zsh")
            task.arguments = ["-lc", command]
            task.currentDirectoryURL = dir
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            do { try task.run() } catch {
                continuation.resume(returning: "Couldn't run that: \(error.localizedDescription)"); return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            var text = String(data: data, encoding: .utf8) ?? ""
            if text.count > 12_000 { text = String(text.prefix(12_000)) + "\n… (truncated)" }
            if task.terminationStatus != 0 { text += "\n(exit status \(task.terminationStatus))" }
            continuation.resume(returning: text.isEmpty ? "(no output)" : text)
        }
    }

    static func fetch(_ url: URL) async -> String {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("Mozilla/5.0 (Visor CLI)", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            guard var html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                return "The page loaded but had no readable text"
            }
            for tag in ["script", "style", "noscript", "svg"] {
                html = html.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: " ", options: .regularExpression)
            }
            html = html.replacingOccurrences(of: "<br\\s*/?>|</p>|</div>|</li>|</h[1-6]>|</tr>", with: "\n", options: .regularExpression)
            html = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] {
                html = html.replacingOccurrences(of: entity, with: char)
            }
            let lines = html.components(separatedBy: .newlines)
                .map { $0.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            var text = lines.joined(separator: "\n")
            if text.count > 16_000 { text = String(text.prefix(16_000)) + "\n… (truncated)" }
            return text.isEmpty ? "The page loaded but had no readable text" : text
        } catch {
            return "Couldn't load it: \(error.localizedDescription)"
        }
    }
}
