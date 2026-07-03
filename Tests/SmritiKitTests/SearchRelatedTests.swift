import XCTest
@testable import SmritiKit

final class SearchRelatedTests: XCTestCase {

    func testSearchRelatedMatchesAnyTermAndSkipsRecent() throws {
        let store = try Store(dbPath: ":memory:")
        try store.upsert(
            app: "Slack", bundleId: "com.tinyspeck.slackmacgap",
            windowTitle: "hearing-aid-project", content: "budget discussion for the hearing aid firmware")
        // Fresh snapshot — excluded by the recency filter (it IS the screen).
        let hits = try store.searchRelated(terms: ["hearing", "nonexistent"])
        XCTAssertTrue(hits.isEmpty, "sub-hour snapshots must be excluded")
        // With the filter relaxed it matches on OR semantics.
        let loose = try store.searchRelated(terms: ["hearing", "nonexistent"], excludeRecentMinutes: 0)
        XCTAssertEqual(loose.count, 1)
        // Short/quote-y terms are sanitized away, empty query returns empty.
        XCTAssertTrue(try store.searchRelated(terms: ["a", "\"" ]).isEmpty)
    }
}
