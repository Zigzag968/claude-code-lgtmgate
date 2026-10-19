#!/usr/bin/env bash
# Regression test for hooks/Stop-supervise-runs.sh — bash only, zero dependency
# (no jq, no gh, no network). Covers the pr-ready/needs-human false-positive
# fixed in issue #20, the blacklist->whitelist conversion fixed in issue #47
# (unknown/typo'd statuses must never be treated as in-flight), plus the
# true-positive and anti-spam behaviors it must not regress.
#
# Fixtures are created fresh per case under mktemp -d (never reused across
# unrelated cases, so one case's `.nudged` sidecar can't pollute another) and
# are intentionally left in place afterwards — nothing in this file deletes
# them (see .claude/rules/pr-acceptance.md on scratch vs in-place deletion).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../hooks" && pwd)"
HOOK="$SCRIPT_DIR/Stop-supervise-runs.sh"
FIXTURE_ROOT="${FIXTURE_ROOT:-${TMPDIR:-/tmp}}"

pass_count=0
fail_count=0
total=0

# --- helpers -----------------------------------------------------------

new_fixture() {
  mktemp -d -p "$FIXTURE_ROOT" "stop-supervise-test.XXXXXX"
}

# backdate_mtime <file> <seconds-ago>
backdate_mtime() {
  local file="$1" ago="$2"
  local epoch=$(( $(date +%s) - ago ))
  local ts
  ts="$(date -r "$epoch" +%Y%m%d%H%M 2>/dev/null || date -d "@$epoch" +%Y%m%d%H%M)"
  touch -t "$ts" "$file"
}

# write_state <fixture_dir> <name.json> <content>
write_state() {
  local fixture_dir="$1" name="$2" content="$3"
  mkdir -p "$fixture_dir/.pipeline"
  printf '%s' "$content" > "$fixture_dir/.pipeline/$name"
  echo "$fixture_dir/.pipeline/$name"
}

# run_hook <fixture_dir> -> prints exit code, stderr on fd 2 as usual
run_hook() {
  local fixture_dir="$1"
  CLAUDE_PROJECT_DIR="$fixture_dir" CLAUDE_PROJECTS_DIR="$fixture_dir/projects" bash "$HOOK" >/dev/null 2>/dev/null
  echo "$?"
}

# write_transcript <fixture_dir> <sessionId> <runId> <launched:0|1> <started:0|1> <injected:0|1>
# Creates <fixture_dir>/projects/<proj>/<sessionId>/subagents/workflows/<runId>/journal.jsonl
# (+ agent-1.jsonl carrying the exact injection tag when injected=1), matching the layout
# verify-workflow-launch.sh expects and CLAUDE_PROJECTS_DIR points run_hook at.
write_transcript() {
  local fixture_dir="$1" session_id="$2" run_id="$3" launched="$4" started="$5" injected="$6"
  local dir="$fixture_dir/projects/-some-project/$session_id/subagents/workflows/$run_id"
  mkdir -p "$dir"
  local journal=""
  [ "$launched" -eq 1 ] && journal="${journal}{\"type\":\"launched\"}\n"
  [ "$started" -eq 1 ] && journal="${journal}{\"type\":\"started\"}\n"
  printf '%b' "$journal" > "$dir/journal.jsonl"
  if [ "$injected" -eq 1 ]; then
    printf '{"content":"[Workflow harness — user request] do something"}\n' > "$dir/agent-1.jsonl"
  fi
  echo "$dir"
}

assert_exit() {
  local case_name="$1" expected="$2" actual="$3"
  total=$((total + 1))
  if [ "$actual" -eq "$expected" ]; then
    echo "PASS - $case_name (exit $actual)"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL - $case_name (expected exit $expected, got $actual)"
    fail_count=$((fail_count + 1))
  fi
}

# --- case 1: status=pr-ready, idle 45m -> 0 (the bug from issue #20) ---

fixture1="$(new_fixture)"
state1="$(write_state "$fixture1" "318.json" \
  '{"issue":318,"prNumber":460,"entryStage":"review","status":"pr-ready","runId":"wf_e4b68358-811","taskId":"wbipinz0i","resumeAttempts":0,"lastTouchedAt":"2026-08-01T01:38:50Z"}')"
backdate_mtime "$state1" $((45 * 60))
assert_exit "pr-ready idle 45m" 0 "$(run_hook "$fixture1")"

# --- case 2: status=needs-human, idle 45m -> 0 ---

fixture2="$(new_fixture)"
state2="$(write_state "$fixture2" "run.json" '{"status":"needs-human"}')"
backdate_mtime "$state2" $((45 * 60))
assert_exit "needs-human idle 45m" 0 "$(run_hook "$fixture2")"

# --- case 3: .json with no top-level "status" field, idle 45m -> 0 ---

fixture3="$(new_fixture)"
state3="$(write_state "$fixture3" "capacity.json" '{"note":"scratch file","notARun":true}')"
backdate_mtime "$state3" $((45 * 60))
assert_exit "no status field idle 45m" 0 "$(run_hook "$fixture3")"

# --- case 4: status=in-progress, idle 45m -> 2 (true positive preserved) ---

fixture4="$(new_fixture)"
state4="$(write_state "$fixture4" "run.json" '{"status":"in-progress"}')"
backdate_mtime "$state4" $((45 * 60))
exit4="$(run_hook "$fixture4")"
assert_exit "in-progress idle 45m" 2 "$exit4"

# --- case 5: status=in-progress, mtime=now -> 0 (not stale yet) ---

fixture5="$(new_fixture)"
state5="$(write_state "$fixture5" "run.json" '{"status":"in-progress"}')"
backdate_mtime "$state5" 0
assert_exit "in-progress fresh" 0 "$(run_hook "$fixture5")"

# --- case 6: status=merged, idle 45m -> 0 (terminal) ---

fixture6="$(new_fixture)"
state6="$(write_state "$fixture6" "run.json" '{"status":"merged"}')"
backdate_mtime "$state6" $((45 * 60))
assert_exit "merged idle 45m" 0 "$(run_hook "$fixture6")"

# --- case 7: anti-spam — 2nd consecutive run on case 4's fixture -> 0 ---

exit7="$(run_hook "$fixture4")"
assert_exit "anti-spam 2nd run on same stale fixture" 0 "$exit7"

# --- case 8: status=unknown, idle 45m -> 0 (not on the whitelist, issue #47) ---

fixture8="$(new_fixture)"
state8="$(write_state "$fixture8" "run.json" '{"status":"unknown"}')"
backdate_mtime "$state8" $((45 * 60))
assert_exit "unknown status idle 45m" 0 "$(run_hook "$fixture8")"

# --- case 9: status=in-progress, idle 45m, fresh fixture -> 2 (whitelisted, issue #47) ---

fixture9="$(new_fixture)"
state9="$(write_state "$fixture9" "run.json" '{"status":"in-progress"}')"
backdate_mtime "$state9" $((45 * 60))
assert_exit "whitelisted in-progress idle 45m" 2 "$(run_hook "$fixture9")"

# --- case 10: no status field at all, idle 45m -> 0 (unchanged behavior, issue #47) ---

fixture10="$(new_fixture)"
state10="$(write_state "$fixture10" "run.json" '{"note":"no status key here"}')"
backdate_mtime "$state10" $((45 * 60))
assert_exit "no status field at all idle 45m" 0 "$(run_hook "$fixture10")"

# --- case 11: status=blocked-by, idle 45m -> 0 (awaiting-external, issue #104) ---

fixture11="$(new_fixture)"
state11="$(write_state "$fixture11" "run.json" '{"status":"blocked-by"}')"
backdate_mtime "$state11" $((45 * 60))
assert_exit "blocked-by idle 45m" 0 "$(run_hook "$fixture11")"

# --- case 12: status split across lines (pretty-printed JSON), idle 45m -> 2 (issue #23) ---

fixture12="$(new_fixture)"
state12="$(write_state "$fixture12" "run.json" \
  '{
  "issue": 999,
  "status":
    "in-progress",
  "runId": "wf_test"
}')"
backdate_mtime "$state12" $((45 * 60))
assert_exit "split-line status in-progress idle 45m" 2 "$(run_hook "$fixture12")"

# --- case 13: in-progress + valid runId + clean fresh transcript -> 0 (issue #269, no false block on a healthy run) ---

fixture13="$(new_fixture)"
state13="$(write_state "$fixture13" "run.json" '{"status":"in-progress","runId":"wf_case13-aaa"}')"
backdate_mtime "$state13" 0
write_transcript "$fixture13" "sess13" "wf_case13-aaa" 1 1 0 >/dev/null
assert_exit "in-progress + valid runId + clean transcript" 0 "$(run_hook "$fixture13")"

# --- case 14: in-progress + valid runId + FRESH mtime + contaminated transcript -> 2 (issue #269, contamination checked independent of staleness age) ---

fixture14="$(new_fixture)"
state14="$(write_state "$fixture14" "run.json" '{"status":"in-progress","runId":"wf_case14-bbb"}')"
backdate_mtime "$state14" 0
write_transcript "$fixture14" "sess14" "wf_case14-bbb" 1 1 1 >/dev/null
exit14="$(run_hook "$fixture14")"
assert_exit "in-progress fresh mtime + contaminated transcript" 2 "$exit14"

# --- case 15: anti-spam — 2nd consecutive run_hook on case 14's fixture -> 0 (mirrors case 7 for .contam-nudged) ---

exit15="$(run_hook "$fixture14")"
assert_exit "anti-spam 2nd run on same contaminated fixture" 0 "$exit15"

# --- case 16: in-progress + runId with NO matching transcript dir anywhere -> 0 (too-early run must never false-block) ---

fixture16="$(new_fixture)"
state16="$(write_state "$fixture16" "run.json" '{"status":"in-progress","runId":"wf_case16-does-not-exist"}')"
backdate_mtime "$state16" 0
assert_exit "in-progress + unresolvable runId" 0 "$(run_hook "$fixture16")"

# --- case 17: status=merged + valid runId + contaminated transcript -> 0 (contamination gated by the SAME whitelist as staleness) ---

fixture17="$(new_fixture)"
state17="$(write_state "$fixture17" "run.json" '{"status":"merged","runId":"wf_case17-ccc"}')"
backdate_mtime "$state17" 0
write_transcript "$fixture17" "sess17" "wf_case17-ccc" 1 1 1 >/dev/null
assert_exit "merged + valid runId + contaminated transcript stays silent" 0 "$(run_hook "$fixture17")"

# --- cases 18-23: owner escape hatch scripts/abandon-run.sh (issue #571) ---

ABANDON="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/abandon-run.sh"

# case 18: unmarked review run, idle 45m -> 2 (control)
fixture18="$(new_fixture)"
state18="$(write_state "$fixture18" "run.json" '{"status":"review"}')"
backdate_mtime "$state18" $((45 * 60))
assert_exit "unmarked review idle 45m" 2 "$(run_hook "$fixture18")"

# case 19: abandon-run.sh exits 0 and writes the sidecar
fixture19="$(new_fixture)"
state19="$(write_state "$fixture19" "run.json" '{"status":"review"}')"
backdate_mtime "$state19" $((45 * 60))
cksum19="$(cksum < "$state19")"
bash "$ABANDON" "$state19" >/dev/null 2>&1
rc19=$?
sidecar19=1; [ -f "${state19}.abandoned" ] && sidecar19=0
assert_exit "abandon-run.sh exit 0, abandoned sidecar written" 0 "$((rc19 + sidecar19))"

# case 20: the state file is kept byte for byte
same20=1; [ -f "$state19" ] && [ "$(cksum < "$state19")" = "$cksum19" ] && same20=0
assert_exit "abandoned marking keeps the state file unchanged" 0 "$same20"

# case 21: marked run, idle 3944m, no .nudged yet -> 0
fixture21="$(new_fixture)"
state21="$(write_state "$fixture21" "run.json" '{"status":"review"}')"
backdate_mtime "$state21" $((3944 * 60))
bash "$ABANDON" "$state21" >/dev/null 2>&1
assert_exit "abandoned review idle 3944m" 0 "$(run_hook "$fixture21")"

# case 22: one marked, one unmarked, both stale -> 2, stderr names only the unmarked one
fixture22="$(new_fixture)"
marked22="$(write_state "$fixture22" "marked-run.json" '{"status":"review"}')"
other22="$(write_state "$fixture22" "other-run.json" '{"status":"dev"}')"
backdate_mtime "$marked22" $((45 * 60))
backdate_mtime "$other22" $((45 * 60))
bash "$ABANDON" "$marked22" >/dev/null 2>&1
err22="$(CLAUDE_PROJECT_DIR="$fixture22" CLAUDE_PROJECTS_DIR="$fixture22/projects" bash "$HOOK" 2>&1 >/dev/null)"
rc22=$?
names22=1
case "$err22" in
  *"other-run.json (status=dev"*) case "$err22" in *"marked-run.json ("*) ;; *) names22=0 ;; esac ;;
esac
assert_exit "abandoned sibling skipped, unmarked sibling reported" 0 "$(( (rc22 == 2 ? 0 : 1) + names22 ))"

# case 23: abandon-run.sh on a missing path -> exit 1, nothing written
fixture23="$(new_fixture)"
bash "$ABANDON" "$fixture23/.pipeline/nope.json" >/dev/null 2>&1
rc23=$?
none23=1; [ ! -e "$fixture23/.pipeline/nope.json.abandoned" ] && none23=0
assert_exit "abandon-run.sh missing file refused, no abandoned sidecar" 1 "$((rc23 + none23))"

# --- cases 24-27: the stale message names the per-run abandon command (issue #584) ---

# hook_stderr <fixture_dir> -> prints the hook's stderr, then a final line "rc=<exit code>"
hook_stderr() {
  local errfile rc
  errfile="$(mktemp -p "$FIXTURE_ROOT" "stop-supervise-err.XXXXXX")"
  CLAUDE_PROJECT_DIR="$1" CLAUDE_PROJECTS_DIR="$1/projects" bash "$HOOK" >/dev/null 2>"$errfile"
  rc=$?
  cat "$errfile"
  echo "rc=$rc"
}

# case 24: idle review run -> 2, the message carries the exact command with the absolute record path and the marker semantics
fixture24="$(new_fixture)"
state24="$(write_state "$fixture24" "run.json" '{"status":"review"}')"
backdate_mtime "$state24" $((6853 * 60))
err24="$(hook_stderr "$fixture24")"
miss24=0
for needle24 in \
  "rc=2" \
  "Pipeline run(s) in flight with no activity" \
  "bash $ABANDON '$state24'" \
  "never deletes or moves" \
  "any session of this repository" \
  "remove"; do
  case "$err24" in *"$needle24"*) ;; *) miss24=$((miss24 + 1)); echo "  missing in output: $needle24" ;; esac
done
assert_exit "idle review run: message names abandon-run.sh command, record path and marker semantics" 0 "$miss24"

# case 25: stale run marked with abandon-run.sh first -> 0, empty stderr
fixture25="$(new_fixture)"
state25="$(write_state "$fixture25" "run.json" '{"status":"review"}')"
backdate_mtime "$state25" $((6853 * 60))
bash "$ABANDON" "$state25" >/dev/null 2>&1
err25="$(hook_stderr "$fixture25")"
empty25=1; [ "$err25" = "rc=0" ] && empty25=0
assert_exit "abandoned idle run stays silent" 0 "$empty25"

# case 26: fresh review run -> 0, empty stderr
fixture26="$(new_fixture)"
state26="$(write_state "$fixture26" "run.json" '{"status":"review"}')"
backdate_mtime "$state26" 0
err26="$(hook_stderr "$fixture26")"
empty26=1; [ "$err26" = "rc=0" ] && empty26=0
assert_exit "fresh run still gets no stale message" 0 "$empty26"

# case 27: fresh in-progress run with a contaminated transcript -> 2, contamination message without the abandon command
fixture27="$(new_fixture)"
state27="$(write_state "$fixture27" "run.json" '{"status":"in-progress","runId":"wf_case27-ddd"}')"
backdate_mtime "$state27" 0
write_transcript "$fixture27" "sess27" "wf_case27-ddd" 1 1 1 >/dev/null
err27="$(hook_stderr "$fixture27")"
ok27=1
case "$err27" in
  *"rc=2"*"Contamination detected"*|*"Contamination detected"*"rc=2"*) case "$err27" in *"abandon-run.sh"*) ;; *) ok27=0 ;; esac ;;
esac
assert_exit "fresh contaminated run keeps its current message" 0 "$((ok27 == 0 ? 0 : 1))"

# --- summary -------------------------------------------------------------

echo "${pass_count}/${total} PASS"
[ "$fail_count" -eq 0 ] || exit 1
exit 0
