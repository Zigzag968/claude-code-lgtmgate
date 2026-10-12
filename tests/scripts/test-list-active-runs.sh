#!/usr/bin/env bash
# Regression test for scripts/list-active-runs.sh — bash only, fresh mktemp fixture per case.
# No network, no gh, no jq, no simulate seam.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_DIR/scripts/list-active-runs.sh"
HOOK="$REPO_DIR/hooks/Stop-supervise-runs.sh"

TMP_BASE="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
WORK="$(mktemp -d "$TMP_BASE/list-active-runs-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass_count=0
fail_count=0
total=0

# check <name> <command...> — passes when the command exits 0.
check() {
  local name="$1"; shift
  total=$((total + 1))
  if "$@" >/dev/null 2>&1; then
    pass_count=$((pass_count + 1)); echo "PASS: $name"
  else
    fail_count=$((fail_count + 1)); echo "FAIL: $name"
  fi
}

# eq <a> <b> — string equality as a command.
eq() { [ "$1" = "$2" ]; }
# has_line <text> <regex> — some line of text matches the regex.
has_line() { printf '%s\n' "$1" | grep -q -- "$2"; }

new_fixture() { local d; d="$(mktemp -d "$WORK/fx.XXXXXX")"; mkdir -p "$d/.pipeline"; printf '%s' "$d"; }
write_state() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; }
backdate_mtime() { # backdate_mtime <file> <minutes>
  local ts
  ts="$(date -v-"$2"M +%Y%m%d%H%M.%S 2>/dev/null || date -d "$2 minutes ago" +%Y%m%d%H%M.%S)"
  touch -t "$ts" "$1"
}
snapshot() { # path list + mtimes + content checksums
  local f
  ( cd "$1" && find . -print | sort | while IFS= read -r f; do
      printf '%s %s %s\n' "$f" "$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f")" \
        "$( if [ -f "$f" ]; then cksum < "$f"; else echo dir; fi )"
    done )
}

# 1. empty fixture and absent .pipeline
fx="$(new_fixture)"
out="$(bash "$SCRIPT" "$fx")"; rc=$?
check "empty .pipeline -> 'active: 0'" eq "$out" "active: 0"
check "empty .pipeline -> exit 0" eq "$rc" 0
out="$(bash "$SCRIPT" "$WORK/nonexistent-xyz")"; rc=$?
check "absent dir -> 'active: 0'" eq "$out" "active: 0"
check "absent dir -> exit 0" eq "$rc" 0

# 2. whitelisted statuses counted
fx="$(new_fixture)"
for s in in-progress plan dev review; do write_state "$fx/.pipeline/run-$s.json" "{\"status\": \"$s\"}"; done
out="$(bash "$SCRIPT" "$fx")"
check "four whitelisted statuses -> active: 4" eq "$(printf '%s\n' "$out" | head -1)" "active: 4"
for s in in-progress plan dev review; do
  check "line for status=$s" has_line "$out" "^.pipeline/run-$s.json  status=$s  idle=[0-9]*m\$"
done

# 3. non-active statuses not counted
fx="$(new_fixture)"
for s in ready plan-ready escalate review-died pr-ready blocked-by merged devx; do
  write_state "$fx/.pipeline/$s.json" "{\"status\": \"$s\"}"
done
write_state "$fx/.pipeline/nostatus.json" '{"runId": "wf_1"}'
out="$(bash "$SCRIPT" "$fx")"
check "non-active, typo and no-status files -> active: 0" eq "$out" "active: 0"

# 4. split-line status and nested file
fx="$(new_fixture)"
write_state "$fx/.pipeline/split.json" $'{"status":\n"dev"}'
write_state "$fx/.pipeline/sub/x.json" '{"status": "review"}'
out="$(bash "$SCRIPT" "$fx")"
check "split-line status counted" has_line "$out" '^.pipeline/split.json  status=dev'
check "nested file counted" has_line "$out" '^.pipeline/sub/x.json  status=review'

# 5. idle minutes
fx="$(new_fixture)"
write_state "$fx/.pipeline/old.json" '{"status": "dev"}'
backdate_mtime "$fx/.pipeline/old.json" 45
out="$(bash "$SCRIPT" "$fx")"
check "backdated 45m -> idle=45m" has_line "$out" 'idle=45m$'

# 6. deterministic order
fx="$(new_fixture)"
for n in c a b; do write_state "$fx/.pipeline/$n.json" '{"status": "plan"}'; done
o1="$(bash "$SCRIPT" "$fx")"; o2="$(bash "$SCRIPT" "$fx")"
check "output stable across two runs" eq "$o1" "$o2"
check "run lines sorted by path" eq "$(printf '%s\n' "$o1" | tail -n +2)" "$(printf '%s\n' "$o1" | tail -n +2 | LC_ALL=C sort)"

# 7. read-only
fx="$(new_fixture)"
write_state "$fx/.pipeline/a.json" '{"status": "dev"}'
write_state "$fx/.pipeline/b.json" '{"status": "ready"}'
backdate_mtime "$fx/.pipeline/a.json" 50
before="$(snapshot "$fx")"
bash "$SCRIPT" "$fx" >/dev/null
after="$(snapshot "$fx")"
check "read-only: files, mtimes, contents unchanged, no sidecar" eq "$before" "$after"

# 8. parity with the hook whitelist
check "whitelist alternation present in script" grep -q 'in-progress|plan|dev|review' "$SCRIPT"
check "whitelist alternation present in hook" grep -q 'in-progress|plan|dev|review' "$HOOK"

echo "$pass_count/$total PASS"
[ "$fail_count" -eq 0 ]
