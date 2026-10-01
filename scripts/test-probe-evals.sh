#!/usr/bin/env bash
# Offline validator for the probe eval cases (evals/probe-*/, #81). No `claude` call, no network.
# (a) structure of each case (4 graders), (b) each case's commands really run through
# templates/probe-run.cjs: the pinned probe-line grader equals the real PROBE line and rejects
# corrupted / invented / wrapped variants, the verify-ok grader matches the real --verify output as a
# tool_result and nothing weaker, (c) the local runner, (d) workflows hold no secret, schedule or eval
# step. bash 3.2 safe.
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

echo "status=$([ "$fail_count" -eq 0 ] && echo pass || echo fail) pass=$pass_count fail=$fail_count"
[ "$fail_count" -eq 0 ]
