#!/usr/bin/env bash
# Offline test of scripts/gate-check.sh (#158). Fixture artefacts: copies of the REAL grader files and
# fixtures in a throwaway repo-shaped root (GATE_ROOT), plus fake aggregate-result.json files and canary
# records. Positive and negative cases per metric: a missing or failing incident fixture, a weakened or
# generic grader, 28/30 fully passed runs, one canary run. No `claude` call, no network. bash 3.2 safe.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_BASE="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
WORK="$(mktemp -d "$TMP_BASE/gate-check-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
GC="$ROOT/scripts/gate-check.sh"

pass_count=0
fail_count=0
check() {
  local name="$1" ok="$2"
  if [ "$ok" -eq 1 ]; then echo "PASS - $name"; pass_count=$((pass_count + 1))
  else echo "FAIL - $name"; fail_count=$((fail_count + 1)); fi
}

# mkres.cjs <file> <case> <spec>: same helper and spec as scripts/test-probe-evals.sh ("8x1,2x0.75" = 8 clean
# runs and 2 runs at 0.75), the shape of `claude plugin eval` 2.1.286 aggregate-result.json.
cat > "$WORK/mkres.cjs" <<'JS'
const fs = require('fs')
const path = require('path')
const [file, name, spec] = process.argv.slice(2)
const runs = []
for (const part of spec.split(',')) {
  const m = part.match(/^(\d+)x([0-9.]+)(!?)$/)
  if (!m) throw new Error('bad spec ' + part)
  for (let i = 0; i < Number(m[1]); i++) runs.push({ score: Number(m[2]), passed: Number(m[2]) >= 1, error: m[3] ? 'boom' : null })
}
const mean = runs.reduce((a, r) => a + r.score, 0) / runs.length
fs.mkdirSync(path.dirname(file), { recursive: true })
fs.writeFileSync(file, JSON.stringify({
  schemaVersion: 1, claudeVersion: '2.1.286', partial: false,
  cases: [{ name, runsPerCase: runs.length, arms: { with: runs }, aggregates: { score: mean, passRate: 0 } }],
}, null, 2))
JS

# edit.cjs sub <file> <regex> <replacement> (first match, ^ and $ match per line, must match: the mutations
# never hard-code a sha, so regenerated graders keep the test valid) | expect <fixture.json> <status>
cat > "$WORK/edit.cjs" <<'JS'
const fs = require('fs')
const [mode, file, a, b] = process.argv.slice(2)
let text = fs.readFileSync(file, 'utf8')
if (mode === 'sub') {
  const re = new RegExp(a, 'm')
  if (!re.test(text)) throw new Error('/' + a + '/ does not match in ' + file)
  text = text.replace(re, () => b)
} else {
  const j = JSON.parse(text)
  j.expect.status = a
  text = JSON.stringify(j, null, 2)
}
fs.writeFileSync(file, text)
JS

# mkroot <dir>: a repo-shaped root holding the real evals/probe-* cases and fixtures/, no results, no canary record
mkroot() {
  mkdir -p "$1/evals" "$1/docs/gate"
  cp -R "$ROOT"/evals/probe-* "$1/evals/"
  cp -R "$ROOT/fixtures" "$1/fixtures"
}
# mkresults <dir> <spec provision> <spec pr-state> <spec pr-write>
mkresults() {
  local dir="$1" c spec
  shift
  for c in probe-provision probe-pr-state probe-pr-write; do
    spec="$1"; shift
    node "$WORK/mkres.cjs" "$dir/evals/results/$c/aggregate-result.json" "$c" "$spec"
  done
}
# canary <dir> <json>
canary() { printf '%s\n' "$2" > "$1/docs/gate/e2-canary.json"; }
R1='{"issue":1,"pr":3,"status":"merged","pipelineStates":[]}'
R2='{"issue":2,"pr":4,"status":"ready","pipelineStates":[{"file":"issue-2.json","status":"pr-ready"}]}'

# gc <dir> [args]: sets GOUT (stdout+stderr) and GRC (exit code); the results dir variable is unset
gc() {
  local d="$1"
  shift
  GOUT="$(env -u PROBE_EVALS_RESULTS_DIR GATE_ROOT="$d" bash "$GC" e2 "$@" 2>&1)"
  GRC=$?
}
# is <metric> <STATUS> [needle...]: the metric's line starts with STATUS and holds every needle
is() {
  local m="$1" s="$2" l n
  shift 2
  l="$(printf '%s\n' "$GOUT" | grep -E "^(PASS|FAIL|SKIP) $m: ")"
  case "$l" in "$s $m: "*) ;; *) return 1 ;; esac
  for n in "$@"; do
    case "$l" in *"$n"*) ;; *) return 1 ;; esac
  done
  return 0
}
has() { case "$GOUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

# all green: replay, pins, 30/30, two canary runs
mkroot "$WORK/green"
mkresults "$WORK/green" 10x1 10x1 10x1
canary "$WORK/green" "{\"runs\":[$R1,$R2]}"
gc "$WORK/green"
ok=0; [ "$GRC" -eq 0 ] && is incidents PASS 'passed=' '#10 #14 #27 #32 #40' && is eval PASS 'grader pins ok (3 cases)' '30/30 fully passed runs' && is canary PASS '2/2 qualifying canary runs' && has 'gate e2: 3 PASS, 0 FAIL, 0 SKIP -> PASS' && ok=1
check "all three metrics green -> three PASS lines, exit 0" "$ok"
n="$(printf '%s\n' "$GOUT" | grep -cE '^(PASS|FAIL|SKIP) ')"
ok=0; [ "$n" -eq 3 ] && ok=1
check "exactly one PASS/FAIL/SKIP line per metric ($n)" "$ok"

# --- incidents
mkroot "$WORK/i-missing"
mkresults "$WORK/i-missing" 10x1 10x1 10x1
canary "$WORK/i-missing" "{\"runs\":[$R1,$R2]}"
rm "$WORK"/i-missing/fixtures/incidents/10-*.json
gc "$WORK/i-missing"
ok=0; [ "$GRC" -eq 1 ] && is incidents FAIL 'no fixtures/incidents/<n>-*.json for #10' && has 'gate e2: 2 PASS, 1 FAIL, 0 SKIP -> FAIL' && ok=1
check "incidents: a deleted E2 incident fixture (#10) -> FAIL, exit 1 (the replay alone stays green)" "$ok"

mkroot "$WORK/i-red"
mkresults "$WORK/i-red" 10x1 10x1 10x1
canary "$WORK/i-red" "{\"runs\":[$R1,$R2]}"
node "$WORK/edit.cjs" expect "$WORK/i-red/fixtures/incidents/14-pr-state-probe.json" escalate
gc "$WORK/i-red"
ok=0; [ "$GRC" -eq 1 ] && is incidents FAIL 'replay not green' 'failed=1' && ok=1
check "incidents: a fixture that no longer replays to its expected status -> FAIL, exit 1" "$ok"

# --- eval grader pins (the weakened-grader negative tests)
mkroot "$WORK/e-weak"
mkresults "$WORK/e-weak" 10x1 10x1 10x1
canary "$WORK/e-weak" "{\"runs\":[$R1,$R2]}"
node "$WORK/edit.cjs" sub "$WORK/e-weak/evals/probe-provision/graders/probe-line.md" '^pattern: .*$' "pattern: 'PROBE name=provision'"
gc "$WORK/e-weak"
ok=0; [ "$GRC" -eq 1 ] && is eval FAIL 'probe-provision: probe-line.md pattern is not anchored' && ok=1
check "eval: probe-line.md reduced to an unanchored prefix -> FAIL, exit 1 (even with 30/30 results)" "$ok"

mkroot "$WORK/e-generic"
node "$WORK/edit.cjs" sub "$WORK/e-generic/evals/probe-pr-write/graders/probe-line.md" 'sha=[0-9a-f]{64}' 'sha=[0-9a-f]{64}'
gc "$WORK/e-generic" --ci
ok=0; [ "$GRC" -eq 1 ] && is eval FAIL 'probe-pr-write: probe-line.md pattern holds an unescaped regex metacharacter' && ok=1
check "eval: probe-line.md with a generic sha class -> FAIL, exit 1, also with --ci" "$ok"

mkroot "$WORK/e-verify"
node "$WORK/edit.cjs" sub "$WORK/e-verify/evals/probe-pr-state/graders/verify-ok.md" '^pattern: .*$' "pattern: 'VERIFY ok'"
gc "$WORK/e-verify" --ci
ok=0; [ "$GRC" -eq 1 ] && is eval FAIL 'probe-pr-state: verify-ok.md pattern is not the tool_result VERIFY ok line' && ok=1
check "eval: verify-ok.md reduced to 'VERIFY ok' -> FAIL, exit 1" "$ok"

mkroot "$WORK/e-sha"
node "$WORK/edit.cjs" sub "$WORK/e-sha/evals/probe-provision/graders/verify-ok.md" 'sha=[0-9a-f]' 'sha=x'
gc "$WORK/e-sha" --ci
ok=0; [ "$GRC" -eq 1 ] && is eval FAIL 'probe-provision: verify-ok.md pattern is not the tool_result VERIFY ok line of the probe-line sha' && ok=1
check "eval: verify-ok.md pinning another sha than probe-line.md -> FAIL, exit 1" "$ok"

mkroot "$WORK/e-flags"
node "$WORK/edit.cjs" sub "$WORK/e-flags/evals/probe-pr-state/graders/probe-line.md" '^target: last_message$' $'target: last_message\nflags: i'
gc "$WORK/e-flags" --ci
ok=0; [ "$GRC" -eq 1 ] && is eval FAIL 'probe-pr-state: probe-line.md must be type regex, target last_message, no flags' && ok=1
check "eval: a flag on probe-line.md -> FAIL, exit 1" "$ok"

mkroot "$WORK/e-nograder"
rm "$WORK/e-nograder/evals/probe-pr-write/graders/verify-ok.md"
gc "$WORK/e-nograder" --ci
ok=0; [ "$GRC" -eq 1 ] && is eval FAIL 'probe-pr-write: graders/verify-ok.md missing' && ok=1
check "eval: a deleted verify-ok.md -> FAIL, exit 1" "$ok"

mkroot "$WORK/e-nocase"
rm -rf "$WORK/e-nocase/evals/probe-pr-write"
gc "$WORK/e-nocase" --ci
ok=0; [ "$GRC" -eq 1 ] && is eval FAIL 'probe-pr-write: case directory missing' && ok=1
check "eval: a deleted case directory -> FAIL, exit 1" "$ok"

# --- eval results (delegated to scripts/probe-eval-gate.sh)
mkroot "$WORK/r29"
mkresults "$WORK/r29" 9x1,1x0.75 10x1 10x1
canary "$WORK/r29" "{\"runs\":[$R1,$R2]}"
gc "$WORK/r29"
ok=0; [ "$GRC" -eq 0 ] && is eval PASS '29/30 fully passed runs (need >= 29/30) -> PASS' && ok=1
check "eval results: 29/30 fully passed runs -> PASS, exit 0" "$ok"

mkroot "$WORK/r28"
mkresults "$WORK/r28" 8x1,2x0.75 10x1 10x1
canary "$WORK/r28" "{\"runs\":[$R1,$R2]}"
gc "$WORK/r28"
ok=0; [ "$GRC" -eq 1 ] && is eval FAIL 'grader pins ok (3 cases)' '28/30 fully passed runs (need >= 29/30) -> FAIL' && is incidents PASS && is canary PASS && ok=1
check "eval results: 28/30 fully passed runs -> FAIL, exit 1, the other metrics unaffected" "$ok"

mkroot "$WORK/r-none"
canary "$WORK/r-none" "{\"runs\":[$R1,$R2]}"
gc "$WORK/r-none"
ok=0; [ "$GRC" -eq 1 ] && is eval FAIL 'grader pins ok (3 cases)' 'no results dir' && ok=1
check "eval results: absent evals/results run as the gate -> FAIL, exit 1" "$ok"
gc "$WORK/r-none" --ci
ok=0; [ "$GRC" -eq 0 ] && is eval SKIP 'grader pins ok (3 cases)' 'no results dir' && has 'gate e2: 2 PASS, 0 FAIL, 1 SKIP -> INCOMPLETE' && ok=1
check "eval results: absent evals/results with --ci -> SKIP, exit 0, summary INCOMPLETE" "$ok"

mkroot "$WORK/r-partial"
mkresults "$WORK/r-partial" 10x1 10x1 10x1
rm "$WORK/r-partial/evals/results/probe-pr-state/aggregate-result.json"
gc "$WORK/r-partial" --ci
ok=0; [ "$GRC" -eq 1 ] && is eval FAIL 'probe-pr-state: results unusable (file missing)' && ok=1
check "eval results: a results dir that lacks a case -> FAIL even with --ci (SKIP only when the dir is absent)" "$ok"

# --- canary
mkroot "$WORK/c-one"
mkresults "$WORK/c-one" 10x1 10x1 10x1
canary "$WORK/c-one" "{\"runs\":[$R1]}"
gc "$WORK/c-one"
ok=0; [ "$GRC" -eq 1 ] && is canary FAIL '1/2 qualifying canary runs' && is incidents PASS && is eval PASS && ok=1
check "canary: one run -> FAIL, exit 1" "$ok"
gc "$WORK/c-one" --ci
ok=0; [ "$GRC" -eq 0 ] && is canary SKIP '1/2 qualifying canary runs' && has '-> INCOMPLETE' && ok=1
check "canary: one run with --ci -> SKIP, exit 0" "$ok"

mkroot "$WORK/c-open"
mkresults "$WORK/c-open" 10x1 10x1 10x1
canary "$WORK/c-open" "{\"runs\":[$R1,{\"issue\":2,\"pr\":4,\"status\":\"ready\",\"pipelineStates\":[{\"file\":\"issue-2.json\",\"status\":\"dev\"}]}]}"
gc "$WORK/c-open"
ok=0; [ "$GRC" -eq 1 ] && is canary FAIL '1/2 qualifying canary runs' 'non-terminal .pipeline state issue-2.json=dev' && ok=1
check "canary: a run that left an in-flight .pipeline state -> not counted, FAIL" "$ok"

mkroot "$WORK/c-status"
mkresults "$WORK/c-status" 10x1 10x1 10x1
canary "$WORK/c-status" "{\"runs\":[$R1,{\"issue\":2,\"pr\":4,\"status\":\"escalate\",\"pipelineStates\":[]}]}"
gc "$WORK/c-status"
ok=0; [ "$GRC" -eq 1 ] && is canary FAIL '1/2 qualifying canary runs' 'status escalate is not ready/merged' && ok=1
check "canary: a run that did not end ready/merged -> not counted, FAIL" "$ok"

mkroot "$WORK/c-dup"
mkresults "$WORK/c-dup" 10x1 10x1 10x1
canary "$WORK/c-dup" "{\"runs\":[$R1,$R1]}"
gc "$WORK/c-dup"
ok=0; [ "$GRC" -eq 1 ] && is canary FAIL '1/2 qualifying canary runs' 'pr 3: listed twice' && ok=1
check "canary: the same run listed twice counts once, FAIL" "$ok"

mkroot "$WORK/c-bad"
mkresults "$WORK/c-bad" 10x1 10x1 10x1
canary "$WORK/c-bad" '{"runs":[{"issue":1,"status":"merged","pipelineStates":[]}]}'
gc "$WORK/c-bad" --ci
ok=0; [ "$GRC" -eq 1 ] && is canary FAIL 'runs[0]: issue and pr must be positive integers' && ok=1
check "canary: a run without pr -> malformed record, FAIL even with --ci" "$ok"
printf 'not json\n' > "$WORK/c-bad/docs/gate/e2-canary.json"
gc "$WORK/c-bad" --ci
ok=0; [ "$GRC" -eq 1 ] && is canary FAIL 'unreadable: not valid JSON' && ok=1
check "canary: a record that is not JSON -> FAIL even with --ci" "$ok"

mkroot "$WORK/c-none"
mkresults "$WORK/c-none" 10x1 10x1 10x1
gc "$WORK/c-none"
ok=0; [ "$GRC" -eq 1 ] && is canary FAIL '0/2 qualifying canary runs' 'not found' && ok=1
check "canary: no record file run as the gate -> FAIL" "$ok"
gc "$WORK/c-none" --ci
ok=0; [ "$GRC" -eq 0 ] && is canary SKIP 'not found' && ok=1
check "canary: no record file with --ci -> SKIP" "$ok"

# --- usage and the committed state
gc "$WORK/green" bogus
ok=0; [ "$GRC" -eq 2 ] && has 'usage: gate-check.sh e2 [--ci]' && ok=1
check "an unknown option -> usage, exit 2" "$ok"
GOUT="$(bash "$GC" 2>&1)"; GRC=$?
ok=0; [ "$GRC" -eq 2 ] && has 'usage: gate-check.sh e2 [--ci]' && ok=1
check "no suite -> usage, exit 2" "$ok"

# the committed repo, with --ci and no results dir: incidents replay green, eval pins hold, the committed
# canary record is well-formed (SKIP or PASS, never FAIL); the exit code is 0
GOUT="$(env PROBE_EVALS_RESULTS_DIR="$WORK/no-results" bash "$GC" e2 --ci 2>&1)"; GRC=$?
ok=0; [ "$GRC" -eq 0 ] && is incidents PASS && is eval SKIP 'grader pins ok (3 cases)' && ! is canary FAIL && ok=1
check "committed repo with --ci: incidents PASS, grader pins hold, canary record well-formed, exit 0" "$ok"

# the in-flight statuses the canary check applies are the whitelist of the Stop hook
ok=0
grep -q '^INFLIGHT="in-progress plan dev review"' "$GC" && grep -q 'in-progress|plan|dev|review) ;;' "$ROOT/hooks/Stop-supervise-runs.sh" && ok=1
check "gate-check.sh INFLIGHT equals the in-flight whitelist of hooks/Stop-supervise-runs.sh" "$ok"

# guards CI runs this test and the gate in --ci mode, without evals/results
ok=0
grep -qE '^ +run: bash scripts/test-gate-check\.sh$' "$ROOT/.github/workflows/guards.yml" && grep -qE '^ +run: bash scripts/gate-check\.sh e2 --ci$' "$ROOT/.github/workflows/guards.yml" && ok=1
check "guards.yml has a run: step for test-gate-check.sh and one for gate-check.sh e2 --ci" "$ok"

echo "status=$([ "$fail_count" -eq 0 ] && echo pass || echo fail) pass=$pass_count fail=$fail_count"
[ "$fail_count" -eq 0 ]
