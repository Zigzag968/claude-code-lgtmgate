#!/usr/bin/env bash
# Offline validator for the probe eval cases (evals/probe-*/, #81). No `claude` call, no network.
# (a) structure of each case, (b) each case's command really runs through templates/probe-run.cjs
# and its regex grader matches the produced PROBE line, (c) the local runner, (d) workflows hold no
# secret, schedule or eval step. bash 3.2 safe.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_BASE="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
WORK="$(mktemp -d "$TMP_BASE/probe-evals-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass_count=0
fail_count=0

check() {
  local name="$1" ok="$2"
  if [ "$ok" -eq 1 ]; then echo "PASS - $name"; pass_count=$((pass_count + 1))
  else echo "FAIL - $name"; fail_count=$((fail_count + 1)); fi
}

# (a) exactly three cases with prompt.md and >= 3 graders
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
  [ "$n_gr" -ge 3 ] && [ "$bad" -eq 0 ] && [ "$n_tool" -ge 1 ] && [ "$n_regex" -ge 1 ] && ok=1
  check "$name: >= 3 graders, typed tool_used/regex, both kinds present ($n_gr/$n_tool/$n_regex)" "$ok"

  # `last_message` is the main session's final message: the prompt must make it a pure relay
  ok=0
  grep -q 'ONLY the PROBE line' "$d/prompt.md" && grep -q 'verbatim: no prose' "$d/prompt.md" \
    && grep -q 'no code fences' "$d/prompt.md" && grep -q 'Do not rerun the commands yourself' "$d/prompt.md" && ok=1
  check "$name: prompt requires a verbatim-only relay (no prose, no fences)" "$ok"
  ok=0
  grep -q '^target: last_message$' "$d/graders/probe-line.md" \
    && grep -q 'exit=0 sha=\[0-9a-f\]{64} cmd=\[0-9a-f\]{64} json=' "$d/graders/probe-line.md" \
    && grep -q "^pattern: '\^PROBE name=" "$d/graders/probe-line.md" && ok=1
  check "$name: probe-line grader keeps a strict regex (name, exit, 64-hex sha, 64-hex cmd, json)" "$ok"

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
  LINE="$(cd "$run" && EVAL_PLUGIN_ROOT="$ROOT" bash "$run/cmd.sh" 2>/dev/null)"
  rc=$?
  ok=0
  [ "$rc" -eq 0 ] && [ "$(printf '%s\n' "$LINE" | wc -l | tr -d ' ')" = "1" ] && ok=1
  check "$name: case command runs and prints a single line" "$ok"

  ok=0
  if node -e '
    const fs = require("fs")
    const src = fs.readFileSync(process.argv[1], "utf8")
    const field = (k) => { const m = src.match(new RegExp("^" + k + ": *(.*)$", "m")); return m ? m[1].trim() : "" }
    let pat = field("pattern")
    if (pat.length > 1 && pat[0] === "\x27" && pat[pat.length - 1] === "\x27") pat = pat.slice(1, -1)
    const re = new RegExp(pat, field("flags"))
    process.exit(re.test(process.argv[2]) ? 0 : 1)
  ' "$d/graders/probe-line.md" "$LINE" 2>/dev/null; then ok=1; fi
  check "$name: probe-line grader matches the real PROBE line" "$ok"
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
