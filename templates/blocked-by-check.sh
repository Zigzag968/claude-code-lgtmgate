#!/usr/bin/env bash
# Read-only resolver for the one-sided machine-readable blockedBy cross-repo signal (design: #104).
#
# Convention: a `<project>/.pipeline/**/<id>.json` state file MAY carry a "blockedBy" object
# naming an issue in ANOTHER repo this run is parked on:
#   { "repo": "<owner>/<repo>", "issue": <n>, "resolveOnLabel": "<label>" (optional,
#     default "auto:merged"), "since": "<iso8601>" (optional), "note": "<free text>" (optional) }
# `status: "blocked-by"` is the paired state-file value the orchestrator sets alongside it — a
# new awaiting-EXTERNAL status, not on hooks/Stop-supervise-runs.sh's in-flight whitelist, so a
# parked run is never nudged as stale by that watchdog (see README.md "Supervision of runs in
# flight").
#
# This script is READ-ONLY by design: it never mutates state in either repo — it never edits,
# comments on, closes, reopens or merges an issue/PR, never adds or removes a label, and never
# commits, pushes, checks out or stages anything in git. State mutation stays the calling
# orchestrator's job; this script only probes and prints a verdict.
#
# Usage: bash blocked-by-check.sh <state-file>
#
# Verdicts — ALWAYS followed by the fixed trailer as the LAST line, on every path including
# every error path:
#   [blocked-by] status=<verdict> repo=<repo|-> issue=<issue|-> label=<label|->
#
#   none       exit 0   no "blockedBy" key on the state file — nothing to do
#   resolved   exit 0   resolveOnLabel is present on the referenced issue — unblock the run
#   pending    exit 10  label absent, issue not (finally) closed as abandoned — stay parked
#   abandoned  exit 11  referenced issue CLOSED with stateReason "NOT_PLANNED" and no label —
#                        will never resolve on its own, escalate to a human
#   unknown    exit 20  probe failed, or the state file / its "blockedBy" object is malformed —
#                        fail-closed on the unblock decision, stay parked
#
# BLOCKED_BY_PROBE_CMD overrides the `gh` call with a command that prints the same JSON shape
# (top-level "state", "stateReason", "labels": [{"name": ...}, ...]) on stdout — the offline
# injection seam that makes this testable with zero network / zero real `gh`
# (templates/test-blocked-by-check.sh), same idiom as MANIFEST/WORKFLOW_FILE/HEADLESS_SCRIPT in
# templates/test-canonical-guards.sh.
#
# Deliberately does NOT `set -e`: every verdict is carried by its exit code, and the trailer
# must always print — including on the error paths above.
set -uo pipefail

STATE_FILE="${1:?usage: blocked-by-check.sh <state-file>}"

trailer() {
  printf '[blocked-by] status=%s repo=%s issue=%s label=%s\n' "${1:-unknown}" "${2:--}" "${3:--}" "${4:--}"
}

if [ ! -f "$STATE_FILE" ]; then
  trailer "unknown" "-" "-" "-"
  exit 20
fi

# --- parse blockedBy.{repo,issue,resolveOnLabel} from the state file -------------------------
PARSED="$(python3 -c '
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    print("ERROR")
    sys.exit(0)
bb = data.get("blockedBy")
if bb is None:
    print("NONE")
    sys.exit(0)
if not isinstance(bb, dict):
    print("ERROR")
    sys.exit(0)
repo = bb.get("repo")
issue = bb.get("issue")
label = bb.get("resolveOnLabel") or "auto:merged"
if not repo or not issue:
    print("ERROR")
    sys.exit(0)
print("OK|%s|%s|%s" % (repo, issue, label))
' "$STATE_FILE" 2>/dev/null)"

if [ "$PARSED" = "NONE" ]; then
  trailer "none" "-" "-" "-"
  exit 0
fi

case "$PARSED" in
  OK\|*) ;;
  *)
    trailer "unknown" "-" "-" "-"
    exit 20
    ;;
esac

REST="${PARSED#OK|}"
IFS='|' read -r REPO ISSUE LABEL <<EOF
$REST
EOF

# --- probe the blocker issue (gh, or the BLOCKED_BY_PROBE_CMD offline stub) -------------------
DEFAULT_PROBE_CMD='gh issue view "$ISSUE" --repo "$REPO" --json state,stateReason,labels'
PROBE_CMD="${BLOCKED_BY_PROBE_CMD:-$DEFAULT_PROBE_CMD}"
PROBE_JSON="$(eval "$PROBE_CMD" 2>/dev/null)"
PROBE_EXIT=$?

if [ "$PROBE_EXIT" -ne 0 ] || [ -z "$PROBE_JSON" ]; then
  trailer "unknown" "$REPO" "$ISSUE" "$LABEL"
  exit 20
fi

# --- verdict: label present -> resolved; closed+NOT_PLANNED w/o label -> abandoned; else pending
VERDICT="$(python3 -c '
import json, sys
label = sys.argv[1]
raw = sys.argv[2]
try:
    data = json.loads(raw)
except Exception:
    print("unknown")
    sys.exit(0)
labels = data.get("labels")
if not isinstance(labels, list):
    print("unknown")
    sys.exit(0)
names = [l.get("name") for l in labels if isinstance(l, dict)]
state = data.get("state")
reason = data.get("stateReason")
if label in names:
    print("resolved")
elif state == "CLOSED" and reason == "NOT_PLANNED":
    print("abandoned")
else:
    print("pending")
' "$LABEL" "$PROBE_JSON" 2>/dev/null)"

case "$VERDICT" in
  resolved)  trailer "resolved"  "$REPO" "$ISSUE" "$LABEL"; exit 0 ;;
  pending)   trailer "pending"   "$REPO" "$ISSUE" "$LABEL"; exit 10 ;;
  abandoned) trailer "abandoned" "$REPO" "$ISSUE" "$LABEL"; exit 11 ;;
  *)         trailer "unknown"   "$REPO" "$ISSUE" "$LABEL"; exit 20 ;;
esac
