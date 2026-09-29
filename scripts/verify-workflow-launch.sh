#!/usr/bin/env bash
# verify-workflow-launch.sh — mechanical post-launch health check for a Workflow run's
# transcript directory. Any session driving this plugin's deliver-pipeline (nightly's Lead,
# or an interactive Lead on any consumer repo) should call this right after every
# Workflow(...) launch/resume, once the run has had a moment to spawn its first agent(s).
#
# Checks (all mechanical, no reliance on any agent's own self-report):
#   1. The transcript dir + journal.jsonl exist and are non-empty (the run actually started).
#   2. At least one agent was spawned (a "started" journal entry).
#   3. No agent transcript carries the Workflow-harness stale-message-injection marker
#      (anthropics/claude-code#96640, #95369 — open, unfixed as of 2026-09-27). REMOVE this
#      check (and this script's #3 concern entirely) once that bug ships a fix upstream —
#      it exists solely as a stopgap for a harness bug, not a permanent pipeline feature.
#
# The injection check matches on the JSON message content field STARTING WITH the exact tag —
# not a bare substring grep. A substring grep false-positives on any agent whose loaded context
# (e.g. a CLAUDE.md/memory file) merely quotes or discusses the bug, which is a real and
# non-obvious trap (hit while building this script, 2026-09-27 — a Lead session's own memory
# note about this exact bug got matched as if it were the injection itself).
#
# Usage: verify-workflow-launch.sh <transcriptDir>
#   <transcriptDir> is the "Transcript dir:" path the Workflow tool result printed for this run
#   (~/.claude/projects/<session>/subagents/workflows/<runId>/).
#
# Exit codes:
#   0  OK — run started, no injection detected
#   2  NOT-STARTED — journal missing/empty, or zero agents spawned yet (too early, or dead)
#   3  INJECTION-DETECTED — one or more agents received the stale-message-injection frame;
#      treat that agent's result as unverified until manually re-checked against real state
set -euo pipefail

dir="${1:?usage: verify-workflow-launch.sh <transcriptDir>}"

if [ ! -d "$dir" ]; then
  echo "NOT-STARTED: transcript dir missing ($dir)"
  exit 2
fi

journal="$dir/journal.jsonl"
if [ ! -s "$journal" ]; then
  echo "NOT-STARTED: journal.jsonl missing or empty ($journal)"
  exit 2
fi

if ! grep -q '"type":"launched"' "$journal"; then
  echo "NOT-STARTED: no launched marker in journal"
  exit 2
fi

started_count=$(grep -c '"type":"started"' "$journal" || true)
if [ "$started_count" -eq 0 ]; then
  echo "NOT-STARTED: launched but zero agents started yet"
  exit 2
fi

injected="$(grep -l '"content":"\[Workflow harness — user request\]' "$dir"/agent-*.jsonl 2>/dev/null || true)"
if [ -n "$injected" ]; then
  echo "INJECTION-DETECTED:"
  echo "$injected"
  exit 3
fi

echo "OK: $started_count agent(s) started, no injection marker found"
exit 0
