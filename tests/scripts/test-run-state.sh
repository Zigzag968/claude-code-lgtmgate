#!/usr/bin/env bash
# The engine writes the per-run state file (#502): op run-state of scripts/runtime/pr-write.sh puts
# <main checkout>/.pipeline/issue-<N>.json where the Stop watchdog looks, and the real hook reads it. When the
# main checkout is not writable (a worktree session, #663) it falls back to <worktree>/.pipeline.
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

named "main-checkout case unchanged: written at the main checkout, no copy in the worktree (#663 fallback not taken)" "$([ -f "$STATE" ] && [ ! -e "$WT/.pipeline/issue-7.json" ] && echo 1 || echo 0)"

# #663: common dir not writable (a worktree session) -> falls back to the worktree's own .pipeline
RO="$(cd "$AREA" && mkdir ro && cd ro && pwd -P)"
git -C "$RO" init -q 2>/dev/null
git -C "$RO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null
WTRO="$AREA/wtro"
git -C "$RO" worktree add -q "$WTRO" -b feat/issue-8 2>/dev/null
chmod a-w "$RO"
out="$(bash "$PW" run-state --issue 8 --status dev --worktree "$WTRO")"
FB="$WTRO/.pipeline/issue-8.json"
[ "$(printf '%s' "$out" | jq -r .result)" = written ] && ok=1 || ok=0
named "read-only common dir: run-state reports written" "$ok"
[ "$(jq -r .status "$FB" 2>/dev/null)" = dev ] && [ ! -e "$RO/.pipeline" ] && [ ! -e "$FB.tmp" ] && ok=1 || ok=0
named "fallback file holds status in the worktree .pipeline, nothing in the main checkout" "$ok"
scan="$(bash "$ROOT/scripts/list-active-runs.sh" "$WTRO" 2>/dev/null)"
printf '%s' "$scan" | grep -q 'active: 1' && printf '%s' "$scan" | grep -q '\.pipeline/issue-8\.json' && ok=1 || ok=0
named "list-active-runs.sh on the worktree sees the fallback file" "$ok"
backdate_mtime "$FB" $((45 * 60))
CLAUDE_PROJECT_DIR="$WTRO" CLAUDE_PROJECTS_DIR="$AREA/projects" bash "$HOOK" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok=1 || ok=0
named "Stop hook with CLAUDE_PROJECT_DIR=worktree reports the stalled fallback file" "$ok"
chmod u+w "$RO"

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

# phase (#614): status + run-state in one call, with a gh stub on PATH (no network)
STUB="$AREA/ghstub"; mkdir -p "$STUB"
cat > "$STUB/gh" <<'STUBEOF'
#!/bin/bash
echo "$*" >> "$GH_STUB_LOG"
case "$1 $2" in
  "api graphql")
    if [ "$GH_STUB_MODE" = fail ]; then echo "HTTP 401" >&2; exit 1; fi
    echo '{"data":{"repository":{"issue":{"projectItems":{"nodes":[{"id":"ITEM1","project":{"number":3},"fieldValues":{"nodes":[{"optionId":"OLD","field":{"id":"F1"}}]}}]}}}}}' ;;
  "project item-edit") exit 0 ;;
  *) exit 0 ;;
esac
STUBEOF
chmod +x "$STUB/gh"
PH="$AREA/phase"; mkdir -p "$PH"; git -C "$PH" init -q 2>/dev/null
PHARGS="--issue 21 --status dev --project-number 3 --project-id PID --field-id F1 --option-id NEW --repo o/r --worktree $PH"
export GH_STUB_LOG="$AREA/gh-stub.log"; : > "$GH_STUB_LOG"
out="$(PATH="$STUB:$PATH" GH_STUB_MODE=fail bash "$PW" phase $PHARGS)"
[ "$(printf '%s' "$out" | jq -r '.op + "/" + .result + "/" + .reason')" = "phase/failed/read-failed" ] \
  && ! grep -q 'item-edit' "$GH_STUB_LOG" && [ "$(jq -r .status "$PH/.pipeline/issue-21.json" 2>/dev/null)" = dev ] && ok=1 || ok=0
named "phase: status read fails, zero edit issued, run-state still written (rule i)" "$ok"

: > "$GH_STUB_LOG"; rm_state="$PH/.pipeline/issue-21.json"; echo '{}' > "$rm_state"
out="$(PATH="$STUB:$PATH" GH_STUB_MODE=ok bash "$PW" phase $PHARGS)"
[ "$(printf '%s' "$out" | jq -r '.op + "/" + .result')" = "phase/written" ] \
  && [ "$(grep -c 'item-edit' "$GH_STUB_LOG")" = 1 ] && [ "$(jq -r .status "$rm_state" 2>/dev/null)" = dev ] && ok=1 || ok=0
named "phase: happy path issues one item-edit and writes run-state" "$ok"

PHB="$AREA/phasebad"; mkdir -p "$PHB"; git -C "$PHB" init -q 2>/dev/null
out="$(PATH="$STUB:$PATH" GH_STUB_MODE=ok bash "$PW" phase --issue x --status dev --project-number 3 --project-id PID --field-id F1 --option-id NEW --worktree "$PHB")"
[ "$(printf '%s' "$out" | jq -r '.result + "/" + .reason')" = "failed/bad-args" ] && [ ! -e "$PHB/.pipeline/issue-x.json" ] && ok=1 || ok=0
named "phase: bad args -> failed/bad-args and no file" "$ok"

echo "[test-run-state] status=$([ "$fail" = 0 ] && echo ok || echo fail) passed=$pass failed=$fail"
[ "$fail" = 0 ]
