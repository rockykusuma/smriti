# Memory Surfacing — Design

**Date:** 2026-07-06
**Status:** Draft
**Scope:** Today's Digest, enhanced Chronicle timeline, in-app Search UI

## Problem

Smriti captures everything but surfaces almost nothing without asking. Chronicles
exist in the DB but are buried in a flat list. Snapshots are only visible
through "Ask Smriti" (AI chat) or the raw meeting detail view. There's no way
to *browse* your day or search your memory without invoking an LLM.

## Approach

Three new/enhanced sidebar sections, all using existing `Store` queries. No new
database tables. Each section is a self-contained `MainSection` conformer in its
own file — `MainWindow.swift` gains only wiring and sidebar order changes.

### Sidebar order (after this work)

1. Ask Smriti (existing, unchanged)
2. **Today** (new)
3. **Search** (new)
4. Chronicles (enhanced)
5. Meetings (unchanged)
6. Overview (unchanged)
7. Settings (unchanged)

---

## Feature 1: Today's Digest

**File:** `Sources/SmritiKit/TodaySection.swift` (new)

A dedicated section showing today's chronicle and a compact snapshot timeline.

### Data

- `store.getChronicle(day: Chronicler.dayString())` — today's chronicle if
  written
- `store.snapshotsForDay(Chronicler.dayString())` — today's raw snapshots
- `store.countForDay(_:)` — snapshot count for the status line

### UI layout

```
┌─────────────────────────────────────────────┐
│  Today                          [Write now] │  ← header row
│  Monday, July 6 · 47 snapshots              │
├─────────────────────────────────────────────┤
│  ┌─ Chronicle ──────────────────────────┐   │
│  │  ## Summary                          │   │  ← rendered markdown
│  │  You worked on the hearing aid...    │   │     (or CTA if none)
│  └──────────────────────────────────────┘   │
│                                             │
│  ── 9:00 AM ──                              │  ← hour separator
│  [Safari]  GitHub — PR #3 merged            │  ← snapshot row
│  [Slack]   #hearing-aid — budget thread     │
│                                             │
│  ── 10:30 AM ──                             │
│  [Xcode]   SmritiKit/Store.swift            │
│  ...                                        │
└─────────────────────────────────────────────┘
```

### Components

1. **Header row:** "Today" title (serif 22), date subtitle, snapshot count,
   "Write now" button (ThemedButton, same style as HomeSection action buttons).
   Button triggers `writeChronicleNow()` hook.

2. **Chronicle card:** `Theme.makeCard()` containing an `NSTextView` that
   renders the chronicle markdown via `MarkdownRenderer.attributed()`. If no
   chronicle exists, shows a centered "No chronicle yet — write one to capture
   today's story" with the write button.

3. **Snapshot timeline:** Scrollable `NSStackView` (inside `NSScrollView`).
   Snapshots are grouped by hour (truncated from `lastSeenAt`). Each hour group
   has:
   - Separator label: `── 9:00 AM ──` (inkTertiary, body 11, kern 0.5)
   - Snapshot rows: `[App icon]  Window title` (body 13, ink) with a 1-line
     content preview below (body 12, inkSecondary, max 120 chars).

### Snapshot row rendering (reusable)

A `SnapshotRowView` (or function) that takes a `Store.Snapshot` and returns an
`NSView`. Used by Today, Timeline, and Search. Layout:

```
[appIcon 16×16]  [windowTitle — bold, body 13]
                  [content preview — body 12, inkSecondary, 1 line clipped]
                  [timestamp · app name — body 10, inkTertiary]
```

- App icon: `NSWorkspace.shared.icon(forFile:)` for the bundle path, or a
  fallback `NSImage(systemSymbolName: "app")` if lookup fails.
- Content preview: first 120 chars of `content`, newlines replaced with spaces,
  truncated with ellipsis.

---

## Feature 2: Enhanced Chronicle Timeline

**File:** Modify existing Chronicles section inline, or replace with
`ChronicleTimelineSection.swift` (new) if the MasterDetailSection is too
constraining.

### Data

- `store.listChronicles(limit: 200)` — day list
- `store.snapshotsForDay(_:)` — snapshots for selected day

### UI layout

Left pane (list): chronological day cards. Each card shows:
- Day name + date (e.g. "Monday, July 6")
- Snapshot count badge
- First line of chronicle summary (truncated)

Right pane (detail): same hour-grouped timeline as Today, but for the selected
day. Chronicle markdown rendered at top. If no chronicle exists for that day,
shows "No chronicle written for this day."

### Implementation

This reuses the `SnapshotRowView` from Feature 1. The hour-grouping logic is
extracted into a shared helper:

```swift
struct HourGroup {
    let hour: String        // "9:00 AM"
    let snapshots: [Store.Snapshot]
}

func groupByHour(_ snapshots: [Store.Snapshot]) -> [HourGroup]
```

The existing `MasterDetailSection` may work if we customize the detail provider.
If the hour-grouped detail view is too complex for the generic detail provider,
replace with a custom section class.

---

## Feature 3: Search UI

**File:** `Sources/SmritiKit/SearchSection.swift` (new)

A dedicated search interface — type to search, see results instantly.

### Data

- `store.search(_:limit:)` — FTS5 search, returns `[Store.Snapshot]`

### UI layout

```
┌─────────────────────────────────────────────┐
│  Search your memory                         │
│  ┌─ [🔍 search field ──────────────────┐   │
│  └──────────────────────────────────────┘   │
│                                             │
│  12 results for "hearing aid"               │  ← result count
│                                             │
│  ┌─ [Safari] ──────────────────────────┐   │
│  │  GitHub — PR #3 merged              │   │
│  │  budget discussion for the hearing..│   │
│  │  2026-07-06 09:14 · Safari          │   │
│  └──────────────────────────────────────┘   │
│                                             │
│  ┌─ [Slack] ───────────────────────────┐   │
│  │  #hearing-aid — budget thread       │   │
│  │  the firmware BOM came in at $12... │   │
│  │  2026-07-06 10:32 · Slack           │   │
│  └──────────────────────────────────────┘   │
│  ...                                        │
└─────────────────────────────────────────────┘
```

### Components

1. **Search field:** `NSSearchField` (or `NSTextField` styled as search).
   Debounced at 300ms — fires `store.search()` after typing pauses. Shows
   placeholder "Search your captured memory…"

2. **Results list:** Scrollable `NSStackView` of `SnapshotRowView` instances
   (reused from Feature 1). Each row is clickable — opens the snapshot in the
   existing snapshot panel (same as AskSection's `openSnapshot(id:)`).

3. **Empty state:** "Type to search across all your captured snapshots."
   Shows when the field is empty.

4. **No results:** "No results for \"{query}\". Try different terms."

5. **Loading:** Not needed — FTS5 is synchronous and fast (<10ms for typical
   queries).

### Behavior

- Search is case-insensitive (FTS5 default with `"insensitive"` tokenizer, or
  handled by quoting terms in the existing `Store.search` method).
- Results are ordered by FTS5 rank (most relevant first).
- Limit: 50 results max (configurable).
- Clicking a result opens the snapshot panel and highlights the result row.

---

## Shared code

### SnapshotRowView

New file: `Sources/SmritiKit/SnapshotRowView.swift`

Reusable view for rendering a single snapshot in a list context. Used by Today,
Chronicle Timeline, and Search.

```swift
final class SnapshotRowView: NSView {
    init(snapshot: Store.Snapshot, showTimestamp: Bool = true)
}
```

Layout: horizontal stack with app icon (16×16), vertical text column (title +
preview + optional timestamp). Themed with `Theme.card` background, rounded
corners, hover highlight.

### groupByHour helper

Free function or static method on a `TimelineHelpers` enum:

```swift
enum TimelineHelpers {
    static func groupByHour(_ snapshots: [Store.Snapshot]) -> [HourGroup]
}
```

Extracts the hour from `lastSeenAt` ("2026-07-06 09:14:03" → "9:00 AM"),
groups chronologically, returns ordered `[HourGroup]`.

---

## MainWindow changes

`MainWindow.swift` changes (minimal):

1. Add `TodaySection` and `SearchSection` to the `sections` array in the
   correct sidebar order.
2. Wire `writeChronicleNow` hook into `TodaySection`.
3. The existing Chronicles `MasterDetailSection` may be replaced with
   `ChronicleTimelineSection` if needed.

Estimated impact: ~20 lines changed in MainWindow.swift (wiring only).

---

## Files touched

| File | Action | Purpose |
|------|--------|---------|
| `Sources/SmritiKit/SnapshotRowView.swift` | **New** | Reusable snapshot row component |
| `Sources/SmritiKit/TodaySection.swift` | **New** | Today's digest + timeline |
| `Sources/SmritiKit/SearchSection.swift` | **New** | In-app search UI |
| `Sources/SmritiKit/ChronicleTimelineSection.swift` | **New** (or modify existing) | Enhanced chronicle browsing |
| `Sources/SmritiKit/MainWindow.swift` | Modify | Sidebar wiring, ~20 lines |
| `Tests/SmritiKitTests/StoreTests.swift` | Modify | Add tests for any new Store queries if needed |

## What's NOT changing

- No new database tables or migrations
- No new Store methods (existing queries are sufficient)
- No changes to AskSection, Meetings, HomeSection, SettingsSection
- No changes to MenuBarApp.swift, CaptureDaemon, or any background code
- No new dependencies

## Test strategy

- `SnapshotRowView` rendering: unit test that creates snapshots with known
  content and verifies the view hierarchy
- `groupByHour`: unit test with edge cases (empty list, midnight boundary,
  single-hour day)
- `TodaySection`: integration test that populates a store with today's
  snapshots and verifies the chronicle card and timeline render
- `SearchSection`: integration test that populates a store, runs a search, and
  verifies results appear
- All existing tests remain green (no Store API changes)
