# Smriti (स्मृति)

*A local memory for your Mac — with Claude as the brain.*

[![CI](https://github.com/rockykusuma/smriti/actions/workflows/ci.yml/badge.svg)](https://github.com/rockykusuma/smriti/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)
![Swift](https://img.shields.io/badge/swift-5.9-orange)

Smriti (Sanskrit: *memory*) quietly reads the text of whatever window you're
working in — using the macOS Accessibility API, text only, never screenshots —
and stores it in a local SQLite database with full-text search. A built-in MCP
server exposes that memory to Claude Desktop, so you can ask things like:

> *"What was I working on before lunch?"*
> *"Find that error message I saw in Terminal yesterday."*
> *"What did I read about FTS5 last week?"*

**Everything stays on your Mac.** No cloud, no telemetry, no API keys. The
only LLM involved is Claude via your existing subscription — Smriti itself
contains no model at all.

## Why

Screen-memory tools are genuinely useful and genuinely dangerous: they see
your bank, your work IP, your private messages. Smriti exists because I
wanted the utility without trusting a third party. The design constraints,
in order:

1. **Local-only, inspectable.** One small Swift binary, the system SQLite,
   no dependencies. Your memory is one `.sqlite` file you can open, query,
   and delete.
2. **No silent behavior.** Capture runs when *you* start it. The login
   agent is installed by an explicit command and removed by another.
3. **Exclusion-first.** Password managers are excluded by default; apps,
   web domains (with subdomains), and window-title keywords are one command
   to block — *before* content ever reaches the database.
4. **No LLM inside.** Claude, on the subscription you already pay for, does
   all the thinking through MCP. Search is SQLite FTS5, not embeddings.

## Install

```bash
git clone https://github.com/rockykusuma/smriti.git && cd smriti
swift build -c release
sudo install -m 755 .build/release/smriti /usr/local/bin/smriti
```

> **Updating?** Always use `install` (not `cp`) — overwriting the binary in
> place makes macOS kill it with a stale code-signing cache. And because the
> binary is ad-hoc signed, each update needs the Accessibility grant redone
> (remove + re-add in System Settings).

### First run

```bash
smriti capture
```

Grant Accessibility permission when prompted (System Settings → Privacy &
Security → Accessibility), then re-run. To instead run from the menu bar
with a pause button and per-app exclusions one click away:

```bash
smriti menubar               # or start it at login:
smriti install-agent menubar
```

### Connect Claude

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`
(quit Claude Desktop first — it rewrites this file from memory on exit):

```json
{
  "mcpServers": {
    "smriti": { "command": "/usr/local/bin/smriti", "args": ["mcp"] }
  }
}
```

Restart Claude Desktop. Claude now has five tools: `search_memory`,
`get_recent_activity`, `get_snapshot`, `get_chronicle`, `list_chronicles`.

## Usage

```bash
smriti capture              # capture daemon in the foreground (Ctrl-C stops)
smriti menubar              # ...or as a menu bar app
smriti recent 60            # what was on screen in the last hour
smriti search hearing aid   # full-text search
smriti stats                # snapshot counts and date range

smriti exclude com.tinyspeck.slackmacgap   # never capture Slack
smriti exclude-domain mybank.com           # never capture a site (+subdomains)
smriti exclusions                          # list all exclusions

smriti chronicle yesterday  # summarize a day via `claude -p` (Claude Code CLI)
smriti chronicles           # list stored daily summaries
smriti retention 90         # prune raw snapshots after 90 days (chronicles kept)

smriti install-agent [menubar]  # start at login; uninstall-agent removes it
smriti agent-status
```

Pause without quitting: click the menu bar icon, or send `SIGUSR1` to the
capture process.

## Architecture

```
smriti (CLI)                       SmritiKit
┌──────────────┐   ┌───────────────────────────────────────────┐
│ capture ─────┼──▶│ CaptureDaemon (5s timer, prune daily)     │
│ menubar ─────┼──▶│   └─ AXReader (AX tree → window text)     │
│              │   │        └─ BrowserURL (AXWebArea → URL)    │
│ mcp ─────────┼──▶│ MCPServer (stdio JSON-RPC for Claude)     │
│ chronicle ───┼──▶│ Chronicler (digest → `claude -p`)         │
│ recent/      │   │        │                                  │
│ search/stats─┼──▶│ Store ─┴─ SQLite + FTS5                   │
└──────────────┘   │   snapshots (deduped by content hash)     │
                   │   chronicles (daily summaries, kept)      │
                   └───────────────────────────────────────────┘
```

- **Dedup**: a snapshot is keyed by (app, window title, content hash);
  re-seeing identical content bumps `last_seen_at` instead of inserting.
  An idle window costs one row, not 720/hour.
- **Data**: `~/Library/Application Support/Smriti/smriti.sqlite` (WAL).
  Deleting your memory = deleting that file.
- **Config**: `~/Library/Application Support/Smriti/config.json`.
- **Logs** (agent mode): `~/Library/Logs/smriti.log`.

## Privacy model, honestly stated

Smriti sees what you see. That is the point, and the risk. Mitigations:

- Text only; screenshots are never taken.
- Default exclusions: password managers, Keychain, private/incognito
  windows. Add your own for work apps and sensitive domains **before**
  running capture during work hours — captured text is in the DB until
  retention prunes it.
- The MCP server gives Claude read access to your memory. That is the
  feature. If you don't want a conversation to see it, remove the server
  or pause capture.
- Chronicles send a *digest of your day* through the Claude Code CLI under
  your subscription — the only data that ever leaves the machine, and only
  when you (or your scheduler) invoke it.

## Meeting capture (roadmap)

Ingesting Teams/meeting transcripts may require participant consent in your
jurisdiction and under your employer's policy. Smriti will prefer official
exported transcripts over any form of silent audio capture.

## Development

```bash
swift test    # 18 tests: Store/FTS/dedup/prune, domain matching, MCP tools
```

See [CONTRIBUTING.md](CONTRIBUTING.md). PRs that add network calls or
dependencies will be declined; that's a feature.

## License

[MIT](LICENSE)
