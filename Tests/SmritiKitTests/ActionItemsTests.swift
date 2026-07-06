import XCTest
@testable import SmritiKit

final class ActionItemsTests: XCTestCase {

    // MARK: - parse

    func testParsesDashAndStarBullets() {
        let content = """
        ## Summary

        Overview here.

        ### Decisions
        - Use SQLite

        ### Action items
        - Ship the fix
        * Email Bob about the rollout

        ---

        transcript body
        """
        XCTAssertEqual(ActionItems.parse(content),
                       ["Ship the fix", "Email Bob about the rollout"])
    }

    func testParsesNumberedBullets() {
        let content = "### Action items\n1. First thing\n2) Second thing\n"
        XCTAssertEqual(ActionItems.parse(content), ["First thing", "Second thing"])
    }

    func testNoneYieldsEmpty() {
        XCTAssertEqual(ActionItems.parse("### Action items\n- none\n"), [])
        XCTAssertEqual(ActionItems.parse("### Action items\n- None.\n"), [])
    }

    func testMissingHeadingYieldsEmpty() {
        XCTAssertEqual(ActionItems.parse("just a transcript, no summary"), [])
        XCTAssertEqual(ActionItems.parse(""), [])
    }

    func testStopsAtNextHeadingAndRule() {
        let content = """
        ### Action items
        - Real item

        ### Notes
        - Not an action item

        ---
        - Not one either
        """
        XCTAssertEqual(ActionItems.parse(content), ["Real item"])
    }

    func testStripsBoldMarkers() {
        XCTAssertEqual(ActionItems.parse("### Action items\n- **Urgent:** call Ann\n"),
                       ["Urgent: call Ann"])
    }

    func testDecisionsBulletsAreNotActionItems() {
        let content = "### Decisions\n- Chose Postgres\n\n### Action items\n- Migrate schema\n"
        XCTAssertEqual(ActionItems.parse(content), ["Migrate schema"])
    }

    // MARK: - MeetingSummary.split

    func testSplitSeparatesSummaryAndTranscript() {
        let content = "## Summary\n\nOverview.\n\n### Action items\n- X\n\n---\n\nraw transcript"
        let (summary, transcript) = MeetingSummary.split(content)
        XCTAssertEqual(summary, "Overview.\n\n### Action items\n- X")
        XCTAssertEqual(transcript, "raw transcript")
    }

    func testSplitWithoutSummaryReturnsWholeAsTranscript() {
        let (summary, transcript) = MeetingSummary.split("plain transcript only")
        XCTAssertNil(summary)
        XCTAssertEqual(transcript, "plain transcript only")
    }

    func testSplitWithoutRuleReturnsWholeAsTranscript() {
        let content = "## Summary\n\nno rule separator here"
        let (summary, transcript) = MeetingSummary.split(content)
        XCTAssertNil(summary)
        XCTAssertEqual(transcript, content)
    }
}
