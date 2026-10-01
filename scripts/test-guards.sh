#!/usr/bin/env bash
# Regression test for scripts/guards.cjs. Drives it through its env seams
# (GUARDS_BASE_FILE / GUARDS_BRANCH_FILE / GUARDS_BASE_MANIFEST / GUARDS_BRANCH_MANIFEST,
# GUARDS_ONLY) with throwaway files under $TMPDIR — never mutates tracked files.
# Cases: positive (same counts), 3 negative R1 counters, parser markers not counted/balanced,
# block comments, multi-line agent calls, missing base, all-tests-wired (wired/unwired/comment-only),
# version floor, sam-parity, doc-budgets (at budget / over / missing / per-line cap, through GUARDS_ROOT).
# Ends with `[test-guards] status=<ok|fail> passed=<n> failed=<n>`.
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

# negative: a new simulate.probes.<key> (dotted, bracket, optional-chain forms) counts as a seam
cp "$BASE" "$T/b2a.js"; printf 'const k = simulate.probes.brandNewSeamA\n' >> "$T/b2a.js"
run_r1 "$T/b2a.js"; expect_up "new simulate.probes.x key -> simulate-seams UP" simulate-seams
cp "$BASE" "$T/b2b.js"; printf "const k = simulate.probes['brandNewSeamB']\n" >> "$T/b2b.js"
run_r1 "$T/b2b.js"; expect_up "new simulate.probes['x'] bracket key -> simulate-seams UP" simulate-seams
cp "$BASE" "$T/b2c.js"; printf 'const k = simulate?.probes?.brandNewSeamC\n' >> "$T/b2c.js"
run_r1 "$T/b2c.js"; expect_up "new simulate?.probes?.x optional-chain key -> simulate-seams UP" simulate-seams

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

# version floor, semver 2.0.0 §11 precedence (prerelease channel 1.0.0-beta.N): <base> <branch> <ok|fail>
while read -r vb vn want; do
  printf '{"version":"%s"}\n' "$vb" > "$T/vf-base.json"; printf '{"version":"%s"}\n' "$vn" > "$T/vf-branch.json"
  OUT="$(GUARDS_ONLY=version GUARDS_BASE_MANIFEST="$T/vf-base.json" GUARDS_BRANCH_MANIFEST="$T/vf-branch.json" node scripts/guards.cjs 2>&1)"; RC=$?
  if [ "$want" = ok ] && [ "$RC" -eq 0 ]; then ok "version floor: branch $vn vs main $vb -> ok"
  elif [ "$want" = fail ] && [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: version-floor'; then ok "version floor: branch $vn vs main $vb -> FAIL"
  else ko "version floor: branch $vn vs main $vb expected $want (rc=$RC) $OUT"; fi
done <<'EOF'
0.8.113 1.0.0-beta.1 ok
1.0.0-beta.1 1.0.0-beta.1 ok
1.0.0-beta.1 1.0.0-beta.2 ok
1.0.0-beta.2 1.0.0-beta.1 fail
1.0.0-beta.2 1.0.0-beta.10 ok
1.0.0-beta.10 1.0.0-beta.2 fail
1.0.0-beta.9 1.0.0 ok
1.0.0 1.0.0-beta.9 fail
1.0.0-alpha.9 1.0.0-beta.1 ok
1.0.0-beta.1 1.0.0-alpha.9 fail
1.0.0-beta 1.0.0-beta.1 ok
1.0.0-beta.1 1.0.0-beta fail
1.0.0-1 1.0.0-beta ok
1.0.0-beta 1.0.0-1 fail
1.0.0+build.5 1.0.0 ok
1.0.0 1.0.0+build.5 ok
1.0.0 1.0.0garbage fail
EOF
printf '{"version":"1.0.0-beta.1"}\n' > "$T/vf-base.json"; printf '{"version":"1.0.0-beta.2"}\n' > "$T/vf-branch.json"
OUT="$(GUARDS_ONLY=version GUARDS_BASE_MANIFEST="$T/vf-base.json" GUARDS_BRANCH_MANIFEST="$T/vf-branch.json" node scripts/guards.cjs 2>&1)"
if [ "$OUT" = "PASS: version-floor: branch 1.0.0-beta.2 >= origin/main 1.0.0-beta.1" ]; then ok "version floor message names the full prerelease versions"; else ko "version floor message: $OUT"; fi

# ---- R1: comments and multi-line calls ----
# block comments are skipped by all three counters
cp "$BASE" "$T/c1.js"
printf '/* await agent("p", {})\n   simulate.zz\n   out.match(/z/) */\n' >> "$T/c1.js"
run_r1 "$T/c1.js"
if [ "$RC" -eq 0 ]; then ok "block comment content not counted by any counter -> exit 0"; else ko "block comment (rc=$RC) $OUT"; fi

# await split across lines is counted
cp "$BASE" "$T/c2.js"; printf 'async function extra() { return await\n  agent("p", {}) }\n' >> "$T/c2.js"
run_r1 "$T/c2.js"; expect_up "multi-line await\\n agent( -> agent-calls UP" agent-calls

# ---- R1: parser marker balance ----
cp "$BASE" "$T/m1.js"; printf '// guards:parser-begin\nconst m = out.match(/z/)\n' >> "$T/m1.js"
run_r1 "$T/m1.js"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: R1 parser markers:.*unclosed guards:parser-begin at line'; then ok "unclosed parser-begin -> FAIL"; else ko "unclosed begin (rc=$RC) $OUT"; fi
cp "$BASE" "$T/m2.js"; printf 'const q = 1\n// guards:parser-end\n' >> "$T/m2.js"
run_r1 "$T/m2.js"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: R1 parser markers:.*parser-end at line .* no matching'; then ok "orphan parser-end -> FAIL"; else ko "orphan end (rc=$RC) $OUT"; fi
cp "$BASE" "$T/m3.js"; printf '// guards:parser-begin\n// guards:parser-begin\n// guards:parser-end\n' >> "$T/m3.js"
run_r1 "$T/m3.js"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q 'nested guards:parser-begin'; then ok "nested parser-begin -> FAIL"; else ko "nested begin (rc=$RC) $OUT"; fi
# malformed BASE only: warn, branch fine -> exit 0
OUT="$(GUARDS_ONLY=r1 GUARDS_BASE_FILE="$T/m1.js" GUARDS_BRANCH_FILE="$BASE" node scripts/guards.cjs 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q '^WARN: R1 parser markers: base'; then ok "malformed base only -> WARN, exit 0"; else ko "malformed base (rc=$RC) $OUT"; fi

# ---- R1: origin/main missing ----
OUT="$(GUARDS_ONLY=r1 GUARDS_BASE_FILE="$T/does-not-exist.js" GUARDS_BRANCH_FILE="$BASE" node scripts/guards.cjs 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "^FAIL: R1 ratchet: cannot read base.*git fetch origin main"; then ok "base missing (seam) -> FAIL with actionable message"; else ko "base missing seam (rc=$RC) $OUT"; fi
mkdir -p "$T/nogit"
OUT="$(GUARDS_ROOT="$T/nogit" GUARDS_ONLY=r1 GUARDS_BRANCH_FILE="$BASE" node scripts/guards.cjs 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "git fetch origin main"; then ok "origin/main unresolvable (no git) -> FAIL with actionable message"; else ko "no origin/main (rc=$RC) $OUT"; fi

# ---- all-tests-wired ----
# mkroot <dir> <guards.yml body>: fake repo root with one suite scripts/test-foo.sh
mkroot() {
  mkdir -p "$1/scripts" "$1/.github/workflows"
  : > "$1/scripts/test-foo.sh"
  printf '%s\n' "$2" > "$1/.github/workflows/guards.yml"
}
run_wired() { OUT="$(GUARDS_ROOT="$1" GUARDS_ONLY=wired node scripts/guards.cjs 2>&1)"; RC=$?; }
WIRED_RUN='      - run: node scripts/run-offline.cjs --all fixtures'
mkroot "$T/w1" "jobs:
  g:
    steps:
$WIRED_RUN
      - run: bash scripts/test-foo.sh"
run_wired "$T/w1"
if [ "$RC" -eq 0 ]; then ok "suite wired in a single-line run: -> ok"; else ko "wired single-line (rc=$RC) $OUT"; fi
mkroot "$T/w2" "jobs:
  g:
    steps:
      - name: x
        run: |
          node scripts/run-offline.cjs
          bash scripts/test-foo.sh # trailing comment"
run_wired "$T/w2"
if [ "$RC" -eq 0 ]; then ok "suite wired in a run: | block -> ok"; else ko "wired block (rc=$RC) $OUT"; fi
mkroot "$T/w3" "jobs:
  g:
    steps:
$WIRED_RUN"
run_wired "$T/w3"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: all-tests-wired:.*scripts/test-foo.sh'; then ok "suite on disk but not wired -> FAIL"; else ko "unwired (rc=$RC) $OUT"; fi
mkroot "$T/w4" "# Steps: scripts/test-foo.sh
jobs:
  g:
    steps:
$WIRED_RUN
      - run: echo hi # scripts/test-foo.sh"
run_wired "$T/w4"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: all-tests-wired:.*scripts/test-foo.sh'; then ok "suite only in a guards.yml comment -> FAIL"; else ko "comment-only (rc=$RC) $OUT"; fi
mkroot "$T/w5" "jobs:
  g:
    steps:
$WIRED_RUN
      - name: scripts/test-foo.sh
        run: echo hi"
run_wired "$T/w5"
if [ "$RC" -ne 0 ]; then ok "suite named only in a step name (not a run:) -> FAIL"; else ko "name-only (rc=$RC) $OUT"; fi

# ---- sam-parity ----
LR="$(node -e "const s=require('fs').readFileSync('scripts/guards.cjs','utf8');console.log(/const LAYER_RULE = '(.*)'\n/.exec(s)[1])")"
printf '%s\nlist patch-avoided: x\n' "$LR" > "$T/sam-ok.md"
run_parity() { OUT="$(GUARDS_ONLY=parity GUARDS_SAM_FILE="$1" GUARDS_SAM_JS_FILE="$2" node scripts/guards.cjs 2>&1)"; RC=$?; }
run_parity "$T/sam-ok.md" "$T/sam-ok.md"
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q '^PASS: sam-parity'; then ok "sam-parity: both sides carry token + sentence -> PASS"; else ko "sam-parity positive (rc=$RC) $OUT"; fi
printf 'nothing here\n' > "$T/sam-notoken.md"
run_parity "$T/sam-notoken.md" "$T/sam-ok.md"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: sam-parity:.*lacks the token patch-avoided:'; then ok "sam-parity: token missing on one side -> FAIL"; else ko "sam-parity token (rc=$RC) $OUT"; fi
printf 'list patch-avoided: x\n' > "$T/sam-nosentence.md"
run_parity "$T/sam-ok.md" "$T/sam-nosentence.md"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: sam-parity:.*LAYER RULE sentence'; then ok "sam-parity: sentence missing on one side -> FAIL"; else ko "sam-parity sentence (rc=$RC) $OUT"; fi
printf '%s\nlist patch-avoided: x\nroot-cause: y\n' "$LR" > "$T/sam-rc.md"
run_parity "$T/sam-rc.md" "$T/sam-ok.md"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: sam-parity:.*root-cause:'; then ok "sam-parity: root-cause: present -> FAIL"; else ko "sam-parity root-cause (rc=$RC) $OUT"; fi

# ---- doc-budgets (#77) ----
# mkdocs <dir> <vision lines> <architecture lines>: fake repo root holding the two docs (0 = absent)
mkdocs() {
  mkdir -p "$1"
  [ "$2" -gt 0 ] && seq 1 "$2" | sed 's/^/line /' > "$1/VISION.md"
  [ "$3" -gt 0 ] && seq 1 "$3" | sed 's/^/line /' > "$1/ARCHITECTURE.md"
  return 0
}
run_budgets() { OUT="$(GUARDS_ROOT="$1" GUARDS_ONLY=budgets node scripts/guards.cjs 2>&1)"; RC=$?; }
mkdocs "$T/d1" 20 60; run_budgets "$T/d1"
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q '^PASS: doc-budgets: VISION.md 20/20 lines, longest 7/160 chars; ARCHITECTURE.md 60/60 lines, longest 7/160 chars$'; then ok "doc-budgets: exactly at budget (20/60) -> PASS"; else ko "doc-budgets at budget (rc=$RC) $OUT"; fi
mkdocs "$T/d2" 21 60; run_budgets "$T/d2"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: doc-budgets: VISION.md has 21 lines, budget 20'; then ok "doc-budgets: VISION.md 21 lines -> FAIL"; else ko "doc-budgets vision over (rc=$RC) $OUT"; fi
mkdocs "$T/d3" 20 61; run_budgets "$T/d3"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: doc-budgets: ARCHITECTURE.md has 61 lines, budget 60'; then ok "doc-budgets: ARCHITECTURE.md 61 lines -> FAIL"; else ko "doc-budgets architecture over (rc=$RC) $OUT"; fi
mkdocs "$T/d4" 0 10; run_budgets "$T/d4"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: doc-budgets: VISION.md missing'; then ok "doc-budgets: VISION.md absent -> FAIL"; else ko "doc-budgets missing (rc=$RC) $OUT"; fi
mkdir -p "$T/d5"; printf 'a\nb' > "$T/d5/VISION.md"; seq 1 60 > "$T/d5/ARCHITECTURE.md"; printf 'x\n' >> "$T/d5/ARCHITECTURE.md"
run_budgets "$T/d5"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q 'ARCHITECTURE.md has 61 lines' && ! echo "$OUT" | grep -q 'VISION.md has'; then ok "doc-budgets: last line without newline counted, 61st appended line -> FAIL"; else ko "doc-budgets newline edge (rc=$RC) $OUT"; fi
# per-line cap (160 characters): a long line cannot dodge the line budget
mkdocs "$T/d6" 5 5; printf '%s\n' "$(printf 'x%.0s' $(seq 1 160))" >> "$T/d6/VISION.md"; printf '%s\n' "$(printf '\342\200\224%.0s' $(seq 1 160))" >> "$T/d6/ARCHITECTURE.md"
run_budgets "$T/d6"
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q '^PASS: doc-budgets: VISION.md 6/20 lines, longest 160/160 chars; ARCHITECTURE.md 6/60 lines, longest 160/160 chars$'; then ok "doc-budgets: lines of exactly 160 characters (ASCII, multi-byte) -> PASS"; else ko "doc-budgets line at cap (rc=$RC) $OUT"; fi
mkdocs "$T/d7" 5 5; printf '%s\n' "$(printf 'x%.0s' $(seq 1 161))" >> "$T/d7/VISION.md"
run_budgets "$T/d7"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: doc-budgets: VISION.md line 6 has 161 characters, cap 160' && ! echo "$OUT" | grep -q 'ARCHITECTURE.md line'; then ok "doc-budgets: VISION.md line of 161 characters -> FAIL naming the line"; else ko "doc-budgets vision long line (rc=$RC) $OUT"; fi
mkdocs "$T/d8" 5 5; for _ in 1 2; do printf '%s\n' "$(printf 'y%.0s' $(seq 1 200))" >> "$T/d8/ARCHITECTURE.md"; done
run_budgets "$T/d8"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q 'ARCHITECTURE.md line 6 has 200 characters, cap 160 (+1 more)'; then ok "doc-budgets: two long ARCHITECTURE.md lines -> FAIL, first named, count of the rest"; else ko "doc-budgets architecture long lines (rc=$RC) $OUT"; fi

STATUS=ok; [ "$FAIL_N" -eq 0 ] || STATUS=fail
echo "[test-guards] status=${STATUS} passed=${PASS_N} failed=${FAIL_N}"
[ "$FAIL_N" -eq 0 ]
