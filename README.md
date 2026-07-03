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

**Everything stays on your Mac.** No cloud, no telemetry, no API keys. Smriti
ships no model of its own: the thinking is done by Claude via your existing
subscription, or — for instant replies — by a local Ollama model you run
yourself, so that text never leaves the machine.

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
   the thinking through MCP — or, for instant replies, a local Ollama model
   so text never leaves the Mac. Search is SQLite FTS5, not embeddings.

## Install

**Homebrew** (easiest):

```bash
brew tap rockykusuma/smriti
brew install smriti
```

**From source:**

```bash
git clone https://github.com/rockykusuma/smriti.git && cd smriti
swift build -c release
sudo install -m 755 .build/release/smriti /usr/local/bin/smriti
```

> **Updating?** Always use `install` (not `cp`) — overwriting the binary in
> place makes macOS kill it with a stale code-signing cache.
>
> **Recommended: sign with a stable identity.** Ad-hoc-signed binaries lose
> their Accessibility / Input Monitoring grants on every rebuild. Create a
> self-signed code-signing certificate once (Keychain Access → Certificate
> Assistant → Create a Certificate → type "Code Signing", e.g. named
> "Smriti Dev Signing"), then sign each build before installing:
>
> ```bash
> codesign --force --sign "Smriti Dev Signing" \
>   --identifier com.smriti.cli --timestamp=none .build/release/smriti
> ```
>
> With a stable identity + identifier, permission grants survive updates.

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

## Reply assist

Focused in a message box — Teams, Slack, a LinkedIn comment, any text field —
**double-tap the right ⌥ key**. Smriti reads the conversation (from its own
seconds-old capture, no extra walk), pulls related older context from your
memory, and streams a draft into the field as Claude generates it. The
action is context-sensitive: an **empty field gets a reply**, an unfinished
**draft gets continued**, and **selected text gets rewritten** in place.

Run `smriti learn-tone` once (or use the menu item) and drafts follow your
personal writing style, distilled from your own captured messages into an
editable `tone.md`. Toggle the assist from the menu bar; it beeps when
there's nothing sensible to reply to.

Requires the menu bar app (`smriti menubar`) and, one time, the Input
Monitoring permission alongside Accessibility.

### Local or cloud replies (hybrid backend)

Reply assist can draft with a **local Ollama model** or with **Claude**. When
Ollama is running, drafts are generated on-device — the first token lands in
well under a second and your reply text never leaves the Mac. If Ollama isn't
reachable, Smriti automatically falls back to a pre-warmed Claude process, so
the double-tap always works.

Two config keys in `config.json` control it:

| Key | Values | Default |
| --- | --- | --- |
| `assistBackend` | `auto` (Ollama, fall back to Claude) · `ollama` · `claude` | `auto` |
| `ollamaModel` | any installed Ollama model tag | `llama3.2:latest` |

To use local replies, install [Ollama](https://ollama.com) and pull a small
instruct model:

```bash
ollama pull llama3.2      # fast; great for short replies
```

Smriti keeps the chosen model resident so there's no cold-start cost. Switch
the backend and model live from the menu bar → **Settings…** (⌘,) — the popups
list every model Ollama reports, and changes apply immediately (the new model
is re-warmed without a restart). Chronicles, tone learning, and meeting
summaries always use Claude for quality, regardless of this setting.

## Usage

```bash
smriti capture              # capture daemon in the foreground (Ctrl-C stops)
smriti menubar              # ...or as a menu bar app (includes reply assist)
smriti recent 60            # what was on screen in the last hour
smriti search hearing aid   # full-text search
smriti stats                # snapshot counts and date range

smriti exclude com.tinyspeck.slackmacgap   # never capture Slack
smriti exclude-domain mybank.com           # never capture a site (+subdomains)
smriti exclusions                          # list all exclusions

smriti chronicle yesterday  # summarize a day via `claude -p` (Claude Code CLI)
smriti chronicles           # list stored daily summaries
smriti learn-tone           # distill your writing style from captured chats
smriti tone                 # show/inspect the stored tone profile
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
- **Config**: `~/Library/Application Support/Smriti/config.json` — exclusions,
  `retentionDays`, and the reply backend (`assistBackend`, `ollamaModel`).
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

## Meeting recording (consent-first)

When any app opens the microphone — Teams, Meet, Zoom, FaceTime, WhatsApp —
Smriti shows a consent panel for 10 seconds: click **Record** or nothing
happens. Approved calls are recorded locally (your mic and the system audio
as separate tracks), transcribed **on-device** with Apple's speech engine,
auto-summarized (decisions, action items) via `claude -p`, and stored in
memory — searchable, visible to Claude, part of the daily chronicle. Browse
everything under menu bar → **Meetings…**; audio lives in
`~/Library/Application Support/Smriti/meetings/` and never leaves the Mac.

Recording calls may require participant consent in your jurisdiction and
under your employer's policy — Smriti asks *you*, the rest is on you.

## Development

```bash
swift test    # 23 tests: Store/FTS/dedup/prune, domain matching, MCP tools
```

See [CONTRIBUTING.md](CONTRIBUTING.md). PRs that add network calls or
dependencies will be declined; that's a feature.

## License

[MIT](LICENSE)
