import Foundation

// visor — Visor's agents in the terminal.
//
//   visor                         the full-screen client, in this folder
//   visor run "prompt" [-a NAME]  one turn, streamed to stdout (--yes skips approvals)
//   visor agents                  the agents Visor knows
//   visor sessions                recent chats

let arguments = Array(CommandLine.arguments.dropFirst())

func printAgents() {
    let loaded = Agents.load()
    if loaded.agents.isEmpty { print("No agents. Add one in Visor → Settings → Agents."); return }
    for a in loaded.agents {
        let mark = a.name == loaded.defaultName ? "*" : " "
        let how = a.isChat ? "openrouter · \(a.model ?? ChatEngine.defaultModel)" : "cli · \(a.command)"
        let blocked = Agents.blocker(for: a).map { "  (\($0))" } ?? ""
        print("\(mark) \(a.name)  —  \(how)\(blocked)")
    }
}

func printSessions() {
    let store = ChatStore()
    if store.summaries.isEmpty { print("No chats yet."); return }
    let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short
    for s in store.summaries.prefix(30) {
        print("\(f.string(from: s.updatedAt))  \(s.title.isEmpty ? "Untitled" : s.title)  —  \(s.agentName), \(s.messageCount) turns")
    }
}

/// One turn, streamed to stdout. Resolves with the exit code once the
/// reply (and any tool rounds) are done.
@MainActor
func runOnce(prompt: String, agentName: String?, autoApprove: Bool) async -> Int32 {
    let engine = ChatEngine()
    if let agentName {
        guard let a = engine.agents.first(where: { $0.name.lowercased() == agentName.lowercased() }) else {
            FileHandle.standardError.write("No agent named \(agentName).\n".data(using: .utf8)!); return 2
        }
        engine.use(a)
    }
    var printed = 0
    var finished = false
    return await withCheckedContinuation { (done: CheckedContinuation<Int32, Never>) in
        engine.onChange = {
            guard !finished else { return }
            if let last = engine.conversation.messages.last, last.role == .assistant {
                let text = last.content
                if text.count > printed {
                    FileHandle.standardOutput.write(String(text.dropFirst(printed)).data(using: .utf8)!)
                    printed = text.count
                }
            } else if engine.conversation.messages.last?.role == .tool {
                printed = 0
            }
            if let pending = engine.pendingApproval {
                let call = pending.needing[0]
                let what = call.name == "run_shell" ? (call.decodedArguments["command"] as? String ?? "") : call.arguments
                if autoApprove {
                    FileHandle.standardError.write("\n[\(call.name)] \(what)\n".data(using: .utf8)!)
                    engine.approvePending(always: true)
                } else {
                    FileHandle.standardError.write("\n[\(call.name)] \(what)\nAllow? [y/N] ".data(using: .utf8)!)
                    let answer = readLine()?.lowercased() ?? "n"
                    if answer.hasPrefix("y") { engine.approvePending(always: false) } else { engine.denyPending() }
                }
                return
            }
            if let error = engine.error, !engine.isStreaming {
                finished = true
                FileHandle.standardError.write("\n✖ \(error)\n".data(using: .utf8)!)
                done.resume(returning: 1)
            } else if !engine.isStreaming, printed > 0 {
                finished = true
                FileHandle.standardOutput.write("\n".data(using: .utf8)!)
                done.resume(returning: 0)
            }
        }
        engine.send(prompt)
    }
}

switch arguments.first {
case "agents": printAgents()
case "sessions", "chats": printSessions()
case "--version", "-v": print("visor \(AppInfoCLI.version)")
case "--help", "-h", "help":
    print("""
    visor — Visor's agents in the terminal

      visor                          full-screen client, in the current folder
      visor run "prompt" [-a NAME]   one turn, streamed to stdout (--yes: run tools without asking)
      visor agents                   the agents Visor knows
      visor sessions                 recent chats

    Inside: /agent /model /sessions /new /quit · esc stops a reply · ↑↓ scroll
    """)
case "run":
    var rest = Array(arguments.dropFirst())
    var agentName: String?
    var yes = false
    if let i = rest.firstIndex(where: { $0 == "-a" || $0 == "--agent" }), i + 1 < rest.count {
        agentName = rest[i + 1]; rest.removeSubrange(i...(i + 1))
    }
    if let i = rest.firstIndex(of: "--yes") { yes = true; rest.remove(at: i) }
    let prompt = rest.joined(separator: " ")
    if prompt.isEmpty { FileHandle.standardError.write("usage: visor run \"prompt\" [-a agent] [--yes]\n".data(using: .utf8)!); exit(2) }
    let chosenAgent = agentName, approveAll = yes
    Task { @MainActor in
        exit(await runOnce(prompt: prompt, agentName: chosenAgent, autoApprove: approveAll))
    }
    RunLoop.main.run()
default:
    guard Terminal.shared.isTTY else {
        FileHandle.standardError.write("visor needs a terminal; use `visor run \"prompt\"` for pipes.\n".data(using: .utf8)!); exit(2)
    }
    Task { @MainActor in
        TUIHolder.client = TUI(engine: ChatEngine())
        TUIHolder.client?.start()
    }
    RunLoop.main.run()
}

/// Held for the process lifetime.
@MainActor
enum TUIHolder {
    static var client: TUI?
}

enum AppInfoCLI {
    static let version = "1.0-beta.36"
}
