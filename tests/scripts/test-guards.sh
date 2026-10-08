#!/usr/bin/env bash
# Regression test for scripts/guards.cjs. Drives it through its env seams
# (GUARDS_BASE_FILE / GUARDS_BRANCH_FILE / GUARDS_BASE_MANIFEST / GUARDS_BRANCH_MANIFEST,
# GUARDS_ONLY) with throwaway files under $TMPDIR — never mutates tracked files.
# Cases: positive (same counts), 3 negative R1 counters, parser markers not counted/balanced,
# block comments, multi-line agent calls, missing base, all-tests-wired (wired/unwired/comment-only, nested below a test folder, outside every test folder),
# version floor, sam-parity (PLAN RULE both sides, LAYER RULE workflow only, no engine vocabulary in the persona),
# doc-budgets (at budget / over / missing / per-line cap, through GUARDS_ROOT),
# instructions-wired (imports outside code, once each, no @AGENTS.md, AGENTS.md names both, omitClaudeMd),
# status-table (registry <-> §5 table both ways, grouped rows, missing registry or table; #180),
# phase-titles (real titles, a 16-character title, a 17-character title, a case-insensitive prefix title either order, a whitespace-padded title, no phases list; #141).
# audit (the default list runs the audit check: a baseline raised vs origin/main fails; #289; rename-aware rule 2 and NEW-RULE, #303).
# The audit cases really run scripts/audit.cjs: like test-audit.sh this file needs `npm ci` and ruff at the version of ruff.toml on PATH.
# Ends with `[test-guards] status=<ok|fail> passed=<n> failed=<n>`.
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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
# the walk is recursive: a nested suite is a suite, a test file outside every known test folder is a FAIL
mkroot "$T/w6" "jobs:
  g:
    steps:
$WIRED_RUN
      - run: bash scripts/test-foo.sh"
mkdir -p "$T/w6/scripts/lib" && : > "$T/w6/scripts/lib/test-bar.sh"
run_wired "$T/w6"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: all-tests-wired:.*scripts/lib/test-bar.sh'; then ok "all-tests-wired: a suite nested below a test folder, not wired -> FAIL naming it"; else ko "nested unwired (rc=$RC) $OUT"; fi
mkroot "$T/w7" "jobs:
  g:
    steps:
$WIRED_RUN
      - run: bash scripts/test-foo.sh"
mkdir -p "$T/w7/docs" && : > "$T/w7/docs/test-baz.sh"
run_wired "$T/w7"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: all-tests-wired:.*outside.*docs/test-baz.sh'; then ok "all-tests-wired: a test file outside every known test folder -> FAIL naming it"; else ko "outside folder (rc=$RC) $OUT"; fi
mkroot "$T/w8" "jobs:
  g:
    steps:
$WIRED_RUN
      - run: bash scripts/test-foo.sh
      - run: bash scripts/test-baz.sh"
: > "$T/w8/scripts/test-baz.sh"
run_wired "$T/w8"
if [ "$RC" -eq 0 ]; then ok "all-tests-wired: the same file inside a test folder, wired -> ok"; else ko "inside folder wired (rc=$RC) $OUT"; fi
# the tests/ folder is a known test folder: an unwired suite there FAILs, a wired one is ok
mkroot "$T/w9" "jobs:
  g:
    steps:
$WIRED_RUN
      - run: bash scripts/test-foo.sh"
mkdir -p "$T/w9/tests/scripts" && : > "$T/w9/tests/scripts/test-bar.sh"
run_wired "$T/w9"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: all-tests-wired:.*tests/scripts/test-bar.sh'; then ok "all-tests-wired: a suite under tests/, not wired -> FAIL naming it"; else ko "tests/ unwired (rc=$RC) $OUT"; fi
mkroot "$T/w10" "jobs:
  g:
    steps:
$WIRED_RUN
      - run: bash scripts/test-foo.sh
      - run: bash tests/scripts/test-bar.sh"
mkdir -p "$T/w10/tests/scripts" && : > "$T/w10/tests/scripts/test-bar.sh"
run_wired "$T/w10"
if [ "$RC" -eq 0 ]; then ok "all-tests-wired: a suite under tests/, wired -> ok"; else ko "tests/ wired (rc=$RC) $OUT"; fi

# ---- guard-steps (#308) ----
# gsyml <dir> <guards-job-steps> [extra smoke-install steps]: guards.yml with a guards job and a smoke-install job
gsyml() {
  mkdir -p "$1/.github/workflows"
  printf 'jobs:\n  guards:\n    steps:\n%s\n  smoke-install:\n    steps:\n%s\n' "$2" "${3:-      - run: echo smoke}" > "$1/.github/workflows/guards.yml"
}
GS_ALL='      - name: Canonical guard net
        run: bash templates/test-canonical-guards.sh
      - name: Offline flow suite
        run: node scripts/run-flow-suite.cjs
      - name: Offline harness
        run: node scripts/run-offline.cjs --all fixtures'
gsyml "$T/gs-base" "$GS_ALL"
run_gs() { OUT="$(GUARDS_ROOT="$1" GUARDS_ONLY=guard-steps GUARDS_BASE_YML="$T/gs-base/.github/workflows/guards.yml" node scripts/guards.cjs 2>&1)"; RC=$?; }
gsyml "$T/gs1" "$GS_ALL"
run_gs "$T/gs1"
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q '^PASS: guard-steps: 3 protected'; then ok "guard-steps: identical guards job -> PASS"; else ko "guard-steps identical (rc=$RC) $OUT"; fi
gi=0
for path in templates/test-canonical-guards.sh scripts/run-flow-suite.cjs scripts/run-offline.cjs; do
  gi=$((gi+1))
  gsyml "$T/gsr$gi" "$(printf '%s\n' "$GS_ALL" | grep -v -F "$path" | grep -v -E '^      - name: (Canonical guard net|Offline flow suite|Offline harness)$' | sed 's/^$//')"
  # re-add the other two steps' names are irrelevant: the command text is what counts
  run_gs "$T/gsr$gi"
  if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "^FAIL: guard-steps:.*no longer runs.*$path"; then ok "guard-steps: $path removed -> FAIL naming it"; else ko "guard-steps removed $path (rc=$RC) $OUT"; fi
done
gsyml "$T/gs5" "      - run: bash templates/test-canonical-guards.sh
      - run: node scripts/run-flow-suite.cjs
      # node scripts/run-offline.cjs --all fixtures"
run_gs "$T/gs5"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: guard-steps:.*scripts/run-offline.cjs'; then ok "guard-steps: step only in a # comment -> FAIL"; else ko "guard-steps comment (rc=$RC) $OUT"; fi
gsyml "$T/gs6" "      - run: bash templates/test-canonical-guards.sh
      - run: node scripts/run-flow-suite.cjs" "      - run: node scripts/run-offline.cjs --all fixtures"
run_gs "$T/gs6"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: guard-steps:.*scripts/run-offline.cjs'; then ok "guard-steps: step moved to another job -> FAIL"; else ko "guard-steps other job (rc=$RC) $OUT"; fi
gsyml "$T/gs7" "      - run: echo nothing"
printf 'jobs:\n  guards:\n    steps:\n      - run: bash templates/test-canonical-guards.sh\n' > "$T/gs-base2.yml"
OUT="$(GUARDS_ROOT="$T/gs7" GUARDS_ONLY=guard-steps GUARDS_BASE_YML="$T/gs-base2.yml" node scripts/guards.cjs 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q 'canonical-guards' && ! echo "$OUT" | grep -q 'run-flow-suite'; then ok "guard-steps: only a step the base runs is required"; else ko "guard-steps base lacks step (rc=$RC) $OUT"; fi
gsyml "$T/gs8" "      - run: bash templates/test-canonical-guards.sh"
printf 'jobs:\n  guards:\n    steps:\n      - run: echo hi\n' > "$T/gs-base3.yml"
OUT="$(GUARDS_ROOT="$T/gs8" GUARDS_ONLY=guard-steps GUARDS_BASE_YML="$T/gs-base3.yml" node scripts/guards.cjs 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q '^PASS: guard-steps: 0 protected'; then ok "guard-steps: base lacks every step -> PASS"; else ko "guard-steps base lacks all (rc=$RC) $OUT"; fi
mkdir -p "$T/gs9"
OUT="$(GUARDS_ROOT="$T/gs9" GUARDS_ONLY=guard-steps GUARDS_BASE_YML="$T/gs-base/.github/workflows/guards.yml" node scripts/guards.cjs 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: guard-steps:.*missing'; then ok "guard-steps: branch guards.yml missing -> FAIL"; else ko "guard-steps branch missing (rc=$RC) $OUT"; fi
OUT="$(GUARDS_ROOT="$T/gs1" GUARDS_ONLY=guard-steps GUARDS_BASE_YML="$T/does-not-exist.yml" node scripts/guards.cjs 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "git fetch origin main"; then ok "guard-steps: base unreadable -> FAIL with actionable message"; else ko "guard-steps base unreadable (rc=$RC) $OUT"; fi

# ---- sam-parity ----
# PR = neutral PLAN_RULE (persona + workflow), LR = engine LAYER_RULE (workflow only; the persona must not carry it, #163)
PR="$(node -e "const s=require('fs').readFileSync('scripts/guards.cjs','utf8');console.log(/const PLAN_RULE = '(.*)'\n/.exec(s)[1])")"
LR="$(node -e "const s=require('fs').readFileSync('scripts/guards.cjs','utf8');console.log(/const LAYER_RULE = '(.*)'\n/.exec(s)[1])")"
# Human-gate text bridge (#28): GT = the human-gate test, EX = the proof-rule exemption key, HGR = the rule sentence
# (taken from the real persona, so the fixtures follow its wording), OLD = the retired definition
GT="$(node -e "const s=require('fs').readFileSync('scripts/guards.cjs','utf8');console.log(/const GATE_TEST = '(.*)'\n/.exec(s)[1])")"
EX="$(node -e "const s=require('fs').readFileSync('scripts/guards.cjs','utf8');console.log(/const EXEMPTION_KEY = '(.*)'\n/.exec(s)[1])")"
OLD="$(node -e "const s=require('fs').readFileSync('scripts/guards.cjs','utf8');console.log(/const OLD_GATE_DEF = '(.*)'\n/.exec(s)[1])")"
HGR="$(node -e "const s=require('fs').readFileSync('agents/sam.md','utf8');console.log(/efore tagging an item[^\n']*/.exec(s)[0])")"
# Follow-up issue rule (#29): FUR = the rule sentence, taken from the real persona like HGR
FUR="$(node -e "const s=require('fs').readFileSync('agents/sam.md','utf8');console.log(/FOLLOW-UP ISSUE RULE:[^\n]*/.exec(s)[0])")"
printf '%s\nlist patch-avoided: x\n%s\n%s\nB%s\n%s\n' "$PR" "$GT" "$EX" "$HGR" "$FUR" > "$T/sam-ok.md"
printf '%s\n%s\nlist patch-avoided: x\n%s\n%s\nb%s\n%s\n' "$PR" "$LR" "$GT" "$EX" "$HGR" "$FUR" > "$T/sam-js-ok.md"
run_parity() { OUT="$(GUARDS_ONLY=parity GUARDS_SAM_FILE="$1" GUARDS_SAM_JS_FILE="$2" node scripts/guards.cjs 2>&1)"; RC=$?; }
run_parity "$T/sam-ok.md" "$T/sam-js-ok.md"
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q '^PASS: sam-parity'; then ok "sam-parity: persona carries PLAN RULE + token, workflow adds the LAYER RULE -> PASS"; else ko "sam-parity positive (rc=$RC) $OUT"; fi
printf 'nothing here\n' > "$T/sam-notoken.md"
run_parity "$T/sam-notoken.md" "$T/sam-js-ok.md"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: sam-parity:.*lacks the token patch-avoided:'; then ok "sam-parity: token missing on one side -> FAIL"; else ko "sam-parity token (rc=$RC) $OUT"; fi
printf '%s\nlist patch-avoided: x\n' "$LR" > "$T/sam-js-noplan.md"
run_parity "$T/sam-ok.md" "$T/sam-js-noplan.md"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: sam-parity:.*PLAN RULE sentence'; then ok "sam-parity: PLAN RULE sentence missing in the workflow -> FAIL"; else ko "sam-parity plan sentence (rc=$RC) $OUT"; fi
run_parity "$T/sam-ok.md" "$T/sam-ok.md"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: sam-parity:.*LAYER RULE sentence'; then ok "sam-parity: LAYER RULE sentence missing in the workflow -> FAIL"; else ko "sam-parity layer sentence (rc=$RC) $OUT"; fi
run_parity "$T/sam-js-ok.md" "$T/sam-js-ok.md"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: sam-parity:.*engine vocabulary'; then ok "sam-parity: persona carrying the engine LAYER RULE -> FAIL engine vocabulary"; else ko "sam-parity engine vocabulary (rc=$RC) $OUT"; fi
printf '%s\nlist patch-avoided: x\nroot-cause: y\n' "$PR" > "$T/sam-rc.md"
run_parity "$T/sam-rc.md" "$T/sam-js-ok.md"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: sam-parity:.*root-cause:'; then ok "sam-parity: root-cause: present -> FAIL"; else ko "sam-parity root-cause (rc=$RC) $OUT"; fi
# human-gate bridge (#28): the exemption, the retired definition (also wrapped over two lines), the rule sentence
grep -v -F "$EX" "$T/sam-ok.md" > "$T/sam-noex.md"
run_parity "$T/sam-noex.md" "$T/sam-js-ok.md"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: sam-parity:.*agents/sam.md lacks the proof-rule exemption'; then ok "sam-parity: proof-rule exemption missing in the persona -> FAIL"; else ko "sam-parity exemption persona (rc=$RC) $OUT"; fi
grep -v -F "$EX" "$T/sam-js-ok.md" > "$T/sam-js-noex.md"
run_parity "$T/sam-ok.md" "$T/sam-js-noex.md"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: sam-parity:.*workflows/deliver-pipeline.js lacks the proof-rule exemption'; then ok "sam-parity: proof-rule exemption missing in the workflow -> FAIL"; else ko "sam-parity exemption workflow (rc=$RC) $OUT"; fi
grep -v -F "$GT" "$T/sam-ok.md" > "$T/sam-nogt.md"
run_parity "$T/sam-nogt.md" "$T/sam-js-ok.md"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: sam-parity:.*agents/sam.md lacks the human-gate test'; then ok "sam-parity: human-gate test missing in the persona -> FAIL"; else ko "sam-parity gate test (rc=$RC) $OUT"; fi
printf '%s\nand also %s\n' "$(cat "$T/sam-ok.md")" "$OLD" > "$T/sam-old.md"
run_parity "$T/sam-old.md" "$T/sam-js-ok.md"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: sam-parity:.*agents/sam.md still carries the retired human-gate definition'; then ok "sam-parity: retired human-gate definition in the persona -> FAIL"; else ko "sam-parity retired def (rc=$RC) $OUT"; fi
# follow-up issue rule (#29): missing on either side, a different sentence, no sub_issues, a repeated marker key
grep -v -F "$FUR" "$T/sam-ok.md" > "$T/sam-nofur.md"
run_parity "$T/sam-nofur.md" "$T/sam-js-ok.md"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: sam-parity:.*agents/sam.md lacks the follow-up issue rule'; then ok "sam-parity: follow-up issue rule missing in the persona -> FAIL"; else ko "sam-parity follow-up persona (rc=$RC) $OUT"; fi
grep -v -F "$FUR" "$T/sam-js-ok.md" > "$T/sam-js-nofur.md"
run_parity "$T/sam-ok.md" "$T/sam-js-nofur.md"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: sam-parity:.*workflows/deliver-pipeline.js lacks the follow-up issue rule'; then ok "sam-parity: follow-up issue rule missing in the workflow -> FAIL"; else ko "sam-parity follow-up workflow (rc=$RC) $OUT"; fi
grep -v -F "$FUR" "$T/sam-js-ok.md" > "$T/sam-js-fur2.md"
printf 'FOLLOW-UP ISSUE RULE: file at will via sub_issues, marker pipeline-followup:issue-<N>.\n' >> "$T/sam-js-fur2.md"
run_parity "$T/sam-ok.md" "$T/sam-js-fur2.md"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: sam-parity:.*follow-up issue rule differs from agents/sam.md'; then ok "sam-parity: another follow-up issue rule sentence in the workflow -> FAIL"; else ko "sam-parity follow-up differs (rc=$RC) $OUT"; fi
sed 's/sub_issues/children/g' "$T/sam-ok.md" > "$T/sam-nosub.md"
run_parity "$T/sam-nosub.md" "$T/sam-js-ok.md"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: sam-parity:.*agents/sam.md follow-up issue rule lacks sub_issues'; then ok "sam-parity: follow-up issue rule without sub_issues in the persona -> FAIL"; else ko "sam-parity follow-up sub_issues (rc=$RC) $OUT"; fi
printf '%s\nextra pipeline-followup:issue-<N> line\n' "$(cat "$T/sam-ok.md")" > "$T/sam-mark2.md"
run_parity "$T/sam-mark2.md" "$T/sam-js-ok.md"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: sam-parity:.*agents/sam.md carries the follow-up marker [0-9]* times'; then ok "sam-parity: follow-up marker repeated in the persona -> FAIL"; else ko "sam-parity follow-up marker (rc=$RC) $OUT"; fi
# the rule holds apostrophes (the jq filters): the whole sentence is compared, and the engine form (escaped quotes, closing quote) matches the persona
FUR_JS="$(printf '%s' "$FUR" | sed "s/'/\\\\'/g")"
grep -v -F "$FUR" "$T/sam-js-ok.md" > "$T/sam-js-esc.md"
printf "const FOLLOWUP_ISSUE_RULE = '%s';\n" "$FUR_JS" >> "$T/sam-js-esc.md"
run_parity "$T/sam-ok.md" "$T/sam-js-esc.md"
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q '^PASS: sam-parity'; then ok "sam-parity: follow-up issue rule in its engine string form (escaped quotes) -> PASS"; else ko "sam-parity follow-up engine form (rc=$RC) $OUT"; fi
grep -v -F "$FUR" "$T/sam-js-ok.md" > "$T/sam-js-tail.md"
printf '%s\n' "$FUR" | sed 's/\.$/ Extra clause after the quotes./' >> "$T/sam-js-tail.md"
run_parity "$T/sam-ok.md" "$T/sam-js-tail.md"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: sam-parity:.*follow-up issue rule differs from agents/sam.md'; then ok "sam-parity: follow-up issue rule differing after an apostrophe -> FAIL"; else ko "sam-parity follow-up tail (rc=$RC) $OUT"; fi
printf '%s\nB%s\n' "$GT" "$HGR" > "$T/pracc-ok.md"
printf 'x\n%s\n%s\nB%s\n' "an external system out" "of reach" "$HGR" > "$T/pracc-wrapped.md"
run_pracc() { OUT="$(GUARDS_ONLY=parity GUARDS_SAM_FILE="$T/sam-ok.md" GUARDS_SAM_JS_FILE="$T/sam-js-ok.md" GUARDS_PRACC_FILE="$1" GUARDS_PRACC_COPY="$2" node scripts/guards.cjs 2>&1)"; RC=$?; }
run_pracc "$T/pracc-ok.md" "$T/pracc-ok.md"
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q '^PASS: sam-parity'; then ok "sam-parity: both pr-acceptance copies carry the test and the rule sentence -> PASS"; else ko "sam-parity pracc positive (rc=$RC) $OUT"; fi
run_pracc "$T/pracc-wrapped.md" "$T/pracc-ok.md"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: sam-parity:.*templates/pr-acceptance.md still carries the retired human-gate definition'; then ok "sam-parity: retired definition wrapped over two lines in pr-acceptance -> FAIL"; else ko "sam-parity pracc wrapped (rc=$RC) $OUT"; fi
printf '%s\nBefore tagging an item whatever you like.\n' "$GT" > "$T/pracc-diff.md"
run_pracc "$T/pracc-ok.md" "$T/pracc-diff.md"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: sam-parity:.*.claude/rules/pr-acceptance.md human-gate rule sentence differs'; then ok "sam-parity: pr-acceptance copy with another rule sentence -> FAIL"; else ko "sam-parity pracc differs (rc=$RC) $OUT"; fi

# ---- doc-budgets (#77) ----
# mkdocs <dir> <vision lines> <architecture lines>: fake repo root holding the two docs (0 = absent)
mkdocs() {
  mkdir -p "$1"
  [ "$2" -gt 0 ] && seq 1 "$2" | sed 's/^/line /' > "$1/VISION.md"
  [ "$3" -gt 0 ] && seq 1 "$3" | sed 's/^/line /' > "$1/ARCHITECTURE.md"
  return 0
}
run_budgets() { OUT="$(GUARDS_ROOT="$1" GUARDS_ONLY=budgets node scripts/guards.cjs 2>&1)"; RC=$?; }
mkdocs "$T/d1" 20 20; run_budgets "$T/d1"
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q '^PASS: doc-budgets: VISION.md 20/20 lines, longest 7/160 chars; ARCHITECTURE.md 20/20 lines, longest 7/160 chars$'; then ok "doc-budgets: exactly at budget (20/20) -> PASS"; else ko "doc-budgets at budget (rc=$RC) $OUT"; fi
mkdocs "$T/d2" 21 20; run_budgets "$T/d2"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: doc-budgets: VISION.md has 21 lines, budget 20'; then ok "doc-budgets: VISION.md 21 lines -> FAIL"; else ko "doc-budgets vision over (rc=$RC) $OUT"; fi
mkdocs "$T/d3" 20 21; run_budgets "$T/d3"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: doc-budgets: ARCHITECTURE.md has 21 lines, budget 20'; then ok "doc-budgets: ARCHITECTURE.md 21 lines -> FAIL"; else ko "doc-budgets architecture over (rc=$RC) $OUT"; fi
mkdocs "$T/d4" 0 10; run_budgets "$T/d4"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: doc-budgets: VISION.md missing'; then ok "doc-budgets: VISION.md absent -> FAIL"; else ko "doc-budgets missing (rc=$RC) $OUT"; fi
mkdir -p "$T/d5"; printf 'a\nb' > "$T/d5/VISION.md"; seq 1 20 > "$T/d5/ARCHITECTURE.md"; printf 'x\n' >> "$T/d5/ARCHITECTURE.md"
run_budgets "$T/d5"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q 'ARCHITECTURE.md has 21 lines' && ! echo "$OUT" | grep -q 'VISION.md has'; then ok "doc-budgets: last line without newline counted, 21st appended line -> FAIL"; else ko "doc-budgets newline edge (rc=$RC) $OUT"; fi
# per-line cap (160 characters): a long line cannot dodge the line budget
mkdocs "$T/d6" 5 5; printf '%s\n' "$(printf 'x%.0s' $(seq 1 160))" >> "$T/d6/VISION.md"; printf '%s\n' "$(printf '\342\200\224%.0s' $(seq 1 160))" >> "$T/d6/ARCHITECTURE.md"
run_budgets "$T/d6"
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q '^PASS: doc-budgets: VISION.md 6/20 lines, longest 160/160 chars; ARCHITECTURE.md 6/20 lines, longest 160/160 chars$'; then ok "doc-budgets: lines of exactly 160 characters (ASCII, multi-byte) -> PASS"; else ko "doc-budgets line at cap (rc=$RC) $OUT"; fi
mkdocs "$T/d7" 5 5; printf '%s\n' "$(printf 'x%.0s' $(seq 1 161))" >> "$T/d7/VISION.md"
run_budgets "$T/d7"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: doc-budgets: VISION.md line 6 has 161 characters, cap 160' && ! echo "$OUT" | grep -q 'ARCHITECTURE.md line'; then ok "doc-budgets: VISION.md line of 161 characters -> FAIL naming the line"; else ko "doc-budgets vision long line (rc=$RC) $OUT"; fi
mkdocs "$T/d8" 5 5; for _ in 1 2; do printf '%s\n' "$(printf 'y%.0s' $(seq 1 200))" >> "$T/d8/ARCHITECTURE.md"; done
run_budgets "$T/d8"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q 'ARCHITECTURE.md line 6 has 200 characters, cap 160 (+1 more)'; then ok "doc-budgets: two long ARCHITECTURE.md lines -> FAIL, first named, count of the rest"; else ko "doc-budgets architecture long lines (rc=$RC) $OUT"; fi

# ---- instructions-wired (#77) ----
# mkinst <dir> [no-agents-md]: fake repo root wired as this repo is (CLAUDE.md imports, AGENTS.md, one agent with a
# frontmatter that does not skip the project instructions); each case then breaks one thing.
mkinst() {
  mkdir -p "$1/agents"
  printf '# CLAUDE.md\n\n@VISION.md\n@ARCHITECTURE.md\n\n- An escalation that trades off a `VISION.md` principle names it.\n' > "$1/CLAUDE.md"
  [ "${2:-}" = no-agents-md ] || printf '# AGENTS.md\n\nRead `VISION.md` and `ARCHITECTURE.md` first.\n' > "$1/AGENTS.md"
  printf -- '---\nname: A\nomitClaudeMd: false\n---\nBody mentions omitClaudeMd: true outside the frontmatter.\n' > "$1/agents/a.md"
}
run_inst() { OUT="$(GUARDS_ROOT="$1" GUARDS_ONLY=instructions node scripts/guards.cjs 2>&1)"; RC=$?; }
inst_fail() { # <label> <dir> <expected FAIL substring>
  run_inst "$2"
  if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: instructions-wired: ' && echo "$OUT" | grep -qF "$3"; then ok "$1"; else ko "$1 (rc=$RC) $OUT"; fi
}
mkinst "$T/i1"; run_inst "$T/i1"
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q '^PASS: instructions-wired: CLAUDE.md imports @VISION.md and @ARCHITECTURE.md once each; AGENTS.md names both; 1 agents/\*.md, none sets omitClaudeMd: true$'; then ok "instructions-wired: imports, AGENTS.md, omitClaudeMd false (and only in the body) -> PASS"; else ko "instructions-wired positive (rc=$RC) $OUT"; fi
mkinst "$T/i2"; printf '# CLAUDE.md\n\n@VISION.md\n- Technical constraints: `ARCHITECTURE.md`.\n' > "$T/i2/CLAUDE.md"
inst_fail "instructions-wired: ARCHITECTURE.md only named in a code span -> FAIL" "$T/i2" 'CLAUDE.md has no line `@ARCHITECTURE.md` outside code'
mkinst "$T/i3"; printf '# CLAUDE.md\n\n```\n@VISION.md\n```\n@ARCHITECTURE.md\n' > "$T/i3/CLAUDE.md"
inst_fail "instructions-wired: @VISION.md only inside a fenced block -> FAIL" "$T/i3" 'CLAUDE.md has no line `@VISION.md` outside code'
mkinst "$T/i4"; printf '# CLAUDE.md\n\n`@VISION.md`\n  @ARCHITECTURE.md\n' > "$T/i4/CLAUDE.md"
run_inst "$T/i4"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qF 'no line `@VISION.md`' && echo "$OUT" | grep -qF 'no line `@ARCHITECTURE.md`'; then ok "instructions-wired: import in a code span, indented import line -> FAIL for both"; else ko "instructions-wired code span / indent (rc=$RC) $OUT"; fi
mkinst "$T/i5"; printf '# CLAUDE.md\n\n@VISION.md\n@ARCHITECTURE.md\n- Product vision, read by every agent: @VISION.md\n' > "$T/i5/CLAUDE.md"
inst_fail "instructions-wired: a second, inline @VISION.md import -> FAIL" "$T/i5" 'CLAUDE.md imports VISION.md 2 times, keep exactly one `@VISION.md` line'
mkinst "$T/i6"; printf '# CLAUDE.md\n\n@VISION.md\n@ARCHITECTURE.md\n@AGENTS.md\n' > "$T/i6/CLAUDE.md"
inst_fail "instructions-wired: CLAUDE.md imports AGENTS.md -> FAIL" "$T/i6" 'CLAUDE.md imports AGENTS.md, which loads the docs twice'
mkinst "$T/i7" no-agents-md
inst_fail "instructions-wired: AGENTS.md absent -> FAIL" "$T/i7" 'AGENTS.md missing'
mkinst "$T/i8"; printf '# AGENTS.md\n\nRead `VISION.md` first.\n' > "$T/i8/AGENTS.md"
inst_fail "instructions-wired: AGENTS.md does not name ARCHITECTURE.md -> FAIL" "$T/i8" 'AGENTS.md does not name ARCHITECTURE.md'
mkinst "$T/i9"; printf -- '---\nname: B\nomitClaudeMd: true\n---\nbody\n' > "$T/i9/agents/b.md"
inst_fail "instructions-wired: agents/b.md frontmatter omitClaudeMd: true -> FAIL" "$T/i9" 'agents/b.md sets omitClaudeMd: true'

# ---- status-table (#180) ----
# A registry of 3 statuses (plus agentDeathRouting's indented role table, which must not be read as the
# registry) and a runbook whose §5 table groups two of them in one row; a table before §5 is ignored.
cat > "$T/st.js" <<'JS'
const STATUS = Object.freeze({
  'ready': { status: 'ready' },
  'dev-died': { status: 'dev-died', resumable: true },
  'plan-died': { status: 'plan-died', resumable: true },
})
function agentDeathRouting(role) {
  const STATUS = { nick: 'dev-died', ghost: 'not-a-run-status' }
  return STATUS[role]
}
JS
cat > "$T/st-ok.md" <<'MD'
## 4. Launch the workflow
| status | note |
|---|---|
| `not-in-the-registry` | a table before §5 is not the status table |

## 5. Handle the returned status
The workflow returns an object `{ status, ... }`.

| status | Meaning | Lead action |
|--------|------|-------------|
| `ready` | LGTM | Update. See §6. |
| `dev-died` / `plan-died` | An agent died; `resumable:true` | Relaunch via `resumeFromRunId`. |

Always relaunch the workflow with the same `config`.
MD
run_status() { OUT="$(GUARDS_ONLY=status GUARDS_STATUS_JS_FILE="$1" GUARDS_DELIVER_MD="$2" node scripts/guards.cjs 2>&1)"; RC=$?; }
run_status "$T/st.js" "$T/st-ok.md"
if [ "$RC" -eq 0 ] && [ "$OUT" = "PASS: status-table: 3 STATUS keys, each with a row in commands/deliver.md §5, no row without a key" ]; then ok "status-table: every key has a row (a grouped row counts each status), every row is a key -> PASS"; else ko "status-table positive (rc=$RC) $OUT"; fi
grep -v '^| `ready` |' "$T/st-ok.md" > "$T/st-norow.md"; run_status "$T/st.js" "$T/st-norow.md"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "^FAIL: status-table: STATUS key 'ready' (workflows/deliver-pipeline.js) has no row in the status table of commands/deliver.md §5$"; then ok "status-table: a registry key without a row -> FAIL naming the status"; else ko "status-table key without row (rc=$RC) $OUT"; fi
awk '{ print } /^\| `ready` \|/ { print "| `ghost` | no such outcome | none |" }' "$T/st-ok.md" > "$T/st-extra.md"; run_status "$T/st.js" "$T/st-extra.md"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "^FAIL: status-table: row 'ghost' of the status table (commands/deliver.md §5) is not a STATUS key in workflows/deliver-pipeline.js$"; then ok "status-table: a row that is no registry key -> FAIL naming the row"; else ko "status-table row without key (rc=$RC) $OUT"; fi
printf 'const finish = (def, extra = {}) => ({ ...def, ...extra })\n' > "$T/st-none.js"; run_status "$T/st-none.js" "$T/st-ok.md"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: status-table: no top-level `const STATUS = Object.freeze({ ... })` registry in workflows/deliver-pipeline.js$'; then ok "status-table: registry absent (only agentDeathRouting's table) -> FAIL"; else ko "status-table no registry (rc=$RC) $OUT"; fi
printf '## 5. Handle the returned status\nNo table here.\n' > "$T/st-notable.md"; run_status "$T/st.js" "$T/st-notable.md"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: status-table: no table under `## 5. Handle the returned status` in commands/deliver.md$'; then ok "status-table: §5 without a table -> FAIL"; else ko "status-table no table (rc=$RC) $OUT"; fi

# ---- phase-titles (#141) ----
# mkphases <file> <title>...: a workflow whose `export const meta` declares the given phase titles, followed by a decoy
# `title:` of more than sixteen characters AFTER the meta block (proves only the meta block is read).
mkphases() {
  local f="$1"; shift
  { printf "export const meta = {\n  name: 'x',\n  phases: [\n"
    for t in "$@"; do printf "    { title: '%s', detail: 'd' },\n" "$t"; done
    printf "  ],\n}\n\nconst ghost = { title: 'A decoy title that is far too long' }\n"; } > "$f"
}
run_phases() { OUT="$(GUARDS_ONLY=phases GUARDS_PHASES_JS_FILE="$1" node scripts/guards.cjs 2>&1)"; RC=$?; }
run_phases workflows/deliver-pipeline.js
if [ "$RC" -eq 0 ] && [ "$OUT" = "PASS: phase-titles: 5 declared titles, longest 8/16 characters, none a prefix of another" ]; then ok "phase-titles: the 5 real titles are within the cap and none is a prefix of another -> PASS"; else ko "phase-titles real file (rc=$RC) $OUT"; fi
mkphases "$T/ph-16.js" Setup ABCDEFGHIJKLMNOP; run_phases "$T/ph-16.js"
if [ "$RC" -eq 0 ] && [ "$OUT" = "PASS: phase-titles: 2 declared titles, longest 16/16 characters, none a prefix of another" ]; then ok "phase-titles: a title of exactly 16 characters passes (the decoy after the meta block is not read)"; else ko "phase-titles 16 characters (rc=$RC) $OUT"; fi
mkphases "$T/ph-17.js" Setup ABCDEFGHIJKLMNOPQ; run_phases "$T/ph-17.js"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "^FAIL: phase-titles: title 'ABCDEFGHIJKLMNOPQ' has 17 characters, cap 16$"; then ok "phase-titles: a title of 17 characters -> FAIL naming it"; else ko "phase-titles 17 characters (rc=$RC) $OUT"; fi
mkphases "$T/ph-pre.js" Setup Plan "Plan check"; run_phases "$T/ph-pre.js"; RC1=$RC; OUT1="$OUT"
mkphases "$T/ph-pre-ci.js" Setup plan "Plan check"; run_phases "$T/ph-pre-ci.js"
if [ "$RC1" -ne 0 ] && [ "$RC" -ne 0 ] && echo "$OUT1" | grep -q "^FAIL: phase-titles: title 'Plan' is a prefix of 'Plan check' (case-insensitive), the progress view merges them$" && echo "$OUT" | grep -q "^FAIL: phase-titles: title 'plan' is a prefix of 'Plan check' (case-insensitive), the progress view merges them$"; then ok "phase-titles: a title that is a prefix of another, case-insensitively -> FAIL naming both"; else ko "phase-titles prefix (rc=$RC1/$RC) $OUT1 $OUT"; fi
mkphases "$T/ph-pre-rev.js" Setup "Plan check" Plan; run_phases "$T/ph-pre-rev.js"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "^FAIL: phase-titles: title 'Plan' is a prefix of 'Plan check' (case-insensitive), the progress view merges them$"; then ok "phase-titles: the longer title listed before its prefix title -> FAIL naming both"; else ko "phase-titles prefix, longer first (rc=$RC) $OUT"; fi
mkphases "$T/ph-trim.js" Setup Plan " Plan"; run_phases "$T/ph-trim.js"; RC1=$RC; OUT1="$OUT"
mkphases "$T/ph-trim-pre.js" Setup "Plan " " Plan check"; run_phases "$T/ph-trim-pre.js"
if [ "$RC1" -ne 0 ] && [ "$RC" -ne 0 ] && echo "$OUT1" | /usr/bin/grep -q "^FAIL: phase-titles: title 'Plan' is a prefix of ' Plan'" && echo "$OUT" | /usr/bin/grep -q "^FAIL: phase-titles: title 'Plan ' is a prefix of ' Plan check'"; then ok "phase-titles: titles compared after trimming surrounding whitespace -> FAIL"; else ko "phase-titles trim (rc=$RC1/$RC) $OUT1 $OUT"; fi
printf "export const meta = {\n  name: 'x',\n}\n" > "$T/ph-none.js"; run_phases "$T/ph-none.js"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: phase-titles: no '; then ok "phase-titles: a meta block without a phases list -> FAIL"; else ko "phase-titles no list (rc=$RC) $OUT"; fi

# ---- init-stubs (#267) ----
run_stubs() { OUT="$(GUARDS_ONLY=init-stubs GUARDS_INIT_STUBS="$1" node scripts/guards.cjs 2>&1)"; RC=$?; }
run_stubs "$REPO_ROOT/scripts/init-specifics.cjs"
if [ "$RC" -eq 0 ] && [ "$OUT" = "PASS: init-stubs: 6 stubs, 1 lane stub, 1 lane sentence, no engine vocabulary, empty once comments are stripped" ]; then ok "init-stubs: the six real stubs -> PASS"; else ko "init-stubs real stubs (rc=$RC) $OUT"; fi
printf "exports.STUBS = { sam: '<!-- run the simulate step -->' }\n" > "$T/stubs-bad.cjs"; run_stubs "$T/stubs-bad.cjs"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "^FAIL: init-stubs: stub 'sam' carries the engine word 'simulate'$"; then ok "init-stubs: a stub with an engine word -> FAIL naming the stub"; else ko "init-stubs engine word (rc=$RC) $OUT"; fi
printf "exports.STUBS = { sam: 'a rule that injects text' }\n" > "$T/stubs-text.cjs"; run_stubs "$T/stubs-text.cjs"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "^FAIL: init-stubs: stub 'sam' is not empty once comments are stripped$"; then ok "init-stubs: a stub with text outside a comment -> FAIL"; else ko "init-stubs text (rc=$RC) $OUT"; fi

# ---- audit (#289) ----
# The default list (no GUARDS_ONLY) must run the audit check: a clone whose baseline is raised vs its origin/main fails on
# the baseline-vs-origin line. Removing 'audit' from ONLY in scripts/guards.cjs makes this case fail.
AUD_ORIGIN="$T/aud-origin.git"; AUD_CLONE="$T/aud-clone"
git init -q --bare "$AUD_ORIGIN" && git init -q "$AUD_CLONE" && mkdir -p "$AUD_CLONE/scripts"
printf '{"a.sh":{"max-lines":1}}\n' > "$AUD_CLONE/scripts/audit-baseline.json"
git -C "$AUD_CLONE" add -A && git -C "$AUD_CLONE" -c user.name=t -c user.email=t@t commit -qm base \
  && git -C "$AUD_CLONE" branch -M main && git -C "$AUD_CLONE" remote add origin "$AUD_ORIGIN" \
  && git -C "$AUD_CLONE" push -q origin main && git -C "$AUD_CLONE" fetch -q origin main
printf '{"a.sh":{"max-lines":2}}\n' > "$AUD_CLONE/scripts/audit-baseline.json"
OUT="$(GUARDS_ROOT="$AUD_CLONE" node scripts/guards.cjs 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: audit: baseline-vs-origin a.sh max-lines 2 > origin/main 1$'; then ok "audit: the default list runs the audit check (removing the key from ONLY fails this case)"; else ko "audit default list (rc=$RC) $OUT"; fi

# aud_clone <name>: a clone with a bare origin holding warn.sh (one SC2034) and the baseline {"warn.sh":{"SC2034":1}}; sets AUD_CLONE.
aud_clone() {
  local origin="$T/$1-origin.git"
  AUD_CLONE="$T/$1-clone"
  git init -q --bare "$origin" && git init -q "$AUD_CLONE" && mkdir -p "$AUD_CLONE/scripts"
  printf '#!/usr/bin/env bash\nunused=1\n' > "$AUD_CLONE/warn.sh"
  printf '{"warn.sh":{"SC2034":1}}\n' > "$AUD_CLONE/scripts/audit-baseline.json"
  git -C "$AUD_CLONE" add -A && git -C "$AUD_CLONE" -c user.name=t -c user.email=t@t commit -qm base \
    && git -C "$AUD_CLONE" branch -M main && git -C "$AUD_CLONE" remote add origin "$origin" \
    && git -C "$AUD_CLONE" push -q origin main && git -C "$AUD_CLONE" fetch -q origin main
}
aud_run() { OUT="$(GUARDS_ROOT="$AUD_CLONE" GUARDS_ONLY=audit node scripts/guards.cjs 2>&1)"; RC=$?; }

# Rename-aware rule 2: a git mv keeps its budget, a copy does not.
aud_clone rename
git -C "$AUD_CLONE" mv warn.sh moved.sh
printf '{"moved.sh":{"SC2034":1}}\n' > "$AUD_CLONE/scripts/audit-baseline.json"
aud_run
if [ "$RC" -eq 0 ] && ! echo "$OUT" | grep -q 'baseline-vs-origin'; then ok "audit: rename keeps the budget of a moved baselined file"; else ko "audit rename (rc=$RC) $OUT"; fi
aud_clone copy
cp "$AUD_CLONE/warn.sh" "$AUD_CLONE/copy.sh" && git -C "$AUD_CLONE" add copy.sh
printf '{"copy.sh":{"SC2034":1},"warn.sh":{"SC2034":1}}\n' > "$AUD_CLONE/scripts/audit-baseline.json"
aud_run
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qF 'FAIL: audit: baseline-vs-origin copy.sh SC2034 1 > origin/main 0'; then ok "audit: rename control, a copy does not inherit the budget"; else ko "audit rename control (rc=$RC) $OUT"; fi

# NEW-RULE: a rule absent from the origin baseline needs a tool config change in the same branch.
aud_clone newrule
{ echo '#!/usr/bin/env bash'; awk 'BEGIN { for (k = 1; k <= 601; k++) print "# filler" }'; } > "$AUD_CLONE/big.sh"
git -C "$AUD_CLONE" add big.sh
printf '{"big.sh":{"max-lines":1},"warn.sh":{"SC2034":1}}\n' > "$AUD_CLONE/scripts/audit-baseline.json"
aud_run
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: audit: NEW-RULE max-lines'; then ok "audit: NEW-RULE a rule absent from origin/main is red without a tool config change"; else ko "audit NEW-RULE (rc=$RC) $OUT"; fi
printf '# config\n' > "$AUD_CLONE/ruff.toml" && git -C "$AUD_CLONE" add ruff.toml
aud_run
if [ "$RC" -eq 0 ]; then ok "audit: NEW-RULE enters when a tool config file changes in the same branch"; else ko "audit NEW-RULE with config (rc=$RC) $OUT"; fi

STATUS=ok; [ "$FAIL_N" -eq 0 ] || STATUS=fail
echo "[test-guards] status=${STATUS} passed=${PASS_N} failed=${FAIL_N}"
[ "$FAIL_N" -eq 0 ]
