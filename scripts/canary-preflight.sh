#!/usr/bin/env bash
# canary-preflight.sh (#235) — read-only prerequisites of a canary run launched from the Lead session.
#
# Usage: bash scripts/canary-preflight.sh --consumer <dir> --issue <n> [--target <version>]   (run from the engine checkout)
#
# Runs every check and prints one line per problem:
#   canary-preflight: FAIL <cause>: <detail>. Fix: <exact command>
# then the last line `canary-preflight: ok` or `canary-preflight: <k> problem(s)`.
# Causes: clone-behind, stale-plugin, no-plugin, state-left, issue-not-ready.
# The only write is `git fetch origin <baseBranch>` in the consumer (refs only). Version staleness is
# decided by scripts/plugin-versions.sh and "in flight" by scripts/list-active-runs.sh (no second definition).
# Exit: 0 ok, 1 problems, 2 cannot decide (usage, not a git repository, no pipeline config, fetch failed,
# plugin-versions could not decide). See docs/consumer-reference.md (canary).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CONSUMER=""; ISSUE=""; TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --consumer) CONSUMER="${2:-}"; { shift; [ $# -gt 0 ] && shift; } ;;
    --issue) ISSUE="${2:-}"; { shift; [ $# -gt 0 ] && shift; } ;;
    --target) TARGET="${2:-}"; { shift; [ $# -gt 0 ] && shift; } ;;
    *) echo "canary-preflight: unknown argument '$1'. Usage: canary-preflight.sh --consumer <dir> --issue <n> [--target <version>]" >&2; exit 2 ;;
  esac
done

die2() { echo "canary-preflight: cannot decide: $1" >&2; exit 2; }

[ -n "$CONSUMER" ] && [ -n "$ISSUE" ] || die2 "usage: canary-preflight.sh --consumer <dir> --issue <n> [--target <version>]"
case "$ISSUE" in ''|*[!0-9]*) die2 "--issue must be a number, got '$ISSUE'" ;; esac
[ -d "$CONSUMER" ] || die2 "'$CONSUMER' is not a directory"
git -C "$CONSUMER" rev-parse --git-dir >/dev/null 2>&1 || die2 "'$CONSUMER' is not a git repository"
CONFIG="$CONSUMER/.claude/pipeline.config.json"
[ -f "$CONFIG" ] || die2 "no .claude/pipeline.config.json in '$CONSUMER'"

read_key() {
  python3 -c '
import json, sys
try:
    v = json.load(open(sys.argv[1])).get(sys.argv[2])
except (OSError, ValueError, AttributeError):
    v = None
print(v if isinstance(v, str) else "")' "$CONFIG" "$1"
}
BASE="$(read_key baseBranch)"; [ -n "$BASE" ] || BASE="main"
REPO="$(read_key repo)"
if [ -z "$REPO" ]; then
  REPO="$(git -C "$CONSUMER" remote get-url origin 2>/dev/null | sed -E 's#^.*[:/]([^/:]+/[^/]+)$#\1#; s#\.git$##')"
fi
[ -n "$REPO" ] || die2 "no repo in the consumer config and no origin remote"

git -C "$CONSUMER" fetch origin "$BASE" >/dev/null 2>&1 || die2 "git fetch origin $BASE failed in '$CONSUMER'"

PROBLEMS=0
problem() { # cause detail fix
  echo "canary-preflight: FAIL $1: $2. Fix: $3"
  PROBLEMS=$((PROBLEMS + 1))
}

# 1. clone behind its remote
BEHIND="$(git -C "$CONSUMER" rev-list --count "HEAD..origin/$BASE" 2>/dev/null)" || die2 "git rev-list failed in '$CONSUMER'"
case "$BEHIND" in ''|*[!0-9]*) die2 "unreadable rev-list count '$BEHIND'" ;; esac
if [ "$BEHIND" -gt 0 ]; then
  problem clone-behind "the consumer clone is $BEHIND commit(s) behind origin/$BASE" "git -C $CONSUMER merge --ff-only origin/$BASE"
fi

# 2. installed plugin (stale or absent), decided by plugin-versions.sh
PV_ARGS=(--project "$CONSUMER")
[ -z "$TARGET" ] || PV_ARGS+=(--target "$TARGET")
PV_OUT="$(bash "$HERE/plugin-versions.sh" "${PV_ARGS[@]}" </dev/null 2>/dev/null)"; PV_RC=$?
case "$PV_RC" in
  0|1) ;;
  *) die2 "scripts/plugin-versions.sh could not decide (exit $PV_RC); run it by hand: bash scripts/plugin-versions.sh --project $CONSUMER" ;;
esac
if printf '%s\n' "$PV_OUT" | tail -n 1 | grep -qF 'plugin-versions: no install of lgtmgate found'; then
  problem no-plugin "no install of lgtmgate applies to $CONSUMER, so /lgtmgate:deliver is absent in a headless session there" "install lgtmgate for the consumer scope (MAINTAINING.md, beta channel), then restart the session"
elif [ "$PV_RC" -eq 1 ]; then
  MISMATCH_LINE="$(printf '%s\n' "$PV_OUT" | grep -E 'MISMATCH|CONFLICT|LOADED-CACHE' | head -1)"
  [ -n "$MISMATCH_LINE" ] || MISMATCH_LINE="$(printf '%s\n' "$PV_OUT" | tail -n 1)"
  SCOPE="$(printf '%s' "$MISMATCH_LINE" | awk '{print $1}')"
  CHANNEL="$(printf '%s' "$MISMATCH_LINE" | sed -n 's/.*channel=\([^ ]*\).*/\1/p')"
  case "$SCOPE" in local|project|user) ;; *) SCOPE="local" ;; esac
  [ -n "$CHANNEL" ] || CHANNEL="<channel>"
  problem stale-plugin "$MISMATCH_LINE" "claude plugin update lgtmgate@$CHANNEL --scope $SCOPE, then restart the session"
fi

# 3. state left in the consumer (an in-flight run, or a non-terminal state file)
ACTIVE="$(bash "$HERE/list-active-runs.sh" "$CONSUMER" 2>/dev/null | sed -n '1s/^active: //p')"
case "$ACTIVE" in ''|*[!0-9]*) ACTIVE=0 ;; esac
if [ "$ACTIVE" -gt 0 ]; then
  problem state-left "$ACTIVE run(s) in flight under $CONSUMER/.pipeline" "capture the raw run data then clear it per skills/deliver/SKILL.md"
fi

# 4. the issue carries status:ready
LABELS="$(gh api "repos/$REPO/issues/$ISSUE" --jq '.labels|map(.name)|join(" ")' 2>/dev/null)" || die2 "gh api repos/$REPO/issues/$ISSUE failed"
case " $LABELS " in
  *" status:ready "*) ;;
  *) problem issue-not-ready "issue #$ISSUE of $REPO does not carry status:ready (labels: ${LABELS:-none})" "gh api -X POST repos/$REPO/issues/$ISSUE/labels -f 'labels[]=status:ready'" ;;
esac

if [ "$PROBLEMS" -eq 0 ]; then
  echo "canary-preflight: ok"
  exit 0
fi
echo "canary-preflight: $PROBLEMS problem(s)"
exit 1
