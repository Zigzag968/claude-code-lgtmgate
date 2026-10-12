#!/usr/bin/env bash
# The engine writes the per-run state file (#502): op run-state of scripts/runtime/pr-write.sh puts
# <main checkout>/.pipeline/issue-<N>.json where the Stop watchdog looks, and the real hook reads it.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PW="$ROOT/scripts/runtime/pr-write.sh"
HOOK="$ROOT/hooks/Stop-supervise-runs.sh"
pass=0; fail=0
check() { if [ "$2" = 1 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }
named() { if [ "$2" = 1 ]; then pass=$((pass+1)); echo "PASS - $1"; else fail=$((fail+1)); echo "FAIL: $1"; fi; }

AREA="$(mktemp -d "${TMPDIR:-/tmp}/run-state.XXXXXX")"
REPO="$(cd "$AREA" && mkdir repo && cd repo && pwd -P)"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null
WT="$AREA/wt"
git -C "$REPO" worktree add -q "$WT" -b feat/issue-7 2>/dev/null

backdate_mtime() {
  local epoch=$(( $(date +%s) - $2 )) ts
  ts="$(date -r "$epoch" +%Y%m%d%H%M 2>/dev/null || date -d "@$epoch" +%Y%m%d%H%M)"
  touch -t "$ts" "$1"
}

STATE="$REPO/.pipeline/issue-7.json"
for s in plan dev review ready; do
  out="$(bash "$PW" run-state --issue 7 --status "$s" --worktree "$WT")"
  [ "$(printf '%s' "$out" | jq -r .result)" = written ] && ok=1 || ok=0
  check "run-state $s reports written" "$ok"
  [ -f "$STATE" ] && [ "$(jq -r .status "$STATE" 2>/dev/null)" = "$s" ] && ok=1 || ok=0
  check "main checkout state file holds status $s" "$ok"
  [ "$(jq -r .issue "$STATE" 2>/dev/null)" = 7 ] && jq -e '.lastTouchedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' "$STATE" >/dev/null 2>&1 && ok=1 || ok=0
  check "state file after $s carries issue and lastTouchedAt" "$ok"
  [ ! -e "$WT/.pipeline/issue-7.json" ] && [ ! -e "$STATE.tmp" ] && ok=1 || ok=0
  check "after $s: no copy in the worktree, no temp file left" "$ok"
done

# bad arguments write nothing
BAD="$AREA/bad"; mkdir -p "$BAD"; git -C "$BAD" init -q 2>/dev/null
for args in "--issue 9 --status Bad_Status" "--issue x --status plan" "--issue 9"; do
  out="$(bash "$PW" run-state $args --worktree "$BAD")"
  [ "$(printf '%s' "$out" | jq -r '.result + "/" + .reason')" = "failed/bad-args" ] && [ ! -e "$BAD/.pipeline/issue-9.json" ] && ok=1 || ok=0
  check "bad args '$args' -> failed/bad-args and no file" "$ok"
done

# a directory that is not a git checkout falls back to its own .pipeline
PLAIN="$AREA/plain"; mkdir -p "$PLAIN"
out="$(bash "$PW" run-state --issue 5 --status dev --worktree "$PLAIN")"
[ "$(printf '%s' "$out" | jq -r .result)" = written ] && [ "$(jq -r .status "$PLAIN/.pipeline/issue-5.json" 2>/dev/null)" = dev ] && ok=1 || ok=0
check "non-git directory falls back to its own .pipeline" "$ok"

# the real Stop hook on the engine-written file
bash "$PW" run-state --issue 7 --status review --worktree "$WT" >/dev/null
backdate_mtime "$STATE" $((45 * 60))
CLAUDE_PROJECT_DIR="$REPO" CLAUDE_PROJECTS_DIR="$AREA/projects" bash "$HOOK" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok=1 || ok=0
named "Stop hook reports stalled engine state file" "$ok"

bash "$PW" run-state --issue 7 --status ready --worktree "$WT" >/dev/null
backdate_mtime "$STATE" $((45 * 60))
CLAUDE_PROJECT_DIR="$REPO" CLAUDE_PROJECTS_DIR="$AREA/projects" bash "$HOOK" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok=1 || ok=0
named "Stop hook ignores terminal engine state file" "$ok"

echo "[test-run-state] status=$([ "$fail" = 0 ] && echo ok || echo fail) passed=$pass failed=$fail"
[ "$fail" = 0 ]
