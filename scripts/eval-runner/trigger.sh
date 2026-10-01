#!/usr/bin/env bash
# Drops an eval trigger for the LaunchAgent (#81). Usage: trigger.sh [--wait <seconds>] <worktree> [cases...]
# Env: LGTMGATE_EVAL_SPOOL (spool dir), LGTMGATE_EVAL_POLL (poll seconds, default 10). Prints the id.
# With --wait: polls done/<id>.rc, prints the summary, exits with the eval rc (124 on timeout). bash 3.2 safe.
set -u

wait_s=""
if [ "${1:-}" = "--wait" ]; then
  wait_s="${2:-}"
  case "$wait_s" in ""|*[!0-9]*) echo "trigger: --wait needs a number of seconds" >&2; exit 2 ;; esac
  shift 2
fi
if [ $# -lt 1 ]; then echo "usage: trigger.sh [--wait <seconds>] <worktree> [cases...]" >&2; exit 2; fi
if [ -z "${LGTMGATE_EVAL_SPOOL:-}" ]; then echo "trigger: LGTMGATE_EVAL_SPOOL is not set" >&2; exit 2; fi

wt="$(cd -P "$1" 2>/dev/null && pwd -P)" || { echo "trigger: not a directory: $1" >&2; exit 2; }
shift
spool="$LGTMGATE_EVAL_SPOOL"
[ -d "$spool/inbox" ] || { echo "trigger: $spool/inbox missing (run install.sh)" >&2; exit 2; }

id="$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM$RANDOM"
line="$wt"
for c in "$@"; do line="$line $c"; done
printf '%s\n' "$line" > "$spool/inbox/.$id.tmp" && mv "$spool/inbox/.$id.tmp" "$spool/inbox/$id.trigger" || exit 2
echo "$id"

[ -n "$wait_s" ] || exit 0
poll="${LGTMGATE_EVAL_POLL:-10}"
elapsed=0
while :; do
  if [ -f "$spool/done/$id.rc" ]; then
    cat "$spool/done/$id.summary" 2>/dev/null
    rc="$(cat "$spool/done/$id.rc")"
    echo "rc=$rc (log: $spool/done/$id.log)"
    exit "$rc"
  fi
  [ "$elapsed" -lt "$wait_s" ] || { echo "trigger: timeout after ${wait_s}s waiting for $id" >&2; exit 124; }
  sleep "$poll"
  elapsed=$((elapsed + poll))
done
