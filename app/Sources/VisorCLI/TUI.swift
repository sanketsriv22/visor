import Foundation

/// The full-screen terminal client: a transcript, an input line, and the
/// pickers — in the shape people know from terminal agents.
@MainActor
final class TUI {
    private let engine: ChatEngine
    private let term = Terminal.shared

    private var input = ""
    private var cursor = 0                  // index into input, in characters
    /// Lines scrolled up from the bottom of the transcript; 0 follows.
    private var scroll = 0
    private var spinnerFrame = 0
    private var spinner: Timer?
    private var redrawScheduled = false
    private var notice: String?

    /// A modal list.
    private struct Picker {
        let title: String
        let items: [(label: String, detail: String, id: String)]
        var query = ""
        var selected = 0
        let onPick: (String) -> Void
        var filtered: [(label: String, detail: String, id: String)] {
            guard !query.isEmpty else { return items }
            let q = query.lowercased()
            return items.filter { $0.label.lowercased().contains(q) || $0.detail.lowercased().contains(q) }
        }
    }
    private var picker: Picker?

    init(engine: ChatEngine) {
        self.engine = engine
        engine.onChange = { [weak self] in self?.scheduleRedraw() }
    }

    /// Takes the terminal and starts listening; the caller keeps the run
    /// loop going. Returns rather than spinning a loop of its own, so no
    /// nested run loop ever sits inside a task.
    func start() {
        term.enterRaw()
        term.startReading { [weak self] key in self?.handle(key) }
        spinner = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let tui = self else { return }
            Task { @MainActor in
                if tui.engine.isStreaming { tui.spinnerFrame += 1; tui.scheduleRedraw() }
            }
        }
        redraw()
    }

    private func quit() {
        engine.stop()
        term.exitRaw()
        exit(0)
    }

    // MARK: Keys

    private func handle(_ key: Key) {
        if key == .resize { scheduleRedraw(); return }
        notice = nil
        if picker != nil { handlePicker(key); return }
        if let pending = engine.pendingApproval {
            switch key {
            case .char("y"), .char("Y"), .enter: engine.approvePending(always: false)
            case .char("a"), .char("A"): engine.approvePending(always: true)
            case .char("n"), .char("N"), .escape: engine.denyPending()
            case .ctrl("c"): quit()
            default: _ = pending
            }
            scheduleRedraw(); return
        }
        switch key {
        case .ctrl("c"):
            if engine.isStreaming { engine.stop() } else { quit() }
        case .ctrl("d"): if input.isEmpty { quit() }
        case .escape: if engine.isStreaming { engine.stop() } else { input = ""; cursor = 0 }
        case .enter: submit()
        case .backspace:
            if cursor > 0 { input.remove(at: input.index(input.startIndex, offsetBy: cursor - 1)); cursor -= 1 }
        case .delete:
            if cursor < input.count { input.remove(at: input.index(input.startIndex, offsetBy: cursor)) }
        case .left: cursor = max(0, cursor - 1)
        case .right: cursor = min(input.count, cursor + 1)
        case .home, .ctrl("a"): cursor = 0
        case .end, .ctrl("e"): cursor = input.count
        case .ctrl("u"): input = String(input.suffix(input.count - cursor)); cursor = 0
        case .ctrl("w"):
            let head = String(input.prefix(cursor)).replacingOccurrences(of: "\\s*\\S+\\s*$", with: "", options: .regularExpression)
            input = head + String(input.suffix(input.count - cursor)); cursor = head.count
        case .ctrl("k"): input = String(input.prefix(cursor))
        case .ctrl("l"): scroll = 0
        case .ctrl("n"): engine.newChat(); scroll = 0
        case .up, .pageUp: scroll += key == .up ? 1 : 10
        case .down, .pageDown: scroll = max(0, scroll - (key == .down ? 1 : 10))
        case .tab: break
        case .char(let c):
            input.insert(c, at: input.index(input.startIndex, offsetBy: cursor)); cursor += 1
        case .ctrl, .resize: break
        }
        scheduleRedraw()
    }

    private func submit() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""; cursor = 0; scroll = 0
        if text.hasPrefix("/") { command(text); return }
        engine.send(text)
    }

    private func command(_ line: String) {
        let parts = line.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
        let name = parts.first ?? ""
        let arg = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        switch name {
        case "new", "clear": engine.newChat()
        case "quit", "exit", "q": quit()
        case "agent", "agents":
            if !arg.isEmpty, let a = engine.agents.first(where: { $0.name.lowercased() == arg.lowercased() }) {
                engine.use(a)
            } else {
                let items: [(label: String, detail: String, id: String)] = engine.agents.map { a in
                    let detail: String = a.isChat ? (a.model ?? ChatEngine.defaultModel) : a.command
                    return (label: a.name, detail: detail, id: a.name)
                }
                picker = Picker(title: "Agents", items: items) { [weak self] id in
                    guard let self, let a = self.engine.agents.first(where: { $0.name == id }) else { return }
                    self.engine.use(a)
                }
            }
        case "model", "models":
            guard let agent = engine.agent, agent.isChat else { notice = "Only hosted agents pick a model here; CLI agents own theirs."; return }
            if !arg.isEmpty { engine.useModel(arg); return }
            var items: [(label: String, detail: String, id: String)] = (agent.favouriteModels ?? []).map { (label: $0, detail: "favourite", id: $0) }
            if let current = agent.model, !items.contains(where: { $0.id == current }) { items.insert((label: current, detail: "current", id: current), at: 0) }
            picker = Picker(title: "Models — type to filter, or /model <id>", items: items) { [weak self] id in self?.engine.useModel(id) }
            Task { [weak self] in
                guard let models = try? await OpenRouterClient().models() else { return }
                await MainActor.run {
                    guard let self, var p = self.picker, p.title.hasPrefix("Models") else { return }
                    let known = Set(p.items.map(\.id))
                    let more: [(label: String, detail: String, id: String)] = models.filter { !known.contains($0.id) }.map { (label: $0.id, detail: $0.name ?? "", id: $0.id) }
                    p = Picker(title: p.title, items: p.items + more, query: p.query, selected: p.selected, onPick: p.onPick)
                    self.picker = p
                    self.scheduleRedraw()
                }
            }
        case "sessions", "chats", "history":
            let items: [(label: String, detail: String, id: String)] = engine.store.summaries.prefix(60).map { s in
                (label: s.title.isEmpty ? "Untitled" : s.title, detail: "\(s.agentName) · \(s.messageCount) turns", id: s.id.uuidString)
            }
            picker = Picker(title: "Chats", items: items) { [weak self] id in
                if let uuid = UUID(uuidString: id) { self?.engine.open(uuid); self?.scroll = 0 }
            }
        case "help", "?":
            notice = "/new  /agent [name]  /model [id]  /sessions  /quit   —   esc stops a reply · ↑↓ scroll · ctrl+n new chat"
        default:
            notice = "Unknown command /\(name). Try /help."
        }
    }

    private func handlePicker(_ key: Key) {
        guard var p = picker else { return }
        switch key {
        case .escape, .ctrl("c"): picker = nil
        case .enter:
            let rows = p.filtered
            if rows.indices.contains(p.selected) { picker = nil; p.onPick(rows[p.selected].id) } else { picker = nil }
        case .up: p.selected = max(0, p.selected - 1); picker = p
        case .down: p.selected = min(max(0, p.filtered.count - 1), p.selected + 1); picker = p
        case .backspace: if !p.query.isEmpty { p.query.removeLast(); p.selected = 0 }; picker = p
        case .char(let c): p.query.append(c); p.selected = 0; picker = p
        default: break
        }
        scheduleRedraw()
    }

    // MARK: Drawing

    private func scheduleRedraw() {
        guard !redrawScheduled else { return }
        redrawScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            self?.redrawScheduled = false
            self?.redraw()
        }
    }

    private func redraw() {
        let (cols, rows) = term.size
        var out = ""
        let inner = cols - 2

        // Header.
        let agentName = engine.agent?.name ?? "no agent"
        let title = engine.conversation.title.isEmpty ? "new chat" : engine.conversation.title
        var status = ""
        if engine.isStreaming { status = "\(["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"][spinnerFrame % 10]) thinking" }
        if engine.pendingApproval != nil { status = "waiting for you" }
        var header = Styled()
        header.add("╭─ ", Ink.frame)
        header.add("Visor", Ink.accent + ANSI.bold)
        header.add(" · \(agentName) · \(engine.modelName) · \(title)", "")
        let statusStyled = Styled.plain(status, Ink.accent)
        let pad = max(1, cols - header.width - statusStyled.width - 3)
        header.add(" " + String(repeating: "─", count: pad), Ink.frame)
        header.runs += statusStyled.runs
        header.add(" ╮", Ink.frame)
        out += ANSI.at(1, 1) + header.prefix(cols).render() + ANSI.clearLine

        // Input block: prompt line(s) and hint.
        let promptLines = Markdown.hardWrap(input.isEmpty ? "" : input, inner - 4)
        let inputRows = max(1, min(4, promptLines.count))
        let transcriptRows = rows - 2 - inputRows - 2
        let all = transcriptLines(width: inner - 2)
        let maxScroll = max(0, all.count - transcriptRows)
        if scroll > maxScroll { scroll = maxScroll }
        let start = max(0, all.count - transcriptRows - scroll)
        let visible = Array(all[start..<min(all.count, start + transcriptRows)])
        for r in 0..<transcriptRows {
            let line = r < visible.count ? visible[r] : Styled()
            out += ANSI.at(2 + r, 1) + Styled.plain("│ ", Ink.frame).render() + line.prefix(inner - 2).render() + ANSI.clearLine
        }
        // Separator, with a scroll marker when not at the bottom.
        let sep = scroll > 0 ? "├─ ↓ \(scroll) more \(String(repeating: "─", count: max(0, inner - 12)))" : "├" + String(repeating: "─", count: inner)
        out += ANSI.at(2 + transcriptRows, 1) + Styled.plain(String(sep.prefix(cols - 1)) + "┤", Ink.frame).render() + ANSI.clearLine

        // Input.
        let firstInputRow = 3 + transcriptRows
        if let pending = engine.pendingApproval {
            let call = pending.needing[0]
            let what = call.name == "run_shell" ? (call.decodedArguments["command"] as? String ?? "") : call.arguments
            var line = Styled()
            line.add("│ ", Ink.frame); line.add("? ", Ink.tool + ANSI.bold)
            line.add("\(call.name) wants to run: ", Ink.tool); line.add(what, ANSI.bold)
            out += ANSI.at(firstInputRow, 1) + line.prefix(cols).render() + ANSI.clearLine
            var keys = Styled(); keys.add("│   ", Ink.frame)
            keys.add("[y] allow  [a] always allow  [n] deny", Ink.accent)
            for r in 1..<inputRows { out += ANSI.at(firstInputRow + r, 1) + (r == 1 ? keys.render() : "") + ANSI.clearLine }
            if inputRows == 1 { out += "" }
        } else {
            for r in 0..<inputRows {
                var line = Styled()
                line.add("│ ", Ink.frame)
                line.add(r == 0 ? "› " : "  ", Ink.accent + ANSI.bold)
                if r < promptLines.count { line.add(promptLines[r]) }
                else if r == 0, input.isEmpty { line.add(engine.isStreaming ? "esc to stop" : "Ask \(agentName)…", Ink.faint) }
                out += ANSI.at(firstInputRow + r, 1) + line.prefix(cols).render() + ANSI.clearLine
            }
        }
        // Footer.
        var foot = Styled()
        foot.add("╰─ ", Ink.frame)
        if let notice { foot.add(notice, engine.error == nil ? Ink.accent : Ink.bad) }
        else if let error = engine.error { foot.add("✖ " + error, Ink.bad) }
        else { foot.add("enter send · esc stop · / commands · ctrl+n new · ctrl+c quit · \(engine.workDir.lastPathComponent)", Ink.faint) }
        let footPad = max(0, cols - foot.width - 2)
        foot.add(" " + String(repeating: "─", count: footPad) + "╯", Ink.frame)
        out += ANSI.at(rows, 1) + foot.prefix(cols).render() + ANSI.clearLine

        // Picker overlay.
        if let p = picker {
            let w = min(cols - 6, 72), h = min(rows - 4, 18)
            let x = (cols - w) / 2 + 1, y = (rows - h) / 2 + 1
            let rowsList = p.filtered
            out += ANSI.at(y, x) + Styled.plain("╭─ \(p.title) " + String(repeating: "─", count: max(0, w - p.title.count - 5)) + "╮", Ink.accent).render()
            out += ANSI.at(y + 1, x) + Styled.plain("│ › \(p.query)" + String(repeating: " ", count: max(0, w - 5 - p.query.count)) + "│", Ink.accent).render()
            let first = max(0, min(p.selected - (h - 4) / 2, rowsList.count - (h - 3)))
            for i in 0..<(h - 3) {
                let idx = first + i
                var line = Styled(); line.add("│ ", Ink.accent)
                if rowsList.indices.contains(idx) {
                    let item = rowsList[idx]
                    let sel = idx == p.selected
                    let label = String(item.label.prefix(w - 4))
                    let detail = String(item.detail.prefix(max(0, w - 6 - label.count)))
                    line.add((sel ? "▸ " : "  ") + label, sel ? ANSI.bold + Ink.accent : "")
                    line.add(String(repeating: " ", count: max(1, w - 6 - label.count - detail.count)) + detail, Ink.faint)
                } else { line.add(String(repeating: " ", count: w - 3)) }
                out += ANSI.at(y + 2 + i, x) + line.prefix(w - 1).render() + Styled.plain("│", Ink.accent).render()
            }
            out += ANSI.at(y + h - 1, x) + Styled.plain("╰" + String(repeating: "─", count: w - 2) + "╯", Ink.accent).render()
        }

        // Cursor.
        if picker == nil, engine.pendingApproval == nil {
            let col = 5 + (cursor % max(1, inner - 4))
            let row = firstInputRow + min(inputRows - 1, cursor / max(1, inner - 4))
            out += ANSI.at(row, col) + "\u{1b}[?25h"
        } else {
            out += "\u{1b}[?25l"
        }
        term.write(out)
    }

    /// The transcript as styled, wrapped lines.
    private func transcriptLines(width: Int) -> [Styled] {
        var out: [Styled] = []
        let messages = engine.conversation.messages
        if messages.isEmpty {
            out.append(Styled())
            out.append(.plain("  Visor", Ink.accent + ANSI.bold))
            out.append(.plain("  Talk to \(engine.agent?.name ?? "an agent") in \(engine.workDir.path).", Ink.faint))
            out.append(Styled())
            out.append(.plain("  /agent to switch agents · /model to pick a model · /sessions for past chats · /help", Ink.faint))
            if let agent = engine.agent, let why = Agents.blocker(for: agent) { out.append(Styled()); out.append(.plain("  ✖ " + why, Ink.bad)) }
            return out
        }
        let callsByID = Dictionary(uniqueKeysWithValues: messages.flatMap { $0.toolCalls ?? [] }.map { ($0.id, $0) })
        for (index, message) in messages.enumerated() {
            switch message.role {
            case .user:
                out.append(Styled())
                for line in Markdown.wrap(message.content, width: width - 2) {
                    var s = Styled(); s.add("┃ ", Ink.user); s.add(line, ANSI.bold); out.append(s)
                }
                out.append(Styled())
            case .assistant:
                let streaming = engine.isStreaming && index == messages.count - 1
                if !message.content.isEmpty {
                    var lines = Markdown.lines(message.content, width: width)
                    if streaming, var last = lines.popLast() { last.add("▍", Ink.accent); lines.append(last) }
                    out += lines
                } else if streaming {
                    out.append(.plain("▍", Ink.accent))
                }
                for call in message.toolCalls ?? [] {
                    var s = Styled(); s.add("⚙ ", Ink.tool); s.add(call.name, Ink.tool + ANSI.bold)
                    let what = call.name == "run_shell" ? (call.decodedArguments["command"] as? String ?? "") : call.arguments
                    s.add("  " + what.replacingOccurrences(of: "\n", with: " "), Ink.faint)
                    out.append(s.prefix(width))
                }
            case .tool:
                let name = message.toolCallID.flatMap { callsByID[$0]?.name } ?? "tool"
                let lines = message.content.components(separatedBy: "\n")
                let shown = lines.prefix(8)
                for line in shown { out.append(.plain("    " + String(line.prefix(width - 4)), Ink.faint)) }
                if lines.count > shown.count { out.append(.plain("    … \(lines.count - shown.count) more lines from \(name)", Ink.faint)) }
            case .system: break
            }
        }
        if engine.pendingApproval == nil, !engine.isStreaming, let error = engine.error {
            out.append(.plain("✖ " + error, Ink.bad))
        }
        return out
    }
}
