import XCTest
@testable import Visor

/// The half of the chess subsystem that can be checked without a screen.
///
/// Which is deliberately most of it. Position bookkeeping and board geometry
/// are where the quiet, expensive bugs live — a castling right that isn't
/// cleared makes the engine analyse a position that isn't on screen, and reads
/// as the engine playing badly rather than as anything being wrong here. The
/// capture and overlay layers need a display and are left to be exercised by
/// hand.
final class ChessPositionTests: XCTestCase {

    func testStartPositionFEN() {
        XCTAssertEqual(ChessPosition.start.fen,
                       "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
    }

    func testOpeningMovesKeepTheBookkeeping() {
        var position = ChessPosition.start
        position.apply(Move(uci: "e2e4")!)
        XCTAssertEqual(position.fen,
                       "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1",
                       "a double push offers en passant")
        position.apply(Move(uci: "e7e5")!)
        XCTAssertEqual(position.fen,
                       "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2",
                       "black's move increments the full-move number")
        position.apply(Move(uci: "g1f3")!)
        XCTAssertEqual(position.fen,
                       "rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2",
                       "a quiet move clears en passant and advances the half-move clock")
    }

    func testFENRoundTrips() {
        let fen = "r1bqk2r/pppp1ppp/2n2n2/2b1p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4"
        XCTAssertEqual(ChessPosition(fen: fen)?.fen, fen)
    }

    func testRejectsMalformedFEN() {
        XCTAssertNil(ChessPosition(fen: "not a fen"))
        XCTAssertNil(ChessPosition(fen: "8/8/8 w - -"), "too few ranks")
        XCTAssertNil(ChessPosition(fen: "rnbqkbnr/ppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"),
                     "a rank that doesn't add up to eight")
    }

    func testCastlingMovesTheRook() {
        var white = ChessPosition(fen: "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")!
        white.apply(Move(uci: "e1g1")!)
        XCTAssertEqual(white.fen, "r3k2r/8/8/8/8/8/8/R4RK1 b kq - 1 1")

        var black = ChessPosition(fen: "r3k2r/8/8/8/8/8/8/R3K2R b KQkq - 0 1")!
        black.apply(Move(uci: "e8c8")!)
        XCTAssertEqual(black.fen, "2kr3r/8/8/8/8/8/8/R3K2R w KQ - 1 2")
    }

    func testRookLeavingItsCornerCostsThatRightOnly() {
        var position = ChessPosition(fen: "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")!
        position.apply(Move(uci: "a1a5")!)
        XCTAssertEqual(position.castling.fen, "Kkq")
    }

    /// The rule that gets forgotten: nothing moved *from* the corner, something
    /// arrived on it, and the right is gone all the same.
    func testCaptureOnACornerCostsTheRight() {
        var position = ChessPosition(fen: "r3k2r/8/8/8/8/8/8/Q6K w kq - 0 1")!
        position.apply(Move(uci: "a1a8")!)
        XCTAssertEqual(position.castling.fen, "k")
    }

    func testEnPassantCaptureRemovesTheRightPawn() {
        var position = ChessPosition(fen: "8/3p4/8/4P3/8/8/8/8 b - - 0 1")!
        position.apply(Move(uci: "d7d5")!)
        XCTAssertEqual(position.enPassant?.name, "d6")
        position.apply(Move(uci: "e5d6")!)
        XCTAssertEqual(position.fen, "8/8/3P4/8/8/8/8/8 b - - 0 2",
                       "the captured pawn was on d5, not on the landing square")
    }

    func testPromotion() {
        var position = ChessPosition(fen: "8/P7/8/8/8/8/8/8 w - - 0 1")!
        position.apply(Move(uci: "a7a8q")!)
        XCTAssertEqual(position.fen, "Q7/8/8/8/8/8/8/8 b - - 0 1")
    }

    func testMoveParsing() {
        XCTAssertEqual(Move(uci: "e7e8q")?.uci, "e7e8q")
        XCTAssertEqual(Move(uci: "e2e4")?.uci, "e2e4")
        XCTAssertNil(Move(uci: "z9z9"))
        XCTAssertNil(Move(uci: "e2e"))
        XCTAssertEqual(Square("a1")?.index, 0)
        XCTAssertEqual(Square("h8")?.index, 63)
    }
}

/// Board geometry, which three separate layers have to agree on to the pixel.
///
/// If the overlay and the clicker disagree by half a square, the arrows point
/// at the right move and the mouse plays a different one — and both halves look
/// individually correct while you're staring at them.
final class ChessGeometryTests: XCTestCase {
    private let origin = CGPoint(x: 100, y: 200)
    private let square: CGFloat = 64

    private var white: BoardGeometry {
        BoardGeometry(origin: origin, square: square, flipped: false)
    }
    private var black: BoardGeometry {
        BoardGeometry(origin: origin, square: square, flipped: true)
    }

    func testOrientationDecidesWhichCornerIsWhich() {
        XCTAssertEqual(white.rect(of: Square("a8")!).origin, origin)
        XCTAssertEqual(white.rect(of: Square("h1")!).origin,
                       CGPoint(x: origin.x + square * 7, y: origin.y + square * 7))
        XCTAssertEqual(black.rect(of: Square("h1")!).origin, origin,
                       "playing black puts h1 top-left")
        XCTAssertEqual(black.rect(of: Square("a8")!).origin,
                       CGPoint(x: origin.x + square * 7, y: origin.y + square * 7))
    }

    func testEverySquareRoundTripsThroughItsCentre() {
        for board in [white, black] {
            for index in 0..<64 {
                let square = Square(index: index)!
                XCTAssertEqual(board.square(at: board.center(of: square)), square)
            }
        }
    }

    func testBoundingBoxTakesTheShortSide() {
        let wide = BoardGeometry(boundingBox: CGRect(x: 0, y: 0, width: 520, height: 480))
        XCTAssertEqual(wide.square, 60, "480 is the side that fits")
        XCTAssertEqual(wide.origin.x, 20, "and it's centred in the box it was found in")
    }

    /// The overlay draws in AppKit's coordinates, which run the other way up.
    func testOverlayCoordinatesAreFlipped() {
        XCTAssertGreaterThan(white.overlayCenter(of: Square("a8")!).y,
                             white.overlayCenter(of: Square("a1")!).y)
        for index in 0..<64 {
            let centre = white.overlayCenter(of: Square(index: index)!)
            XCTAssertTrue((0...white.side).contains(centre.x))
            XCTAssertTrue((0...white.side).contains(centre.y))
        }
    }
}
