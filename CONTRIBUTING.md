# Contributing to Smriti

Thanks for your interest! Smriti is intentionally small and dependency-free.

## Ground rules

- **Local-only is non-negotiable.** No feature may send captured data off the
  machine, add telemetry, or call external APIs (the sole exception is the
  user-invoked `claude -p` chronicle pipeline, which runs on the user's own
  Claude subscription).
- **No new dependencies** without prior discussion in an issue. The project
  deliberately uses only the system SQLite and Apple frameworks.
- **Privacy defaults err on the side of not capturing.** New capture surface
  needs a corresponding exclusion mechanism.

## Development

```bash
swift build          # debug build
swift test           # run the test suite
swift build -c release
```

PRs should include tests for new Store/parsing logic. UI (menu bar) and
AX-tree code is exercised manually — describe your manual test in the PR.

## Reporting issues

Please include macOS version, how you run capture (terminal, agent, menu
bar), and relevant lines from `~/Library/Logs/smriti.log`. Never paste
snapshot contents you wouldn't want public.
