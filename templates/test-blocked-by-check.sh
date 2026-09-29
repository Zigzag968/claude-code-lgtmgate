#!/usr/bin/env bash
# Offline regression test for templates/blocked-by-check.sh (design: #104) — bash + python3
# only (python3 is already a hard dependency of templates/test-canonical-guards.sh invariants
# 1/2/3/4/10/11, so it is proven present in CI). Zero network, zero real `gh`: every case stubs
# the probe through BLOCKED_BY_PROBE_CMD, the resolver's own injection seam.
#
# Covers the five verdicts (none/resolved/pending/abandoned/unknown) plus a malformed-blockedBy
# case, a probe-failure case, and a custom resolveOnLabel — asserting BOTH the exit code and the
# `[blocked-by] status=...` trailer line, modeled on hooks/test-Stop-supervise-runs.sh's
# new_fixture()/write_state()/assert_exit() shape and its "${pass_count}/${total} PASS" summary.
#
# Fixtures are created fresh per case under mktemp -d and intentionally left in place afterwards
# — nothing in this file deletes them (see .claude/rules/pr-acceptance.md on scratch vs in-place
# deletion).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVER="$SCRIPT_DIR/blocked-by-check.sh"
FIXTURE_ROOT="${FIXTURE_ROOT:-${TMPDIR:-/tmp}}"

pass_count=0
fail_count=0
total=0

# --- helpers -----------------------------------------------------------

new_fixture() {
  mktemp -d -p "$FIXTURE_ROOT" "blocked-by-test.XXXXXX"
}

# write_json <dir> <name.json> <content> -> prints the written path
write_json() {
  local dir="$1" name="$2" content="$3"
  printf '%s' "$content" > "$dir/$name"
  echo "$dir/$name"
}

# run_resolver <state_file> <probe_cmd|""> -> prints "<exit>\n<stdout>"
run_resolver() {
  local state_file="$1" probe_cmd="$2"
  local out exit_code
  if [ -n "$probe_cmd" ]; then
    out="$(BLOCKED_BY_PROBE_CMD="$probe_cmd" bash "$RESOLVER" "$state_file" 2>/dev/null)"
  else
    out="$(bash "$RESOLVER" "$state_file" 2>/dev/null)"
  fi
  exit_code=$?
  printf '%s\n%s' "$exit_code" "$out"
}

# assert_case <name> <expected_exit> <expected_verdict_token> <run_resolver output>
assert_case() {
  local case_name="$1" expected_exit="$2" expected_verdict="$3" result="$4"
  local actual_exit actual_out
  actual_exit="$(printf '%s' "$result" | head -1)"
  actual_out="$(printf '%s' "$result" | tail -n +2)"
  total=$((total + 1))

  if [ "$actual_exit" -ne "$expected_exit" ]; then
    echo "FAIL - $case_name (expected exit $expected_exit, got $actual_exit; output: $actual_out)"
    fail_count=$((fail_count + 1))
    return
  fi

  local expected_trailer_token="status=${expected_verdict}"
  if ! printf '%s' "$actual_out" | tail -1 | grep -q "^\[blocked-by\] ${expected_trailer_token} "; then
    echo "FAIL - $case_name (trailer missing '${expected_trailer_token}': got '$(printf '%s' "$actual_out" | tail -1)')"
    fail_count=$((fail_count + 1))
    return
  fi

  echo "PASS - $case_name (exit $actual_exit, $(printf '%s' "$actual_out" | tail -1))"
  pass_count=$((pass_count + 1))
}

REAL_100_PROBE_JSON='{"closedAt":"2026-08-30T15:41:36Z","labels":[{"name":"auto:merged"}],"number":100,"state":"CLOSED","stateReason":"COMPLETED","title":"feat(pipeline): port resolveWorktreeRoot()"}'

# --- case 1: no "blockedBy" key -> none/0 -------------------------------

f1="$(new_fixture)"
s1="$(write_json "$f1" "run.json" '{"issue":799,"status":"in-progress"}')"
assert_case "no blockedBy key" 0 "none" "$(run_resolver "$s1" "")"

# --- case 2: real #100 payload (label present) -> resolved/0 -----------

f2="$(new_fixture)"
s2="$(write_json "$f2" "run.json" '{"issue":799,"status":"blocked-by","blockedBy":{"repo":"Zigzag968/lgtmgate","issue":100}}')"
p2="$(write_json "$f2" "probe.json" "$REAL_100_PROBE_JSON")"
assert_case "real #100 payload resolved" 0 "resolved" "$(run_resolver "$s2" "cat '$p2'")"

# --- case 3: same issue, OPEN, no label -> pending/10 -------------------

f3="$(new_fixture)"
s3="$(write_json "$f3" "run.json" '{"issue":799,"status":"blocked-by","blockedBy":{"repo":"Zigzag968/lgtmgate","issue":100}}')"
p3="$(write_json "$f3" "probe.json" '{"state":"OPEN","stateReason":null,"labels":[]}')"
assert_case "open no label pending" 10 "pending" "$(run_resolver "$s3" "cat '$p3'")"

# --- case 4: CLOSED, stateReason NOT_PLANNED, no label -> abandoned/11 --

f4="$(new_fixture)"
s4="$(write_json "$f4" "run.json" '{"issue":799,"status":"blocked-by","blockedBy":{"repo":"Zigzag968/lgtmgate","issue":100}}')"
p4="$(write_json "$f4" "probe.json" '{"state":"CLOSED","stateReason":"NOT_PLANNED","labels":[]}')"
assert_case "closed not-planned abandoned" 11 "abandoned" "$(run_resolver "$s4" "cat '$p4'")"

# --- case 5: probe exits non-zero -> unknown/20 -------------------------

f5="$(new_fixture)"
s5="$(write_json "$f5" "run.json" '{"issue":799,"status":"blocked-by","blockedBy":{"repo":"Zigzag968/lgtmgate","issue":100}}')"
assert_case "probe failure unknown" 20 "unknown" "$(run_resolver "$s5" "false")"

# --- case 6: blockedBy missing "issue" -> unknown/20 --------------------

f6="$(new_fixture)"
s6="$(write_json "$f6" "run.json" '{"issue":799,"status":"blocked-by","blockedBy":{"repo":"Zigzag968/lgtmgate"}}')"
assert_case "blockedBy missing issue unknown" 20 "unknown" "$(run_resolver "$s6" "")"

# --- case 7: custom resolveOnLabel honored -> resolved/0 ----------------

f7="$(new_fixture)"
s7="$(write_json "$f7" "run.json" '{"issue":799,"status":"blocked-by","blockedBy":{"repo":"x/y","issue":5,"resolveOnLabel":"custom:done"}}')"
p7="$(write_json "$f7" "probe.json" '{"state":"OPEN","stateReason":null,"labels":[{"name":"custom:done"}]}')"
assert_case "custom resolveOnLabel resolved" 0 "resolved" "$(run_resolver "$s7" "cat '$p7'")"

# --- case 8: "blockedBy" present but not an object -> unknown/20 (malformed) --

f8="$(new_fixture)"
s8="$(write_json "$f8" "run.json" '{"issue":799,"status":"blocked-by","blockedBy":"oops"}')"
assert_case "malformed blockedBy (not an object) unknown" 20 "unknown" "$(run_resolver "$s8" "")"

# --- case 9: state file itself does not exist -> unknown/20 -------------

assert_case "missing state file unknown" 20 "unknown" "$(run_resolver "$FIXTURE_ROOT/does-not-exist-$$.json" "")"

# --- summary -------------------------------------------------------------

echo "${pass_count}/${total} PASS"
[ "$fail_count" -eq 0 ] || exit 1
exit 0
