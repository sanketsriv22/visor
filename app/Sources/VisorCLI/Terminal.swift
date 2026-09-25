import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A key, as the terminal reports it.
enum Key: Equatable {
    case char(Character)
    case enter, backspace, delete, tab, escape
    case up, down, left, right, home, end, pageUp, pageDown
    /// Control-letter, as the lowercase letter.
    case ctrl(Character)
    case resize
}

/// Raw-mode terminal I/O: bytes in, escape sequences out.
final class Terminal {
    static let shared = Terminal()
    private var original = termios()
    private(set) var raw = false
    private var reader: Thread?
    private var winch: DispatchSourceSignal?

    var isTTY: Bool { isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1 }

    var size: (cols: Int, rows: Int) {
        var w = winsize()
        _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &w)
        return (max(40, Int(w.ws_col)), max(8, Int(w.ws_row)))
    }

    func enterRaw() {
        guard !raw, isTTY else { return }
        tcgetattr(STDIN_FILENO, &original)
        var t = original
        t.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG | IEXTEN)
        t.c_iflag &= ~tcflag_t(IXON | ICRNL | BRKINT | INPCK | ISTRIP)
        t.c_oflag &= ~tcflag_t(OPOST)
        withUnsafeMutablePointer(to: &t.c_cc) { cc in
            cc.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { p in
                p[Int(VMIN)] = 1
                p[Int(VTIME)] = 0
            }
        }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &t)
        raw = true
        write("\u{1b}[?1049h\u{1b}[?25l\u{1b}[2J")
    }

    func exitRaw() {
        guard raw else { return }
        write("\u{1b}[?25h\u{1b}[?1049l")
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        raw = false
    }

    func write(_ s: String) {
        let bytes = Array(s.utf8)
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBufferPointer { buf -> Int in
                #if canImport(Darwin)
                return Darwin.write(STDOUT_FILENO, buf.baseAddress, buf.count)
                #else
                return Glibc.write(STDOUT_FILENO, buf.baseAddress, buf.count)
                #endif
            }
            if n <= 0 { break }
            offset += n
        }
    }

    /// Keys arrive on the main queue.
    func startReading(_ handler: @escaping (Key) -> Void) {
        signal(SIGWINCH, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        source.setEventHandler { handler(.resize) }
        source.resume()
        winch = source
        let thread = Thread { [weak self] in
            while let self, self.raw {
                guard let key = self.readKey() else { continue }
                DispatchQueue.main.async { handler(key) }
            }
        }
        thread.name = "visor.keys"
        thread.start()
        reader = thread
    }

    private func readByte(timeoutMs: Int32 = -1) -> UInt8? {
        if timeoutMs >= 0 {
            var fd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            guard poll(&fd, 1, timeoutMs) > 0 else { return nil }
        }
        var b: UInt8 = 0
        return read(STDIN_FILENO, &b, 1) == 1 ? b : nil
    }

    private func readKey() -> Key? {
        guard let b = readByte() else { return nil }
        switch b {
        case 0x0d, 0x0a: return .enter
        case 0x7f, 0x08: return .backspace
        case 0x09: return .tab
        case 0x1b:
            // Alone: Escape. Followed within a beat: a sequence.
            guard let b1 = readByte(timeoutMs: 30) else { return .escape }
            if b1 == UInt8(ascii: "[") || b1 == UInt8(ascii: "O") {
                var params = ""
                while let c = readByte(timeoutMs: 30) {
                    let ch = Character(UnicodeScalar(c))
                    if ch.isLetter || ch == "~" {
                        switch (params, ch) {
                        case ("", "A"): return .up
                        case ("", "B"): return .down
                        case ("", "C"): return .right
                        case ("", "D"): return .left
                        case ("", "H"), ("1", "~"), ("7", "~"): return .home
                        case ("", "F"), ("4", "~"), ("8", "~"): return .end
                        case ("5", "~"): return .pageUp
                        case ("6", "~"): return .pageDown
                        case ("3", "~"): return .delete
                        default: return nil
                        }
                    }
                    params.append(ch)
                }
                return nil
            }
            return .escape
        case 0x01...0x1a:
            return .ctrl(Character(UnicodeScalar(b + 0x60)))
        default:
            // UTF-8: the lead byte says how many follow.
            var bytes = [b]
            let extra = b >= 0xf0 ? 3 : b >= 0xe0 ? 2 : b >= 0xc0 ? 1 : 0
            for _ in 0..<extra { if let c = readByte(timeoutMs: 30) { bytes.append(c) } }
            guard let s = String(bytes: bytes, encoding: .utf8), let ch = s.first else { return nil }
            return .char(ch)
        }
    }
}

/// Escape sequences, named.
enum ANSI {
    static let reset = "\u{1b}[0m"
    static let bold = "\u{1b}[1m"
    static let dim = "\u{1b}[2m"
    static let italic = "\u{1b}[3m"
    static let reverse = "\u{1b}[7m"
    static func fg(_ n: Int) -> String { "\u{1b}[38;5;\(n)m" }
    static func bg(_ n: Int) -> String { "\u{1b}[48;5;\(n)m" }
    static func at(_ row: Int, _ col: Int) -> String { "\u{1b}[\(row);\(col)H" }
    static let clearLine = "\u{1b}[K"
}

/// The palette: Visor's purple, and a few roles.
enum Ink {
    static let accent = ANSI.fg(141)
    static let user = ANSI.fg(75)
    static let tool = ANSI.fg(179)
    static let bad = ANSI.fg(203)
    static let good = ANSI.fg(114)
    static let faint = ANSI.dim
    static let frame = ANSI.fg(240)
}
