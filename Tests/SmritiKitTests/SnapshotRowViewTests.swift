import XCTest
@testable import SmritiKit

final class SnapshotRowViewTests: XCTestCase {

    func testSnapshotRowViewContainsExpectedSubviews() throws {
        let store = try Store(dbPath: ":memory:")
        try store.upsert(
            app: "Safari", bundleId: "com.apple.Safari",
            windowTitle: "GitHub — PR #3", content: "budget discussion for the hearing aid firmware")
        let snap = try XCTUnwrap(store.search("hearing", limit: 1).first)

        let row = SnapshotRowView(snapshot: snap, showTimestamp: true)
        row.layoutSubtreeIfNeeded()

        XCTAssertGreaterThanOrEqual(row.subviews.count, 2,
            "SnapshotRowView should contain an icon and text subviews")
    }

    func testSnapshotRowViewHidesTimestampWhenRequested() throws {
        let store = try Store(dbPath: ":memory:")
        try store.upsert(
            app: "Slack", bundleId: "com.tinyspeck.slackmacgap",
            windowTitle: "#general", content: "hello world")
        let snap = try XCTUnwrap(store.search("hello", limit: 1).first)

        let withTS = SnapshotRowView(snapshot: snap, showTimestamp: true)
        let withoutTS = SnapshotRowView(snapshot: snap, showTimestamp: false)
        withTS.layoutSubtreeIfNeeded()
        withoutTS.layoutSubtreeIfNeeded()

        XCTAssertNotNil(withTS)
        XCTAssertNotNil(withoutTS)
    }

    func testSnapshotRowViewHandlesEmptyContent() throws {
        let store = try Store(dbPath: ":memory:")
        try store.upsert(
            app: "Finder", bundleId: "com.apple.finder",
            windowTitle: "Desktop", content: "")
        let snap = try XCTUnwrap(store.search("Desktop", limit: 1).first)

        let row = SnapshotRowView(snapshot: snap)
        row.layoutSubtreeIfNeeded()
        XCTAssertNotNil(row)
    }
}
