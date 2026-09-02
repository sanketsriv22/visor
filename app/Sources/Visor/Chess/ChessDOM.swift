import AppKit
import Foundation

/// Reads the position straight out of the web page.
///
/// A chess site draws its board from a model, and the model is right there in
/// the DOM: on chess.com every piece is an element whose classes say what it is
/// and where — `piece wp square-54` is a white pawn on e4 — and the move list
/// says how many plies have been played, which is whose turn it is. Lichess is
/// the same idea with different spellings. Reading that is exact, instant, and
/// indifferent to theme, highlight, animation, Space, or which window is in
/// front. Everything the pixel pipeline spent a day being fragile about is a
/// non-question here.
///
/// The pixel pipeline stays for the general case — a board in something that
/// isn't a browser, or a site nobody has mapped. For the sites people actually
/// play on, this is the truth and the pixels are a fallback.
///
/// Goes through AppleScript's JavaScript bridge, which Safari and Chrome both
/// offer and which needs no extension: a one-time toggle in the browser
/// (Safari ▸ Develop ▸ Allow JavaScript from Apple Events) and macOS's
/// Automation permission, which it asks for the first time it runs.
enum ChessDOM {
    struct Reading {
        let position: ChessPosition
        /// True when the user is playing black.
        let flipped: Bool
        let site: String
        /// Plies played per the page's move list; 0 when it couldn't be read,
        /// which on a board that isn't the start position means whose turn it
        /// is has to come from somewhere else.
        let plies: Int
    }

    enum ReadError: LocalizedError {
        case noBrowser
        case scriptFailed(String)
        case noBoard
        var errorDescription: String? {
            switch self {
            case .noBrowser: return "No browser with a chess board is open"
            case .scriptFailed(let why): return "Couldn't read the page — \(why)"
            case .noBoard: return "The page doesn't have a board Visor recognises"
            }
        }
    }

    /// The page-side half. Returns JSON: site, pieces as "wp54"/"bk58" (colour,
    /// kind, file 1–8, rank 1–8), plies played, and whether black is at the
    /// bottom. Written to run on either site and to say which it found.
    private static let script = #"""
    (function(){
      var out={site:'none',pieces:[],plies:0,flipped:false};
      var cb=document.querySelector('wc-chess-board')||document.querySelector('chess-board')||document.querySelector('.board');
      if(cb && cb.querySelector('.piece')){
        out.site='chess.com';
        out.flipped=cb.classList.contains('flipped');
        var ps=cb.querySelectorAll('.piece');
        for(var i=0;i<ps.length;i++){
          var c=ps[i].className.split(' '),p=null,s=null;
          for(var j=0;j<c.length;j++){
            if(/^[wb][pnbrqk]$/.test(c[j]))p=c[j];
            if(/^square-\d\d$/.test(c[j]))s=c[j].slice(7);
          }
          if(p&&s)out.pieces.push(p+s);
        }
        var n=document.querySelectorAll('[data-ply]').length;
        if(!n)n=document.querySelectorAll('.main-line-ply,.move .node').length;
        out.plies=n;
        return JSON.stringify(out);
      }
      var cg=document.querySelector('cg-board');
      if(cg){
        out.site='lichess';
        var wrap=cg.closest('.cg-wrap')||cg.parentElement;
        out.flipped=!!(wrap&&wrap.classList.contains('orientation-black'));
        var r=cg.getBoundingClientRect(),sq=r.width/8;
        var ps=cg.querySelectorAll('piece');
        var roles={pawn:'p',knight:'n',bishop:'b',rook:'r',queen:'q',king:'k'};
        for(var i=0;i<ps.length;i++){
          var cl=ps[i].classList,col=cl.contains('white')?'w':(cl.contains('black')?'b':null),role=null;
          for(var k in roles){if(cl.contains(k))role=roles[k];}
          var m=/translate\(([-\d.]+)px,\s*([-\d.]+)px\)/.exec(ps[i].style.transform||'');
          if(!col||!role||!m)continue;
          var x=Math.round(parseFloat(m[1])/sq),y=Math.round(parseFloat(m[2])/sq);
          var file=out.flipped?7-x:x, rank=out.flipped?y:7-y;
          out.pieces.push(col+role+(file+1)+''+(rank+1));
        }
        out.plies=document.querySelectorAll('kwdb, .tview2 move, l4x kwdb').length;
        return JSON.stringify(out);
      }
      return JSON.stringify(out);
    })()
    """#

    /// Ask each browser that's running, front-most first.
    static func read() async throws -> Reading {
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        var candidates: [(app: String, kind: Browser)] = []
        if running.contains("com.apple.Safari") { candidates.append(("Safari", .safari)) }
        if running.contains("com.google.Chrome") { candidates.append(("Google Chrome", .chrome)) }
        if running.contains("com.brave.Browser") { candidates.append(("Brave Browser", .chrome)) }
        if running.contains("company.thebrowser.Browser") { candidates.append(("Arc", .chrome)) }
        guard !candidates.isEmpty else { throw ReadError.noBrowser }

        var lastError = ""
        for candidate in candidates {
            do {
                let json = try await run(in: candidate.app, kind: candidate.kind)
                if let reading = parse(json) { return reading }
            } catch {
                lastError = error.localizedDescription
                ChessDiagnostics.trace("page: \(candidate.app) — \(lastError)")
            }
        }
        throw lastError.isEmpty ? ReadError.noBoard : ReadError.scriptFailed(lastError)
    }

    private enum Browser { case safari, chrome }

    private static func run(in app: String, kind: Browser) async throws -> String {
        // Every tab of every window, so it's found wherever it is — including
        // a background tab, which is exactly where it goes when you switch to
        // another app to type.
        let js = script.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"")
        let source: String
        switch kind {
        case .safari:
            source = """
            tell application "\(app)"
              repeat with w in windows
                repeat with t in tabs of w
                  try
                    set r to do JavaScript "\(js)" in t
                    if r does not contain "\\"site\\":\\"none\\"" then return r
                  end try
                end repeat
              end repeat
            end tell
            return "{\\"site\\":\\"none\\"}"
            """
        case .chrome:
            source = """
            tell application "\(app)"
              repeat with w in windows
                repeat with t in tabs of w
                  try
                    set r to execute t javascript "\(js)"
                    if r does not contain "\\"site\\":\\"none\\"" then return r
                  end try
                end repeat
              end repeat
            end tell
            return "{\\"site\\":\\"none\\"}"
            """
        }
        // NSAppleScript is main-thread only. Off it, execution can fail with no
        // error at all — which looked like a permission problem for a while.
        // A read is a few tens of milliseconds; the main thread can spare it.
        return try await MainActor.run {
            var error: NSDictionary?
            guard let apple = NSAppleScript(source: source) else {
                throw ReadError.scriptFailed("bad script")
            }
            let result = apple.executeAndReturnError(&error)
            if let error {
                var msg = (error[NSAppleScript.errorMessage] as? String) ?? "\(error)"
                // Safari's own wording for the toggle being off, turned into
                // the instruction rather than left as an error code.
                if msg.lowercased().contains("javascript") && msg.lowercased().contains("apple events") {
                    msg = "turn on Safari ▸ Develop ▸ Allow JavaScript from Apple Events"
                } else if msg.contains("-1743") || msg.lowercased().contains("not permitted") {
                    msg = "allow Visor to control \(app) under Privacy & Security ▸ Automation"
                }
                throw ReadError.scriptFailed(msg)
            }
            return result.stringValue ?? ""
        }
    }

    private static func parse(_ json: String) -> Reading? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let site = obj["site"] as? String, site != "none",
              let pieces = obj["pieces"] as? [String]
        else { return nil }
        let plies = obj["plies"] as? Int ?? 0
        let flipped = obj["flipped"] as? Bool ?? false

        var board = [Piece?](repeating: nil, count: 64)
        for code in pieces {
            let chars = Array(code)
            guard chars.count == 4,
                  let kind = PieceKind(rawValue: chars[1]),
                  let file = chars[2].wholeNumberValue, let rank = chars[3].wholeNumberValue,
                  let square = Square(file: file - 1, rank: rank - 1)
            else { continue }
            board[square.index] = Piece(chars[0] == "w" ? .white : .black, kind)
        }
        guard board.contains(where: { $0 != nil }) else { return nil }

        var position = ChessPosition(board: board,
                                     turn: plies % 2 == 0 ? .white : .black,
                                     castling: [], enPassant: nil,
                                     halfmoveClock: 0, fullmoveNumber: plies / 2 + 1)
        // Castling rights aren't in the piece list. King and rook still at home
        // is the best available guess and beats assuming none.
        var rights: CastlingRights = []
        func at(_ name: String) -> Piece? { Square(name).flatMap { position[$0] } }
        if at("e1") == Piece(.white, .king) {
            if at("h1") == Piece(.white, .rook) { rights.insert(.whiteKing) }
            if at("a1") == Piece(.white, .rook) { rights.insert(.whiteQueen) }
        }
        if at("e8") == Piece(.black, .king) {
            if at("h8") == Piece(.black, .rook) { rights.insert(.blackKing) }
            if at("a8") == Piece(.black, .rook) { rights.insert(.blackQueen) }
        }
        position.castling = rights
        return Reading(position: position, flipped: flipped, site: site, plies: plies)
    }
}
