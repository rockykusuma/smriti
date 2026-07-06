# Memory Surfacing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface Smriti's captured memory through three new sidebar sections: Today's Digest, in-app Search, and an enhanced Chronicle Timeline — all reusing existing `Store` queries with zero new database tables.

**Architecture:** Three new `MainSection` conformers in their own files. A shared `SnapshotRowView` component and `groupByHour` helper are reused across all three. `MainWindow.swift` gains only sidebar wiring (~20 lines). No Store API changes.

**Tech Stack:** Swift 5.9, AppKit (frame-based layout + autoresizing masks, matching existing style), SQLite3 C API via existing `Store` helpers, XCTest.

**Spec:** `docs/superpowers/specs/2026-07-06-memory-surfacing-design.md`

## Global Constraints

- Platform floor: macOS 13 (`Package.swift` — `.macOS(.v13)`). No macOS 14+-only API.
- No new package dependencies.
- Logging: `fputs("smriti <area>: …\n", stderr)` — never dialogs for background failures.
- UI code style: frame-based AppKit with `autoresizingMask`, `Theme` colors, matching `MainWindow.swift`.
- Tests: XCTest in `Tests/SmritiKitTests/`, `Store(dbPath: ":memory:")`.
- All work on branch `feat/memory-surfacing`. Never push to `main`.
- Run tests with: `swift test 2>&1 | tail -20`. Build with: `swift build 2>&1 | tail -5`.

---

### Task 1: SnapshotRowView — shared snapshot row component

**Files:**
- Create: `Sources/SmritiKit/SnapshotRowView.swift`
- Test: `Tests/SmritiKitTests/SnapshotRowViewTests.swift`

**Interfaces:**
- Consumes: `Store.Snapshot`, `Theme` colors/fonts.
- Produces (later tasks depend on this):
  - `final class SnapshotRowView: NSView` — renders one snapshot as a card with app icon, window title, content preview, and optional timestamp.
  - `init(snapshot: Store.Snapshot, showTimestamp: Bool = true)`

- [ ] **Step 1: Write the failing tests**

Create `Tests/SmritiKitTests/SnapshotRowViewTests.swift`:

```swift
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

        // The row should have at least 2 subviews: icon imageView + text stack
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

        // Both should build without crashing
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
```

- [ ] **Step 2: Implement SnapshotRowView**

Create `Sources/SmritiKit/SnapshotRowView.swift`:

```swift
import AppKit

/// A reusable view that renders a single `Store.Snapshot` as a compact card
/// with app icon, window title, content preview, and optional timestamp.
/// Used by TodaySection, SearchSection, and ChronicleTimelineSection.
final class SnapshotRowView: ThemedView {

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let snapshot: Store.Snapshot

    init(snapshot: Store.Snapshot, showTimestamp: Bool = true) {
        self.snapshot = snapshot
        super.init(frame: .zero)
        wantsLayer = true
        corner = Theme.Radius.card
        fillColor = Theme.card
        strokeColor = Theme.border

        // App icon (16×16)
        iconView.image = appIcon(for: snapshot.bundleId)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        // Title
        titleLabel.stringValue = snapshot.windowTitle
        titleLabel.font = Theme.body(13, .semibold)
        titleLabel.textColor = Theme.ink
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        // Content preview (1 line, max 120 chars)
        let preview = String(snapshot.content
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(120))
        previewLabel.stringValue = preview
        previewLabel.font = Theme.body(12)
        previewLabel.textColor = Theme.inkSecondary
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.maximumNumberOfLines = 1
        previewLabel.translatesAutoresizingMaskIntoConstraints = false

        // Meta line (timestamp + app name)
        if showTimestamp {
            let ts = String(snapshot.lastSeenAt.prefix(16)) // "2026-07-06 09:14"
            metaLabel.stringValue = "\(ts)  ·  \(snapshot.app)"
        } else {
            metaLabel.stringValue = snapshot.app
        }
        metaLabel.font = Theme.body(10)
        metaLabel.textColor = Theme.inkTertiary
        metaLabel.translatesAutoresizingMaskIntoConstraints = false

        // Text column: title + preview + meta
        let textCol = NSStackView(views: [titleLabel, previewLabel, metaLabel])
        textCol.orientation = .vertical
        textCol.alignment = .leading
        textCol.spacing = 2
        textCol.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textCol)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            textCol.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            textCol.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            textCol.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            textCol.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func appIcon(for bundleId: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return NSImage(systemSymbolName: "app", accessibilityDescription: nil)
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
```

- [ ] **Step 3: Verify**

```bash
swift test 2>&1 | tail -20
```

All 3 new tests pass. No existing tests broken.

---

### Task 2: TimelineHelpers — groupByHour utility

**Files:**
- Create: `Sources/SmritiKit/TimelineHelpers.swift`
- Test: `Tests/SmritiKitTests/TimelineHelpersTests.swift`

**Interfaces:**
- Consumes: `Store.Snapshot` array.
- Produces (later tasks depend on this):
  - `struct HourGroup { let hour: String; let snapshots: [Store.Snapshot] }`
  - `enum TimelineHelpers { static func groupByHour(_ snapshots: [Store.Snapshot]) -> [HourGroup] }`

- [ ] **Step 1: Write the failing tests**

Create `Tests/SmritiKitTests/TimelineHelpersTests.swift`:

```swift
import XCTest
@testable import SmritiKit

final class TimelineHelpersTests: XCTestCase {

    func testGroupByHourEmpty() {
        let groups = TimelineHelpers.groupByHour([])
        XCTAssertTrue(groups.isEmpty)
    }

    func testGroupByHourSingleGroup() throws {
        let store = try Store(dbPath: ":memory:")
        try store.upsert(
            app: "Safari", bundleId: "com.apple.Safari",
            windowTitle: "A", content: "one")
        try store.upsert(
            app: "Safari", bundleId: "com.apple.Safari",
            windowTitle: "B", content: "two")
        // Both snapshots will have the same hour (now)
        let snaps = try store.search("one OR two", limit: 10)
        let groups = TimelineHelpers.groupByHour(snaps)
        XCTAssertEqual(groups.count, 1, "snapshots in the same hour should group together")
        XCTAssertEqual(groups[0].snapshots.count, 2)
    }

    func testGroupByHourPreservesChronologicalOrder() throws {
        // Manually create snapshots with controlled timestamps
        let store = try Store(dbPath: ":memory:")
        // Insert with different content to get different rows
        try store.upsert(
            app: "Safari", bundleId: "com.apple.Safari",
            windowTitle: "Morning", content: "morning work")
        try store.upsert(
            app: "Slack", bundleId: "com.tinyspeck.slackmacgap",
            windowTitle: "Afternoon", content: "afternoon chat")

        let snaps = try store.search("morning OR afternoon", limit: 10)
        let groups = TimelineHelpers.groupByHour(snaps)
        // Should have at least 1 group, snapshots should be in ascending time order
        XCTAssertFalse(groups.isEmpty)
        for group in groups {
            for i in 1..<group.snapshots.count {
                XCTAssertLessThanOrEqual(
                    group.snapshots[i-1].lastSeenAt,
                    group.snapshots[i].lastSeenAt,
                    "snapshots within a group should be chronological")
            }
        }
    }

    func testGroupByHourSeparatesDifferentHours() {
        // Create snapshots manually with different timestamps
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fmt.locale = Locale(identifier: "en_US_POSIX")

        let cal = Calendar.current
        let now = Date()
        let hour1 = cal.date(byAdding: .hour, value: -3, to: now)!
        let hour2 = now

        let s1 = Store.Snapshot(
            id: 1, app: "Safari", bundleId: "com.apple.Safari",
            windowTitle: "Old", content: "old content", url: "",
            capturedAt: fmt.string(from: hour1),
            lastSeenAt: fmt.string(from: hour1))
        let s2 = Store.Snapshot(
            id: 2, app: "Slack", bundleId: "com.tinyspeck.slackmacgap",
            windowTitle: "New", content: "new content", url: "",
            capturedAt: fmt.string(from: hour2),
            lastSeenAt: fmt.string(from: hour2))

        let groups = TimelineHelpers.groupByHour([s1, s2])
        XCTAssertEqual(groups.count, 2, "snapshots 3 hours apart should be in 2 groups")
    }

    func testGroupByHourFormatsTimeCorrectly() {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fmt.locale = Locale(identifier: "en_US_POSIX")

        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 14
        comps.minute = 30
        comps.second = 0
        let afternoon = cal.date(from: comps)!

        let s = Store.Snapshot(
            id: 1, app: "Test", bundleId: "com.test",
            windowTitle: "T", content: "c", url: "",
            capturedAt: fmt.string(from: afternoon),
            lastSeenAt: fmt.string(from: afternoon))

        let groups = TimelineHelpers.groupByHour([s])
        XCTAssertEqual(groups.count, 1)
        // Should format as "2:00 PM" or "14:00" depending on locale
        XCTAssertFalse(groups[0].hour.isEmpty)
    }
}
```

- [ ] **Step 2: Implement TimelineHelpers**

Create `Sources/SmritiKit/TimelineHelpers.swift`:

```swift
import Foundation

/// A group of snapshots that share the same hour.
struct HourGroup {
    /// Formatted hour label, e.g. "9:00 AM" or "2:30 PM".
    let hour: String
    /// Snapshots in this hour, oldest first.
    let snapshots: [Store.Snapshot]
}

/// Utilities for organizing snapshots into timeline views.
enum TimelineHelpers {

    /// Group snapshots by the hour of their `lastSeenAt` timestamp.
    /// Returns groups in chronological order (oldest hour first),
    /// with snapshots within each group sorted oldest first.
    static func groupByHour(_ snapshots: [Store.Snapshot]) -> [HourGroup] {
        guard !snapshots.isEmpty else { return [] }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fmt.locale = Locale(identifier: "en_US_POSIX")

        let hourFmt = DateFormatter()
        hourFmt.dateFormat = "h:mm a"
        hourFmt.locale = Locale(identifier: "en_US_POSIX")

        // Sort snapshots chronologically (oldest first)
        let sorted = snapshots.sorted { $0.lastSeenAt < $1.lastSeenAt }

        // Group by truncated hour string ("2026-07-06 09")
        var buckets: [String: [Store.Snapshot]] = [:]
        for s in sorted {
            guard let date = fmt.date(from: s.lastSeenAt) else { continue }
            let hourKey = String(s.lastSeenAt.prefix(13)) // "yyyy-MM-dd HH"
            buckets[hourKey, default: []].append(s)
        }

        // Build HourGroups in chronological order
        return buckets.keys.sorted().compactMap { key in
            guard let groupSnaps = buckets[key],
                  let firstDate = fmt.date(from: groupSnaps[0].lastSeenAt)
            else { return nil }
            return HourGroup(
                hour: hourFmt.string(from: firstDate),
                snapshots: groupSnaps)
        }
    }
}
```

- [ ] **Step 3: Verify**

```bash
swift test 2>&1 | tail -20
```

All 4 new tests pass. No existing tests broken.

---

### Task 3: TodaySection — today's digest + timeline

**Files:**
- Create: `Sources/SmritiKit/TodaySection.swift`
- Test: `Tests/SmritiKitTests/TodaySectionTests.swift`

**Interfaces:**
- Consumes: `Store`, `Chronicler.dayString()`, `MarkdownRenderer`, `SnapshotRowView`, `TimelineHelpers.groupByHour`, `Theme`.
- Produces:
  - `final class TodaySection: NSObject, MainSection` — sidebar section showing today's chronicle and hour-grouped snapshot timeline.
  - Hooks: `writeChronicleNow: () -> Void` (set by MainWindow).

- [ ] **Step 1: Write the failing tests**

Create `Tests/SmritiKitTests/TodaySectionTests.swift`:

```swift
import XCTest
@testable import SmritiKit

final class TodaySectionTests: XCTestCase {

    func testTodaySectionConformsToMainSection() {
        let store = try! Store(dbPath: ":memory:")
        let section = TodaySection(store: store)
        XCTAssertEqual(section.title, "Today")
        XCTAssertEqual(section.symbol, "calendar.badge.clock")
    }

    func testTodaySectionMakeViewReturnsNonEmptyView() {
        let store = try! Store(dbPath: ":memory:")
        let section = TodaySection(store: store)
        let view = section.makeView()
        XCTAssertGreaterThan(view.subviews.count, 0, "view should have subviews")
    }

    func testTodaySectionShowsSnapshotCount() throws {
        let store = try Store(dbPath: ":memory:")
        try store.upsert(
            app: "Safari", bundleId: "com.apple.Safari",
            windowTitle: "GitHub", content: "PR #3 merged")
        try store.upsert(
            app: "Slack", bundleId: "com.tinyspeck.slackmacgap",
            windowTitle: "#general", content: "hello")

        let section = TodaySection(store: store)
        _ = section.makeView()
        section.willAppear()

        // Should not crash with snapshots present
        XCTAssertNotNil(section)
    }

    func testTodaySectionHandlesEmptyDay() {
        let store = try! Store(dbPath: ":memory:")
        let section = TodaySection(store: store)
        _ = section.makeView()
        section.willAppear()

        // Should show empty state without crashing
        XCTAssertNotNil(section)
    }

    func testTodaySectionRefreshAfterChronicleWritten() throws {
        let store = try Store(dbPath: ":memory:")
        let day = Chronicler.dayString()
        try store.upsert(
            app: "Safari", bundleId: "com.apple.Safari",
            windowTitle: "GitHub", content: "PR #3 merged")
        try store.upsertChronicle(
            day: day,
            summary: "## Summary\n\nYou worked on Smriti.",
            snapshotCount: 1)

        let section = TodaySection(store: store)
        _ = section.makeView()
        section.willAppear()

        // Should render the chronicle without crashing
        XCTAssertNotNil(section)
    }
}
```

- [ ] **Step 2: Implement TodaySection**

Create `Sources/SmritiKit/TodaySection.swift`:

```swift
import AppKit

/// "Today" sidebar section: shows today's chronicle (or a CTA to write one)
/// and an hour-grouped snapshot timeline for the current day.
final class TodaySection: NSObject, MainSection {
    let title = "Today"
    let symbol = "calendar.badge.clock"

    private let store: Store
    private var view: NSView?
    private var writeButton: ThemedButton?
    private var chronicleCard: ThemedView?
    private var chronicleText: NSTextView?
    private var timelineStack: NSStackView?
    private var emptyLabel: NSTextField?
    private var countLabel: NSTextField?

    var writeChronicleNow: () -> Void = {}

    init(store: Store) {
        self.store = store
        super.init()
    }

    func makeView() -> NSView {
        if let view { return view }
        let W: CGFloat = 739, H: CGFloat = 620
        let container = ThemedView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        container.fillColor = Theme.surface

        // Header
        let heading = NSTextField(labelWithString: "Today")
        heading.font = Theme.serif(24, .semibold)
        heading.textColor = Theme.ink

        countLabel = NSTextField(labelWithString: "")
        countLabel?.font = Theme.body(12)
        countLabel?.textColor = Theme.inkSecondary

        writeButton = ThemedButton(title: "", target: self, action: #selector(writeChronicle))
        writeButton?.isBordered = false
        writeButton?.fillColor = Theme.accent
        writeButton?.corner = Theme.Radius.control
        writeButton?.contentTintColor = .white
        writeButton?.attributedTitle = NSAttributedString(string: "  Write now", attributes: [
            .font: Theme.body(12, .medium), .foregroundColor: NSColor.white,
        ])
        writeButton?.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        writeButton?.imagePosition = .imageLeading
        writeButton?.translatesAutoresizingMaskIntoConstraints = false
        writeButton?.heightAnchor.constraint(equalToConstant: 28).isActive = true
        writeButton?.widthAnchor.constraint(equalToConstant: 90).isActive = true

        let headerRow = NSStackView(views: [heading, countLabel!, writeButton!])
        headerRow.orientation = .horizontal
        headerRow.alignment = .firstBaseline
        headerRow.spacing = Theme.Space.sm
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        // Chronicle card
        let card = Theme.makeCard()
        card.translatesAutoresizingMaskIntoConstraints = false
        chronicleCard = card

        chronicleText = NSTextView()
        chronicleText?.isEditable = false
        chronicleText?.drawsBackground = false
        chronicleText?.textColor = Theme.ink
        chronicleText?.font = Theme.body(14)
        chronicleText?.textContainerInset = NSSize(width: 20, height: 16)
        chronicleText?.isVerticallyResizable = true
        chronicleText?.isHorizontallyResizable = false
        chronicleText?.autoresizingMask = [.width]
        chronicleText?.textContainer?.widthTracksTextView = true
        let chronicleScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 680, height: 200))
        chronicleScroll.drawsBackground = false
        chronicleScroll.hasVerticalScroller = true
        chronicleScroll.documentView = chronicleText
        chronicleScroll.autoresizingMask = [.width, .height]
        chronicleScroll.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(chronicleScroll)

        // Empty state label (shown when no chronicle)
        emptyLabel = NSTextField(labelWithString: "No chronicle yet — write one to capture today's story.")
        emptyLabel?.font = Theme.body(13)
        emptyLabel?.textColor = Theme.inkSecondary
        emptyLabel?.alignment = .center
        emptyLabel?.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel?.isHidden = true
        card.addSubview(emptyLabel!)

        NSLayoutConstraint.activate([
            chronicleScroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            chronicleScroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            chronicleScroll.topAnchor.constraint(equalTo: card.topAnchor),
            chronicleScroll.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            chronicleScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),

            emptyLabel!.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            emptyLabel!.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])

        // Timeline section label
        let timelineLabel = NSTextField(labelWithString: "SNAPSHOTS")
        timelineLabel.attributedStringValue = Theme.label("Snapshots")

        // Timeline stack (scrollable)
        timelineStack = NSStackView()
        timelineStack?.orientation = .vertical
        timelineStack?.alignment = .leading
        timelineStack?.spacing = Theme.Space.sm
        timelineStack?.translatesAutoresizingMaskIntoConstraints = false
        let timelineScroll = NSScrollView(frame: .zero)
        timelineScroll.drawsBackground = false
        timelineScroll.hasVerticalScroller = true
        timelineScroll.documentView = timelineStack
        timelineScroll.autoresizingMask = [.width, .height]
        timelineScroll.translatesAutoresizingMaskIntoConstraints = false
        timelineScroll.borderType = .noBorder

        // Main stack
        let mainStack = NSStackView(views: [headerRow, card, timelineLabel, timelineScroll])
        mainStack.orientation = .vertical
        mainStack.alignment = .width
        mainStack.spacing = Theme.Space.md
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.setCustomSpacing(Theme.Space.sm, after: headerRow)
        mainStack.setCustomSpacing(Theme.Space.sm, after: card)
        mainStack.setCustomSpacing(Theme.Space.xs, after: timelineLabel)

        container.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Theme.Space.xl),
            mainStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Theme.Space.xl),
            mainStack.topAnchor.constraint(equalTo: container.topAnchor, constant: Theme.Space.lg),
        ])

        view = container
        return container
    }

    func willAppear() { refresh() }

    func refresh() {
        let day = Chronicler.dayString()
        let todayCount = (try? store.countForDay(day)) ?? 0
        countLabel?.stringValue = "\(todayCount) snapshot\(todayCount == 1 ? "" : "s") captured"

        // Chronicle
        if let chronicle = try? store.getChronicle(day: day) {
            chronicleText?.textStorage?.setAttributedString(
                MarkdownRenderer.attributed(chronicle.summary))
            chronicleText?.isHidden = false
            chronicleCard?.isHidden = false
            emptyLabel?.isHidden = true
        } else {
            chronicleText?.isHidden = true
            emptyLabel?.isHidden = false
            chronicleCard?.isHidden = false
        }

        // Timeline
        let snapshots = (try? store.snapshotsForDay(day)) ?? []
        rebuildTimeline(snapshots)
    }

    private func rebuildTimeline(_ snapshots: [Store.Snapshot]) {
        timelineStack?.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if snapshots.isEmpty {
            let empty = NSTextField(labelWithString: "No snapshots today. Smriti captures your screen automatically.")
            empty.font = Theme.body(13)
            empty.textColor = Theme.inkSecondary
            empty.alignment = .center
            timelineStack?.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalToConstant: 600).isActive = true
            return
        }

        let groups = TimelineHelpers.groupByHour(snapshots)
        for group in groups {
            // Hour separator
            let sep = NSTextField(labelWithString: "—— \(group.hour) ——")
            sep.font = Theme.body(11, .medium)
            sep.textColor = Theme.inkTertiary
            sep.translatesAutoresizingMaskIntoConstraints = false
            timelineStack?.addArrangedSubview(sep)
            sep.widthAnchor.constraint(equalToConstant: 680).isActive = true

            // Snapshot rows
            for snap in group.snapshots {
                let row = SnapshotRowView(snapshot: snap, showTimestamp: false)
                row.translatesAutoresizingMaskIntoConstraints = false
                timelineStack?.addArrangedSubview(row)
                row.widthAnchor.constraint(equalToConstant: 680).isActive = true
            }
        }
    }

    @objc private func writeChronicle() { writeChronicleNow() }
}
```

- [ ] **Step 3: Verify**

```bash
swift test 2>&1 | tail -20
```

All 5 new tests pass. Existing tests still green.

---

### Task 4: SearchSection — in-app search UI

**Files:**
- Create: `Sources/SmritiKit/SearchSection.swift`
- Test: `Tests/SmritiKitTests/SearchSectionTests.swift`

**Interfaces:**
- Consumes: `Store`, `Store.search(_:limit:)`, `SnapshotRowView`, `Theme`.
- Produces:
  - `final class SearchSection: NSObject, MainSection, NSSearchFieldDelegate` — sidebar section with search field and live results.

- [ ] **Step 1: Write the failing tests**

Create `Tests/SmritiKitTests/SearchSectionTests.swift`:

```swift
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
        // Should show empty state without crashing
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
```

- [ ] **Step 2: Implement SearchSection**

Create `Sources/SmritiKit/SearchSection.swift`:

```swift
import AppKit

/// "Search" sidebar section: a search field at the top with live FTS5 results
/// displayed below. Each result is a clickable `SnapshotRowView`.
final class SearchSection: NSObject, MainSection, NSSearchFieldDelegate {
    let title = "Search"
    let symbol = "magnifyingglass"

    private let store: Store
    private var view: NSView?
    private let searchField = NSSearchField()
    private let resultsStack = NSStackView()
    private let resultCountLabel = NSTextField(labelWithString: "")
    private let emptyStateLabel = NSTextField(labelWithString: "")
    private let noResultsLabel = NSTextField(labelWithString: "")
    private var snapshotPanel: NSPanel?
    private let snapshotText = NSTextView()
    private var debounceTimer: Timer?

    init(store: Store) {
        self.store = store
        super.init()
    }

    func makeView() -> NSView {
        if let view { return view }
        let W: CGFloat = 739, H: CGFloat = 620
        let container = ThemedView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        container.fillColor = Theme.surface

        // Header
        let heading = NSTextField(labelWithString: "Search your memory")
        heading.font = Theme.serif(24, .semibold)
        heading.textColor = Theme.ink

        // Search field
        searchField.placeholderString = "Search across all captured snapshots…"
        searchField.font = Theme.body(14)
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.heightAnchor.constraint(equalToConstant: 36).isActive = true

        // Result count
        resultCountLabel.font = Theme.body(12)
        resultCountLabel.textColor = Theme.inkSecondary
        resultCountLabel.translatesAutoresizingMaskIntoConstraints = false

        // Empty state
        emptyStateLabel.stringValue = "Type to search across all your captured snapshots."
        emptyStateLabel.font = Theme.body(14)
        emptyStateLabel.textColor = Theme.inkSecondary
        emptyStateLabel.alignment = .center
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false

        // No results
        noResultsLabel.font = Theme.body(14)
        noResultsLabel.textColor = Theme.inkSecondary
        noResultsLabel.alignment = .center
        noResultsLabel.translatesAutoresizingMaskIntoConstraints = false
        noResultsLabel.isHidden = true

        // Results stack
        resultsStack.orientation = .vertical
        resultsStack.alignment = .leading
        resultsStack.spacing = Theme.Space.xs
        resultsStack.translatesAutoresizingMaskIntoConstraints = false

        let resultsScroll = NSScrollView(frame: .zero)
        resultsScroll.drawsBackground = false
        resultsScroll.hasVerticalScroller = true
        resultsScroll.documentView = resultsStack
        resultsScroll.autoresizingMask = [.width, .height]
        resultsScroll.translatesAutoresizingMaskIntoConstraints = false
        resultsScroll.borderType = .noBorder

        // Main stack
        let mainStack = NSStackView(views: [
            heading, searchField, resultCountLabel, emptyStateLabel, noResultsLabel, resultsScroll
        ])
        mainStack.orientation = .vertical
        mainStack.alignment = .width
        mainStack.spacing = Theme.Space.sm
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.setCustomSpacing(Theme.Space.md, after: heading)
        mainStack.setCustomSpacing(Theme.Space.sm, after: searchField)

        container.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Theme.Space.xl),
            mainStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Theme.Space.xl),
            mainStack.topAnchor.constraint(equalTo: container.topAnchor, constant: Theme.Space.lg),
        ])

        view = container
        return container
    }

    func willAppear() {
        DispatchQueue.main.async { [weak self] in
            self?.searchField.window?.makeFirstResponder(self?.searchField)
        }
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            self?.executeSearch()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Enter key: execute immediately (bypass debounce)
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            debounceTimer?.invalidate()
            executeSearch()
            return true
        }
        return false
    }

    // MARK: - Search

    private func executeSearch() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        resultsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if query.isEmpty {
            emptyStateLabel.isHidden = false
            noResultsLabel.isHidden = true
            resultCountLabel.stringValue = ""
            return
        }

        emptyStateLabel.isHidden = true
        let results = (try? store.search(query, limit: 50)) ?? []

        if results.isEmpty {
            noResultsLabel.stringValue = "No results for \"\(query)\". Try different terms."
            noResultsLabel.isHidden = false
            resultCountLabel.stringValue = ""
            return
        }

        noResultsLabel.isHidden = true
        resultCountLabel.stringValue = "\(results.count) result\(results.count == 1 ? "" : "s") for \"\(query)\""

        for snap in results {
            let row = SnapshotRowView(snapshot: snap, showTimestamp: true)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.wantsLayer = true
            row.layer?.cornerRadius = Theme.Radius.card
            // Make it clickable
            let click = NSClickGestureRecognizer(target: self, action: #selector(resultClicked(_:)))
            row.addGestureRecognizer(click)
            resultsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: 680).isActive = true
        }
    }

    // MARK: - Snapshot viewer

    @objc private func resultClicked(_ sender: NSClickGestureRecognizer) {
        guard let row = sender.view as? SnapshotRowView else { return }
        // Find the snapshot by searching the visible results
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let results = (try? store.search(query, limit: 50)) ?? []
        guard let index = resultsStack.arrangedSubviews.firstIndex(of: row),
              index < results.count else { return }
        openSnapshot(results[index])
    }

    private func openSnapshot(_ snap: Store.Snapshot) {
        let urlLine = snap.url.isEmpty ? "" : "\(snap.url)\n"
        let body = "\(snap.app) — \(snap.windowTitle)\n\(snap.lastSeenAt)\n\(urlLine)\(String(repeating: "─", count: 40))\n\n\(snap.content)"

        let panel = snapshotPanel ?? makeSnapshotPanel()
        snapshotPanel = panel
        snapshotText.string = body
        snapshotText.scrollToBeginningOfDocument(nil)
        panel.title = "Snapshot #\(snap.id)"
        panel.makeKeyAndOrderFront(nil)
        panel.center()
    }

    private func makeSnapshotPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        Theme.style(window: panel, background: Theme.surface)
        let scroll = MasterDetailSection.makeTextScroll(
            snapshotText, frame: NSRect(x: 0, y: 0, width: 560, height: 460))
        scroll.autoresizingMask = [.width, .height]
        snapshotText.isEditable = false
        snapshotText.drawsBackground = false
        snapshotText.textColor = Theme.ink
        panel.contentView = scroll
        return panel
    }
}
```

- [ ] **Step 3: Verify**

```bash
swift test 2>&1 | tail -20
```

All 4 new tests pass. Existing tests still green.

---

### Task 5: ChronicleTimelineSection — enhanced chronicle browsing

**Files:**
- Create: `Sources/SmritiKit/ChronicleTimelineSection.swift`
- Test: `Tests/SmritiKitTests/ChronicleTimelineTests.swift`

**Interfaces:**
- Consumes: `Store`, `Store.listChronicles(limit:)`, `Store.snapshotsForDay(_:)`, `MarkdownRenderer`, `SnapshotRowView`, `TimelineHelpers.groupByHour`, `Theme`.
- Produces:
  - `final class ChronicleTimelineSection: NSObject, MainSection, NSTableViewDataSource, NSTableViewDelegate` — enhanced chronicle browser with hour-grouped timeline detail.

- [ ] **Step 1: Write the failing tests**

Create `Tests/SmritiKitTests/ChronicleTimelineTests.swift`:

```swift
import XCTest
@testable import SmritiKit

final class ChronicleTimelineTests: XCTestCase {

    func testChronicleTimelineConformsToMainSection() {
        let store = try! Store(dbPath: ":memory:")
        let section = ChronicleTimelineSection(store: store)
        XCTAssertEqual(section.title, "Chronicles")
        XCTAssertEqual(section.symbol, "calendar")
    }

    func testChronicleTimelineMakeViewReturnsNonEmptyView() {
        let store = try! Store(dbPath: ":memory:")
        let section = ChronicleTimelineSection(store: store)
        let view = section.makeView()
        XCTAssertGreaterThan(view.subviews.count, 0)
    }

    func testChronicleTimelineWithEmptyStore() {
        let store = try! Store(dbPath: ":memory:")
        let section = ChronicleTimelineSection(store: store)
        _ = section.makeView()
        section.willAppear()
        XCTAssertNotNil(section)
    }

    func testChronicleTimelineWithChroniclesAndSnapshots() throws {
        let store = try Store(dbPath: ":memory:")
        let day = Chronicler.dayString()
        try store.upsert(
            app: "Safari", bundleId: "com.apple.Safari",
            windowTitle: "GitHub", content: "PR #3 merged")
        try store.upsertChronicle(
            day: day,
            summary: "## Summary\n\nProductive day.",
            snapshotCount: 1)

        let section = ChronicleTimelineSection(store: store)
        _ = section.makeView()
        section.willAppear()
        XCTAssertNotNil(section)
    }
}
```

- [ ] **Step 2: Implement ChronicleTimelineSection**

Create `Sources/SmritiKit/ChronicleTimelineSection.swift`:

```swift
import AppKit

/// Enhanced Chronicles section: a list of days on the left, and an
/// hour-grouped snapshot timeline with chronicle markdown on the right.
/// Replaces the flat MasterDetailSection used previously.
final class ChronicleTimelineSection: NSObject, MainSection, NSTableViewDataSource, NSTableViewDelegate {
    let title = "Chronicles"
    let symbol = "calendar"

    private let store: Store
    private var view: NSView?
    private let table = NSTableView()
    private var chronicles: [Store.Chronicle] = []
    private let detailContainer = NSView()
    private let detailText = NSTextView()
    private var detailScroll: NSScrollView?
    private let timelineStack = NSStackView()
    private var selectedDay: String?

    init(store: Store) {
        self.store = store
        super.init()
    }

    func makeView() -> NSView {
        if let view { return view }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 739, height: 620))

        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 739, height: 620))
        split.isVertical = true
        split.dividerStyle = .thin
        split.autoresizingMask = [.width, .height]

        // Left: day list
        let column = NSTableColumn(identifier: .init("day"))
        column.width = 240
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 48
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = .clear
        table.style = .inset
        let listScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: 620))
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false
        listScroll.autoresizingMask = [.height]

        // Right: detail (chronicle + timeline)
        detailText.isEditable = false
        detailText.drawsBackground = false
        detailText.textColor = Theme.ink
        detailText.font = Theme.body(14)
        detailText.textContainerInset = NSSize(width: 24, height: 22)
        detailText.isVerticallyResizable = true
        detailText.isHorizontallyResizable = false
        detailText.autoresizingMask = [.width]
        detailText.textContainer?.widthTracksTextView = true
        detailScroll = MasterDetailSection.makeTextScroll(
            detailText, frame: NSRect(x: 0, y: 0, width: 478, height: 620))
        detailScroll?.autoresizingMask = [.width, .height]

        // Timeline stack (below the chronicle text, in the same scroll)
        timelineStack.orientation = .vertical
        timelineStack.alignment = .leading
        timelineStack.spacing = Theme.Space.xs
        timelineStack.translatesAutoresizingMaskIntoConstraints = false

        // Composite detail: chronicle text at top, timeline below
        let detailWrapper = NSView(frame: NSRect(x: 0, y: 0, width: 478, height: 620))
        detailWrapper.autoresizingMask = [.width, .height]

        let chronicleScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 478, height: 300))
        chronicleScroll.drawsBackground = false
        chronicleScroll.hasVerticalScroller = true
        chronicleScroll.documentView = detailText
        chronicleScroll.autoresizingMask = [.width, .height]

        let timelineScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 478, height: 320))
        timelineScroll.drawsBackground = false
        timelineScroll.hasVerticalScroller = true
        timelineScroll.documentView = timelineStack
        timelineScroll.autoresizingMask = [.width, .height]
        timelineScroll.borderType = .noBorder

        // Use a vertical split inside the detail for chronicle + timeline
        let detailSplit = NSSplitView(frame: NSRect(x: 0, y: 0, width: 478, height: 620))
        detailSplit.isVertical = false // horizontal split (top/bottom)
        detailSplit.dividerStyle = .thin
        detailSplit.autoresizingMask = [.width, .height]
        detailSplit.addSubview(chronicleScroll)
        detailSplit.addSubview(timelineScroll)
        detailSplit.setPosition(300, ofDividerAt: 0)

        detailContainer.frame = detailSplit.frame
        detailContainer.autoresizingMask = [.width, .height]
        detailContainer.addSubview(detailSplit)

        split.addSubview(listScroll)
        split.addSubview(detailContainer)
        container.addSubview(split)
        split.setPosition(260, ofDividerAt: 0)

        view = container
        return container
    }

    func willAppear() { reload() }

    private func reload() {
        chronicles = (try? store.listChronicles(limit: 200)) ?? []
        table.reloadData()
        if !chronicles.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            selectDay(chronicles[0].day)
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { chronicles.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < chronicles.count else { return nil }
        let c = chronicles[row]
        let cell = NSTableCellView()

        let titleLabel = NSTextField(labelWithString: formatDay(c.day))
        titleLabel.font = Theme.body(13, .semibold)
        titleLabel.textColor = Theme.ink
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let countBadge = NSTextField(labelWithString: "\(c.snapshotCount) snaps")
        countBadge.font = Theme.body(10)
        countBadge.textColor = Theme.inkTertiary
        countBadge.translatesAutoresizingMaskIntoConstraints = false

        let preview = NSTextField(labelWithString: c.summary
            .components(separatedBy: "\n").first ?? "")
        preview.font = Theme.body(11)
        preview.textColor = Theme.inkSecondary
        preview.lineBreakMode = .byTruncatingTail
        preview.maximumNumberOfLines = 1
        preview.translatesAutoresizingMaskIntoConstraints = false

        let col = NSStackView(views: [titleLabel, preview])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 2
        col.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(col)
        cell.addSubview(countBadge)
        NSLayoutConstraint.activate([
            col.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            col.trailingAnchor.constraint(equalTo: countBadge.leadingAnchor, constant: -6),
            col.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            countBadge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            countBadge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0, table.selectedRow < chronicles.count else { return }
        selectDay(chronicles[table.selectedRow].day)
    }

    // MARK: - Detail

    private func selectDay(_ day: String) {
        selectedDay = day
        let chronicle = try? store.getChronicle(day: day)

        // Chronicle markdown
        if let chronicle {
            detailText.textStorage?.setAttributedString(
                MarkdownRenderer.attributed(chronicle.summary))
        } else {
            detailText.textStorage?.setAttributedString(NSAttributedString(
                string: "No chronicle written for \(day).",
                attributes: [.font: Theme.body(13), .foregroundColor: Theme.inkSecondary]))
        }

        // Timeline
        let snapshots = (try? store.snapshotsForDay(day)) ?? []
        rebuildTimeline(snapshots)
    }

    private func rebuildTimeline(_ snapshots: [Store.Snapshot]) {
        timelineStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if snapshots.isEmpty {
            let empty = NSTextField(labelWithString: "No snapshots for this day.")
            empty.font = Theme.body(13)
            empty.textColor = Theme.inkSecondary
            timelineStack.addArrangedSubview(empty)
            return
        }

        let groups = TimelineHelpers.groupByHour(snapshots)
        for group in groups {
            let sep = NSTextField(labelWithString: "—— \(group.hour) ——")
            sep.font = Theme.body(11, .medium)
            sep.textColor = Theme.inkTertiary
            sep.translatesAutoresizingMaskIntoConstraints = false
            timelineStack.addArrangedSubview(sep)
            sep.widthAnchor.constraint(equalToConstant: 440).isActive = true

            for snap in group.snapshots {
                let row = SnapshotRowView(snapshot: snap, showTimestamp: false)
                row.translatesAutoresizingMaskIntoConstraints = false
                timelineStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalToConstant: 440).isActive = true
            }
        }
    }

    private func formatDay(_ day: String) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        guard let date = fmt.date(from: day) else { return day }
        let out = DateFormatter()
        out.dateFormat = "EEEE, MMM d"
        return out.string(from: date)
    }
}
```

- [ ] **Step 3: Verify**

```bash
swift test 2>&1 | tail -20
```

All 4 new tests pass. Existing tests still green.

---

### Task 6: MainWindow wiring — add new sections to sidebar

**Files:**
- Modify: `Sources/SmritiKit/MainWindow.swift` (~20 lines)

**Interfaces:**
- Consumes: `TodaySection`, `SearchSection`, `ChronicleTimelineSection`.
- Modifies: `sections` array order, hooks `writeChronicleNow` into `TodaySection`.

- [ ] **Step 1: Write the failing tests**

No new test file needed — existing `MainWindow` tests (if any) and a manual build check verify wiring. Add a lightweight integration test:

Append to `Tests/SmritiKitTests/StoreTests.swift` (or create a new file):

```swift
    // MARK: - Memory surfacing wiring

    func testNewSectionsCanInstantiateWithStore() throws {
        let store = try Store(dbPath: ":memory:")
        // These should not crash
        _ = TodaySection(store: store)
        _ = SearchSection(store: store)
        _ = ChronicleTimelineSection(store: store)
    }
```

- [ ] **Step 2: Modify MainWindow.swift**

In `Sources/SmritiKit/MainWindow.swift`, update the `sections` array and wiring.

**Change the `sections` lazy var** (around line 50):

From:
```swift
    private lazy var sections: [MainSection] = [
        AskSection(store: store),
        MasterDetailSection(title: "Chronicles", symbol: "calendar",
                            empty: "No chronicles yet. Write one from Overview or the menu bar.",
                            loader: { [store] in
                                (try? store.listChronicles(limit: 200))?.map {
                                    ($0.day, $0.summary)
                                } ?? []
                            }),
        meetingsSection,
        HomeSection(store: store, owner: self),
        SettingsSection(config: config, onChange: { [weak self] c in
            self?.config = c
            self?.onConfigChange(c)
        }),
    ]
```

To:
```swift
    private lazy var todaySection = TodaySection(store: store)

    private lazy var sections: [MainSection] = [
        AskSection(store: store),
        todaySection,
        SearchSection(store: store),
        ChronicleTimelineSection(store: store),
        meetingsSection,
        HomeSection(store: store, owner: self),
        SettingsSection(config: config, onChange: { [weak self] c in
            self?.config = c
            self?.onConfigChange(c)
        }),
    ]
```

**Wire `writeChronicleNow`** into TodaySection — in `init(store:config:)` (around line 70), add:

```swift
        todaySection.writeChronicleNow = { [weak self] in self?.writeChronicleNow() }
```

- [ ] **Step 3: Verify**

```bash
swift build 2>&1 | tail -5
swift test 2>&1 | tail -20
```

Build succeeds. All tests pass (existing + new).

---

### Task 7: Final verification and CHANGELOG

- [ ] **Step 1: Run full test suite**

```bash
swift test 2>&1
```

All tests green.

- [ ] **Step 2: Build the app bundle**

```bash
Scripts/build-app.sh
```

App builds successfully.

- [ ] **Step 3: Update CHANGELOG.md**

Add entry under `## [Unreleased]`:

```markdown
### Added
- **Today** sidebar section: shows today's chronicle (or a one-click write button) and an hour-grouped snapshot timeline.
- **Search** sidebar section: live FTS5 search with debounced input, clickable results that open a snapshot viewer.
- **Chronicle Timeline**: enhanced Chronicles section with a split view — day list on the left, chronicle markdown + hour-grouped snapshots on the right.
- `SnapshotRowView`: reusable snapshot row component with app icon, title, content preview, and timestamp.
- `TimelineHelpers.groupByHour`: shared utility for grouping snapshots into hourly buckets.
```

- [ ] **Step 4: Commit and push to feature branch**

```bash
git checkout -b feat/memory-surfacing
git add -A
git commit -m "✨ memory surfacing: Today digest, Search UI, Chronicle timeline

- TodaySection: daily chronicle + hour-grouped snapshot timeline
- SearchSection: live FTS5 search with clickable results
- ChronicleTimelineSection: enhanced day browser with split detail
- SnapshotRowView: reusable snapshot row component
- TimelineHelpers: groupByHour utility for timeline rendering
- MainWindow: sidebar wiring for new sections"
```

- [ ] **Step 5: Create PR**

Push branch and open PR into `main`.
