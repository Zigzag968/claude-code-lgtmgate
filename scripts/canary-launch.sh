#!/usr/bin/env bash
# canary-launch.sh (#235) — start a canary run from the Lead session through the headless profile (#245).
#
# Usage: bash scripts/canary-launch.sh --consumer <dir> --issue <n> --brief <text> --out-dir <dir> \
#          --max-turns <n> --max-budget-usd <x>
#
# A headless `claude` whose working directory is the consumer repository runs `/lgtmgate:deliver <n> "<brief>"`
# through scripts/run-workflow-headless.sh, unchanged (its refusals stay the single enforcement point), with the
# shipped settings and the plugin INSTALLED for the consumer scope: never --plugin-dir, --setting-sources, a bypass
# flag or --permission-mode. The caps are required, no default. The session inherits the maintainer's user
# settings, so its effective allow list can be wider than the profile (docs/headless.md, "Canary launch").
# Each refusal exits 2: `canary-launch: refused <cause>: <detail>. Fix: ...`, checked in this order:
#   engine-repo, not-configured, out-dir-used, bad-brief, run-in-flight.
# Then scripts/canary-preflight.sh runs (non-zero: its output is printed and this exits 1), the run is launched, and
# the output ends with scripts/canary-measure.sh <out-dir> (`canary: PASS` or `canary: FAIL <cause>`); the exit code
# is the measure's. Run directory: launch.json, result.json, stream.log, wrapper.out, optional gestures.log.
# See docs/consumer-reference.md (canary) for each refusal. bash 3.2 compatible, python3 for JSON.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
ENGINE_ROOT="$(cd "$HERE/.." && pwd -P)"

CONSUMER=""; ISSUE=""; BRIEF=""; OUT_DIR=""; MAX_TURNS=""; MAX_BUDGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --consumer) CONSUMER="${2:-}"; { shift; [ $# -gt 0 ] && shift; } ;;
    --issue) ISSUE="${2:-}"; { shift; [ $# -gt 0 ] && shift; } ;;
    --brief) BRIEF="${2:-}"; { shift; [ $# -gt 0 ] && shift; } ;;
    --out-dir) OUT_DIR="${2:-}"; { shift; [ $# -gt 0 ] && shift; } ;;
    --max-turns) MAX_TURNS="${2:-}"; { shift; [ $# -gt 0 ] && shift; } ;;
    --max-budget-usd) MAX_BUDGET="${2:-}"; { shift; [ $# -gt 0 ] && shift; } ;;
    *) echo "canary-launch: unknown argument '$1'. Usage: canary-launch.sh --consumer <dir> --issue <n> --brief <text> --out-dir <dir> --max-turns <n> --max-budget-usd <x>" >&2; exit 2 ;;
  esac
done

refuse() { # cause detail fix
  echo "canary-launch: refused $1: $2. Fix: $3" >&2
  exit 2
}

[ -n "$CONSUMER" ] || refuse usage "--consumer <dir> is required" "pass the canary consumer repository"
[ -n "$ISSUE" ] || refuse usage "--issue <n> is required" "pass the issue number"
case "$ISSUE" in *[!0-9]*) refuse usage "--issue must be a number, got '$ISSUE'" "pass the issue number" ;; esac
[ -n "$OUT_DIR" ] || refuse usage "--out-dir <dir> is required" "pass an empty run directory"
[ -n "$MAX_TURNS" ] || refuse usage "--max-turns <n> is required, no default" "pass --max-turns (docs/headless.md)"
[ -n "$MAX_BUDGET" ] || refuse usage "--max-budget-usd <x> is required, no default" "pass --max-budget-usd (docs/headless.md)"
[ -d "$CONSUMER" ] || refuse usage "'$CONSUMER' is not a directory" "pass the canary consumer repository"
CONSUMER="$(cd "$CONSUMER" && pwd -P)"

# 1. engine-repo: never run from, or against, the checkout that holds this script
TOP="$(git -C "$CONSUMER" rev-parse --show-toplevel 2>/dev/null)" || TOP=""
[ -n "$TOP" ] || TOP="$CONSUMER"
TOP="$(cd "$TOP" 2>/dev/null && pwd -P || echo "$TOP")"
if [ "$TOP" = "$ENGINE_ROOT" ] || [ "$CONSUMER" = "$ENGINE_ROOT" ]; then
  refuse engine-repo "'$CONSUMER' is the engine checkout" "pass the canary consumer repository, not the lgtmgate checkout"
fi
if [ -f "$CONSUMER/.claude-plugin/plugin.json" ] && grep -q '"name"[[:space:]]*:[[:space:]]*"lgtmgate"' "$CONSUMER/.claude-plugin/plugin.json"; then
  refuse engine-repo "'$CONSUMER' holds .claude-plugin/plugin.json naming lgtmgate" "pass the canary consumer repository, not an lgtmgate checkout"
fi

# 2. not-configured
[ -f "$CONSUMER/.claude/pipeline.config.json" ] || refuse not-configured "no .claude/pipeline.config.json in '$CONSUMER'" "run /lgtmgate:init in the consumer first"

# 3. out-dir-used, bad-brief
if [ -f "$OUT_DIR/launch.json" ]; then
  refuse out-dir-used "'$OUT_DIR' already holds a launch.json" "pass a new --out-dir"
fi
case "$BRIEF" in
  *\"*|*$'\n'*) refuse bad-brief "the brief contains a double quote or a newline" "rewrite the brief on one line without double quotes" ;;
esac

# 4. run-in-flight: a run listed by list-active-runs.sh, or a live launch lock
ACTIVE="$(bash "$HERE/list-active-runs.sh" "$CONSUMER" 2>/dev/null | sed -n '1s/^active: //p')"
case "$ACTIVE" in ''|*[!0-9]*) ACTIVE=0 ;; esac
[ "$ACTIVE" -eq 0 ] || refuse run-in-flight "$ACTIVE run(s) in flight under $CONSUMER/.pipeline" "wait for the run, or capture then clear its state per skills/deliver/SKILL.md"

LOCK="$CONSUMER/.pipeline/canary-launch.lock"
mkdir -p "$CONSUMER/.pipeline"
if ! mkdir "$LOCK" 2>/dev/null; then
  OLD_PID="$(cat "$LOCK/pid" 2>/dev/null)"
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    refuse run-in-flight "a launch holds $LOCK (pid $OLD_PID, alive)" "wait for that launch to end"
  fi
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null || refuse run-in-flight "cannot take $LOCK" "wait for the other launch to end"
fi
echo "$$" > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

mkdir -p "$OUT_DIR" || refuse out-dir-used "cannot create '$OUT_DIR'" "pass a writable --out-dir"
OUT_DIR="$(cd "$OUT_DIR" && pwd -P)"

# 5. preflight
PRE_OUT="$(bash "$HERE/canary-preflight.sh" --consumer "$CONSUMER" --issue "$ISSUE" 2>&1)"; PRE_RC=$?
if [ "$PRE_RC" -ne 0 ]; then
  printf '%s\n' "$PRE_OUT"
  exit 1
fi

# 6. launch
write_launch() { # wrapperStatus wrapperExit
  python3 -c '
import json, sys
issue, consumer, started, status, code = sys.argv[2:7]
json.dump({"issue": int(issue), "consumer": consumer, "startedAt": started,
           "wrapperStatus": status, "wrapperExit": int(code)}, open(sys.argv[1], "w"))
open(sys.argv[1], "a").write("\n")' "$OUT_DIR/launch.json" "$ISSUE" "$CONSUMER" "$STARTED" "$1" "$2"
}
STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
write_launch started 0

PROMPT="/lgtmgate:deliver $ISSUE \"$BRIEF\""
(
  cd "$CONSUMER" || exit 2
  printf '%s' "$PROMPT" | bash "$HERE/run-workflow-headless.sh" \
    --max-turns "$MAX_TURNS" --max-budget-usd "$MAX_BUDGET" --out "$OUT_DIR/result.json"
) > "$OUT_DIR/wrapper.out" 2> "$OUT_DIR/wrapper.err"
WRAP_RC=$?

WRAP_STATUS="$(sed -n 's/^\[wf-headless\] status=\([a-z-]*\) .*/\1/p' "$OUT_DIR/wrapper.out" | tail -n 1)"
[ -n "$WRAP_STATUS" ] || WRAP_STATUS="error"
STREAM="$(sed -n 's/^\[wf-headless\] stream-log=//p' "$OUT_DIR/wrapper.out" | head -n 1)"
if [ -n "$STREAM" ] && [ -f "$STREAM" ]; then cp "$STREAM" "$OUT_DIR/stream.log"; fi
write_launch "$WRAP_STATUS" "$WRAP_RC"

# 7. record
echo "canary-launch: run=$OUT_DIR"
bash "$HERE/canary-measure.sh" "$OUT_DIR"
exit $?
