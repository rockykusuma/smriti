import XCTest
@testable import SmritiKit

final class MCPServerTests: XCTestCase {

    private var store: Store!
    private var server: MCPServer!

    override func setUpWithError() throws {
        store = try Store(dbPath: ":memory:")
        server = MCPServer(store: store)
        try store.upsert(
            app: "Terminal", bundleId: "com.apple.Terminal",
            windowTitle: "zsh", content: "swift build release output",
            url: "")
    }

    func testSearchMemoryTool() throws {
        let out = try server.callTool(name: "search_memory", args: ["query": "swift build"])
        XCTAssertTrue(out.contains("Terminal"))
        XCTAssertTrue(out.contains("#")) // includes snapshot id for follow-up
    }

    func testSearchMemoryRequiresQuery() {
        XCTAssertThrowsError(try server.callTool(name: "search_memory", args: [:]))
        XCTAssertThrowsError(try server.callTool(name: "search_memory", args: ["query": ""]))
    }

    func testRecentActivityTool() throws {
        let out = try server.callTool(
            name: "get_recent_activity", args: ["minutes": 10, "limit": 5])
        XCTAssertTrue(out.contains("Terminal — zsh"))
    }

    func testGetSnapshotTool() throws {
        let id = try XCTUnwrap(store.recent(minutes: 5).first?.id)
        let out = try server.callTool(name: "get_snapshot", args: ["id": Int(id)])
        XCTAssertTrue(out.contains("swift build release output"))
        XCTAssertThrowsError(try server.callTool(name: "get_snapshot", args: ["id": 424242]))
    }

    func testChronicleTools() throws {
        try store.upsertChronicle(day: "2026-07-03", summary: "A fine day.", snapshotCount: 3)
        let one = try server.callTool(name: "get_chronicle", args: ["day": "2026-07-03"])
        XCTAssertTrue(one.contains("A fine day."))
        let list = try server.callTool(name: "list_chronicles", args: [:])
        XCTAssertTrue(list.contains("2026-07-03"))
        XCTAssertThrowsError(try server.callTool(name: "get_chronicle", args: ["day": "1999-01-01"]))
    }

    func testUnknownToolThrows() {
        XCTAssertThrowsError(try server.callTool(name: "definitely_not_a_tool", args: [:]))
    }
}
