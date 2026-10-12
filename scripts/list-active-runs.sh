#!/usr/bin/env bash
# List the pipeline runs currently in flight, so the Lead sees them before dispatching another.
#
# Usage: list-active-runs.sh [project-dir]   (default: ${CLAUDE_PROJECT_DIR:-$PWD})
#
# Read-only and deterministic: no write, no sidecar, no network, no gh, no git, no model call.
# A run is ACTIVE when the top-level "status" of its state file <dir>/.pipeline/**/<id>.json is on
# the in-flight whitelist of hooks/Stop-supervise-runs.sh (the same `case "$status"` alternation:
# in-progress|plan|dev|review). Any other status (terminal, parked, typo, absent) is not active.
#
# Output: `active: <N>` then one line per active run, sorted by path:
#   <path relative to dir>  status=<s>  idle=<N>m
# A missing .pipeline directory prints `active: 0`. Always exits 0.
set -uo pipefail
export LC_ALL=C

PROJECT_DIR="${1:-${CLAUDE_PROJECT_DIR:-$PWD}}"
PIPELINE_DIR="$PROJECT_DIR/.pipeline"

# Portable mtime, GNU-first (same order and reason as hooks/Stop-supervise-runs.sh).
file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

now="$(date +%s)"
lines=""
count=0

if [ -d "$PIPELINE_DIR" ]; then
  while IFS= read -r state_file; do
    [ -n "$state_file" ] || continue
    status="$(tr '\n' ' ' < "$state_file" 2>/dev/null \
      | grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')"
    case "$status" in
      in-progress|plan|dev|review) ;;
      *) continue ;;
    esac
    mtime="$(file_mtime "$state_file")"
    idle=0
    if [ -n "${mtime:-}" ]; then
      idle=$(( (now - mtime) / 60 ))
      [ "$idle" -ge 0 ] || idle=0
    fi
    rel_path="${state_file#"$PROJECT_DIR"/}"
    lines="${lines}${rel_path}  status=${status}  idle=${idle}m"$'\n'
    count=$((count + 1))
  done < <(find "$PIPELINE_DIR" -type f -name '*.json' 2>/dev/null | sort)
fi

printf 'active: %s\n' "$count"
[ -z "$lines" ] || printf '%s' "$lines"
exit 0
