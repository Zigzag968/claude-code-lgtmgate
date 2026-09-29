#!/usr/bin/env bash
# Stop hook — deterministic watchdog for pipeline runs left silently stuck.
#
# Convention (any orchestrator built on this plugin, not just one project):
# persisted per-run state lives under <project>/.pipeline/**/<id>.json, one
# JSON object per run, with a "status" field. Only a WHITELIST of statuses
# denotes an in-flight run worth nudging: "in-progress", "plan", "dev",
# "review". Everything else is skipped — terminal ("merged", "blocked",
# "done"), awaiting-human ("pr-ready", "needs-founder" — the run is
# correctly parked, waiting on a human, not silently stuck), awaiting-EXTERNAL
# ("blocked-by" — the run is correctly parked on an issue in ANOTHER repo, see
# README.md "Cross-repo blockedBy signal" and templates/blocked-by-check.sh),
# an absent status, an unrecognized/typo'd value, or a future status word the
# hook doesn't know about yet. A run is STALE when its status is on the
# whitelist AND its state file's mtime is older than the configured
# threshold. A `.json` file with no top-level "status" field at all isn't a
# state file per this convention and is ignored. Timestamps are always the
# file's own mtime (code), never the model.
#
# On stale runs found: exit 2 with a stderr message, which blocks the Stop
# event and re-prompts the Lead to do a supervision pass (resume the
# resumable, block the exhausted, escalate the ambiguous) instead of ending
# the turn with a run silently abandoned. No network calls, no `gh` — must
# stay millisecond-fast since it runs on every Stop event.
#
# Anti-spam: a `.nudged` sidecar per state file rate-limits re-nudging for
# that SAME run to at most once per threshold window, so an already-flagged
# stale run doesn't re-block every single turn.
#
# Optional field: "runId" (top-level, string, e.g. "wf_<hex>-<hex>"). When a
# whitelisted in-flight state file carries it, the hook opportunistically
# resolves that run's `Workflow` transcript dir under
# ~/.claude/projects/**/subagents/workflows/<runId>/ (overridable via
# CLAUDE_PROJECTS_DIR, for hermetic tests) and calls
# scripts/verify-workflow-launch.sh on it — the mechanical detector for the
# harness stale-message-injection bug (anthropics/claude-code#96640, #95369).
# This is opportunistic, never required: an orchestrator not carrying
# "runId" is skipped exactly like an absent "status" is skipped today, and a
# transcript dir that can't be resolved yet (run just launched, hasn't
# spawned an agent yet) is silently skipped this Stop, never treated as an
# error. A resolved transcript dir is cached in a `.transcriptdir` sidecar so
# the `find` under ~/.claude/projects (measured ~0.43s for a full miss
# across 181 session dirs, 2026-09-27) is only paid once per run, not once
# per Stop. A `.contam-nudged` sidecar rate-limits re-nudging the SAME run's
# contamination finding, mirroring `.nudged` above. Remove this wiring once
# claude-code#96640/#95369 ship a fix upstream (mirrors the removal note in
# scripts/verify-workflow-launch.sh itself).
set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
PIPELINE_DIR="$PROJECT_DIR/.pipeline"
CLAUDE_PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY_SCRIPT="$SCRIPT_DIR/../scripts/verify-workflow-launch.sh"
[ -x "$VERIFY_SCRIPT" ] || VERIFY_SCRIPT=""

# Nothing to supervise if the project doesn't use the .pipeline/ convention.
[ -d "$PIPELINE_DIR" ] || exit 0

# --- threshold: pipeline.config.json { "supervision": { "staleMinutes": N } }, default 30 ---
STALE_MINUTES=30
CONFIG_FILE="$PROJECT_DIR/.claude/pipeline.config.json"
if [ -f "$CONFIG_FILE" ]; then
  configured="$(grep -o '"staleMinutes"[[:space:]]*:[[:space:]]*[0-9]\+' "$CONFIG_FILE" 2>/dev/null \
    | grep -o '[0-9]\+$' | head -1 || true)"
  [ -n "${configured:-}" ] && STALE_MINUTES="$configured"
fi
STALE_SECONDS=$((STALE_MINUTES * 60))

# --- portable mtime, GNU-first (GNU/uutils `stat -c` on Linux, BSD `stat -f` on macOS) ---
# GNU-first order matters: on GNU/uutils stat, `-f` means `--file-system` (a different
# mode — prints a multi-line filesystem block and exits 1), so trying it first can
# pollute captured stdout even though the fallback then succeeds. GNU-first avoids that
# risk entirely: on macOS BSD stat, `-c` fails cleanly (`stat: illegal option -- c`,
# exit 1, no stdout) and falls through to `-f` with no side effect.
file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# resolve_transcript_dir <state_file> <runId> — echoes the transcript dir
# path if found (cached or freshly resolved), echoes nothing if not found
# yet (never an error — a run may simply not have spawned an agent yet).
resolve_transcript_dir() {
  local state_file="$1" run_id="$2"
  local cache="${state_file}.transcriptdir"
  if [ -s "$cache" ]; then
    local cached
    cached="$(cat "$cache" 2>/dev/null || true)"
    if [ -n "$cached" ] && [ -d "$cached" ]; then
      printf '%s' "$cached"
      return 0
    fi
  fi
  local found
  found="$(find "$CLAUDE_PROJECTS_DIR" -maxdepth 5 -mindepth 5 -type d -name "$run_id" 2>/dev/null | head -1)"
  if [ -n "$found" ]; then
    printf '%s' "$found" > "$cache" 2>/dev/null || true
    printf '%s' "$found"
  fi
}

now="$(date +%s)"
stale_lines=""
any_fresh_nudge=0
contam_lines=""
any_fresh_contam=0

while IFS= read -r -d '' state_file; do
  status="$(tr '\n' ' ' < "$state_file" 2>/dev/null \
    | grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')"

  case "$status" in
    in-progress|plan|dev|review) ;;  # whitelisted in-flight statuses — fall through
    *) continue ;;  # terminal, awaiting-human, not a state file, or unrecognized — never stale
  esac

  rel_path="${state_file#"$PROJECT_DIR"/}"

  # --- opportunistic contamination check (issue #269) — gated by the SAME
  # whitelist as staleness above, but independent of staleness/age: a fresh
  # (not-yet-stale) run with a contaminated transcript is flagged too.
  if [ -n "$VERIFY_SCRIPT" ]; then
    run_id="$(tr '\n' ' ' < "$state_file" 2>/dev/null \
      | grep -o '"runId"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')"
    if [ -n "${run_id:-}" ]; then
      transcript_dir="$(resolve_transcript_dir "$state_file" "$run_id")"
      if [ -n "$transcript_dir" ]; then
        verify_status=0
        "$VERIFY_SCRIPT" "$transcript_dir" >/dev/null 2>/dev/null || verify_status=$?
        if [ "$verify_status" -eq 3 ]; then
          contam_lines="${contam_lines}${rel_path} (runId=${run_id})\n"
          contam_marker="${state_file}.contam-nudged"
          contam_marker_mtime="$(file_mtime "$contam_marker" 2>/dev/null || echo 0)"
          contam_marker_age=$((now - contam_marker_mtime))
          if [ ! -f "$contam_marker" ] || [ "$contam_marker_age" -gt "$STALE_SECONDS" ]; then
            any_fresh_contam=1
            : > "$contam_marker" 2>/dev/null || true
          fi
        fi
      fi
    fi
  fi

  mtime="$(file_mtime "$state_file")"
  [ -n "${mtime:-}" ] || continue
  age=$((now - mtime))
  [ "$age" -gt "$STALE_SECONDS" ] || continue  # not stale yet

  age_min=$((age / 60))
  stale_lines="${stale_lines}${rel_path} (status=${status:-unknown}, idle ${age_min}m)\n"

  marker="${state_file}.nudged"
  marker_mtime="$(file_mtime "$marker" 2>/dev/null || echo 0)"
  marker_age=$((now - marker_mtime))
  if [ ! -f "$marker" ] || [ "$marker_age" -gt "$STALE_SECONDS" ]; then
    any_fresh_nudge=1
    : > "$marker" 2>/dev/null || true
  fi
done < <(find "$PIPELINE_DIR" -type f -name '*.json' -print0 2>/dev/null)

[ -n "$stale_lines" ] || [ -n "$contam_lines" ] || exit 0
[ "$any_fresh_nudge" -eq 1 ] || [ "$any_fresh_contam" -eq 1 ] || exit 0  # everything currently flagged was already nudged recently

msg=""
[ -z "$stale_lines" ] || msg="${msg}Pipeline run(s) in flight with no activity (threshold ${STALE_MINUTES}m):\n${stale_lines}Do a guard round: resume if resumable / block / escalate.\n"
[ -z "$contam_lines" ] || msg="${msg}Contamination detected (harness stale-message-injection, cf anthropics/claude-code#96640) on:\n${contam_lines}Do NOT trust the result of the affected agent without manual re-verification.\n"
printf '%b' "$msg" >&2
exit 2
