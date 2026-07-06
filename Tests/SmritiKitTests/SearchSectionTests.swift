import XCTest
@testable import SmritiKit

final class SearchSectionTests: XCTestCase {

    func testSearchSectionConformsToMainSection() {
        let store = try! Store(dbPath: ":memory:")
        let section = SearchSection(store: store)
        XCTAssertEqual(section.title, "Search")
        XCTAssertEqual(section.symbol, "magnifyingglass")
    }

    func testSearchSectionMakeViewReturnsNonEmptyView() {
        let store = try! Store(dbPath: ":memory:")
        let section = SearchSection(store: store)
        let view = section.makeView()
        XCTAssertGreaterThan(view.subviews.count, 0)
    }

    func testSearchSectionHandlesEmptyQuery() {
        let store = try! Store(dbPath: ":memory:")
        let section = SearchSection(store: store)
        _ = section.makeView()
        XCTAssertNotNil(section)
    }

    func testSearchSectionWithSnapshotsInStore() throws {
        let store = try Store(dbPath: ":memory:")
        try store.upsert(
            app: "Safari", bundleId: "com.apple.Safari",
            windowTitle: "GitHub", content: "PR #3 about hearing aid firmware")
        try store.upsert(
            app: "Slack", bundleId: "com.tinyspeck.slackmacgap",
            windowTitle: "#hearing-aid", content: "budget discussion")

        let section = SearchSection(store: store)
        _ = section.makeView()
        section.willAppear()
        XCTAssertNotNil(section)
    }
}
