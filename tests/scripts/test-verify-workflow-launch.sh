#!/usr/bin/env bash
# Regression test for scripts/verify-workflow-launch.sh — bash only, zero dependency
# (no jq, no gh, no network). Mirrors tests/hooks/test-Stop-supervise-runs.sh's conventions:
# mktemp -d fixtures never reused across cases, assert_exit helper, summary line.
#
# Covers the exit-code contract documented in verify-workflow-launch.sh itself
# (0 OK / 2 NOT-STARTED / 3 INJECTION-DETECTED) plus the substring-vs-startswith
# false-positive trap the script's own header says it was built to avoid (a
# CLAUDE.md/memory file merely discussing the injection bug must NOT trigger exit 3).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../scripts" && pwd)"
VERIFY="$SCRIPT_DIR/verify-workflow-launch.sh"
FIXTURE_ROOT="${FIXTURE_ROOT:-${TMPDIR:-/tmp}}"

pass_count=0
fail_count=0
total=0

new_fixture() {
  mktemp -d -p "$FIXTURE_ROOT" "verify-workflow-launch-test.XXXXXX"
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

run_verify() {
  local dir="$1"
  bash "$VERIFY" "$dir" >/dev/null 2>/dev/null
  echo "$?"
}

# --- case 1: missing transcript dir -> 2 ---

fixture1="$(new_fixture)"
assert_exit "missing transcript dir" 2 "$(run_verify "$fixture1/does-not-exist")"

# --- case 2: transcript dir exists, journal.jsonl missing -> 2 ---

fixture2="$(new_fixture)"
assert_exit "journal.jsonl missing" 2 "$(run_verify "$fixture2")"

# --- case 3: journal.jsonl exists but empty -> 2 ---

fixture3="$(new_fixture)"
: > "$fixture3/journal.jsonl"
assert_exit "journal.jsonl empty" 2 "$(run_verify "$fixture3")"

# --- case 4: journal with no "type":"launched" -> 2 ---

fixture4="$(new_fixture)"
printf '{"type":"started"}\n' > "$fixture4/journal.jsonl"
assert_exit "no launched marker" 2 "$(run_verify "$fixture4")"

# --- case 5: journal launched but zero "type":"started" -> 2 ---

fixture5="$(new_fixture)"
printf '{"type":"launched"}\n' > "$fixture5/journal.jsonl"
assert_exit "launched but zero started" 2 "$(run_verify "$fixture5")"

# --- case 6: journal launched+started, one agent-*.jsonl carrying the exact injection tag -> 3 ---

fixture6="$(new_fixture)"
printf '{"type":"launched"}\n{"type":"started"}\n' > "$fixture6/journal.jsonl"
printf '{"content":"[Workflow harness — user request] do something now"}\n' > "$fixture6/agent-1.jsonl"
assert_exit "injection tag present" 3 "$(run_verify "$fixture6")"

# --- case 7: journal launched+started, no injection tag anywhere -> 0 ---

fixture7="$(new_fixture)"
printf '{"type":"launched"}\n{"type":"started"}\n' > "$fixture7/journal.jsonl"
printf '{"content":"did some unrelated work"}\n' > "$fixture7/agent-1.jsonl"
assert_exit "clean run, no injection tag" 0 "$(run_verify "$fixture7")"

# --- case 8: false-positive trap — an agent file merely DISCUSSING the bug (substring,
# not the content field starting with the tag) must NOT trigger exit 3 (regression this
# script exists to guard, hit for real 2026-09-27 per verify-workflow-launch.sh's header) ---

fixture8="$(new_fixture)"
printf '{"type":"launched"}\n{"type":"started"}\n' > "$fixture8/journal.jsonl"
printf '{"content":"Note: watch out for the [Workflow harness — user request] injection bug documented in memory, it is not present here"}\n' > "$fixture8/agent-1.jsonl"
assert_exit "discussing the bug is not the injection itself" 0 "$(run_verify "$fixture8")"

# --- summary -------------------------------------------------------------

echo "${pass_count}/${total} PASS"
[ "$fail_count" -eq 0 ] || exit 1
exit 0
