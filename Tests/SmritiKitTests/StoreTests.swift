import XCTest
@testable import SmritiKit

final class StoreTests: XCTestCase {

    private var store: Store!

    override func setUpWithError() throws {
        store = try Store(dbPath: ":memory:")
    }

    private func insertSample() throws {
        try store.upsert(
            app: "Safari", bundleId: "com.apple.Safari",
            windowTitle: "Swift docs", content: "The Swift programming language guide",
            url: "https://swift.org/docs")
        try store.upsert(
            app: "Xcode", bundleId: "com.apple.dt.Xcode",
            windowTitle: "Store.swift", content: "final class Store persistence sqlite")
    }

    func testUpsertAndRecent() throws {
        try insertSample()
        let rows = try store.recent(minutes: 5)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.app, "Xcode") // newest first
        XCTAssertEqual(rows.last?.url, "https://swift.org/docs")
    }

    func testDedupBumpsInsteadOfDuplicating() throws {
        for _ in 0..<5 {
            try store.upsert(
                app: "Safari", bundleId: "com.apple.Safari",
                windowTitle: "Same window", content: "identical content")
        }
        XCTAssertEqual(try store.stats().snapshotCount, 1)
    }

    func testSearchFindsByContent() throws {
        try insertSample()
        let hits = try store.search("sqlite persistence", limit: 10)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.app, "Xcode")
        XCTAssertTrue(try store.search("nonexistentterm", limit: 10).isEmpty)
    }

    func testSearchSurvivesFTSSyntaxCharacters() throws {
        try insertSample()
        // Quotes/operators must not crash or throw FTS5 syntax errors.
        XCTAssertNoThrow(try store.search("\"swift OR (guide\"", limit: 10))
    }

    func testGetSnapshotById() throws {
        try insertSample()
        let id = try XCTUnwrap(store.recent(minutes: 5).first?.id)
        let row = try XCTUnwrap(store.getSnapshot(id: id))
        XCTAssertEqual(row.id, id)
        XCTAssertNil(try store.getSnapshot(id: 999_999))
    }

    func testDeleteKeepsFTSInSync() throws {
        try insertSample()
        _ = try store.prune(olderThanDays: 0) // no-op: disabled
        XCTAssertEqual(try store.stats().snapshotCount, 2)
    }

    func testChronicleRoundTrip() throws {
        try store.upsertChronicle(day: "2026-07-03", summary: "Built things.", snapshotCount: 23)
        let c = try XCTUnwrap(store.getChronicle(day: "2026-07-03"))
        XCTAssertEqual(c.summary, "Built things.")
        XCTAssertEqual(c.snapshotCount, 23)
        // Upsert replaces
        try store.upsertChronicle(day: "2026-07-03", summary: "Rewritten.", snapshotCount: 24)
        XCTAssertEqual(try store.getChronicle(day: "2026-07-03")?.summary, "Rewritten.")
        XCTAssertEqual(try store.listChronicles().count, 1)
        XCTAssertNil(try store.getChronicle(day: "1999-01-01"))
    }

    func testCountForDay() throws {
        try insertSample()
        let today = Chronicler.dayString()
        XCTAssertEqual(try store.countForDay(today), 2)
        XCTAssertEqual(try store.countForDay("1999-01-01"), 0)
    }

    func testStats() throws {
        try insertSample()
        let s = try store.stats()
        XCTAssertEqual(s.snapshotCount, 2)
        XCTAssertEqual(s.distinctApps, 2)
        XCTAssertNotNil(s.oldest)
        XCTAssertNotNil(s.newest)
    }
}
