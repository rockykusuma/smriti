# Changelog

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
