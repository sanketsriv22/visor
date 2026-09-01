import Foundation

/// The vocabulary: squares, pieces, moves, and a position that can produce a
/// FEN.
///
/// Deliberately not a chess library. There is no move generator here and there
/// isn't going to be one — Stockfish is already a correct one, it's already a
/// subprocess, and `go perft 1` makes it list the legal moves for any position
/// for free. Writing a second generator would mean owning every en-passant and
/// castling edge case twice, and being wrong in only one of them is the kind of
/// bug that looks like a vision failure for a day and a half.
///
/// What *is* here is the smallest thing the pixels need: somewhere to record
/// what's on the board, and a FEN to hand the engine.

/// 0 is a1, 63 is h8. The engine's own ordering, so nothing is translated on
/// the way out.
struct Square: Hashable, CustomStringConvertible {
    let index: Int

    var file: Int { index % 8 }     // 0 = a
    var rank: Int { index / 8 }     // 0 = rank 1

    init?(index: Int) {
        guard (0..<64).contains(index) else { return nil }
        self.index = index
    }

    init?(file: Int, rank: Int) {
        guard (0..<8).contains(file), (0..<8).contains(rank) else { return nil }
        self.index = rank * 8 + file
    }

    init?(_ name: String) {
        let chars = Array(name.lowercased())
        guard chars.count == 2,
              let f = chars[0].asciiValue, let r = chars[1].wholeNumberValue,
              (97...104).contains(Int(f))
        else { return nil }
        self.init(file: Int(f) - 97, rank: r - 1)
    }

    var name: String {
        String(UnicodeScalar(UInt8(97 + file))) + String(rank + 1)
    }
    var description: String { name }
}

enum PieceColor: Hashable {
    case white, black
    var opposite: PieceColor { self == .white ? .black : .white }
}

enum PieceKind: Character, Hashable, CaseIterable {
    case pawn = "p", knight = "n", bishop = "b", rook = "r", queen = "q", king = "k"
}

struct Piece: Hashable {
    let color: PieceColor
    let kind: PieceKind

    /// The FEN letter — uppercase for white, which is also how every piece
    /// sprite sheet in the world names its files.
    var letter: Character {
        color == .white
            ? Character(String(kind.rawValue).uppercased())
            : kind.rawValue
    }

    init(_ color: PieceColor, _ kind: PieceKind) {
        self.color = color
        self.kind = kind
    }

    init?(letter: Character) {
        guard let kind = PieceKind(rawValue: Character(String(letter).lowercased()))
        else { return nil }
        self.init(letter.isUppercase ? .white : .black, kind)
    }
}

/// From, to, and what a pawn became. Long-algebraic, because that is what UCI
/// speaks and what the watcher can actually see: two squares changed, and
/// occasionally a piece that isn't a pawn standing on the back rank.
struct Move: Hashable, CustomStringConvertible {
    let from: Square
    let to: Square
    let promotion: PieceKind?

    init(from: Square, to: Square, promotion: PieceKind? = nil) {
        self.from = from
        self.to = to
        self.promotion = promotion
    }

    init?(uci: String) {
        let s = uci.trimmingCharacters(in: .whitespaces).lowercased()
        guard s.count == 4 || s.count == 5,
              let from = Square(String(s.prefix(2))),
              let to = Square(String(s.dropFirst(2).prefix(2)))
        else { return nil }
        var promotion: PieceKind?
        if s.count == 5, let last = s.last {
            guard let kind = PieceKind(rawValue: last) else { return nil }
            promotion = kind
        }
        self.init(from: from, to: to, promotion: promotion)
    }

    var uci: String {
        from.name + to.name + (promotion.map { String($0.rawValue) } ?? "")
    }
    var description: String { uci }
}

struct CastlingRights: OptionSet, Hashable {
    let rawValue: Int
    // Spelled out rather than left to synthesis: with `Hashable` alongside
    // `OptionSet` the compiler infers `RawValue` as the option set itself and
    // every `CastlingRights(rawValue: 1 << n)` below stops compiling.
    init(rawValue: Int) { self.rawValue = rawValue }

    static let whiteKing  = CastlingRights(rawValue: 1 << 0)
    static let whiteQueen = CastlingRights(rawValue: 1 << 1)
    static let blackKing  = CastlingRights(rawValue: 1 << 2)
    static let blackQueen = CastlingRights(rawValue: 1 << 3)
    static let all: CastlingRights = [.whiteKing, .whiteQueen, .blackKing, .blackQueen]

    var fen: String {
        var s = ""
        if contains(.whiteKing)  { s += "K" }
        if contains(.whiteQueen) { s += "Q" }
        if contains(.blackKing)  { s += "k" }
        if contains(.blackQueen) { s += "q" }
        return s.isEmpty ? "-" : s
    }
}

/// Everything a FEN needs, and nothing else.
struct ChessPosition: Equatable {
    /// Indexed by `Square.index`, so `board[0]` is a1.
    private(set) var board: [Piece?]
    var turn: PieceColor
    var castling: CastlingRights
    var enPassant: Square?
    var halfmoveClock: Int
    var fullmoveNumber: Int

    init(board: [Piece?], turn: PieceColor = .white,
         castling: CastlingRights = .all, enPassant: Square? = nil,
         halfmoveClock: Int = 0, fullmoveNumber: Int = 1) {
        precondition(board.count == 64, "a board is 64 squares")
        self.board = board
        self.turn = turn
        self.castling = castling
        self.enPassant = enPassant
        self.halfmoveClock = halfmoveClock
        self.fullmoveNumber = fullmoveNumber
    }

    subscript(square: Square) -> Piece? {
        get { board[square.index] }
        set { board[square.index] = newValue }
    }

    static let start: ChessPosition = {
        var board = [Piece?](repeating: nil, count: 64)
        let back: [PieceKind] = [.rook, .knight, .bishop, .queen, .king, .bishop, .knight, .rook]
        for file in 0..<8 {
            board[Square(file: file, rank: 0)!.index] = Piece(.white, back[file])
            board[Square(file: file, rank: 1)!.index] = Piece(.white, .pawn)
            board[Square(file: file, rank: 6)!.index] = Piece(.black, .pawn)
            board[Square(file: file, rank: 7)!.index] = Piece(.black, back[file])
        }
        return ChessPosition(board: board)
    }()

    /// Read a position back out of a FEN.
    ///
    /// Needed for starting mid-game — Visor is as likely to be pointed at a
    /// board on move twenty as at a fresh one, and the calibration pass has to
    /// be able to say what it found. Also the only sane way to write a test for
    /// castling rights without hand-placing sixteen pieces.
    init?(fen: String) {
        let fields = fen.split(separator: " ").map(String.init)
        guard fields.count >= 4 else { return nil }

        var board = [Piece?](repeating: nil, count: 64)
        let rows = fields[0].split(separator: "/")
        guard rows.count == 8 else { return nil }
        for (offset, row) in rows.enumerated() {
            let rank = 7 - offset            // FEN starts at rank 8
            var file = 0
            for character in row {
                if let empty = character.wholeNumberValue {
                    file += empty
                } else if let piece = Piece(letter: character) {
                    guard let square = Square(file: file, rank: rank) else { return nil }
                    board[square.index] = piece
                    file += 1
                } else {
                    return nil
                }
            }
            guard file == 8 else { return nil }
        }

        var rights: CastlingRights = []
        if fields[2] != "-" {
            for character in fields[2] {
                switch character {
                case "K": rights.insert(.whiteKing)
                case "Q": rights.insert(.whiteQueen)
                case "k": rights.insert(.blackKing)
                case "q": rights.insert(.blackQueen)
                default:  return nil
                }
            }
        }

        self.init(board: board,
                  turn: fields[1] == "b" ? .black : .white,
                  castling: rights,
                  enPassant: fields[3] == "-" ? nil : Square(fields[3]),
                  halfmoveClock: fields.count > 4 ? Int(fields[4]) ?? 0 : 0,
                  fullmoveNumber: fields.count > 5 ? Int(fields[5]) ?? 1 : 1)
    }

    var fen: String {
        var ranks: [String] = []
        for rank in stride(from: 7, through: 0, by: -1) {
            var row = "", gap = 0
            for file in 0..<8 {
                if let piece = board[Square(file: file, rank: rank)!.index] {
                    if gap > 0 { row += String(gap); gap = 0 }
                    row.append(piece.letter)
                } else {
                    gap += 1
                }
            }
            if gap > 0 { row += String(gap) }
            ranks.append(row)
        }
        return [
            ranks.joined(separator: "/"),
            turn == .white ? "w" : "b",
            castling.fen,
            enPassant?.name ?? "-",
            String(halfmoveClock),
            String(fullmoveNumber),
        ].joined(separator: " ")
    }

    /// Play a move that is already known to be legal.
    ///
    /// Legality is the engine's job — this is only asked to apply a move the
    /// engine listed, or one the watcher saw actually happen on screen. What it
    /// does have to get right is the bookkeeping the FEN carries and the pixels
    /// don't: castling rights, the en-passant square, and the two clocks. Get
    /// one of those wrong and the engine analyses a position that isn't the one
    /// on screen, which reads as the engine playing badly rather than as a bug
    /// here.
    mutating func apply(_ move: Move) {
        guard let moving = self[move.from] else { return }
        let captured = self[move.to]

        // Castling: the king moving two files is the whole tell, and the rook
        // has to come with it. Chess960 would break this; chess.com's bots
        // don't play it.
        if moving.kind == .king, abs(move.to.file - move.from.file) == 2 {
            let rank = move.from.rank
            let kingside = move.to.file > move.from.file
            let rookFrom = Square(file: kingside ? 7 : 0, rank: rank)!
            let rookTo   = Square(file: kingside ? 5 : 3, rank: rank)!
            self[rookTo] = self[rookFrom]
            self[rookFrom] = nil
        }

        // En passant: a pawn that changes file onto an empty square took
        // something, and the thing it took isn't on the square it landed on.
        var epCapture: Square?
        if moving.kind == .pawn, move.from.file != move.to.file, captured == nil {
            epCapture = Square(file: move.to.file, rank: move.from.rank)
            if let epCapture { self[epCapture] = nil }
        }

        self[move.to] = move.promotion.map { Piece(moving.color, $0) } ?? moving
        self[move.from] = nil

        // A rook that leaves its corner, a king that moves at all, or a rook
        // captured *on* its corner all cost the right to castle. The last one
        // is the case that gets forgotten, because nothing moved from the
        // corner — something arrived on it.
        switch (moving.kind, move.from.index) {
        case (.king, _):
            castling.subtract(moving.color == .white ? [.whiteKing, .whiteQueen]
                                                     : [.blackKing, .blackQueen])
        case (.rook, 0):  castling.remove(.whiteQueen)
        case (.rook, 7):  castling.remove(.whiteKing)
        case (.rook, 56): castling.remove(.blackQueen)
        case (.rook, 63): castling.remove(.blackKing)
        default: break
        }
        switch move.to.index {
        case 0:  castling.remove(.whiteQueen)
        case 7:  castling.remove(.whiteKing)
        case 56: castling.remove(.blackQueen)
        case 63: castling.remove(.blackKing)
        default: break
        }

        // Only a double push offers en passant, and only for one move.
        if moving.kind == .pawn, abs(move.to.rank - move.from.rank) == 2 {
            enPassant = Square(file: move.from.file,
                               rank: (move.from.rank + move.to.rank) / 2)
        } else {
            enPassant = nil
        }

        let irreversible = moving.kind == .pawn || captured != nil || epCapture != nil
        halfmoveClock = irreversible ? 0 : halfmoveClock + 1
        if turn == .black { fullmoveNumber += 1 }
        turn = turn.opposite
    }

    func applying(_ move: Move) -> ChessPosition {
        var next = self
        next.apply(move)
        return next
    }

    /// Where the pieces are, ignoring whose turn it is and every clock.
    ///
    /// The watcher can see this much and no more, so it's the only thing worth
    /// comparing a screen-read against when checking for drift.
    var placement: [Piece?] { board }
}
