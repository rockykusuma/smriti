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

    // MARK: - extract / backfill (need a store)

    private func makeStore() throws -> Store { try Store(dbPath: ":memory:") }

    private func insertMeeting(_ store: Store, title: String, content: String) throws -> Int64 {
        try store.upsert(app: "Meeting", bundleId: "sh.smriti.meeting",
                         windowTitle: title, content: content)
        return try XCTUnwrap(store.listMeetings(limit: 1).first?.id)
    }

    func testExtractPersistsAndIsIdempotent() throws {
        let store = try makeStore()
        let content = "## Summary\n\nx\n\n### Action items\n- Ship it\n\n---\n\nt"
        let id = try insertMeeting(store, title: "M", content: content)
        ActionItems.extract(store: store, snapshotId: id, content: content)
        ActionItems.extract(store: store, snapshotId: id, content: content)
        XCTAssertEqual(try store.actionItems(snapshotId: id).map(\.text), ["Ship it"])
    }

    func testBackfillOnlyTouchesUnextractedMeetings() throws {
        let store = try makeStore()
        let contentA = "### Action items\n- From A\n"
        let contentB = "### Action items\n- From B\n"
        let a = try insertMeeting(store, title: "A", content: contentA)
        let b = try insertMeeting(store, title: "B", content: contentB)
        // Meeting A already extracted — and its item checked off.
        ActionItems.extract(store: store, snapshotId: a, content: contentA)
        let itemA = try XCTUnwrap(store.actionItems(snapshotId: a).first)
        try store.setActionItemDone(id: itemA.id, done: true)

        ActionItems.backfill(store: store)

        // B got extracted; A untouched (done state survives — backfill must
        // not re-extract and wipe it).
        XCTAssertEqual(try store.actionItems(snapshotId: b).map(\.text), ["From B"])
        XCTAssertTrue(try XCTUnwrap(store.actionItems(snapshotId: a).first).done)
    }
}
