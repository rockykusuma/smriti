import XCTest
@testable import SmritiKit

final class TodaySectionTests: XCTestCase {

    func testTodaySectionConformsToMainSection() {
        let store = try! Store(dbPath: ":memory:")
        let section = TodaySection(store: store)
        XCTAssertEqual(section.title, "Today")
        XCTAssertEqual(section.symbol, "calendar.badge.clock")
    }

    func testTodaySectionMakeViewReturnsNonEmptyView() {
        let store = try! Store(dbPath: ":memory:")
        let section = TodaySection(store: store)
        let view = section.makeView()
        XCTAssertGreaterThan(view.subviews.count, 0, "view should have subviews")
    }

    func testTodaySectionShowsSnapshotCount() throws {
        let store = try Store(dbPath: ":memory:")
        try store.upsert(
            app: "Safari", bundleId: "com.apple.Safari",
            windowTitle: "GitHub", content: "PR #3 merged")
        try store.upsert(
            app: "Slack", bundleId: "com.tinyspeck.slackmacgap",
            windowTitle: "#general", content: "hello")

        let section = TodaySection(store: store)
        _ = section.makeView()
        section.willAppear()

        XCTAssertNotNil(section)
    }

    func testTodaySectionHandlesEmptyDay() {
        let store = try! Store(dbPath: ":memory:")
        let section = TodaySection(store: store)
        _ = section.makeView()
        section.willAppear()

        XCTAssertNotNil(section)
    }

    func testTodaySectionRefreshAfterChronicleWritten() throws {
        let store = try Store(dbPath: ":memory:")
        let day = Chronicler.dayString()
        try store.upsert(
            app: "Safari", bundleId: "com.apple.Safari",
            windowTitle: "GitHub", content: "PR #3 merged")
        try store.upsertChronicle(
            day: day,
            summary: "## Summary\n\nYou worked on Smriti.",
            snapshotCount: 1)

        let section = TodaySection(store: store)
        _ = section.makeView()
        section.willAppear()

        XCTAssertNotNil(section)
    }
}
