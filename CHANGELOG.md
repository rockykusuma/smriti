# Changelog

## v0.3.0 — 2026-07-04

- **Warm Claude pool**: reply assist now keeps a pre-warmed `claude`
  process (stream-json mode) with the slow first turn burned on a dummy
  exchange; each request gets a clean, already-hot session and a fresh
  replacement warms in the background. Cold-run fallback retained.
- LaunchAgent runs as ProcessType=Interactive and claude subprocesses get
  user-initiated QoS — background throttling was multiplying latency.
- Real-world drafting: ~86s worst case → ~6–9s.

## v0.2.1 — 2026-07-04

- Reply assist feedback: "Pop" sound when the double-tap registers, floating
  "drafting…" HUD panel while Claude works, "Glass" chime when the reply is
  typed, and a "Basso" thunk when you double-tap while a draft is already in
  flight. Logs drafting duration.

## v0.2.0 — 2026-07-04

- **Reply assist**: double-tap the right Option key in any text field and
  Smriti reads the on-screen conversation via Accessibility, drafts a reply
  with Claude Haiku (`claude -p --model haiku`), and types it at the cursor.
  Detects the key through modifier-state polling (reliable for launchd
  agents where event taps and NSEvent monitors are not delivered); typing
  between taps cancels the gesture; beeps when focus isn't an editable field
  or there's nothing to reply to.
- Menu bar: reply-assist toggle; icon switches to a speech bubble while
  drafting.
- Deterministic ordering for `recent`/`search` results within the same
  second.
- Build docs: sign with a stable self-signed certificate so Accessibility /
  Input Monitoring grants survive binary updates.

## v0.1.0 — 2026-07-04

Initial public release.

- **Capture daemon**: samples the frontmost window's text every 5s via the
  Accessibility API (text only — no screenshots), deduplicated by content
  hash into SQLite with FTS5 full-text search.
- **Browser awareness**: page URL captured via the AX tree (Safari, Chrome,
  Arc, Edge, Brave, Vivaldi, Opera, Firefox) with domain-based exclusions
  (`smriti exclude-domain`), plus app (`smriti exclude`) and window-title
  exclusions. Password managers excluded by default.
- **MCP server** (`smriti mcp`): stdio server for Claude Desktop/Cowork with
  `search_memory`, `get_recent_activity`, `get_snapshot`, `get_chronicle`,
  `list_chronicles`.
- **Chronicles** (`smriti chronicle`): daily summaries written by piping a
  compacted digest through the Claude Code CLI (`claude -p`).
- **Retention** (`smriti retention N`): raw snapshots pruned after N days
  (default 90); chronicles kept forever.
- **Menu bar app** (`smriti menubar`): capture state, today's count,
  pause/resume, one-click app exclusion, chronicle actions.
- **Login autostart** (`smriti install-agent [menubar]`): transparent,
  user-invoked LaunchAgent; `uninstall-agent` removes every trace.
