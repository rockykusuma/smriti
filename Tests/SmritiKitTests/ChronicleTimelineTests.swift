import XCTest
@testable import SmritiKit

final class ChronicleTimelineTests: XCTestCase {

    func testChronicleTimelineConformsToMainSection() {
        let store = try! Store(dbPath: ":memory:")
        let section = ChronicleTimelineSection(store: store)
        XCTAssertEqual(section.title, "Chronicles")
        XCTAssertEqual(section.symbol, "calendar")
    }

    func testChronicleTimelineMakeViewReturnsNonEmptyView() {
        let store = try! Store(dbPath: ":memory:")
        let section = ChronicleTimelineSection(store: store)
        let view = section.makeView()
        XCTAssertGreaterThan(view.subviews.count, 0)
    }

    func testChronicleTimelineWithEmptyStore() {
        let store = try! Store(dbPath: ":memory:")
        let section = ChronicleTimelineSection(store: store)
        _ = section.makeView()
        section.willAppear()
        XCTAssertNotNil(section)
    }

    func testChronicleTimelineWithChroniclesAndSnapshots() throws {
        let store = try Store(dbPath: ":memory:")
        let day = Chronicler.dayString()
        try store.upsert(
            app: "Safari", bundleId: "com.apple.Safari",
            windowTitle: "GitHub", content: "PR #3 merged")
        try store.upsertChronicle(
            day: day,
            summary: "## Summary\n\nProductive day.",
            snapshotCount: 1)

        let section = ChronicleTimelineSection(store: store)
        _ = section.makeView()
        section.willAppear()
        XCTAssertNotNil(section)
    }
}
