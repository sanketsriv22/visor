import Foundation

/// A line of terminal text: plain characters with styling runs, so width is
/// counted on the text and the escapes are added at the end.
struct Styled {
    var runs: [(text: String, style: String)] = []
    var width: Int { runs.reduce(0) { $0 + $1.text.count } }
    mutating func add(_ text: String, _ style: String = "") {
        guard !text.isEmpty else { return }
        runs.append((text, style))
    }
    func render() -> String {
        runs.map { $0.style.isEmpty ? $0.text : $0.style + $0.text + ANSI.reset }.joined()
    }
    /// The first `width` cells.
    func prefix(_ width: Int) -> Styled {
        var out = Styled(); var left = width
        for run in runs where left > 0 {
            let take = String(run.text.prefix(left))
            out.add(take, run.style); left -= take.count
        }
        return out
    }
    static func plain(_ text: String, _ style: String = "") -> Styled {
        var s = Styled(); s.add(text, style); return s
    }
}

/// Markdown, the terminal's share of it: fences, headings, bullets, quotes,
/// bold and inline code. Everything else is left as written.
enum Markdown {
    /// Wrap `text` to `width`, styled, with a base style for every run.
    static func lines(_ text: String, width: Int, base: String = "") -> [Styled] {
        var out: [Styled] = []
        var inFence = false
        for raw in text.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\t", with: "    ")
            if line.hasPrefix("```") {
                inFence.toggle()
                let lang = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                out.append(.plain(inFence ? "  ╭─ \(lang.isEmpty ? "code" : lang)" : "  ╰─", Ink.frame))
                continue
            }
            if inFence {
                for piece in hardWrap("  │ " + line, width) { out.append(.plain(piece, ANSI.fg(250))) }
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { out.append(Styled()); continue }
            var content = line
            var style = base
            var indent = ""
            if let m = content.range(of: "^#{1,6} ", options: .regularExpression) {
                content = String(content[m.upperBound...]); style = ANSI.bold + base
            } else if let m = content.range(of: "^\\s*[-*•] ", options: .regularExpression) {
                let lead = content[content.startIndex..<m.lowerBound].count
                indent = String(repeating: " ", count: lead) + "  "
                content = String(repeating: " ", count: lead) + "• " + String(content[m.upperBound...])
            } else if let m = content.range(of: "^\\s*\\d+\\. ", options: .regularExpression) {
                let lead = content.distance(from: content.startIndex, to: m.lowerBound)
                indent = String(repeating: " ", count: content.distance(from: m.lowerBound, to: m.upperBound) + lead)
            } else if content.hasPrefix("> ") {
                content = "▎ " + content.dropFirst(2); style = ANSI.italic + base
            }
            for (i, piece) in wrap(content, width: width, indent: indent).enumerated() {
                out.append(inline(i == 0 ? piece : piece, style: style))
            }
        }
        return out
    }

    /// Word-wrap; continuation lines get `indent`.
    static func wrap(_ text: String, width: Int, indent: String = "") -> [String] {
        guard width > 4 else { return [text] }
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
            let candidate = current.isEmpty ? word : current + " " + word
            if candidate.count <= width {
                current = candidate
            } else {
                if !current.isEmpty { lines.append(current) }
                if word.count > width {
                    for piece in hardWrap(word, width) { lines.append(piece) }
                    current = lines.removeLast()
                } else {
                    current = indent + word
                }
            }
        }
        lines.append(current)
        return lines
    }

    static func hardWrap(_ text: String, _ width: Int) -> [String] {
        guard width > 0, text.count > width else { return [text] }
        var out: [String] = []; var rest = Substring(text)
        while !rest.isEmpty { out.append(String(rest.prefix(width))); rest = rest.dropFirst(width) }
        return out
    }

    /// `**bold**` and `` `code` `` inside one line.
    static func inline(_ text: String, style: String) -> Styled {
        var out = Styled()
        var buffer = ""
        var i = text.startIndex
        var bold = false, code = false
        func flush() { out.add(buffer, (code ? ANSI.reverse : "") + (bold ? ANSI.bold : "") + style); buffer = "" }
        while i < text.endIndex {
            if !code, text[i...].hasPrefix("**") {
                flush(); bold.toggle(); i = text.index(i, offsetBy: 2); continue
            }
            if text[i] == "`" {
                flush(); code.toggle(); i = text.index(after: i); continue
            }
            buffer.append(text[i]); i = text.index(after: i)
        }
        flush()
        return out
    }
}
