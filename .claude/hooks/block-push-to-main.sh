#!/usr/bin/env bash
# PreToolUse(Bash) hook: block any `git push` that would update the remote
# `main` branch directly. Pushes must go through a feature branch + PR.
#
# This is a local tripwire for convenience; GitHub branch protection on `main`
# is the authoritative server-side guard. To override in a genuine emergency,
# run the push yourself in a terminal outside Claude.
set -euo pipefail

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")

# Only inspect git push commands; let everything else through untouched.
if ! printf '%s' "$cmd" | grep -Eq '(^|[^[:alnum:]])git[[:space:]]+push([[:space:]]|$)'; then
  exit 0
fi

# Portion of the command from `git push` onward (its arguments).
push=$(printf '%s' "$cmd" | sed -E 's/.*git[[:space:]]+push//')

targets_main=0

# Explicit target of `main`: `... main`, `... HEAD:main`, `... src:main`, `+main`.
# `main` must be a whole token (won't match `maintenance` or `main-backup`).
if printf '%s' "$push" | grep -Eq '(^|[[:space:]:+])main([[:space:]]|$)'; then
  targets_main=1
fi

# Bare push (no branch refspec) resolves to the current branch's upstream.
# Strip option flags and count remaining tokens: <=1 means only a remote (or
# nothing) was given, i.e. the destination is the current branch.
refargs=$(printf '%s' "$push" | tr ' ' '\n' | grep -Ev '^-' | grep -v '^$' || true)
nrefs=$(printf '%s\n' "$refargs" | grep -c . || true)
if [ "${nrefs:-0}" -le 1 ]; then
  branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || echo "")
  if [ "$branch" = "main" ]; then
    targets_main=1
  fi
fi

if [ "$targets_main" -eq 1 ]; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Direct push to main is blocked. Create a feature branch (git checkout -b <type>/<slug>), push it (git push -u origin <branch>), then open a PR into main (gh pr create). For a real emergency, run the push yourself in a terminal outside Claude."}}
JSON
  exit 0
fi

exit 0
