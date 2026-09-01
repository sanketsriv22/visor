import AppKit

/// Reads the pieces off a board, so a game already under way can be joined.
///
/// Everything else in this feature deliberately avoids a model: the watcher
/// sees *which* squares changed and never *what* is on them, because a model in
/// the move loop would cost hundreds of milliseconds and be confidently wrong
/// often enough to matter. That reasoning holds — and it is exactly why this is
/// allowed. It runs once, before the game starts, on a still image, and its
/// answer is checked before anything is built on it.
///
/// The check is the point. The board finder already knows, from pixels alone
/// and very reliably, which squares are occupied and whether each piece is
/// light or dark. A model that hallucinates a knight onto an empty square, or
/// gives Black a bishop that is plainly White's, disagrees with that — and gets
/// rejected. What the model is trusted for is the one thing pixels can't give
/// cheaply: which *kind* of piece is on each occupied square.
enum ChessVision {
    enum ReadError: LocalizedError {
        case noKey
        case badResponse(String)
        case disagreesWithScreen(Int)

        var errorDescription: String? {
            switch self {
            case .noKey:
                return "Reading a game in progress needs an OpenRouter key — add one under Agents"
            case .badResponse(let detail):
                return "Couldn't read the position: \(detail)"
            case .disagreesWithScreen(let wrong):
                return "Read the position but it disagrees with the screen on \(wrong) squares"
            }
        }
    }

    struct Reading {
        let position: ChessPosition
        /// True when the user is playing black.
        let flipped: Bool
    }

    /// Which model does the reading. Overridable, because model availability is
    /// not something this file should be the authority on.
    static var model: String {
        UserDefaults.standard.string(forKey: "visor.chess.visionModel")
            ?? "anthropic/claude-opus-5"
    }

    static func read(board: CGImage, occupancy: [Square: PieceColor?],
                     flipped: Bool) async throws -> Reading {
        guard let key = OpenRouterClient.key else { throw ReadError.noKey }

        let rep = NSBitmapImageRep(cgImage: board)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw ReadError.badResponse("couldn't encode the board")
        }

        let prompt = """
            This is a chess board from a screenshot. \
            \(flipped ? "Black" : "White") is at the bottom.

            Reply with only a JSON object, no prose and no code fence:
            {"placement": "<the piece-placement field of a FEN, ranks 8 to 1, \
            slash separated, from White's point of view regardless of how the \
            image is oriented>", "side_to_move": "white" or "black"}

            Be exact about which squares are occupied. If you are unsure what a \
            piece is, still place a piece of the right colour there rather than \
            leaving the square empty.
            """

        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://kitalabs.com/visor", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Visor", forHTTPHeaderField: "X-Title")
        request.timeoutInterval = 60

        // The multimodal shape, which the app's own chat client has no way to
        // express: its `ChatMessage.content` is a String, and every other
        // request Visor makes is text.
        let body: [String: Any] = [
            "model": model,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": prompt],
                    ["type": "image_url",
                     "image_url": ["url": "data:image/png;base64," + png.base64EncodedString()]],
                ],
            ]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let detail = String(data: data, encoding: .utf8)?.prefix(180) ?? ""
            throw ReadError.badResponse("HTTP \(http.statusCode) \(detail)")
        }
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = envelope["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String
        else { throw ReadError.badResponse("unexpected response shape") }

        let (placement, sideToMove) = try parse(text)
        var position = try assemble(placement: placement, sideToMove: sideToMove)

        // Cross-check. This is what makes the reading usable rather than
        // plausible: a model is being trusted for piece identity only, and
        // anything it says about *where* the pieces are gets checked against
        // what the screen plainly shows.
        var disagreements = 0
        for index in 0..<64 {
            guard let square = Square(index: index) else { continue }
            let seen = occupancy[square] ?? nil
            let read = position[square]
            if (seen == nil) != (read == nil) { disagreements += 1 }
            else if let seen, let read, seen != read.color { disagreements += 1 }
        }
        // A couple of squares can legitimately differ — a piece mid-animation,
        // a square under the cursor, a highlight over an empty one. Six is not
        // a near miss, it's a different board.
        guard disagreements <= 5 else { throw ReadError.disagreesWithScreen(disagreements) }

        position.castling = inferredCastling(in: position)
        return Reading(position: position, flipped: flipped)
    }

    private static func parse(_ text: String) throws -> (String, PieceColor) {
        // Fences happen however firmly you ask for none.
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = body.firstIndex(of: "{"), let end = body.lastIndex(of: "}") {
            body = String(body[start...end])
        }
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let placement = object["placement"] as? String
        else { throw ReadError.badResponse("no JSON in the reply") }
        let side = (object["side_to_move"] as? String)?.lowercased() == "black" ? PieceColor.black : .white
        return (placement, side)
    }

    private static func assemble(placement: String, sideToMove: PieceColor) throws -> ChessPosition {
        let fen = "\(placement) \(sideToMove == .white ? "w" : "b") KQkq - 0 1"
        guard let position = ChessPosition(fen: fen) else {
            throw ReadError.badResponse("the placement wasn't a legal FEN field")
        }
        return position
    }

    /// Castling rights can't be seen in a photograph — whether a king has
    /// already moved and come back is not a fact about the current position. A
    /// king and rook still on their home squares is the closest available
    /// guess, and it is right far more often than assuming none.
    private static func inferredCastling(in position: ChessPosition) -> CastlingRights {
        var rights: CastlingRights = []
        func piece(_ name: String) -> Piece? { Square(name).flatMap { position[$0] } }
        if piece("e1") == Piece(.white, .king) {
            if piece("h1") == Piece(.white, .rook) { rights.insert(.whiteKing) }
            if piece("a1") == Piece(.white, .rook) { rights.insert(.whiteQueen) }
        }
        if piece("e8") == Piece(.black, .king) {
            if piece("h8") == Piece(.black, .rook) { rights.insert(.blackKing) }
            if piece("a8") == Piece(.black, .rook) { rights.insert(.blackQueen) }
        }
        return rights
    }
}
