#!/usr/bin/env bash
# Regression test for scripts/guards.cjs. Drives it through its env seams
# (GUARDS_BASE_FILE / GUARDS_BRANCH_FILE / GUARDS_BASE_MANIFEST / GUARDS_BRANCH_MANIFEST,
# GUARDS_ONLY) with throwaway files under $TMPDIR — never mutates tracked files.
# Cases: positive (same counts), 3 negative R1 counters, parser markers not counted,
# version floor. Ends with `[test-guards] status=<ok|fail> passed=<n> failed=<n>`.
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1
T="$(mktemp -d "${TMPDIR:-/tmp}/test-guards.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PASS_N=0; FAIL_N=0
ok()  { echo "PASS: $1"; PASS_N=$((PASS_N + 1)); }
ko()  { echo "FAIL: $1"; FAIL_N=$((FAIL_N + 1)); }

BASE="$T/base.js"
cat > "$BASE" <<'JS'
async function callAgent(role, prompt) {
  const s = { a: 1 }
  return await agent(prompt, s)
}
async function run() {
  if (simulate && simulate.theo) return simulate.theo
  const out = await callAgent('x', 'y')
  return /a/.test(out)
}
JS

# run_r1 <branch-file> -> sets RC and OUT
run_r1() {
  OUT="$(GUARDS_ONLY=r1 GUARDS_BASE_FILE="$BASE" GUARDS_BRANCH_FILE="$1" node scripts/guards.cjs 2>&1)"; RC=$?
}
expect_up() { # <label> <counter>
  if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qE "^R1 $2 base=[0-9]+ branch=[0-9]+ UP$"; then ok "$1"; else ko "$1 (rc=$RC) $OUT"; fi
}

# positive: identical file
run_r1 "$BASE"
if [ "$RC" -eq 0 ] && [ "$(echo "$OUT" | grep -c ' ok$')" -eq 3 ]; then ok "same counts -> exit 0, three ok lines"; else ko "same counts (rc=$RC) $OUT"; fi

# negative: one more await agent( outside callAgent
cp "$BASE" "$T/b1.js"; printf 'async function extra() { return await agent("p", {}) }\n' >> "$T/b1.js"
run_r1 "$T/b1.js"; expect_up "extra await agent( outside callAgent -> agent-calls UP" agent-calls

# negative: one more distinct simulate key
cp "$BASE" "$T/b2.js"; printf 'const k = simulate.x\n' >> "$T/b2.js"
run_r1 "$T/b2.js"; expect_up "new simulate.x key -> simulate-seams UP" simulate-seams

# negative: one more .match( outside markers
cp "$BASE" "$T/b3.js"; printf 'const m = out.match(/z/)\n' >> "$T/b3.js"
run_r1 "$T/b3.js"; expect_up "new .match( outside markers -> agent-output-regex UP" agent-output-regex

# positive: the same .match( inside parser markers does not count
cp "$BASE" "$T/b4.js"
printf '// guards:parser-begin\nconst m = out.match(/z/)\n// guards:parser-end\n' >> "$T/b4.js"
run_r1 "$T/b4.js"
if [ "$RC" -eq 0 ]; then ok "occurrence inside parser markers not counted -> exit 0"; else ko "parser markers (rc=$RC) $OUT"; fi

# positive: a parser moved inside markers lowers the counter (branch < base is ok)
run_r1_lower() { OUT="$(GUARDS_ONLY=r1 GUARDS_BASE_FILE="$T/b3.js" GUARDS_BRANCH_FILE="$T/b4.js" node scripts/guards.cjs 2>&1)"; RC=$?; }
run_r1_lower
if [ "$RC" -eq 0 ]; then ok "counter going down -> exit 0"; else ko "lower (rc=$RC) $OUT"; fi

# invariant 1 (relaxed): version floor
printf '{"version":"0.8.5"}\n' > "$T/m-old.json"; printf '{"version":"0.8.10"}\n' > "$T/m-new.json"
OUT="$(GUARDS_ONLY=version GUARDS_BASE_MANIFEST="$T/m-new.json" GUARDS_BRANCH_MANIFEST="$T/m-old.json" node scripts/guards.cjs 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: version-floor'; then ok "lower version -> FAIL"; else ko "lower version (rc=$RC) $OUT"; fi
OUT="$(GUARDS_ONLY=version GUARDS_BASE_MANIFEST="$T/m-old.json" GUARDS_BRANCH_MANIFEST="$T/m-new.json" node scripts/guards.cjs 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then ok "higher version (0.8.10 > 0.8.5, numeric compare) -> ok"; else ko "higher version (rc=$RC) $OUT"; fi

STATUS=ok; [ "$FAIL_N" -eq 0 ] || STATUS=fail
echo "[test-guards] status=${STATUS} passed=${PASS_N} failed=${FAIL_N}"
[ "$FAIL_N" -eq 0 ]
