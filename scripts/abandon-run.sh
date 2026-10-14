#!/usr/bin/env bash
# Mark a pipeline run as left on purpose, so the Stop hook stops reporting it.
#
# Usage: abandon-run.sh <state-file>
#
# Writes <state-file>.abandoned (a UTC ISO-8601 timestamp) next to the run's state file, the same
# sidecar family as `.nudged` in hooks/Stop-supervise-runs.sh. It never modifies, moves or deletes
# the state file. Idempotent. To report the run again: rm <state-file>.abandoned
# No jq, no gh, no git, no network. Exits 1 (writing nothing) when the argument is not an existing
# regular .json file.
set -uo pipefail

usage="Usage: abandon-run.sh <state-file>   (an existing .pipeline/**/<id>.json file)"

state_file="${1:-}"
if [ -z "$state_file" ]; then
  printf 'abandon-run: no state file given\n%s\n' "$usage" >&2
  exit 1
fi
if [ ! -f "$state_file" ]; then
  printf 'abandon-run: not an existing regular file: %s\n%s\n' "$state_file" "$usage" >&2
  exit 1
fi
case "$state_file" in
  *.json) ;;
  *)
    printf 'abandon-run: not a .json state file: %s\n%s\n' "$state_file" "$usage" >&2
    exit 1
    ;;
esac

if ! date -u +%Y-%m-%dT%H:%M:%SZ > "${state_file}.abandoned" 2>/dev/null; then
  printf 'abandon-run: cannot write %s.abandoned\n%s\n' "$state_file" "$usage" >&2
  exit 1
fi
printf 'abandoned: %s\n' "$state_file"
exit 0
