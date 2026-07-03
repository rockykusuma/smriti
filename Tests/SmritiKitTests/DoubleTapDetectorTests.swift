import XCTest
@testable import SmritiKit

final class DoubleTapDetectorTests: XCTestCase {

    func testTwoQuickTapsTrigger() {
        var d = DoubleTapDetector(window: 0.45)
        XCTAssertFalse(d.optionDown(at: 10.00))
        XCTAssertTrue(d.optionDown(at: 10.30))
    }

    func testSlowTapsDoNotTrigger() {
        var d = DoubleTapDetector(window: 0.45)
        XCTAssertFalse(d.optionDown(at: 10.00))
        XCTAssertFalse(d.optionDown(at: 11.00))
        // ...but the second tap starts a fresh window:
        XCTAssertTrue(d.optionDown(at: 11.30))
    }

    func testInterruptionBreaksSequence() {
        var d = DoubleTapDetector(window: 0.45)
        XCTAssertFalse(d.optionDown(at: 10.00))
        d.interrupt() // e.g. user typed ⌥4 for ₹
        XCTAssertFalse(d.optionDown(at: 10.20))
        XCTAssertTrue(d.optionDown(at: 10.40))
    }

    func testTripleTapTriggersOnceThenRestartsCleanly() {
        var d = DoubleTapDetector(window: 0.45)
        XCTAssertFalse(d.optionDown(at: 10.00))
        XCTAssertTrue(d.optionDown(at: 10.20))
        XCTAssertFalse(d.optionDown(at: 10.40)) // third tap = start of new pair
        XCTAssertTrue(d.optionDown(at: 10.60))
    }
}
