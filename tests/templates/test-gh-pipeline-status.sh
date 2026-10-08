#!/usr/bin/env bash
# Offline regression test for templates/gh-pipeline-status.sh (#147) — bash + jq only, zero
# network, zero real `gh`. Modeled on tests/templates/test-blocked-by-check.sh's shape
# (pass_count/fail_count/total counters, mktemp -d fixtures left in place).
#
# Covers:
#   1) config-driven owner/projectNumber reach `gh`, old hardcoded literal absent.
#   2) incomplete ghProject config fails closed, `gh` never invoked.
#   3) real auto-detect path: script copied under <repo>/.claude/scripts/, config two
#      levels up, resolved via git rev-parse --show-toplevel (no override env var).
#
# Not wired into .github/workflows/guards.yml — same precedent as
# tests/templates/test-blocked-by-check.sh (README.md), an offline-only test file not invoked there.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../templates" && pwd)"
RESOLVER="$SCRIPT_DIR/gh-pipeline-status.sh"
FIXTURE_ROOT="${FIXTURE_ROOT:-${TMPDIR:-/tmp}}"

pass_count=0
fail_count=0
total=0

# --- helpers -----------------------------------------------------------

new_fixture() {
  mktemp -d -p "$FIXTURE_ROOT" "gh-pipeline-status-test.XXXXXX"
}

# fake_gh <dir> -> writes a fake `gh` on PATH under <dir>/bin that logs its argv to
# <dir>/gh-calls.log and answers `project item-list` / `api graphql` with canned JSON.
fake_gh() {
  local dir="$1"
  mkdir -p "$dir/bin"
  cat > "$dir/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_GH_LOG"
case "$1" in
  project)
    echo '{"items":[{"id":"ITEM_1","content":{"number":799}}]}'
    ;;
  api)
    echo "In Progress"
    ;;
  *)
    echo "fake gh: unhandled args: $*" >&2
    exit 1
    ;;
esac
FAKE_GH
  chmod +x "$dir/bin/gh"
}

pass() {
  echo "PASS - $1"
  pass_count=$((pass_count + 1))
  total=$((total + 1))
}

fail() {
  echo "FAIL - $1"
  fail_count=$((fail_count + 1))
  total=$((total + 1))
}

# --- case 1: config-driven owner/projectNumber, no hardcoded literal ----

f1="$(new_fixture)"
fake_gh "$f1"
cfg1="$f1/pipeline.config.json"
printf '%s' '{"ghProject":{"owner":"SomeOtherOrg","projectNumber":42}}' > "$cfg1"
log1="$f1/gh-calls.log"
: > "$log1"

out1="$(PATH="$f1/bin:$PATH" FAKE_GH_LOG="$log1" LGTMGATE_CONFIG_FILE="$cfg1" bash "$RESOLVER" 799 2>"$f1/stderr")"
exit1=$?

if [ "$exit1" -ne 0 ]; then
  fail "config-driven resolves (expected exit 0, got $exit1; stderr: $(cat "$f1/stderr"))"
elif [ "$out1" != "In Progress" ]; then
  fail "config-driven resolves (expected status 'In Progress', got '$out1')"
elif ! grep -q -- '--owner SomeOtherOrg' "$log1"; then
  fail "config-driven resolves (call log missing --owner SomeOtherOrg: $(cat "$log1"))"
elif ! grep -q 'project item-list 42 ' "$log1"; then
  fail "config-driven resolves (call log missing 'item-list 42': $(cat "$log1"))"
elif grep -q 'Zigzag968' "$log1"; then
  fail "config-driven resolves (call log still contains hardcoded Zigzag968: $(cat "$log1"))"
elif grep -q 'item-list 1 ' "$log1"; then
  fail "config-driven resolves (call log still contains hardcoded 'item-list 1 ': $(cat "$log1"))"
else
  pass "config-driven resolves (owner=SomeOtherOrg projectNumber=42, no hardcoded literal, status='In Progress')"
fi

# --- case 2: incomplete ghProject config fails closed, gh never invoked --

f2="$(new_fixture)"
fake_gh "$f2"
cfg2="$f2/pipeline.config.json"
printf '%s' '{"ghProject":{}}' > "$cfg2"
log2="$f2/gh-calls.log"
# Intentionally do NOT pre-create log2 — the fake gh only creates it if invoked.

bash -c "PATH='$f2/bin:$PATH' FAKE_GH_LOG='$log2' LGTMGATE_CONFIG_FILE='$cfg2' bash '$RESOLVER' 799" >"$f2/stdout" 2>"$f2/stderr"
exit2=$?

if [ "$exit2" -eq 0 ]; then
  fail "incomplete config fails closed (expected non-zero exit, got 0)"
elif ! grep -q 'ghProject.owner' "$f2/stderr"; then
  fail "incomplete config fails closed (stderr missing 'ghProject.owner': $(cat "$f2/stderr"))"
elif [ -f "$log2" ]; then
  fail "incomplete config fails closed (gh was invoked: $(cat "$log2"))"
else
  pass "incomplete config fails closed (exit $exit2, gh never invoked)"
fi

# --- case 3: real auto-detect path (script under <repo>/.claude/scripts/) -

f3="$(new_fixture)"
fake_gh "$f3"
repo3="$f3/repo"
mkdir -p "$repo3/.claude/scripts"
cp "$RESOLVER" "$repo3/.claude/scripts/gh-pipeline-status.sh"
chmod +x "$repo3/.claude/scripts/gh-pipeline-status.sh"
printf '%s' '{"ghProject":{"owner":"AcmeCo","projectNumber":7}}' > "$repo3/.claude/pipeline.config.json"
git init -q "$repo3"
log3="$f3/gh-calls.log"
: > "$log3"

PATH="$f3/bin:$PATH" FAKE_GH_LOG="$log3" bash "$repo3/.claude/scripts/gh-pipeline-status.sh" 799 >/dev/null 2>"$f3/stderr"
exit3=$?

if [ "$exit3" -ne 0 ]; then
  fail "real auto-detect path (expected exit 0, got $exit3; stderr: $(cat "$f3/stderr"))"
elif ! grep -q -- '--owner AcmeCo' "$log3"; then
  fail "real auto-detect path (call log missing --owner AcmeCo: $(cat "$log3"))"
else
  pass "real auto-detect path (deployed layout <repo>/.claude/scripts/ + <repo>/.claude/pipeline.config.json resolved via git rev-parse --show-toplevel)"
fi

# --- summary -------------------------------------------------------------

echo "${pass_count}/${total} PASS"
[ "$fail_count" -eq 0 ] || exit 1
exit 0
