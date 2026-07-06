# Meeting Intelligence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Smriti's meeting summaries into working intelligence: a checkable action-items hub, audio playback for saved recordings, and a structured meeting detail view.

**Architecture:** Meetings stay as `snapshots` rows (`bundle_id = 'sh.smriti.meeting'`). A new `action_items` table stores items parsed from the `### Action items` section of composed summaries. Audio location comes from the existing `snapshots.url` column (already populated by both recording lanes). All new UI lives in new files; `MainWindow.swift` gains only wiring.

**Tech Stack:** Swift 5.9, AppKit (frame-based layout + autoresizing masks, matching existing style), SQLite3 C API via existing `Store` helpers, AVFoundation (`AVMutableComposition` + `AVPlayer`), XCTest.

**Spec:** `docs/superpowers/specs/2026-07-06-meeting-intelligence-design.md`

## Global Constraints

- Platform floor: macOS 13 (`Package.swift` — `.macOS(.v13)`). No macOS 14+-only API.
- No new package dependencies.
- Logging: `fputs("smriti <area>: …\n", stderr)` — never dialogs for background failures.
- UI code style: frame-based AppKit with `autoresizingMask`, `Theme` colors, matching `MainWindow.swift`.
- Tests: XCTest in `Tests/SmritiKitTests/`, `Store(dbPath: ":memory:")`.
- All work on branch `feat/meeting-intelligence`. Never push to `main`.
- Run tests with: `swift test 2>&1 | tail -20`. Build with: `swift build 2>&1 | tail -5`.

---

### Task 1: Store — `action_items` table + CRUD

**Files:**
- Modify: `Sources/SmritiKit/Store.swift` (table create in `init` after the chronicles table, ~line 73; new API after `listMeetings`, ~line 290)
- Test: `Tests/SmritiKitTests/StoreTests.swift`

**Interfaces:**
- Consumes: existing `Store` helpers `prepare`, `exec`, `columnText`, `lastErrorMessage`, `Store.timestamp()`, `StoreError`.
- Produces (later tasks rely on these exact signatures):
  - `public struct Store.ActionItem { id: Int64, snapshotId: Int64, text: String, done: Bool, createdAt: String, doneAt: String? }`
  - `public func replaceActionItems(snapshotId: Int64, texts: [String]) throws`
  - `public func actionItems(snapshotId: Int64) throws -> [ActionItem]`
  - `public func allActionItems(includeDone: Bool) throws -> [(item: ActionItem, meetingTitle: String)]`
  - `public func setActionItemDone(id: Int64, done: Bool) throws`
  - `public func openActionItemCount() throws -> Int`
  - `public func meetingIdsWithoutActionItems() throws -> [Int64]`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/SmritiKitTests/StoreTests.swift` (inside the class):

```swift
    // MARK: - Action items

    /// Insert a meeting snapshot and return its id.
    private func insertMeeting(
        title: String = "Zoom 2026-07-06 14:00 (30 min)",
        content: String = "## Summary\n\nTalked.\n\n### Action items\n- Ship it\n\n---\n\ntranscript"
    ) throws -> Int64 {
        try store.upsert(
            app: "Meeting", bundleId: "sh.smriti.meeting",
            windowTitle: title, content: content)
        return try XCTUnwrap(store.listMeetings(limit: 1).first?.id)
    }

    func testReplaceAndListActionItems() throws {
        let id = try insertMeeting()
        try store.replaceActionItems(snapshotId: id, texts: ["Ship it", "Email Bob"])
        let items = try store.actionItems(snapshotId: id)
        XCTAssertEqual(items.map(\.text), ["Ship it", "Email Bob"])
        XCTAssertTrue(items.allSatisfy { !$0.done && $0.doneAt == nil })
    }

    func testReplaceActionItemsIsIdempotent() throws {
        let id = try insertMeeting()
        try store.replaceActionItems(snapshotId: id, texts: ["Ship it"])
        try store.replaceActionItems(snapshotId: id, texts: ["Ship it"])
        XCTAssertEqual(try store.actionItems(snapshotId: id).count, 1)
    }

    func testSetActionItemDoneTogglesDoneAt() throws {
        let id = try insertMeeting()
        try store.replaceActionItems(snapshotId: id, texts: ["Ship it"])
        let item = try XCTUnwrap(store.actionItems(snapshotId: id).first)
        try store.setActionItemDone(id: item.id, done: true)
        var reread = try XCTUnwrap(store.actionItems(snapshotId: id).first)
        XCTAssertTrue(reread.done)
        XCTAssertNotNil(reread.doneAt)
        try store.setActionItemDone(id: item.id, done: false) // un-check clears
        reread = try XCTUnwrap(store.actionItems(snapshotId: id).first)
        XCTAssertFalse(reread.done)
        XCTAssertNil(reread.doneAt)
    }

    func testOpenActionItemCountAndAllItemsFilter() throws {
        let id = try insertMeeting()
        try store.replaceActionItems(snapshotId: id, texts: ["A", "B"])
        let first = try XCTUnwrap(store.actionItems(snapshotId: id).first)
        try store.setActionItemDone(id: first.id, done: true)
        XCTAssertEqual(try store.openActionItemCount(), 1)
        XCTAssertEqual(try store.allActionItems(includeDone: false).count, 1)
        XCTAssertEqual(try store.allActionItems(includeDone: true).count, 2)
        XCTAssertEqual(try store.allActionItems(includeDone: false).first?.meetingTitle,
                       "Zoom 2026-07-06 14:00 (30 min)")
    }

    func testMeetingIdsWithoutActionItems() throws {
        let a = try insertMeeting(title: "Meeting A", content: "content a")
        let b = try insertMeeting(title: "Meeting B", content: "content b")
        try store.replaceActionItems(snapshotId: a, texts: ["Ship it"])
        XCTAssertEqual(try store.meetingIdsWithoutActionItems(), [b])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter StoreTests 2>&1 | tail -20`
Expected: compile FAILURE — `replaceActionItems` etc. not defined on `Store`.

- [ ] **Step 3: Implement**

In `Store.swift` `init`, after the chronicles `CREATE TABLE` block (before the FTS block):

```swift
        try exec("""
            CREATE TABLE IF NOT EXISTS action_items (
                id          INTEGER PRIMARY KEY,
                snapshot_id INTEGER NOT NULL REFERENCES snapshots(id),
                text        TEXT NOT NULL,
                done        INTEGER NOT NULL DEFAULT 0,
                created_at  TEXT NOT NULL,
                done_at     TEXT
            );
            """)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_action_items_open
            ON action_items(done, snapshot_id);
            """)
```

New section after `listMeetings` (around line 290):

```swift
    // MARK: - Action items

    public struct ActionItem {
        public let id: Int64
        public let snapshotId: Int64
        public let text: String
        public let done: Bool
        public let createdAt: String
        public let doneAt: String?
    }

    /// Replace a meeting's extracted action items (delete + re-insert), so
    /// extraction is idempotent per snapshot.
    public func replaceActionItems(snapshotId: Int64, texts: [String]) throws {
        let del = try prepare("DELETE FROM action_items WHERE snapshot_id = ?;")
        defer { sqlite3_finalize(del) }
        sqlite3_bind_int64(del, 1, snapshotId)
        guard sqlite3_step(del) == SQLITE_DONE else {
            throw StoreError.stepFailed(message: lastErrorMessage())
        }
        for text in texts {
            let ins = try prepare("""
                INSERT INTO action_items (snapshot_id, text, done, created_at)
                VALUES (?, ?, 0, ?);
                """)
            defer { sqlite3_finalize(ins) }
            sqlite3_bind_int64(ins, 1, snapshotId)
            sqlite3_bind_text(ins, 2, text, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(ins, 3, Store.timestamp(), -1, SQLITE_TRANSIENT)
            guard sqlite3_step(ins) == SQLITE_DONE else {
                throw StoreError.stepFailed(message: lastErrorMessage())
            }
        }
    }

    /// One meeting's items, in extraction order.
    public func actionItems(snapshotId: Int64) throws -> [ActionItem] {
        let stmt = try prepare("""
            SELECT id, snapshot_id, text, done, created_at, done_at
            FROM action_items WHERE snapshot_id = ? ORDER BY id;
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, snapshotId)
        return readActionItems(stmt)
    }

    /// Items across all meetings joined with the meeting title, newest
    /// meeting first. `includeDone: false` returns only open items.
    public func allActionItems(includeDone: Bool) throws
        -> [(item: ActionItem, meetingTitle: String)] {
        let stmt = try prepare("""
            SELECT ai.id, ai.snapshot_id, ai.text, ai.done, ai.created_at, ai.done_at,
                   s.window_title
            FROM action_items ai JOIN snapshots s ON s.id = ai.snapshot_id
            WHERE ? OR ai.done = 0
            ORDER BY s.last_seen_at DESC, s.id DESC, ai.id ASC;
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, includeDone ? 1 : 0)
        var rows: [(item: ActionItem, meetingTitle: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append((readActionItem(stmt), columnText(stmt, 6) ?? ""))
        }
        return rows
    }

    public func setActionItemDone(id: Int64, done: Bool) throws {
        let stmt = try prepare(
            "UPDATE action_items SET done = ?, done_at = ? WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, done ? 1 : 0)
        if done {
            sqlite3_bind_text(stmt, 2, Store.timestamp(), -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        sqlite3_bind_int64(stmt, 3, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.stepFailed(message: lastErrorMessage())
        }
    }

    /// Open (not done) item count — for the hub's segment badge.
    public func openActionItemCount() throws -> Int {
        let stmt = try prepare("SELECT COUNT(*) FROM action_items WHERE done = 0;")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Meetings that have never had items extracted — backfill candidates.
    public func meetingIdsWithoutActionItems() throws -> [Int64] {
        let stmt = try prepare("""
            SELECT id FROM snapshots
            WHERE bundle_id = 'sh.smriti.meeting'
              AND id NOT IN (SELECT DISTINCT snapshot_id FROM action_items)
            ORDER BY id;
            """)
        defer { sqlite3_finalize(stmt) }
        var ids: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            ids.append(sqlite3_column_int64(stmt, 0))
        }
        return ids
    }

    private func readActionItems(_ stmt: OpaquePointer?) -> [ActionItem] {
        var rows: [ActionItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(readActionItem(stmt))
        }
        return rows
    }

    /// Columns must be: id, snapshot_id, text, done, created_at, done_at.
    private func readActionItem(_ stmt: OpaquePointer?) -> ActionItem {
        ActionItem(
            id: sqlite3_column_int64(stmt, 0),
            snapshotId: sqlite3_column_int64(stmt, 1),
            text: columnText(stmt, 2) ?? "",
            done: sqlite3_column_int(stmt, 3) != 0,
            createdAt: columnText(stmt, 4) ?? "",
            doneAt: columnText(stmt, 5))
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter StoreTests 2>&1 | tail -20`
Expected: all StoreTests PASS (existing + 5 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/SmritiKit/Store.swift Tests/SmritiKitTests/StoreTests.swift
git commit -m "✨ feat(store): action_items table with CRUD and backfill queries"
```

---

### Task 2: `ActionItems.parse` + `MeetingSummary.split`

**Files:**
- Create: `Sources/SmritiKit/ActionItems.swift`
- Modify: `Sources/SmritiKit/MeetingSummary.swift` (add `split`)
- Test: `Tests/SmritiKitTests/ActionItemsTests.swift` (create)

**Interfaces:**
- Consumes: nothing (pure string functions).
- Produces:
  - `enum ActionItems { static func parse(_ content: String) -> [String] }` (extract/backfill added in Task 3)
  - `MeetingSummary.split(_ content: String) -> (summary: String?, transcript: String)`

- [ ] **Step 1: Write the failing tests**

Create `Tests/SmritiKitTests/ActionItemsTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ActionItemsTests 2>&1 | tail -20`
Expected: compile FAILURE — `ActionItems` and `MeetingSummary.split` not defined.

- [ ] **Step 3: Implement**

Create `Sources/SmritiKit/ActionItems.swift`:

```swift
import Foundation

/// Extracts action items from a composed meeting summary (the markdown
/// `MeetingSummary.compose` prepends to transcripts) and persists them to
/// the `action_items` table so the hub can aggregate and check them off.
enum ActionItems {

    /// Bullets under the `### Action items` heading. Tolerates `-`, `*`, and
    /// numbered bullets; a lone "none" bullet, a missing heading, or
    /// malformed markdown all yield an empty list — never an error.
    static func parse(_ content: String) -> [String] {
        var items: [String] = []
        var inSection = false
        for raw in content.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                inSection = line.lowercased().hasSuffix("action items")
                continue
            }
            if line == "---" { inSection = false; continue }
            guard inSection, !line.isEmpty else { continue }

            var text: String?
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                text = String(line.dropFirst(2))
            } else if let r = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                text = String(line[r.upperBound...])
            }
            guard var t = text?.trimmingCharacters(in: .whitespaces), !t.isEmpty
            else { continue }
            t = t.replacingOccurrences(of: "**", with: "")
            let normalized = t.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if normalized == "none" { continue }
            items.append(t)
        }
        return items
    }
}
```

Append to `Sources/SmritiKit/MeetingSummary.swift` (inside the enum, after `compose`):

```swift
    /// Split composed content back into (summary, transcript). Content that
    /// wasn't composed (no "## Summary" prefix or no "---" rule) comes back
    /// as (nil, whole content) so the UI just shows a transcript.
    static func split(_ content: String) -> (summary: String?, transcript: String) {
        guard content.hasPrefix("## Summary"),
              let rule = content.range(of: "\n\n---\n\n") else {
            return (nil, content)
        }
        let afterHeading = content.index(content.startIndex, offsetBy: "## Summary".count)
        let summary = String(content[afterHeading..<rule.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let transcript = String(content[rule.upperBound...])
        return (summary.isEmpty ? nil : summary, transcript)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ActionItemsTests 2>&1 | tail -20`
Expected: all 10 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SmritiKit/ActionItems.swift Sources/SmritiKit/MeetingSummary.swift Tests/SmritiKitTests/ActionItemsTests.swift
git commit -m "✨ feat(meetings): action-item parser and summary/transcript splitter"
```

---

### Task 3: Extraction wiring — `extract`, `backfill`, three save lanes

**Files:**
- Modify: `Sources/SmritiKit/ActionItems.swift` (add `extract` + `backfill`)
- Modify: `Sources/SmritiKit/MeetingWatcher.swift:347-358` (`finalize`)
- Modify: `Sources/SmritiKit/MenuBarApp.swift:289-299` (`stopVoiceNote`)
- Modify: `Sources/SmritiKit/MeetingTranscription.swift:49-53` (`retranscribe`)
- Test: `Tests/SmritiKitTests/ActionItemsTests.swift`

**Interfaces:**
- Consumes: `Store.replaceActionItems`, `Store.meetingIdsWithoutActionItems`, `Store.getSnapshot`, `ActionItems.parse` (Tasks 1-2).
- Produces:
  - `ActionItems.extract(store: Store, snapshotId: Int64, content: String)` — non-throwing, logs to stderr on failure.
  - `ActionItems.backfill(store: Store)` — non-throwing.

- [ ] **Step 1: Write the failing tests**

Append to `ActionItemsTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ActionItemsTests 2>&1 | tail -20`
Expected: compile FAILURE — `extract`/`backfill` not defined.

- [ ] **Step 3: Implement extract + backfill**

Append inside `enum ActionItems` in `ActionItems.swift`:

```swift
    /// Parse `content` and persist the items for one meeting. Idempotent
    /// (delete + re-insert). Failures are logged, never thrown — extraction
    /// must not break the save path.
    static func extract(store: Store, snapshotId: Int64, content: String) {
        do {
            try store.replaceActionItems(snapshotId: snapshotId, texts: parse(content))
        } catch {
            fputs("smriti action-items: extract failed for #\(snapshotId): \(error)\n", stderr)
        }
    }

    /// One-time pass over meetings recorded before extraction existed. Only
    /// touches meetings with no extracted rows, so checked-off state on
    /// already-extracted meetings survives.
    static func backfill(store: Store) {
        guard let ids = try? store.meetingIdsWithoutActionItems(), !ids.isEmpty else { return }
        for id in ids {
            guard let snap = try? store.getSnapshot(id: id) else {
                fputs("smriti action-items: backfill skipped #\(id) (unreadable)\n", stderr)
                continue
            }
            extract(store: store, snapshotId: id, content: snap.content)
        }
        fputs("smriti action-items: backfill scanned \(ids.count) meeting(s)\n", stderr)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ActionItemsTests 2>&1 | tail -20`
Expected: all PASS.

- [ ] **Step 5: Wire the three save lanes**

`MeetingWatcher.swift` `finalize()` — inside the `do` block, after `try store.upsert(...)` and before the `fputs("smriti meetings: transcript stored…")` line:

```swift
                if let id = (try? store.listMeetings(limit: 1))?.first?.id {
                    ActionItems.extract(store: store, snapshotId: id, content: transcript)
                }
```

`MenuBarApp.swift` `stopVoiceNote()` — same pattern, after `try store.upsert(...)` and before the `fputs("smriti voice-note: stored…")` line:

```swift
                if let id = (try? store.listMeetings(limit: 1))?.first?.id {
                    ActionItems.extract(store: store, snapshotId: id, content: transcript)
                }
```

`MeetingTranscription.swift` `retranscribe` — after `try store.updateContent(id: row.id, content: transcript)`:

```swift
        ActionItems.extract(store: store, snapshotId: row.id, content: transcript)
```

- [ ] **Step 6: Build + full test run**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -5`
Expected: build ok, all tests PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/SmritiKit/ActionItems.swift Sources/SmritiKit/MeetingWatcher.swift Sources/SmritiKit/MenuBarApp.swift Sources/SmritiKit/MeetingTranscription.swift Tests/SmritiKitTests/ActionItemsTests.swift
git commit -m "✨ feat(meetings): extract action items on save, with backfill for old meetings"
```

---

### Task 4: `MasterDetailSection` — pluggable detail view + row selection API

**Files:**
- Modify: `Sources/SmritiKit/MainWindow.swift` (`MasterDetailSection`, ~lines 228-537)

**Interfaces:**
- Consumes: nothing new.
- Produces (Tasks 6-7 rely on):
  - `var detailProvider: ((Int) -> NSView?)?` — return a custom detail view for a row index, or nil for the default text rendering.
  - `func selectRow(_ index: Int)` — programmatic list selection (for jump-to-meeting).
- Behavior contract: with `detailProvider == nil` everything renders exactly as today (Chronicles must be unchanged).

- [ ] **Step 1: Add the detail container and provider**

In `MasterDetailSection`, add properties (near `private let text = NSTextView()`):

```swift
    /// When set, a row can supply its own detail view (used by Meetings for
    /// the structured meeting detail). Return nil to fall back to the default
    /// title + markdown text rendering.
    var detailProvider: ((Int) -> NSView?)?
    private let detailContainer = NSView()
    private var textScroll: NSScrollView?
```

In `makeView()`, replace:

```swift
        let textScroll = MasterDetailSection.makeTextScroll(text,
            frame: NSRect(x: 261, y: 0, width: 478, height: 620))
        textScroll.autoresizingMask = [.width, .height]

        split.addSubview(listScroll)
        split.addSubview(textScroll)
```

with:

```swift
        let scroll = MasterDetailSection.makeTextScroll(text,
            frame: NSRect(x: 261, y: 0, width: 478, height: 620))
        scroll.autoresizingMask = [.width, .height]
        textScroll = scroll
        detailContainer.frame = scroll.frame
        detailContainer.autoresizingMask = [.width, .height]
        setDetail(scroll)

        split.addSubview(listScroll)
        split.addSubview(detailContainer)
```

Add helper methods (near `reloadRows`):

```swift
    /// Swap the right-hand detail area's content.
    private func setDetail(_ v: NSView) {
        guard v.superview !== detailContainer else { return }
        detailContainer.subviews.forEach { $0.removeFromSuperview() }
        v.frame = detailContainer.bounds
        v.autoresizingMask = [.width, .height]
        detailContainer.addSubview(v)
    }

    /// Select a list row programmatically (used by jump-to-meeting).
    func selectRow(_ index: Int) {
        guard index >= 0, index < rows.count else { return }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
    }
```

- [ ] **Step 2: Route selection through the provider**

Replace `tableViewSelectionDidChange`:

```swift
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0, table.selectedRow < rows.count else { return }
        if let provider = detailProvider, let custom = provider(table.selectedRow) {
            setDetail(custom)
            return
        }
        if let textScroll { setDetail(textScroll) }
        let row = rows[table.selectedRow]
        let doc = NSMutableAttributedString()
        doc.append(MarkdownRenderer.caption(row.title))
        doc.append(MarkdownRenderer.attributed(row.body))
        text.textStorage?.setAttributedString(doc)
        text.scrollToBeginningOfDocument(nil)
    }
```

In `reloadRows()`, the empty branch must restore the text view:

```swift
        } else {
            if let textScroll { setDetail(textScroll) }
            text.string = emptyMessage
        }
```

- [ ] **Step 3: Build and verify no behavior change**

Run: `swift build 2>&1 | tail -5`
Expected: ok. (No provider is set anywhere yet — Chronicles and Meetings render as before.)

- [ ] **Step 4: Commit**

```bash
git add Sources/SmritiKit/MainWindow.swift
git commit -m "🔄 refactor(ui): MasterDetailSection gains pluggable detail view + selectRow"
```

---

### Task 5: `AudioPlayerBar`

**Files:**
- Create: `Sources/SmritiKit/AudioPlayerBar.swift`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces (Task 6 relies on):
  - `final class AudioPlayerBar: NSView`
  - `init(directory: URL)` — loads `them.caf` + `me.caf` (whichever exist) asynchronously.
  - `var onUnavailable: (() -> Void)?` — fired on main when nothing playable; owner hides the bar.
  - `func stop()` — pause + release the player.

- [ ] **Step 1: Implement**

Create `Sources/SmritiKit/AudioPlayerBar.swift`:

```swift
import AppKit
import AVFoundation

/// Playback bar for a meeting's saved audio. Merges the saved tracks
/// (them.caf + me.caf, or just me.caf for voice notes) into one
/// AVMutableComposition so both sides play together, the way the call
/// sounded. Calls `onUnavailable` when the directory holds nothing playable.
final class AudioPlayerBar: NSView {

    /// Fired on the main thread when no playable audio was found — the owner
    /// should hide the bar. No error dialogs.
    var onUnavailable: (() -> Void)?

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var desiredRate: Float = 1.0
    private var durationSeconds: Double = 0

    private let playButton = NSButton()
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1,
                                  target: nil, action: nil)
    private let timeLabel = NSTextField(labelWithString: "0:00 / 0:00")
    private let rateButton = NSButton()

    init(directory: URL) {
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 32))
        buildControls()
        setEnabled(false)
        Task { await load(directory) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { stop() }

    /// Pause and release the player (called when the selected row changes or
    /// the user leaves the Meetings section).
    func stop() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        player = nil
        playButton.title = "▶"
    }

    // MARK: - Controls

    private func buildControls() {
        playButton.title = "▶"
        playButton.bezelStyle = .texturedRounded
        playButton.target = self
        playButton.action = #selector(togglePlay)

        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.isContinuous = true

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor

        rateButton.title = "1×"
        rateButton.bezelStyle = .texturedRounded
        rateButton.target = self
        rateButton.action = #selector(cycleRate)

        let stack = NSStackView(views: [playButton, slider, timeLabel, rateButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.frame = bounds
        stack.autoresizingMask = [.width, .height]
        addSubview(stack)
    }

    private func setEnabled(_ enabled: Bool) {
        playButton.isEnabled = enabled
        slider.isEnabled = enabled
        rateButton.isEnabled = enabled
    }

    // MARK: - Loading

    private func load(_ directory: URL) async {
        let candidates = ["them.caf", "me.caf"]
            .map { directory.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let composition = AVMutableComposition()
        for url in candidates {
            let asset = AVURLAsset(url: url)
            guard let tracks = try? await asset.load(.tracks),
                  let duration = try? await asset.load(.duration) else { continue }
            for track in tracks where track.mediaType == .audio {
                let dest = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                try? dest?.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
            }
        }
        guard !composition.tracks.isEmpty else {
            fputs("smriti player: no playable audio in \(directory.path)\n", stderr)
            await MainActor.run { onUnavailable?() }
            return
        }
        let item = AVPlayerItem(asset: composition)
        let total = CMTimeGetSeconds(composition.duration)
        await MainActor.run {
            let player = AVPlayer(playerItem: item)
            self.player = player
            self.durationSeconds = total.isFinite ? total : 0
            self.slider.maxValue = max(1, self.durationSeconds)
            self.updateTimeLabel(0)
            self.setEnabled(true)
            self.timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 4), queue: .main
            ) { [weak self] t in
                guard let self else { return }
                let secs = CMTimeGetSeconds(t)
                self.slider.doubleValue = secs
                self.updateTimeLabel(secs)
                if self.durationSeconds > 0, secs >= self.durationSeconds - 0.1 {
                    self.playButton.title = "▶" // reached the end
                }
            }
        }
    }

    // MARK: - Actions

    @objc private func togglePlay() {
        guard let player else { return }
        if player.rate > 0 {
            player.pause()
            playButton.title = "▶"
        } else {
            if durationSeconds > 0,
               CMTimeGetSeconds(player.currentTime()) >= durationSeconds - 0.1 {
                player.seek(to: .zero) // replay from the start
            }
            player.rate = desiredRate
            playButton.title = "⏸"
        }
    }

    @objc private func sliderMoved() {
        player?.seek(to: CMTime(seconds: slider.doubleValue, preferredTimescale: 600))
    }

    @objc private func cycleRate() {
        desiredRate = desiredRate >= 2.0 ? 1.0 : desiredRate + 0.5
        rateButton.title = desiredRate == 1.0 ? "1×"
            : String(format: "%g×", desiredRate)
        if let player, player.rate > 0 { player.rate = desiredRate }
    }

    private func updateTimeLabel(_ current: Double) {
        func fmt(_ s: Double) -> String {
            let v = max(0, Int(s))
            return String(format: "%d:%02d", v / 60, v % 60)
        }
        timeLabel.stringValue = "\(fmt(current)) / \(fmt(durationSeconds))"
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -5`
Expected: ok. (Not wired into UI yet — manual verification happens in Task 6.)

- [ ] **Step 3: Commit**

```bash
git add Sources/SmritiKit/AudioPlayerBar.swift
git commit -m "✨ feat(meetings): audio player bar merging saved call tracks"
```

---

### Task 6: `MeetingDetailView` + MainWindow wiring

**Files:**
- Create: `Sources/SmritiKit/MeetingDetailView.swift`
- Modify: `Sources/SmritiKit/MainWindow.swift` (meetings loader ~line 28, `init` ~line 57, `selectSection` ~line 152)

**Interfaces:**
- Consumes: `Store.actionItems`, `Store.setActionItemDone` (Task 1); `MeetingSummary.split` (Task 2); `MasterDetailSection.detailProvider` (Task 4); `AudioPlayerBar` (Task 5); existing `MarkdownRenderer.attributed`, `Theme`, `ThemedView`.
- Produces (Task 7 relies on):
  - `final class MeetingDetailView: NSView`
  - `init(store: Store, onItemsChanged: @escaping () -> Void)`
  - `func show(snapshot: Store.Snapshot)`
  - `func stopPlayback()`
  - MainWindow gains `private var meetingSnapshots: [Store.Snapshot]` cache populated by the meetings loader.

- [ ] **Step 1: Implement MeetingDetailView**

Create `Sources/SmritiKit/MeetingDetailView.swift`:

```swift
import AppKit

/// Structured detail view for one meeting: metadata header, summary card,
/// this meeting's action items with checkboxes, an audio player bar, and the
/// transcript collapsed behind a disclosure. Replaces the plain markdown blob
/// in the Meetings pane's right side.
final class MeetingDetailView: NSView {

    private let store: Store
    /// Called after an item is checked/unchecked (owner refreshes the badge).
    private let onItemsChanged: () -> Void

    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private var playerBar: AudioPlayerBar?
    private var transcriptField: NSTextField?
    private var transcriptButton: NSButton?

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    init(store: Store, onItemsChanged: @escaping () -> Void) {
        self.store = store
        self.onItemsChanged = onItemsChanged
        super.init(frame: NSRect(x: 0, y: 0, width: 478, height: 620))

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)

        scroll.frame = bounds
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = doc
        addSubview(scroll)

        NSLayoutConstraint.activate([
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func stopPlayback() { playerBar?.stop() }

    /// Rebuild the view for a meeting snapshot.
    func show(snapshot: Store.Snapshot) {
        playerBar?.stop()
        playerBar = nil
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // 1. Metadata header — the stored title already carries app + time +
        // duration ("Zoom 2026-07-06 14:30 (32 min)").
        let title = NSTextField(labelWithString: snapshot.windowTitle)
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.textColor = Theme.ink
        title.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(title)

        // 2. Player bar — only when the stored url resolves to saved audio.
        if let dir = URL(string: snapshot.url), dir.isFileURL,
           FileManager.default.fileExists(atPath: dir.path) {
            let bar = AudioPlayerBar(directory: dir)
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.heightAnchor.constraint(equalToConstant: 32).isActive = true
            bar.onUnavailable = { [weak bar] in bar?.isHidden = true }
            stack.addArrangedSubview(bar)
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
            playerBar = bar
        }

        let (summary, transcript) = MeetingSummary.split(snapshot.content)

        // 3. Summary card.
        if let summary {
            let card = ThemedView(frame: .zero)
            card.fillColor = Theme.surface
            card.translatesAutoresizingMaskIntoConstraints = false
            let body = NSTextField(wrappingLabelWithString: "")
            body.attributedStringValue = MarkdownRenderer.attributed(summary)
            body.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(body)
            NSLayoutConstraint.activate([
                body.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
                body.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
                body.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
                body.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            ])
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        }

        // 4. This meeting's action items, checkable inline.
        let items = (try? store.actionItems(snapshotId: snapshot.id)) ?? []
        if !items.isEmpty {
            let header = NSTextField(labelWithString: "Action items")
            header.font = .systemFont(ofSize: 12, weight: .semibold)
            header.textColor = .secondaryLabelColor
            stack.addArrangedSubview(header)
            for item in items {
                let box = NSButton(checkboxWithTitle: item.text,
                                   target: self, action: #selector(toggleItem(_:)))
                box.state = item.done ? .on : .off
                box.tag = Int(item.id)
                box.lineBreakMode = .byWordWrapping
                stack.addArrangedSubview(box)
                box.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
            }
        }

        // 5. Transcript, collapsed by default.
        let disclose = NSButton(title: "Show transcript", target: self,
                                action: #selector(toggleTranscript))
        disclose.bezelStyle = .inline
        stack.addArrangedSubview(disclose)
        transcriptButton = disclose

        let body = NSTextField(wrappingLabelWithString: "")
        body.attributedStringValue = MarkdownRenderer.attributed(transcript)
        body.isHidden = true
        stack.addArrangedSubview(body)
        body.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        transcriptField = body

        scroll.contentView.scroll(to: .zero)
    }

    @objc private func toggleItem(_ sender: NSButton) {
        let done = sender.state == .on
        do {
            try store.setActionItemDone(id: Int64(sender.tag), done: done)
            onItemsChanged()
        } catch {
            sender.state = done ? .off : .on // revert — write failed
            fputs("smriti action-items: toggle failed for #\(sender.tag): \(error)\n", stderr)
        }
    }

    @objc private func toggleTranscript() {
        guard let transcriptField else { return }
        transcriptField.isHidden.toggle()
        transcriptButton?.title = transcriptField.isHidden
            ? "Show transcript" : "Hide transcript"
    }
}
```

- [ ] **Step 2: Wire into MainWindow**

In `MainWindow`, add properties (near `private var currentView`):

```swift
    /// Snapshot cache backing the Meetings list — keeps the detail provider
    /// index-aligned with the loader's (title, body) rows.
    private var meetingSnapshots: [Store.Snapshot] = []
    private lazy var meetingDetailView = MeetingDetailView(
        store: store, onItemsChanged: {})
```

*(The `onItemsChanged` closure is wired to the segment badge in Task 7; `{}` keeps this task self-contained and building.)*

Change the meetings loader to cache snapshots:

```swift
    private lazy var meetingsSection = MasterDetailSection(
        title: "Meetings", symbol: "waveform",
        empty: "No recordings yet. Click “Record voice note” above to capture and transcribe one, or Smriti will ask before recording a call.",
        loader: { [weak self, store] in
            let snaps = (try? store.listMeetings(limit: 200)) ?? []
            self?.meetingSnapshots = snaps
            return snaps.map { ($0.windowTitle, $0.content) }
        })
```

In `init`, after the `recordControls` assignment, set the provider:

```swift
        meetingsSection.detailProvider = { [weak self] index in
            guard let self, index >= 0, index < self.meetingSnapshots.count
            else { return nil }
            self.meetingDetailView.show(snapshot: self.meetingSnapshots[index])
            return self.meetingDetailView
        }
```

In `selectSection(_:)` (~line 152), stop playback when leaving the pane — add as the first line of the method body:

```swift
        meetingDetailView.stopPlayback()
```

- [ ] **Step 3: Build + manual verification**

Run: `swift build 2>&1 | tail -5` — expected ok.
Then: `Scripts/build-app.sh` and launch; open Meetings; verify:
- Selecting a meeting shows title, summary card (when one exists), checkboxes, "Show transcript".
- A voice note recorded now shows a player bar; play/pause/scrub/speed work.
- A legacy meeting without saved audio shows no bar.
- Chronicles pane unchanged.

- [ ] **Step 4: Commit**

```bash
git add Sources/SmritiKit/MeetingDetailView.swift Sources/SmritiKit/MainWindow.swift
git commit -m "✨ feat(meetings): structured meeting detail view with playback and checkable items"
```

---

### Task 7: Action-items hub — `ActionItemsView` + `MeetingsSection` segment

**Files:**
- Create: `Sources/SmritiKit/ActionItemsView.swift`
- Create: `Sources/SmritiKit/MeetingsSection.swift`
- Modify: `Sources/SmritiKit/MainWindow.swift` (rename `meetingsSection`→`meetingsList`, add wrapper, wire badge)

**Interfaces:**
- Consumes: `Store.allActionItems`, `Store.setActionItemDone`, `Store.openActionItemCount` (Task 1); `ActionItems.backfill` (Task 3); `MasterDetailSection.selectRow` + `detailProvider` (Task 4); `MeetingDetailView` (Task 6); `MainSection` protocol.
- Produces:
  - `final class ActionItemsView: NSView` — `init(store: Store, jumpToMeeting: @escaping (Int64) -> Void, onCountChanged: @escaping () -> Void)`, `func refresh()`.
  - `final class MeetingsSection: NSObject, MainSection` — `init(store: Store, list: MasterDetailSection, rowForSnapshot: @escaping (Int64) -> Int?)`, `func reloadRows()`, `func reloadBadge()`, `func showMeetings(selecting snapshotId: Int64)`.

- [ ] **Step 1: Implement ActionItemsView**

Create `Sources/SmritiKit/ActionItemsView.swift`:

```swift
import AppKit

/// The action-items hub: open items from every meeting in one checkable
/// list, grouped by source meeting (newest first). Check-off only — no
/// manual add, no edit. Lives behind the "Action items" segment of the
/// Meetings pane.
final class ActionItemsView: NSView {

    private let store: Store
    private let jumpToMeeting: (Int64) -> Void
    /// Called after any toggle so the owner can refresh the segment badge.
    private let onCountChanged: () -> Void

    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let showCompleted = NSButton(checkboxWithTitle: "Show completed",
                                         target: nil, action: nil)

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    init(store: Store, jumpToMeeting: @escaping (Int64) -> Void,
         onCountChanged: @escaping () -> Void) {
        self.store = store
        self.jumpToMeeting = jumpToMeeting
        self.onCountChanged = onCountChanged
        super.init(frame: NSRect(x: 0, y: 0, width: 739, height: 572))

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)

        let footerHeight: CGFloat = 36
        scroll.frame = NSRect(x: 0, y: footerHeight, width: 739,
                              height: bounds.height - footerHeight)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = doc
        addSubview(scroll)

        NSLayoutConstraint.activate([
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])

        showCompleted.target = self
        showCompleted.action = #selector(refreshAction)
        showCompleted.frame = NSRect(x: 24, y: 8, width: 200, height: 20)
        showCompleted.autoresizingMask = [.maxXMargin, .maxYMargin]
        addSubview(showCompleted)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func refreshAction() { refresh() }

    /// Re-query and rebuild the grouped list.
    func refresh() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let rows = (try? store.allActionItems(
            includeDone: showCompleted.state == .on)) ?? []

        guard !rows.isEmpty else {
            let empty = NSTextField(wrappingLabelWithString:
                "No action items yet. They're extracted automatically from meeting summaries — record a call or a voice note and they'll land here.")
            empty.textColor = .secondaryLabelColor
            stack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
            return
        }

        // Group consecutive rows by meeting (query is ordered by meeting).
        var groups: [(id: Int64, title: String, items: [Store.ActionItem])] = []
        for (item, title) in rows {
            if let last = groups.indices.last, groups[last].id == item.snapshotId {
                groups[last].items.append(item)
            } else {
                groups.append((item.snapshotId, title, [item]))
            }
        }

        for group in groups {
            let header = NSButton(title: group.title, target: self,
                                  action: #selector(jump(_:)))
            header.isBordered = false
            header.contentTintColor = .linkColor
            header.font = .systemFont(ofSize: 12, weight: .semibold)
            header.tag = Int(group.id)
            stack.addArrangedSubview(header)
            for item in group.items {
                let box = NSButton(checkboxWithTitle: item.text,
                                   target: self, action: #selector(toggle(_:)))
                box.state = item.done ? .on : .off
                box.tag = Int(item.id)
                box.lineBreakMode = .byWordWrapping
                stack.addArrangedSubview(box)
                box.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -64).isActive = true
            }
        }
    }

    @objc private func jump(_ sender: NSButton) {
        jumpToMeeting(Int64(sender.tag))
    }

    @objc private func toggle(_ sender: NSButton) {
        let done = sender.state == .on
        do {
            try store.setActionItemDone(id: Int64(sender.tag), done: done)
            onCountChanged()
        } catch {
            sender.state = done ? .off : .on
            fputs("smriti action-items: toggle failed for #\(sender.tag): \(error)\n", stderr)
        }
    }
}
```

- [ ] **Step 2: Implement MeetingsSection**

Create `Sources/SmritiKit/MeetingsSection.swift`:

```swift
import AppKit

/// The Meetings pane: a "Meetings | Action items" segmented control that
/// swaps between the recordings master-detail list and the action-items hub.
/// Wraps the existing MasterDetailSection untouched.
final class MeetingsSection: NSObject, MainSection {

    let title = "Meetings"
    let symbol = "waveform"

    private let store: Store
    /// The recordings list (record controls + detail provider live on it).
    let list: MasterDetailSection
    /// Maps a snapshot id to its current list row (owned by MainWindow,
    /// which holds the snapshot cache).
    private let rowForSnapshot: (Int64) -> Int?

    private lazy var hub = ActionItemsView(
        store: store,
        jumpToMeeting: { [weak self] id in self?.showMeetings(selecting: id) },
        onCountChanged: { [weak self] in self?.reloadBadge() })

    private let segment = NSSegmentedControl(
        labels: ["Meetings", "Action items"], trackingMode: .selectOne,
        target: nil, action: nil)
    private var view: NSView?
    private let container = NSView()
    private var didBackfill = false
    private static let headerHeight: CGFloat = 44

    init(store: Store, list: MasterDetailSection,
         rowForSnapshot: @escaping (Int64) -> Int?) {
        self.store = store
        self.list = list
        self.rowForSnapshot = rowForSnapshot
    }

    func makeView() -> NSView {
        if let view { return view }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 739, height: 620))

        segment.target = self
        segment.action = #selector(segmentChanged)
        segment.selectedSegment = 0
        segment.sizeToFit()
        segment.frame.origin = NSPoint(x: 12, y: 620 - MeetingsSection.headerHeight + 8)
        segment.autoresizingMask = [.minYMargin]
        root.addSubview(segment)

        container.frame = NSRect(x: 0, y: 0, width: 739,
                                 height: 620 - MeetingsSection.headerHeight)
        container.autoresizingMask = [.width, .height]
        root.addSubview(container)

        setContent(list.makeView())
        view = root
        return root
    }

    func willAppear() {
        if segment.selectedSegment == 1 { hub.refresh() } else { list.willAppear() }
        backfillOnce()
        reloadBadge()
    }

    /// Re-read both the list and (when visible) the hub — the owner calls
    /// this after a voice note finishes transcribing.
    func reloadRows() {
        list.reloadRows()
        if segment.selectedSegment == 1 { hub.refresh() }
        reloadBadge()
    }

    /// Refresh the open-item count on the segment label.
    func reloadBadge() {
        let n = (try? store.openActionItemCount()) ?? 0
        segment.setLabel(n > 0 ? "Action items · \(n)" : "Action items",
                         forSegment: 1)
    }

    /// Jump from the hub to a specific meeting's detail.
    func showMeetings(selecting snapshotId: Int64) {
        segment.selectedSegment = 0
        setContent(list.makeView())
        list.reloadRows()
        if let row = rowForSnapshot(snapshotId) { list.selectRow(row) }
    }

    @objc private func segmentChanged() {
        if segment.selectedSegment == 1 {
            setContent(hub)
            hub.refresh()
        } else {
            setContent(list.makeView())
            list.reloadRows()
        }
        reloadBadge()
    }

    private func setContent(_ v: NSView) {
        guard v.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        v.frame = container.bounds
        v.autoresizingMask = [.width, .height]
        container.addSubview(v)
    }

    /// Parse action items out of meetings recorded before extraction
    /// existed. One pass, off the main thread, badge refreshed after.
    private func backfillOnce() {
        guard !didBackfill else { return }
        didBackfill = true
        DispatchQueue.global(qos: .utility).async { [store] in
            ActionItems.backfill(store: store)
            DispatchQueue.main.async { [weak self] in
                self?.reloadBadge()
                if self?.segment.selectedSegment == 1 { self?.hub.refresh() }
            }
        }
    }
}
```

- [ ] **Step 3: Rewire MainWindow**

In `MainWindow`:

1. Rename the existing lazy `meetingsSection` (the `MasterDetailSection` with the meetings loader) to `meetingsList` — loader and empty text stay identical.
2. Add the wrapper:

```swift
    private lazy var meetingsSection = MeetingsSection(
        store: store, list: meetingsList,
        rowForSnapshot: { [weak self] id in
            self?.meetingSnapshots.firstIndex { $0.id == id }
        })
```

3. Update references:
- `sections` array entry stays `meetingsSection` (now the `MeetingsSection`).
- `reloadMeetings()` stays `meetingsSection.reloadRows()` (same call, new type).
- In `init`: `recordControls` and `detailProvider` are set on `meetingsList` instead of `meetingsSection`.
- `meetingDetailView`'s `onItemsChanged` (Task 6's `{}`) becomes:

```swift
    private lazy var meetingDetailView = MeetingDetailView(
        store: store,
        onItemsChanged: { [weak self] in self?.meetingsSection.reloadBadge() })
```

- [ ] **Step 4: Build + manual verification**

Run: `swift build 2>&1 | tail -5` — expected ok.
Then `Scripts/build-app.sh`, launch, verify:
- Meetings pane shows the segmented control; badge shows open count after backfill.
- Hub lists items grouped by meeting; checking one updates the badge.
- Clicking a meeting title jumps to that meeting's detail.
- "Show completed" reveals done items; un-checking one reopens it.
- Record voice note flow still works (record bar + visualizer intact).

- [ ] **Step 5: Commit**

```bash
git add Sources/SmritiKit/ActionItemsView.swift Sources/SmritiKit/MeetingsSection.swift Sources/SmritiKit/MainWindow.swift
git commit -m "✨ feat(meetings): action-items hub with segment badge and jump-to-meeting"
```

---

### Task 8: CHANGELOG, full verify, PR

**Files:**
- Modify: `CHANGELOG.md` (new entry at the top of `## Unreleased`)

**Interfaces:** none — verification and documentation.

- [ ] **Step 1: CHANGELOG entry**

Add at the top of the `## Unreleased` section:

```markdown
- **Meeting intelligence: action-items hub, audio playback, structured detail.**
  The Meetings pane gains a "Meetings | Action items" switch. Action items are
  parsed out of each meeting's generated summary into a checkable list grouped
  by meeting (newest first, open count on the segment label, click-through to
  the source meeting); items from meetings recorded before this feature are
  backfilled on first open. Selecting a meeting now shows a structured detail
  view — title, summary card, that meeting's items inline, and the transcript
  collapsed behind "Show transcript" — instead of one long text blob. Saved
  recordings finally play: a player bar merges the call's two tracks
  (`them.caf` + `me.caf`) so both sides play together, with scrubbing and
  1×/1.5×/2× speed. Check-off only by design — no manual items, no due dates.
```

- [ ] **Step 2: Full test + build + app run**

```bash
swift test 2>&1 | tail -5
swift build 2>&1 | tail -5
Scripts/build-app.sh
```
Expected: all tests pass, build ok, app launches. Manual sweep: record a
voice note end-to-end → item appears in hub → check it off → relaunch →
state persisted. Chronicles pane unchanged.

- [ ] **Step 3: Commit + PR**

```bash
git add CHANGELOG.md
git commit -m "📝 docs(changelog): meeting intelligence"
git push -u origin feat/meeting-intelligence
gh pr create --base main --head feat/meeting-intelligence --title "✨ feat(meetings): action-items hub, audio playback, structured detail view"
```

PR body: summarize from the CHANGELOG entry + link the spec. Never push to `main` directly.
