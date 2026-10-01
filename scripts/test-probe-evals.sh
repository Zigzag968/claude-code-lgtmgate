#!/usr/bin/env bash
# Offline validator for the probe eval cases (evals/probe-*/, #81). No `claude` call, no network.
# (a) structure of each case (4 graders), (b) each case's commands really run through
# templates/probe-run.cjs: the pinned probe-line grader equals the real PROBE line and rejects
# corrupted / invented / wrapped variants, the verify-ok grader matches the real --verify output as a
# tool_result and nothing weaker, (c) the local runner, (d) workflows hold no secret, schedule or eval
# step, (e) the gate (>= 29/30 FULLY passed runs, counted per run, never the case mean) on fake
# aggregate-result.json files, the runner wired to it through a fake `claude`, and the pinned CLI
# version. bash 3.2 safe.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_BASE="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
WORK="$(mktemp -d "$TMP_BASE/probe-evals-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Grader helper (node): reads a grader's frontmatter, compiles its regex like the eval does (JS regex,
# `flags`, default match = contains) and answers by exit code.
cat > "$WORK/grade.cjs" <<'JS'
const fs = require('fs')
const [mode, file, a, b] = process.argv.slice(2)
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
const front = mode === 'attest' ? '' : fs.readFileSync(file, 'utf8').split(/^---$/m)[1] || ''
const field = (k) => { const m = front.match(new RegExp('^' + k + ': *(.*)$', 'm')); return m ? m[1].trim() : '' }
let pat = field('pattern')
if (pat.length > 1 && pat[0] === "'" && pat[pat.length - 1] === "'") pat = pat.slice(1, -1).replace(/''/g, "'")
const re = () => new RegExp(pat, field('flags'))
const traceUser = (text) => JSON.stringify({ type: 'user', message: { role: 'user', content: [{ tool_use_id: 't', type: 'tool_result', content: text, is_error: false }] } })
const traceAssistant = (text) => JSON.stringify({ type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text }] } })
const noisy = (t) => 'bash: startup file not readable\n' + t
const flip = (line) => line.replace(/sha=([0-9a-f])/, (m, h) => 'sha=' + (h === '0' ? '1' : '0'))
const ok = (cond) => process.exit(cond ? 0 : 1)
switch (mode) {
  // the grader pattern is exactly the whole real line, anchored, regex-escaped, no flag
  case 'pinned': ok(pat === '^\\s*' + esc(a) + '\\s*$' && field('flags') === '' && field('target') === 'last_message')
  case 'match': ok(re().test(a))
  // the line must be rejected when corrupted, wrapped in prose or fences, or invented
  case 'rejects-variants': ok(
    !re().test(flip(a)) && !re().test(a + '\nDone.') && !re().test('Here it is:\n' + a) &&
    !re().test('```\n' + a + '\n```') && !re().test(a.replace(/ cmd=[0-9a-f]{64}/, ' cmd=' + '0'.repeat(64))) &&
    !re().test(a.replace(/json=.*$/, 'json={}')) && re().test(a + '\n') && re().test(a))
  case 'attest': fs.writeFileSync(file, JSON.stringify({ label: a, round: 0, line: b }) + '\n'); process.exit(0)
  // the verify-ok grader: real VERIFY output as a Bash tool_result matches; a corrupted sha, a failed
  // verify, or the same text written by the agent (prose, report) does not
  case 'verify-ok': ok(
    field('target') === 'trace' &&
    re().test(traceUser(noisy(a))) && re().test(traceUser(a)) &&
    !re().test(traceAssistant(a)) && !re().test(traceUser(flip(a))) &&
    !re().test(traceUser('VERIFY fail reason=no-attestation')) &&
    !re().test(traceUser(noisy('VERIFY fail reason=no-attestation')) + '\n' + traceAssistant(a)))
}
JS

pass_count=0
fail_count=0

check() {
  local name="$1" ok="$2"
  if [ "$ok" -eq 1 ]; then echo "PASS - $name"; pass_count=$((pass_count + 1))
  else echo "FAIL - $name"; fail_count=$((fail_count + 1)); fi
}

# (a) exactly three cases with prompt.md and 4 graders
n_cases=0
for d in "$ROOT"/evals/probe-*/; do
  [ -d "$d" ] || continue
  n_cases=$((n_cases + 1))
done
[ "$n_cases" -eq 3 ] && ok=1 || ok=0
check "exactly 3 evals/probe-*/ cases (found $n_cases)" "$ok"

for d in "$ROOT"/evals/probe-*/; do
  [ -d "$d" ] || continue
  name="$(basename "$d")"
  ok=0
  [ -f "$d/prompt.md" ] && head -1 "$d/prompt.md" | grep -q '^---$' && [ "$(grep -c '^```bash$' "$d/prompt.md")" = "1" ] && ok=1
  check "$name: prompt.md has frontmatter and one bash block" "$ok"

  n_gr=0; n_tool=0; n_regex=0; bad=0
  for g in "$d"/graders/*.md; do
    [ -f "$g" ] || continue
    n_gr=$((n_gr + 1))
    if grep -q '^type: tool_used$' "$g"; then n_tool=$((n_tool + 1))
    elif grep -q '^type: regex$' "$g"; then n_regex=$((n_regex + 1))
    else bad=$((bad + 1)); fi
  done
  ok=0
  [ "$n_gr" -eq 4 ] && [ "$bad" -eq 0 ] && [ "$n_tool" -eq 2 ] && [ "$n_regex" -eq 2 ] \
    && [ -f "$d/graders/agent-dispatched.md" ] && [ -f "$d/graders/bash-called.md" ] \
    && [ -f "$d/graders/probe-line.md" ] && [ -f "$d/graders/verify-ok.md" ] && ok=1
  check "$name: 4 graders (agent-dispatched, bash-called, probe-line, verify-ok): 2 tool_used + 2 regex ($n_gr/$n_tool/$n_regex)" "$ok"

  # `last_message` is the main session's final message: the prompt must make it a pure relay
  ok=0
  grep -q 'ONLY the PROBE line' "$d/prompt.md" && grep -q 'verbatim: no prose' "$d/prompt.md" \
    && grep -q 'no code fences' "$d/prompt.md" && grep -q 'Do not rerun the commands yourself' "$d/prompt.md" && ok=1
  check "$name: prompt requires a verbatim-only relay (no prose, no fences)" "$ok"
  # (b) run the case command for real and match the regex grader against the PROBE line
  run="$WORK/$name"
  mkdir -p "$run"
  node -e '
    const fs = require("fs")
    const m = fs.readFileSync(process.argv[1], "utf8").match(/```bash\n([\s\S]*?)\n```/)
    process.stdout.write(m ? m[1] : "")
  ' "$d/prompt.md" > "$run/cmd2.sh"
  # the block holds two commands: the PROBE run, then its --verify (the SubagentStop hook needs the pair)
  head -1 "$run/cmd2.sh" > "$run/cmd.sh"
  ok=0
  [ "$(grep -c '' "$run/cmd2.sh")" = "2" ] && sed -n 2p "$run/cmd2.sh" | grep -q -- '--verify .*--attest ' && ok=1
  check "$name: bash block holds the run command then its --verify command" "$ok"
  sed -n 2p "$run/cmd2.sh" > "$run/verify.sh"
  LINE="$(cd "$run" && EVAL_PLUGIN_ROOT="$ROOT" bash "$run/cmd.sh" 2>/dev/null)"
  rc=$?
  ok=0
  [ "$rc" -eq 0 ] && [ -n "$LINE" ] && [ "$(printf '%s\n' "$LINE" | wc -l | tr -d ' ')" = "1" ] \
    && case "$LINE" in "PROBE name="*) true ;; *) false ;; esac && ok=1
  check "$name: case command runs and prints a single non-empty line" "$ok"

  G="$d/graders/probe-line.md"
  ok=0; node "$WORK/grade.cjs" pinned "$G" "$LINE" 2>/dev/null && ok=1
  check "$name: probe-line pins exactly the real PROBE line (sha, cmd, json), anchored on the whole last message, no flags" "$ok"
  ok=0; node "$WORK/grade.cjs" match "$G" "$LINE" 2>/dev/null && ok=1
  check "$name: probe-line grader matches the real PROBE line" "$ok"
  ok=0; node "$WORK/grade.cjs" rejects-variants "$G" "$LINE" 2>/dev/null && ok=1
  check "$name: probe-line grader rejects a flipped sha char, a wrong cmd or json, prose or fences around the line" "$ok"

  # the PostToolUse hook would attest the line in a real run; write the entry it writes
  label="$(sed -n 's/.* --label \([A-Za-z0-9._-]*\) .*/\1/p' "$run/cmd.sh")"
  mkdir -p "$run/.pipeline"
  node "$WORK/grade.cjs" attest "$run/.pipeline/probe-attest.jsonl" "$label" "$LINE"
  VERIFY="$(cd "$run" && EVAL_PLUGIN_ROOT="$ROOT" bash "$run/verify.sh" 2>/dev/null)"
  ok=0
  [ -n "$VERIFY" ] && [ "$VERIFY" = "VERIFY ok line=$LINE" ] && ok=1
  check "$name: --verify prints VERIFY ok line=<the real PROBE line>" "$ok"
  ok=0; node "$WORK/grade.cjs" verify-ok "$d/graders/verify-ok.md" "$VERIFY" 2>/dev/null && ok=1
  check "$name: verify-ok grader matches the real VERIFY line as a tool_result, not as agent prose, not corrupted" "$ok"
done

# (c) local runner
R="$ROOT/scripts/run-probe-evals.sh"
ok=0; bash -n "$R" 2>/dev/null && ok=1
check "run-probe-evals.sh parses" "$ok"
ok=1
for needle in '--max-cost-usd' '--no-publish' '--runs 10'; do
  grep -q -- "$needle" "$R" || ok=0
done
check "run-probe-evals.sh sets a cost ceiling, no publish, 10 runs" "$ok"
ok=1
grep -qE 'secrets|API_KEY' "$R" && ok=0
check "run-probe-evals.sh holds no secret reference" "$ok"

# (d) CI never runs the evals nor uses a secret
ok=1
grep -rqE '\$\{\{ *secrets\.' "$ROOT/.github/workflows/" && ok=0
check "no secrets expression in workflows" "$ok"
ok=1
grep -rqE '^ *schedule:' "$ROOT/.github/workflows/" && ok=0
check "no schedule trigger in workflows" "$ok"
ok=1
grep -rq 'claude plugin eval' "$ROOT/.github/workflows/" && ok=0
check "no claude plugin eval step in workflows" "$ok"

# (e) the gate: at least 29 of 30 runs FULLY passed (score 1). Fake aggregate-result.json files, same
# field names as `claude plugin eval` 2.1.286: cases[].name, cases[].arms.with[].score / .error.
G="$ROOT/scripts/probe-eval-gate.sh"
ok=0; bash -n "$G" 2>/dev/null && ok=1
check "probe-eval-gate.sh parses" "$ok"
ok=0; grep -q 'probe-eval-gate.sh' "$R" && ok=1
check "run-probe-evals.sh calls the gate" "$ok"

# mkres.cjs <file> <case> <spec>: spec = comma list of <count>x<score>, a trailing ! sets an error on
# those runs ("8x1,2x0.75" = 8 clean runs, 2 runs at 0.75). Also writes the case mean like the real file.
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

# mkgate <dir> <spec provision> <spec pr-state> <spec pr-write>; a spec of "-" writes no file
mkgate() {
  local dir="$1" c spec
  shift
  for c in probe-provision probe-pr-state probe-pr-write; do
    spec="$1"; shift
    [ "$spec" = "-" ] && continue
    node "$WORK/mkres.cjs" "$dir/$c/aggregate-result.json" "$c" "$spec"
  done
}
# gate_run <dir> sets GOUT (stdout+stderr) and GRC (exit code); has <text> looks in GOUT
gate_run() { GOUT="$(bash "$G" "$1" 2>&1)"; GRC=$?; }
has() { case "$GOUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

mkgate "$WORK/g30" 10x1 10x1 10x1
gate_run "$WORK/g30"
ok=0; [ "$GRC" -eq 0 ] && has 'gate: 30/30 fully passed runs (need >= 29/30) -> PASS' && has 'probe-pr-state: 10/10 runs fully passed' && ok=1
check "gate: 30/30 fully passed runs -> PASS, exit 0" "$ok"

mkgate "$WORK/g29" 9x1,1x0.75 10x1 10x1
gate_run "$WORK/g29"
ok=0; [ "$GRC" -eq 0 ] && has 'probe-provision: 9/10 runs fully passed' && has 'gate: 29/30 fully passed runs (need >= 29/30) -> PASS' && ok=1
check "gate: 29/30 fully passed runs -> PASS, exit 0" "$ok"

# the case that a mean threshold lets through: 2 runs at 0.75 = case mean 0.95, but only 28/30 runs fully pass
mkgate "$WORK/g28" 8x1,2x0.75 10x1 10x1
gate_run "$WORK/g28"
ok=0
node -e '
  const j = require(process.argv[1])
  process.exit(Math.abs(j.cases[0].aggregates.score - 0.95) < 1e-9 ? 0 : 1)
' "$WORK/g28/probe-provision/aggregate-result.json" \
  && [ "$GRC" -eq 1 ] && has 'probe-provision: 8/10 runs fully passed' && has 'gate: 28/30 fully passed runs (need >= 29/30) -> FAIL' && ok=1
check "gate: 28/30 fully passed runs, case mean 0.95 -> FAIL, exit 1" "$ok"

mkgate "$WORK/gerr" 8x1,2x1! 10x1 10x1
gate_run "$WORK/gerr"
ok=0; [ "$GRC" -eq 1 ] && has 'probe-provision: 8/10 runs fully passed' && has '-> FAIL' && ok=1
check "gate: a run with an error is not a fully passed run" "$ok"

mkgate "$WORK/gmiss" 10x1 - 10x1
gate_run "$WORK/gmiss"
ok=0; [ "$GRC" -ne 0 ] && has 'probe-pr-state: results unusable (file missing)' && has '-> FAIL' && ok=1
check "gate: a missing results file -> FAIL, non-zero exit" "$ok"

mkgate "$WORK/gbad" 10x1 10x1 10x1
echo 'not json' > "$WORK/gbad/probe-pr-write/aggregate-result.json"
gate_run "$WORK/gbad"
ok=0; [ "$GRC" -ne 0 ] && has 'probe-pr-write: results unusable (file unreadable)' && has '-> FAIL' && ok=1
check "gate: an unreadable results file -> FAIL, non-zero exit" "$ok"

# 9 runs, all passed: 29 of 29 would clear 95 %, but every case must have its 10 runs
mkgate "$WORK/g9" 10x1 9x1 10x1
gate_run "$WORK/g9"
ok=0; [ "$GRC" -eq 1 ] && has 'probe-pr-state: 9/9 runs fully passed (fewer than 10 runs)' && has '-> FAIL' && ok=1
check "gate: a case with 9 runs -> FAIL, exit 1" "$ok"

# the runner calls the gate and takes its exit code, through a fake `claude` that writes the case's spec
FAKEBIN="$WORK/fakebin"; FAKE="$WORK/fake"
mkdir -p "$FAKEBIN" "$FAKE"
cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
c=""; out=""
while [ "$#" -gt 0 ]; do
  case "$1" in --case) c="$2"; shift ;; --output-dir) out="$2"; shift ;; esac
  shift
done
[ -f "$FAKE_DIR/$c.spec" ] && node "$FAKE_MKRES" "$out/aggregate-result.json" "$c" "$(cat "$FAKE_DIR/$c.spec")"
exit "$(cat "$FAKE_DIR/rc" 2>/dev/null || echo 0)"
SH
chmod +x "$FAKEBIN/claude"
# runner_run <results-dir> sets GOUT and GRC; the spec files and rc come from $FAKE
runner_run() {
  GOUT="$(PATH="$FAKEBIN:$PATH" FAKE_DIR="$FAKE" FAKE_MKRES="$WORK/mkres.cjs" PROBE_EVALS_RESULTS_DIR="$1" bash "$R" 2>&1)"
  GRC=$?
}
set_fake() { echo 10x1 > "$FAKE/probe-provision.spec"; echo "$1" > "$FAKE/probe-pr-state.spec"; echo 10x1 > "$FAKE/probe-pr-write.spec"; echo "$2" > "$FAKE/rc"; }

set_fake 10x1 0
runner_run "$WORK/rr-pass"
ok=0; [ "$GRC" -eq 0 ] && has '== probe-pr-state: claude exit=0' && has 'gate: 30/30 fully passed runs (need >= 29/30) -> PASS' && ok=1
check "run-probe-evals.sh: 30/30 fully passed runs -> exit 0" "$ok"

set_fake 8x1,2x0.75 0
runner_run "$WORK/rr-fail"
ok=0; [ "$GRC" -ne 0 ] && has 'probe-pr-state: 8/10 runs fully passed' && has '-> FAIL' && ok=1
check "run-probe-evals.sh: 28/30 fully passed runs, claude exit 0 -> non-zero exit" "$ok"

# claude's own exit code (its --threshold is a case-mean check) is informational: the run count decides
set_fake 9x1,1x0.5 1
runner_run "$WORK/rr-mean"
ok=0; [ "$GRC" -eq 0 ] && has '== probe-pr-state: claude exit=1' && has '-> PASS' && ok=1
check "run-probe-evals.sh: claude exit 1 with 29/30 fully passed runs -> gate PASS, exit 0" "$ok"

# a stale pass left by an earlier run must not gate a run that produced nothing
mkgate "$WORK/rr-stale" 10x1 10x1 10x1
rm -f "$FAKE/probe-pr-state.spec"
echo 1 > "$FAKE/rc"
runner_run "$WORK/rr-stale"
ok=0; [ "$GRC" -ne 0 ] && has 'probe-pr-state: results unusable (file missing)' && has '-> FAIL' && ok=1
check "run-probe-evals.sh: results of an earlier run are cleared, a run that wrote none -> FAIL" "$ok"

# the CLI the eval runs on is pinned: the verify-ok grader reads the 2.1.286 trace format
pin="$(sed -n 's/^ARG CLAUDE_CODE_VERSION=\([0-9][0-9.]*\)$/\1/p' "$ROOT/.devcontainer/Dockerfile")"
ok=0
[ -n "$pin" ] && grep -q "\"CLAUDE_CODE_VERSION\": \"$pin\"" "$ROOT/.devcontainer/devcontainer.json" \
  && grep -q "$pin" "$ROOT/.claude/skills/run-probe-evals/SKILL.md" && ok=1
check "Dockerfile pins CLAUDE_CODE_VERSION to an exact version (${pin:-none}), devcontainer.json and the skill cite the same" "$ok"

echo "status=$([ "$fail_count" -eq 0 ] && echo pass || echo fail) pass=$pass_count fail=$fail_count"
[ "$fail_count" -eq 0 ]
