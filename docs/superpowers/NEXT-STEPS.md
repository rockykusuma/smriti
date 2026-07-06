# Next Steps — Handover

**Date:** 2026-07-06
**Branch at time of writing:** `main` @ `75106cc`

## Done

**Meeting intelligence** (PR #3, merged `75106cc`) — action-items hub
(check-off only, grouped by meeting, backfilled for old meetings), audio
playback (merged `them.caf`+`me.caf`, scrub, 1×/1.5×/2×), structured meeting
detail view (summary card, inline items, collapsed transcript). Spec:
`docs/superpowers/specs/2026-07-06-meeting-intelligence-design.md`. Plan:
`docs/superpowers/plans/2026-07-06-meeting-intelligence.md`.

## Queued (from 2026-07-06 brainstorm, not yet started)

User picked all three directions this session; meeting intelligence went
first. Two remain, in no particular priority — ask the user which first.

### 1. UX polish pass

Onboarding/permissions flow (TCC pain is real — mic + speech recognition
prompts, `.app` bundle requirement), menu bar quick actions (record note in
one click, live recording indicator), settings reorganization, MainWindow
cleanup (`Sources/SmritiKit/MainWindow.swift` is large — check current size,
it grew again this session with `MeetingsSection`/detail wiring; consider
extraction if the plan touches it further).

### 2. Memory surfacing

Daily digest notification from chronicles, timeline view of your day, richer
in-app search UI instead of only via Claude Desktop MCP. Chronicles already
exist (`Store.Chronicle`, `Chronicler.swift`) — this direction builds a
front-end for data that's already captured but not surfaced.

## Process for whoever picks this up

This repo follows the superpowers workflow strictly:

1. **Never push to `main` directly** — feature branch + PR always
   ([[no-direct-push-to-main]] memory).
2. `superpowers:brainstorming` skill first — one question at a time, propose
   2-3 approaches, get section-by-section design approval, write spec to
   `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`, commit it, get user
   review of the file.
3. `superpowers:writing-plans` skill next — TDD-structured task-by-task plan
   with exact file paths, code, and commands, saved to
   `docs/superpowers/plans/YYYY-MM-DD-<topic>.md`.
4. Execute (inline or subagent-driven per user preference) — commit per task,
   `swift build` + `swift test` must stay green throughout.
5. CHANGELOG entry, final `swift test`/`swift build`/`Scripts/build-app.sh`
   verification, push, PR into `main`.

## Useful facts gathered this session (verify before trusting — code moves)

- Package.swift: `.macOS(.v13)` floor, Swift 5.9.
- `Store.swift` uses raw SQLite3 C API, WAL mode, FTS5 for full-text search.
  Meetings are `snapshots` rows with `bundle_id = 'sh.smriti.meeting'`.
- UI is frame-based AppKit (not SwiftUI) — `NSView`/`NSStackView` with
  `autoresizingMask`, `Theme` for colors (`Theme.ink`, `Theme.surface`,
  `Theme.sidebar`), `ThemedView` for fill-colored containers.
- Test convention: XCTest in `Tests/SmritiKitTests/`,
  `Store(dbPath: ":memory:")` for isolated DB tests.
- Logging convention: `fputs("smriti <area>: …\n", stderr)`, never dialogs
  for background/non-fatal failures.
- Build/run: `swift build`, `swift test`, `Scripts/build-app.sh` (produces
  signed `.app` bundle — required for mic/speech TCC permissions on real
  device testing; a bare `swift run` binary gets aborted by TCC).
