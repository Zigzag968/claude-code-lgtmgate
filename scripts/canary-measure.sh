#!/usr/bin/env bash
# canary-measure.sh (#235) — one measurement record for a canary run directory written by canary-launch.sh.
#
# Usage: bash scripts/canary-measure.sh <run-dir>
#
# Read-only: no git, no GitHub, no model call; a field no source records prints `none`.
# Run directory: launch.json (consumer, issue), result.json (the workflow output_file copy), stream.log
# (raw stream-json), optional gestures.log (one line per manual Lead gesture, `<ISO> <what>`; a line
# starting `[human-gate]`, or whose text after the timestamp starts with it, is not counted: that gesture is the one a human box asks for).
# Prints, in this order, one `canary-measure: <field>=<value>` line each: build, status, rounds,
# escalations, lead-gestures, permission-denials, non-terminal, probes, then the verdict
# `canary: PASS` or `canary: FAIL <cause>[,<cause>...]`.
# Causes: no-result, status-<status>, non-terminal-state:<n>, probes-missing, lead-gestures:<n>, permission-denials:<n>.
# A passing status is `ready` or `ready-pending-human`.
# Exit: 0 PASS, 1 FAIL, 2 unreadable run directory.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RUN="${1:-}"
if [ -z "$RUN" ] || [ ! -f "$RUN/launch.json" ]; then
  echo "canary-measure: unreadable run directory '$RUN' (no launch.json). Fix: pass the --out-dir given to canary-launch.sh" >&2
  exit 2
fi

CONSUMER="$(python3 -c '
import json, sys
try:
    v = json.load(open(sys.argv[1])).get("consumer")
except (OSError, ValueError, AttributeError):
    v = None
print(v if isinstance(v, str) else "")' "$RUN/launch.json")"
if [ -z "$CONSUMER" ]; then
  echo "canary-measure: launch.json in '$RUN' names no consumer. Fix: rerun canary-launch.sh" >&2
  exit 2
fi

# result.json -> build, status, rounds (tab separated; "none" when absent)
RESULT_FIELDS="$(python3 -c '
import json, sys
build = status = rounds = "none"
try:
    data = json.load(open(sys.argv[1]))
    res = data.get("result") if isinstance(data, dict) else None
    if isinstance(res, dict):
        if res.get("buildStamp") not in (None, ""):
            build = str(res["buildStamp"])
        if res.get("status") not in (None, ""):
            status = str(res["status"])
        if res.get("rounds") is not None:
            rounds = str(res["rounds"])
except (OSError, ValueError):
    pass
print("\t".join([build, status, rounds]))' "$RUN/result.json")"
BUILD="$(printf '%s' "$RESULT_FIELDS" | cut -f1)"
STATUS="$(printf '%s' "$RESULT_FIELDS" | cut -f2)"
ROUNDS="$(printf '%s' "$RESULT_FIELDS" | cut -f3)"

case "$STATUS" in ready|ready-pending-human) ESCALATIONS=0 ;; *) ESCALATIONS=1 ;; esac

GESTURES=0
if [ -f "$RUN/gestures.log" ]; then
  GESTURES="$(grep -v '^[[:space:]]*$' "$RUN/gestures.log" | grep -Evc '^([^ ]+ )?\[human-gate\]')"
fi

DENIALS=0
if [ -f "$RUN/stream.log" ]; then
  DENIALS="$(python3 -c '
import json, sys
n = 0
with open(sys.argv[1], errors="replace") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if isinstance(obj, dict) and obj.get("type") == "result":
            d = obj.get("permission_denials")
            n = len(d) if isinstance(d, list) else 0
print(n)' "$RUN/stream.log")"
fi

NONTERMINAL="$(bash "$HERE/list-active-runs.sh" "$CONSUMER" 2>/dev/null | sed -n '1s/^active: //p')"
case "$NONTERMINAL" in ''|*[!0-9]*) NONTERMINAL=0 ;; esac

if [ -d "$CONSUMER/.pipeline/probes" ]; then PROBES=present; else PROBES=absent; fi

echo "canary-measure: build=$BUILD"
echo "canary-measure: status=$STATUS"
echo "canary-measure: rounds=$ROUNDS"
echo "canary-measure: escalations=$ESCALATIONS"
echo "canary-measure: lead-gestures=$GESTURES"
echo "canary-measure: permission-denials=$DENIALS"
echo "canary-measure: non-terminal=$NONTERMINAL"
echo "canary-measure: probes=$PROBES"

CAUSES=""
add() { if [ -z "$CAUSES" ]; then CAUSES="$1"; else CAUSES="$CAUSES,$1"; fi; }
if [ "$STATUS" = "none" ]; then
  add no-result
else
  case "$STATUS" in ready|ready-pending-human) ;; *) add "status-$STATUS" ;; esac
fi
[ "$NONTERMINAL" -eq 0 ] || add "non-terminal-state:$NONTERMINAL"
[ "$PROBES" = "present" ] || add probes-missing
[ "$GESTURES" -eq 0 ] || add "lead-gestures:$GESTURES"
[ "$DENIALS" -eq 0 ] || add "permission-denials:$DENIALS"

if [ -z "$CAUSES" ]; then
  echo "canary: PASS"
  exit 0
fi
echo "canary: FAIL $CAUSES"
exit 1
