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
        /// Plies played per the page's move list; 0 when it couldn't be read.
        let plies: Int
        /// The squares of the last move, if the page highlights them. The one
        /// that still holds a piece is the destination, and that piece's colour
        /// is who just moved — the surest whose-turn signal the page gives.
        let lastMove: [Square]
        /// The board's rectangle on screen, in points, read from the element
        /// itself — so a browser board needs no pixel search for its geometry
        /// and works the same on any site or theme.
        let boardRect: CGRect?
        /// Our own remaining time in seconds, if the page shows a clock. Lets
        /// the pacing speed up as the flag approaches, the way a person blitzes
        /// when low. nil for an untimed game or a clock we can't read.
        let clockSeconds: Double?
        /// The opponent's remaining time, read from the top clock. Lets the
        /// pacing spend the clock lead it has: when we're well ahead, the hard
        /// moves can take a little longer. nil when there's no clock to read.
        let opponentSeconds: Double?
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
      var out={site:'none',pieces:[],plies:0,flipped:false,highlights:[],board:null,clock:null,oppClock:null};
      function clockSeconds(sel){
        var el=document.querySelector(sel); if(!el) return null;
        var t=(el.textContent||'').trim();
        var m=/(\d+):(\d+)(?:\.(\d+))?/.exec(t);
        if(m) return parseInt(m[1])*60+parseInt(m[2])+(m[3]?parseFloat('0.'+m[3]):0);
        var s=/^(\d+(?:\.\d+)?)$/.exec(t); return s?parseFloat(s[1]):null;
      }
      function screenRect(el){
        var r=el.getBoundingClientRect();
        var chrome=window.outerHeight-window.innerHeight;
        return {x:window.screenX+r.left, y:window.screenY+chrome+r.top,
                w:r.width, h:r.height};
      }
      var cb=document.querySelector('wc-chess-board')||document.querySelector('chess-board')||document.querySelector('.board');
      if(cb && cb.querySelector('.piece')){
        out.site='chess.com';
        out.board=screenRect(cb);
        out.clock=clockSeconds('.clock-bottom, [class*="clock-bottom"]');
        out.oppClock=clockSeconds('.clock-top, [class*="clock-top"]');
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
        // Last move: the two highlighted squares. The one still holding a
        // piece is where the mover landed. Robust to how the move list is
        // marked up, which varies.
        var hs=cb.querySelectorAll('.highlight,[class*="highlight"]');
        for(var h=0;h<hs.length;h++){
          var hc=hs[h].className.split(' ');
          for(var k=0;k<hc.length;k++){ if(/^square-\d\d$/.test(hc[k])) out.highlights.push(hc[k].slice(7)); }
        }
        var n=document.querySelectorAll('[data-ply]').length;
        if(!n)n=document.querySelectorAll('.node[data-node], .main-line-ply, .move .node, vertical-move-list .node').length;
        out.plies=n;
        return JSON.stringify(out);
      }
      var cg=document.querySelector('cg-board');
      if(cg){
        out.site='lichess';
        out.board=screenRect((cg.closest('cg-container')||cg.closest('.cg-wrap')||cg));
        out.clock=clockSeconds('.rclock-bottom .time, .rclock-bottom time');
        out.oppClock=clockSeconds('.rclock-top .time, .rclock-top time');
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
        var lm=document.querySelectorAll('.last-move, square.last-move');
        for(var h=0;h<lm.length;h++){
          var st=lm[h].style.transform||'', mm=/translate\(([-\d.]+)px,\s*([-\d.]+)px\)/.exec(st);
          if(mm){ var hx=Math.round(parseFloat(mm[1])/sq), hy=Math.round(parseFloat(mm[2])/sq);
            var hf=out.flipped?7-hx:hx, hr=out.flipped?hy:7-hy; out.highlights.push(''+(hf+1)+(hr+1)); }
        }
        out.plies=document.querySelectorAll('kwdb, .tview2 move, l4x kwdb').length;
        return JSON.stringify(out);
      }
      return JSON.stringify(out);
    })()
    """#

    /// Read the board on the tab the user is actually looking at.
    ///
    /// The frontmost browser's front window's active tab, and only that — not
    /// every tab of every window. Reading all of them returned whichever board
    /// came first in the list, which meant a chess.com game left open in a
    /// background tab got played while the user was on Lichess in front, its
    /// moves dragged onto wherever the visible board happened to be. The board
    /// you play is the board you see.
    static func read() async throws -> Reading {
        let running = NSWorkspace.shared.runningApplications
        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let known: [(bundle: String, app: String, kind: Browser)] = [
            ("com.apple.Safari", "Safari", .safari),
            ("com.google.Chrome", "Google Chrome", .chrome),
            ("com.brave.Browser", "Brave Browser", .chrome),
            ("company.thebrowser.Browser", "Arc", .chrome),
        ]
        let live = Set(running.compactMap(\.bundleIdentifier))
        var candidates = known.filter { live.contains($0.bundle) }
        // Whichever browser is in front gets asked first.
        if let front = frontBundle, let i = candidates.firstIndex(where: { $0.bundle == front }), i != 0 {
            candidates.swapAt(0, i)
        }
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
        // The active tab of the front window only — the board the user is
        // looking at, never a background tab.
        let js = script.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"")
        let source: String
        switch kind {
        case .safari:
            source = """
            tell application "\(app)"
              try
                return do JavaScript "\(js)" in current tab of front window
              end try
            end tell
            return "{\\"site\\":\\"none\\"}"
            """
        case .chrome:
            source = """
            tell application "\(app)"
              try
                return execute (active tab of front window) javascript "\(js)"
              end try
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
        let lastMove = (obj["highlights"] as? [String] ?? []).compactMap { code -> Square? in
            guard code.count == 2, let f = code.first?.wholeNumberValue, let r = code.last?.wholeNumberValue
            else { return nil }
            return Square(file: f - 1, rank: r - 1)
        }
        var boardRect: CGRect?
        if let b = obj["board"] as? [String: Any],
           let x = b["x"] as? Double, let y = b["y"] as? Double,
           let w = b["w"] as? Double, let h = b["h"] as? Double, w > 40, h > 40 {
            let side = min(w, h)
            boardRect = CGRect(x: x + (w - side) / 2, y: y + (h - side) / 2, width: side, height: side)
        }

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
        let clock = obj["clock"] as? Double
        let oppClock = obj["oppClock"] as? Double
        return Reading(position: position, flipped: flipped, site: site,
                       plies: plies, lastMove: lastMove, boardRect: boardRect,
                       clockSeconds: (clock ?? 0) > 0 ? clock : nil,
                       opponentSeconds: (oppClock ?? 0) > 0 ? oppClock : nil)
    }
}
