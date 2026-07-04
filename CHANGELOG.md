# Changelog

## Unreleased

- **Meeting transcription, hardened** (from the first real-call test):
  - Mic is now recorded as mono 16 kHz. It was captured in the input device's
    raw format (often multi-channel float), which the on-device recognizer
    reads as silence.
  - Transcription runs in short (~40s) chunks. Apple's on-device recognizer is
    reliable on short clips but stalls indefinitely on long single files.
  - Fixed a crash while normalizing audio (buffer vs. AVAudioFile processing
    format mismatch).
  - New `smriti transcribe [id]` re-transcribes a saved meeting's audio
    (default: the most recent) — recover meetings whose live transcription
    failed. Re-transcribed text stays searchable via a new FTS update trigger.
  - The recorder now requests Microphone access explicitly, logs which input
    device and format it binds, and warns when a recording comes out silent
    (e.g. a virtual audio device was the default input).
  - New `smriti mic-check [secs]` records a few seconds and reports the input
    device, format, and peak/RMS level (with a live meter) — verify capture
    without a real call.
  - Summary generation no longer misfires on very short transcripts (it used
    to reply "I don't see a transcript…"); short transcripts now skip the
    summary, and the prompt is hardened.
  - Meeting titles fixed: no more doubled word ("Call call"), and short
    recordings show seconds instead of rounding to "0 min".
  - Transcription skips silent chunks (so silent tracks don't crawl),
    transcribes short recordings in a single pass, and overlaps long-file
    chunks so speech at a seam isn't lost.
  - **Mic now captured via ScreenCaptureKit** (macOS 15+) instead of
    AVAudioEngine. VoIP apps (WhatsApp, etc.) hold the input device during a
    call, which starved the AVAudioEngine tap — your side recorded as silence
    while the other participant (system audio) came through fine. SCK captures
    mic and system audio in one stream and coexists with the calling app.

## v0.7.1 — 2026-07-04

- **Settings window**: menu bar → "Settings…" (⌘,) to switch the reply-assist
  backend (Auto / Ollama / Claude) and pick the local model from a list
  populated live from Ollama. Changes save to config.json and apply
  immediately — the chosen model is re-warmed without a restart.

## v0.7.0 — 2026-07-04

- **Hybrid model backend**: the reply assist now uses a local Ollama model
  (default `llama3.2:latest`, kept resident) when Ollama is running —
  sub-second first token, and reply text never leaves the Mac. Automatic
  fallback to the warm Claude process on any failure. Configure via
  `assistBackend` ("auto" | "ollama" | "claude") and `ollamaModel` in
  config.json. Chronicles, tone learning, and meeting summaries stay on
  Claude for quality.

## v0.6.0 — 2026-07-04

- **Meeting recording with explicit consent**: when any app opens the
  microphone (Teams, Meet, Zoom, FaceTime, WhatsApp, Slack…), Smriti asks
  with a 10-second consent panel — no response means NO recording, and it
  won't ask again until that call ends. On yes: system audio (them) and
  microphone (you) are recorded as separate local tracks, transcribed
  on-device with Apple's speech engine, auto-summarized (decisions, action
  items) via claude, and stored in memory — searchable, Claude-visible,
  chronicled.
- **Meetings browser**: menu bar → "Meetings…" opens a window listing all
  recorded meetings with their summaries and full transcripts.
- `smriti meetings` CLI; embedded Info.plist for microphone/speech TCC
  prompts; audio kept under Application Support/Smriti/meetings/.
- Reminder: participant consent for recording calls is the user's
  responsibility under local law and employer policy.

## v0.5.0 — 2026-07-04

- **Action modes**: the double-tap is now context-sensitive — text selected
  → rewrite it in place; unfinished draft → continue it; empty field →
  reply to the conversation.
- **Writes in your tone**: `smriti learn-tone` (or the menu item) distills
  a style guide from two weeks of captured communication windows into
  `tone.md`; every draft follows it. Inspect/edit with `smriti tone`.
- **Memory-informed replies**: the assist runs an FTS query over your
  capture history (window-title terms, older than an hour) and feeds the
  top matches to Claude alongside the on-screen context.

## v0.4.0 — 2026-07-04

- **Streaming replies**: reply assist types the draft progressively as
  Claude generates it (`--include-partial-messages`); first words land in
  ~2s of model time. The decline sentinel is buffered and never typed.
- **Context from memory**: the assist reuses the capture daemon's
  seconds-old snapshot instead of re-walking the accessibility tree
  (walks of large Electron trees cost up to 2s); falls back to a live
  time-boxed walk when the snapshot is stale or the app is excluded.

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
