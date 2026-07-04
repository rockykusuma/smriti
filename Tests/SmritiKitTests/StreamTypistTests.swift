import XCTest
@testable import SmritiKit

/// Covers the streaming typist that inserts reply-assist output — in
/// particular the decline (sentinel) path and the Escape-cancel path, which
/// are the two ways output must be suppressed.
final class StreamTypistTests: XCTestCase {

    /// Builds a typist wired to capture what it types and how often it begins.
    private func makeTypist(threshold: Int = 5, sentinels: [String] = ["STOP"])
        -> (AssistListener.StreamTypist, () -> String, () -> Int) {
        var typed = ""
        var beginCount = 0
        let typist = AssistListener.StreamTypist(
            threshold: threshold, sentinels: sentinels,
            begin: { beginCount += 1 },
            type: { typed += $0 })
        return (typist, { typed }, { beginCount })
    }

    func testShortReplyFlushesOnFinish() {
        let (t, typed, begins) = makeTypist()
        t.feed("Hi")                       // below threshold: buffered, not typed
        XCTAssertEqual(typed(), "")
        let outcome = t.finish(fullText: "Hi")
        XCTAssertEqual(outcome, .typed(2))
        XCTAssertEqual(typed(), "Hi")
        XCTAssertEqual(begins(), 1)        // begin fires exactly once
    }

    func testStreamingAboveThresholdTypesAsItGoes() {
        let (t, typed, begins) = makeTypist()
        t.feed("Hello ")                   // crosses threshold → begins + types
        t.feed("world")
        let outcome = t.finish(fullText: "Hello world")
        XCTAssertEqual(outcome, .typed(11))
        XCTAssertEqual(typed(), "Hello world")
        XCTAssertEqual(begins(), 1)
    }

    func testSentinelDeclinesAndTypesNothing() {
        let (t, typed, begins) = makeTypist()
        t.feed("STOP")                     // decline sentinel
        let outcome = t.finish(fullText: "STOP")
        XCTAssertEqual(outcome, .declined)
        XCTAssertEqual(typed(), "")
        XCTAssertEqual(begins(), 0)
    }

    func testAuthErrorBannerIsNeverTyped() {
        // A CLI error like "Not logged in · Please run /login" must be declined,
        // not typed into the user's field.
        let (t, typed, begins) = makeTypist(
            threshold: 24, sentinels: ["NO_REPLY_CONTEXT", "Not logged in"])
        t.feed("Not logged in · Please run /login")
        let outcome = t.finish(fullText: "Not logged in · Please run /login")
        XCTAssertEqual(outcome, .declined)
        XCTAssertEqual(typed(), "")
        XCTAssertEqual(begins(), 0)
    }

    func testCancelMidStreamStopsTypingAndDiscardsRest() {
        let (t, typed, begins) = makeTypist()
        t.feed("Hello ")                   // types "Hello "
        XCTAssertEqual(typed(), "Hello ")
        t.cancel()                         // user hit Escape
        t.feed("world")                    // dropped
        let outcome = t.finish(fullText: "Hello world")
        XCTAssertEqual(outcome, .cancelled(6))
        XCTAssertEqual(typed(), "Hello ")  // already-typed text kept, rest dropped
        XCTAssertEqual(begins(), 1)
    }

    func testCancelBeforeTypingTypesNothing() {
        let (t, typed, begins) = makeTypist()
        t.cancel()
        t.feed("Hello there")              // dropped entirely
        let outcome = t.finish(fullText: "Hello there")
        XCTAssertEqual(outcome, .cancelled(0))
        XCTAssertEqual(typed(), "")
        XCTAssertEqual(begins(), 0)
    }
}
