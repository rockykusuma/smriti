import XCTest
@testable import SmritiKit

/// Covers the pure stream-json event parsing used by the Ask Smriti session.
final class MemoryChatTests: XCTestCase {

    func testTextDeltaBecomesDelta() {
        let event: [String: Any] = [
            "type": "stream_event",
            "event": [
                "type": "content_block_delta",
                "delta": ["type": "text_delta", "text": "Hello"],
            ],
        ]
        XCTAssertEqual(MemoryChat.parse(event), .delta("Hello"))
    }

    func testAssistantToolUseBecomesTools() {
        let event: [String: Any] = [
            "type": "assistant",
            "message": ["content": [
                ["type": "tool_use", "name": "mcp__smriti__search_memory", "input": ["query": "strix"]],
            ]],
        ]
        XCTAssertEqual(
            MemoryChat.parse(event),
            .tools([MemoryChat.ToolCall(name: "search_memory", summary: "strix")]))
    }

    func testGetSnapshotToolSummarizesId() {
        let event: [String: Any] = [
            "type": "assistant",
            "message": ["content": [
                ["type": "tool_use", "name": "mcp__smriti__get_snapshot", "input": ["id": 42]],
            ]],
        ]
        XCTAssertEqual(
            MemoryChat.parse(event),
            .tools([MemoryChat.ToolCall(name: "get_snapshot", summary: "#42")]))
    }

    func testResultBecomesResult() {
        let event: [String: Any] = ["type": "result", "result": "the answer"]
        XCTAssertEqual(MemoryChat.parse(event), .result("the answer"))
    }

    func testAssistantTextOnlyIsIgnored() {
        let event: [String: Any] = [
            "type": "assistant",
            "message": ["content": [["type": "text", "text": "thinking..."]]],
        ]
        XCTAssertEqual(MemoryChat.parse(event), .ignore)
    }

    func testUnknownEventIsIgnored() {
        XCTAssertEqual(MemoryChat.parse(["type": "system"]), .ignore)
    }
}
