# Meeting Intelligence — Design

**Date:** 2026-07-06
**Status:** Approved
**Scope:** Action-items hub, audio playback, richer meeting detail view

## Problem

Smriti already records meetings and voice notes, transcribes them on-device,
and prepends a Claude-generated summary (`## Summary` / `### Decisions` /
`### Action items`) to each transcript. But the intelligence stops there:

- Action items are markdown bullets buried inside transcript text — nothing
  aggregates them, nothing tracks whether they got done.
- Audio is saved to disk forever (`them.caf` + `me.caf` per meeting) but the
  UI cannot play it. Verifying a transcript against reality means Finder.
- The meeting detail view is a raw text blob: summary, transcript, and
  metadata all run together.

## Approach

Incremental, in-pane (chosen over structured-storage rewrite and UI-only
sidecar alternatives): meetings stay as `snapshots` rows
(`bundle_id = 'sh.smriti.meeting'`); action items get a small new table;
audio location gets a new column; all new UI lives in new files so
`MainWindow.swift` (already 47.5K) only gains wiring.

## Data model

New table:

```sql
CREATE TABLE IF NOT EXISTS action_items (
    id          INTEGER PRIMARY KEY,
    snapshot_id INTEGER NOT NULL REFERENCES snapshots(id),
    text        TEXT NOT NULL,
    done        INTEGER NOT NULL DEFAULT 0,
    created_at  TEXT NOT NULL,
    done_at     TEXT
);
CREATE INDEX IF NOT EXISTS idx_action_items_open ON action_items(done, snapshot_id);
```

New column: `snapshots.audio_dir TEXT NOT NULL DEFAULT ''`, added with an
idempotent `pragma table_info` migration following the existing
`migrateAddURLColumnIfNeeded` pattern. The recorder and voice-note finalize
paths write the recording directory path into it. Legacy meetings keep the
empty default — the detail view simply shows no player for them; no path
reconstruction is attempted.

## Action-item extraction — `ActionItems.swift` (new)

- One parser takes composed summary markdown and returns the bullets under
  `### Action items`. Tolerates `-`, `*`, and numbered bullets. A lone
  "none" bullet, a missing heading, or malformed markdown all yield zero
  rows — never an error.
- Called at meeting-save time on both lanes: live finalize and
  `smriti transcribe`.
- **Idempotent per snapshot:** re-extraction (e.g. re-transcription) deletes
  that snapshot's rows and re-inserts, keyed by `snapshot_id`.
- **Backfill:** on first hub open, one pass over existing
  `sh.smriti.meeting` snapshots that have no extracted rows (snapshot-id set
  difference — no sentinel table). Pure markdown parse, no LLM calls.
  Per-snapshot failures are logged to stderr (`fputs`, matching existing
  style) and skipped; the hub renders regardless.

## Item lifecycle

Check-off only. `done = 1, done_at = now` on check; un-check allowed
(mistake recovery) and clears `done_at`. No manual add, no edit, no due
dates — deliberately not a todo app. Each item links back to its source
meeting.

## UI

Three new files; `MainWindow.swift` gains only a segmented control and
wiring.

### `MeetingDetailView.swift`

Replaces the plain-text body when the selected row is a meeting:

1. Metadata header — app name, date, duration (`AVURLAsset` on the audio
   files; duration hidden when `audio_dir` is empty).
2. Summary card — rendered with the existing `MarkdownRenderer`.
3. This meeting's action items, inline with checkboxes.
4. Player bar (below).
5. Transcript collapsed by default behind a "Show transcript" disclosure.

### `AudioPlayerBar.swift`

- Meetings have two tracks (`them.caf` + `me.caf`); merge into one
  `AVPlayerItem` via `AVMutableComposition` and drive a single `AVPlayer`,
  so both sides play together the way the call sounded. Voice notes play
  `me.caf` alone.
- Controls: play/pause, scrubber with elapsed/total time, speed toggle
  1× / 1.5× / 2×.
- Missing or corrupt files, or a composition build failure → the bar is
  hidden and a line goes to stderr; no error dialog.
- Switching rows stops playback and releases the player. Mismatched track
  lengths are fine — composition duration is the longer track.

### `ActionItemsView.swift` — the hub

- The Meetings pane header gets a segmented control:
  **Meetings | Action items**. The existing `MasterDetailSection` stays
  untouched for list mode; the hub is a sibling view the segment swaps in.
- Open items grouped by source meeting, newest meeting first, checkbox per
  item.
- The meeting name is clickable and jumps to that meeting's detail view.
- "Show completed" toggle at the bottom, off by default.
- The segment label carries an open-count badge ("Action items · 7").

## Error handling

- Extraction/parse failures → zero rows, never a crash.
- Backfill skips failing snapshots, logs to stderr, never blocks the hub.
- `audio_dir` migration is idempotent (`pragma table_info` check).
- Playback failures hide the bar silently (stderr log only).
- A failed check-off DB write reverts the checkbox and logs to stderr.

## Testing

XCTest in `Tests/SmritiKitTests/`, matching existing style:

- **`ActionItemsTests.swift`** — parse: normal bullets, "none", missing
  heading, mixed `-`/`*`, numbered lists; idempotent re-extraction;
  backfill touches only unextracted meetings.
- **`StoreTests` additions** — action_items CRUD, done toggle + `done_at`,
  open-count query, `audio_dir` migration on a legacy DB.
- **Player/UI** — no unit tests (AVPlayer + AppKit); manual verification via
  `Scripts/build-app.sh`: record a voice note, play it back, check off an
  item, relaunch and confirm state persisted.

## Out of scope

- Manual/ad-hoc action items, editing, due dates, priorities.
- Restructuring meeting storage into its own table.
- Waveform rendering or transcript-synced playback position.
- Notifications/reminders for open items.
