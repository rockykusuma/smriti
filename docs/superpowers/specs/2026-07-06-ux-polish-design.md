# UX Polish Pass — Design

**Date:** 2026-07-06
**Status:** Draft
**Scope:** MainWindow extraction, menu bar quick actions, first-launch onboarding, settings reorganization, MenuBarApp extraction

## Problem

MainWindow.swift is 1,166 lines containing 4 unrelated classes. MenuBarApp.swift
is 490 lines mixing menu, HUD, toast, voice notes, and daemon lifecycle. There
is no onboarding — users get a silent menu bar icon with no explanation, and
permissions are never prompted on launch. Settings are a flat undifferentiated
scroll with no visual grouping.

## Approach

Five changes, ordered by dependency (extractions first since they reduce the
surface area for the other work):

---

## 1. Extract classes from MainWindow.swift

**Goal:** Reduce MainWindow.swift from 1,166 to ~220 lines.

### Files

| From | To | Lines moved |
|------|----|-------------|
| `MainWindow.swift` | `MasterDetailSection.swift` (new) | ~343 |
| `MainWindow.swift` | `HomeSection.swift` (new) | ~186 |
| `MainWindow.swift` | `SettingsSection.swift` (new) | ~386 |

### What stays in MainWindow.swift

- `MainWindow` class (~222 lines) — window lifecycle, sidebar wiring, hooks
- `SidebarRowView` (~9 lines) — tiny helper, stays
- `MainSection` protocol (~6 lines) — used by all sections, stays

### Verification

No behavior changes — pure file moves. `swift build` + `swift test` must pass.
No public API changes (all classes are `internal`).

---

## 2. Extract from MenuBarApp.swift

**Goal:** Reduce MenuBarApp.swift from 490 to ~345 lines.

### Files

| From | To | Lines moved |
|------|----|-------------|
| `MenuBarApp.swift` | `DraftHUD.swift` (new) | ~85 |
| `MenuBarApp.swift` | `ToastPanel.swift` (new) | ~60 |

### DraftHUD

The floating "Smriti drafting..." pill panel. Self-contained:
- `NSPanel` creation + positioning
- Timer-driven animated dots
- Show/hide with animation

### ToastPanel

The borderless notification panel below the menu bar. Self-contained:
- `NSPanel` creation + auto-dismiss timer
- Text + optional icon rendering
- Sizing and positioning logic

### What stays in MenuBarApp

- Menu building, daemon lifecycle, voice note recording, assist wiring,
  config management (~345 lines)

---

## 3. Menu bar quick actions

**Goal:** One-click voice note recording + live recording indicator on icon.

### A. "Record voice note" menu item

Add to `menuNeedsUpdate(_:)`, between "Open Smriti" and "Write today's
chronicle":

```
● Record voice note                   (new item)
```

When clicked:
- Calls `startVoiceNote()` if not recording
- Calls `stopVoiceNote()` if already recording (label changes to "◼ Stop & save")
- Same behavior as the Meetings section record button

The infrastructure already exists — `MenuBarApp` owns `startVoiceNote()`/
`stopVoiceNote()` and `VoiceNoteRecorder`. Just needs a menu item wired up.

### B. Live recording indicator

When a voice note or meeting is recording, change the menu bar icon:

- **Default:** `brain` SF Symbol
- **Recording:** `waveform` SF Symbol with a subtle red tint
- **Drafting (existing):** `ellipsis.bubble` SF Symbol

Implementation:
- In the existing `voiceNoteLevel` timer callback (or a new timer), check
  `voiceRecorder.isRecording` and swap the icon
- Use `NSImage(systemSymbolName:)` with `NSImage.SymbolConfiguration` for
  the tint
- Same pattern already used by `assist.onGeneratingChange`

---

## 4. First-launch onboarding

**Goal:** Guide users through permissions on first launch. Prevent the "app
does nothing" silent failure mode.

### Flow

A single `NSWindow` with a step-by-step wizard (4 steps):

```
┌─────────────────────────────────────────────┐
│  Welcome to Smriti                         │
│                                             │
│  Smriti quietly captures your screen so     │
│  you can search and remember your work.     │
│                                             │
│  Let's set up a few things:                 │
│                                             │
│  ┌─ Step 1 ────────────────────────────┐   │
│  │  ✅ Accessibility                   │   │  ← or ⏳ pending
│  │  Smriti needs Accessibility to      │   │
│  │  read window titles and content.    │   │
│  │              [Grant Access]          │   │
│  └──────────────────────────────────────┘   │
│                                             │
│  ┌─ Step 2 ────────────────────────────┐   │
│  │  ⏳ Microphone                      │   │
│  │  For recording voice notes and      │   │
│  │  meeting transcriptions.            │   │
│  │              [Enable]               │   │
│  └──────────────────────────────────────┘   │
│                                             │
│  ┌─ Step 3 ────────────────────────────┐   │
│  │  ⏳ Speech Recognition              │   │
│  │  To transcribe recordings on-device.│   │
│  │              [Enable]               │   │
│  └──────────────────────────────────────┘   │
│                                             │
│  ┌─ Step 4 ────────────────────────────┐   │
│  │  ⏳ Claude Account (optional)       │   │
│  │  For AI-powered replies and         │   │
│  │  chronicle generation.              │   │
│  │              [Login]                │   │
│  └──────────────────────────────────────┘   │
│                                             │
│                        [Skip All] [Done]    │
└─────────────────────────────────────────────┘
```

### Behavior

- **When shown:** On first launch (detected by a `Config` flag:
  `hasCompletedOnboarding: Bool`, default `false`). Also shown when the
  user clicks "Setup" from the menu (new menu item).
- **Each step:** "Grant Access" / "Enable" button triggers the appropriate
  system prompt. The status indicator updates in real-time (✅ when granted,
  ⏳ when pending, ❌ when denied).
- **Accessibility:** Uses existing `AXReader.ensureAccessibilityPermission()`.
- **Microphone:** Uses `AVCaptureDevice.requestAccess(for: .audio)`.
- **Speech Recognition:** Uses `Transcriber.requestAuthorization()`.
- **Claude:** Opens the Claude CLI login flow (existing `ClaudeCLI` code).
- **Skip All:** Sets `hasCompletedOnboarding = true` and closes the window.
  User can re-open from menu.
- **Done:** All steps show ✅ or user clicks Done. Sets
  `hasCompletedOnboarding = true`.

### Config change

Add to `Config`:
```swift
var hasCompletedOnboarding: Bool  // default: false
```

Persisted in `config.json` like all other settings.

### Menu bar integration

Add a "Setup" menu item (shown only when onboarding is not complete, or always
available as "Re-run setup"). When clicked, shows the onboarding window.

---

## 5. Settings reorganization

**Goal:** Group settings into visual sections with cards.

### Current layout (flat)

```
Appearance dropdown
Backend dropdown
Cloud provider dropdown
API key field
Model dropdown
Status label
Privacy checkbox
Auto-record checkbox
Claude account
```

### New layout (grouped)

```
── APPEARANCE ──
┌──────────────────────────────────────┐
│  Theme:  [System / Light / Dark]     │
└──────────────────────────────────────┘

── AI BACKEND ──
┌──────────────────────────────────────┐
│  Reply drafts by:  [Auto ▾]          │
│  Cloud provider:   [Anthropic ▾]     │
│  Model:            [Sonnet ▾]        │
│  API key:          [••••••] [Save]   │
│  Status: Ready                       │
└──────────────────────────────────────┘

── PRIVACY & RECORDING ──
┌──────────────────────────────────────┐
│  ☑ Redact secrets before sending     │
│  ☐ Auto-record meetings              │
└──────────────────────────────────────┘

── ACCOUNT ──
┌──────────────────────────────────────┐
│  Claude CLI: Logged in ✓            │
│  [Check]  [Login]                   │
└──────────────────────────────────────┘
```

### Implementation

- Each group is a `Theme.makeCard()` with a section header above it
- Headers use `Theme.label()` style (uppercase, letter-spaced)
- Cards have `Theme.Space.md` padding inside
- Vertical spacing between cards: `Theme.Space.lg`
- All existing controls stay the same — just reorganized into cards
- The conditional cloud-provider / API-key / model fields still show/hide
  based on backend selection, but within their card

---

## Files touched

| File | Action | Purpose |
|------|--------|---------|
| `Sources/SmritiKit/MasterDetailSection.swift` | **New** | Extracted from MainWindow |
| `Sources/SmritiKit/HomeSection.swift` | **New** | Extracted from MainWindow |
| `Sources/SmritiKit/SettingsSection.swift` | **New** | Extracted from MainWindow |
| `Sources/SmritiKit/DraftHUD.swift` | **New** | Extracted from MenuBarApp |
| `Sources/SmritiKit/ToastPanel.swift` | **New** | Extracted from MenuBarApp |
| `Sources/SmritiKit/OnboardingWindow.swift` | **New** | First-launch wizard |
| `Sources/SmritiKit/MainWindow.swift` | Modify | Remove extracted classes, ~220 lines |
| `Sources/SmritiKit/MenuBarApp.swift` | Modify | Remove extracted classes, add menu items, recording indicator, ~345 lines |
| `Sources/SmritiKit/Config.swift` | Modify | Add `hasCompletedOnboarding` field |
| `Tests/SmritiKitTests/` | Modify | Add tests for onboarding logic, settings grouping |

## What's NOT changing

- No new database tables or migrations
- No new Store methods
- No new dependencies
- No changes to CaptureDaemon, VoiceNoteRecorder, MeetingWatcher, or any
  background capture code
- No changes to the new Memory Surfacing sections (Today, Search, Chronicles)

## Test strategy

- Extraction tasks: existing tests must continue to pass (no behavior changes)
- Onboarding: unit test that `hasCompletedOnboarding` persists correctly, test
  that the window shows/hides based on the flag
- Menu bar: verify menu items are added with correct selectors
- Settings: verify all controls still function after reorganization
