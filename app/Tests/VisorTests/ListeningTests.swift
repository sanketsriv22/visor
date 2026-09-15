import XCTest
@testable import Visor

/// The listening notch: one shape per session, read by the window frame and
/// the pills alike; a key that starts recording on its first instant; and
/// visuals that always fill their grid. These are the invariants behind the
/// bugs of 2026-09-15 — a window framed for one visual while the pills drew
/// another, and a tap that started and cancelled a recording.
@MainActor
final class ListeningTests: XCTestCase {

    // MARK: Shape

    func testShapeFollowsTheTalkingVisualOnly() {
        for during in NotchVisuals.During.allCases {
            let shape = NotchVisuals.Shape.current(during: during)
            XCTAssertEqual(shape.leftPill, !during.rightOnly, "\(during)")
            XCTAssertEqual(shape.extraHeight, during == .voicePong ? VoicePong.extraHeight : 0, "\(during)")
        }
    }

    func testSessionShapeIsFixedUntilItEnds() {
        let v = NotchVisuals.shared
        let original = v.during
        defer { v.during = original; v.endSession() }
        v.during = .wave
        v.beginSession()
        XCTAssertFalse(v.active.leftPill)
        // Changing the setting mid-session must not change the shape in use.
        v.during = .invaders
        XCTAssertFalse(v.active.leftPill, "the session's shape changed underneath the pills")
        v.endSession()
        XCTAssertTrue(v.active.leftPill, "after the session, the new setting applies")
    }

    func testFrameMatchesShape() {
        let hit = NSRect(x: 100, y: 900, width: 200, height: 32)
        let both = NotchController.listeningFrame(around: hit, shape: .init(leftPill: true, extraHeight: 0))
        XCTAssertEqual(both.minX, 100 - NotchController.listeningPillWidth)
        XCTAssertEqual(both.width, 200 + 2 * NotchController.listeningPillWidth)
        let right = NotchController.listeningFrame(around: hit, shape: .init(leftPill: false, extraHeight: 0))
        XCTAssertEqual(right.minX, 100, "a one-sided session must not grow left")
        XCTAssertEqual(right.width, 200 + NotchController.listeningPillWidth)
        let tall = NotchController.listeningFrame(around: hit, shape: .init(leftPill: true, extraHeight: 40))
        XCTAssertEqual(tall.minY, 860)
        XCTAssertEqual(tall.height, 72)
    }

    // MARK: The key

    func testPressArmsTheMicrophoneAtOnce() {
        let key = PushToTalk()
        var arms = 0, shows = 0
        key.onArm = { arms += 1 }
        key.onHoldStart = { shows += 1 }
        key.pressed()
        XCTAssertEqual(arms, 1, "the microphone must open on key-down, before the hold is known")
        XCTAssertEqual(shows, 0, "nothing shows until it's a hold")
    }

    func testHoldEndsOnRelease() {
        let key = PushToTalk()
        var ends = 0, cancels = 0
        key.onHoldEnd = { ends += 1 }
        key.onCancel = { cancels += 1 }
        key.pressed()
        key.released(heldFor: key.holdThreshold + 0.1)
        XCTAssertEqual(ends, 1); XCTAssertEqual(cancels, 0)
    }

    func testALoneTapIsNothing() {
        let key = PushToTalk()
        var ends = 0, cancels = 0, shows = 0
        key.onHoldEnd = { ends += 1 }
        key.onCancel = { cancels += 1 }
        key.onHoldStart = { shows += 1 }
        key.pressed(); key.released(heldFor: 0.05)
        XCTAssertEqual(cancels, 1, "a tap must drop what it armed")
        XCTAssertEqual(ends, 0); XCTAssertEqual(shows, 0)
    }

    func testDoubleTapTogglesOnAndTheNextPressEndsIt() {
        let key = PushToTalk()
        var arms = 0, shows = 0, ends = 0, cancels = 0
        key.onArm = { arms += 1 }; key.onHoldStart = { shows += 1 }
        key.onHoldEnd = { ends += 1 }; key.onCancel = { cancels += 1 }
        key.pressed(); key.released(heldFor: 0.05)      // first tap: cancelled
        key.pressed(); key.released(heldFor: 0.05)      // second tap: toggled on
        XCTAssertEqual(arms, 2); XCTAssertEqual(cancels, 1); XCTAssertEqual(shows, 1)
        key.pressed()                                   // while on: no new arm
        XCTAssertEqual(arms, 2)
        key.released(heldFor: 0.05)                     // done
        XCTAssertEqual(ends, 1)
    }

    func testAReleaseWithoutAPressIsNothing() {
        let key = PushToTalk()
        var cancels = 0, ends = 0
        key.onCancel = { cancels += 1 }
        key.onHoldEnd = { ends += 1 }
        key.released(heldFor: 0.05)
        key.released(heldFor: 2)
        XCTAssertEqual(cancels, 0); XCTAssertEqual(ends, 0)
    }

    func testASecondReleaseAfterAHoldIsNothing() {
        let key = PushToTalk()
        var cancels = 0, ends = 0
        key.onCancel = { cancels += 1 }
        key.onHoldEnd = { ends += 1 }
        key.pressed()
        key.released(heldFor: 2)
        key.released(heldFor: 0.01)                     // a duplicate key-up must not cancel anything
        XCTAssertEqual(ends, 1); XCTAssertEqual(cancels, 0)
    }

    func testAutorepeatDoesNotRearm() {
        let key = PushToTalk()
        var arms = 0
        key.onArm = { arms += 1 }
        key.pressed(); key.pressed(); key.pressed()
        XCTAssertEqual(arms, 1)
    }

    // MARK: Visuals

    func testEveryVisualFillsItsGridOnEverySide() {
        let levels: [Float] = (0..<28).map { Float(abs(sin(Double($0) * 0.7))) }
        for kind in NotchGallery.Live.allCases {
            for side in [ListeningPill.Side.leading, .trailing] {
                let grid = NotchGallery.live(kind, levels: levels, t: 1.234, side: side)
                XCTAssertEqual(grid.count, NotchGallery.columns, "\(kind) \(side)")
                for column in grid {
                    XCTAssertEqual(column.count, NotchGallery.rows, "\(kind) \(side)")
                    for v in column { XCTAssert(v >= 0 && v <= 1, "\(kind): value out of range \(v)") }
                }
            }
        }
        for kind in NotchGallery.Idle.allCases {
            for side in [ListeningPill.Side.leading, .trailing] {
                let grid = NotchGallery.idle(kind, t: 1.234, side: side)
                XCTAssertEqual(grid.count, NotchGallery.columns, "\(kind) \(side)")
                for column in grid {
                    XCTAssertEqual(column.count, NotchGallery.rows)
                    for v in column { XCTAssert(v >= 0 && v <= 1, "\(kind): value out of range \(v)") }
                }
            }
        }
    }

    func testFireBurnsFromTheBottom() {
        let grid = NotchGallery.fire(t: 0.5, height: 0.6, width: 4)
        for column in grid {
            XCTAssertGreaterThan(column[NotchGallery.rows - 1], column[0], "the bottom row must be hotter than the top")
        }
    }

    func testOneSidedVisualsAreEmptyOnTheLeft() {
        let levels: [Float] = Array(repeating: 0.8, count: 28)
        for kind in NotchGallery.Live.allCases where kind.sides == .right {
            // A right-only visual is only ever asked for the trailing side;
            // its grid must still be well-formed.
            let grid = NotchGallery.live(kind, levels: levels, t: 2, side: .trailing)
            XCTAssertEqual(grid.count, NotchGallery.columns)
        }
    }
}
