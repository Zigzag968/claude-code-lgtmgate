#!/usr/bin/env bash
# Regression test for scripts/audit.cjs (the code-quality ratchet, #289). Every case runs the real tools and the real
# configs of this repository against a throwaway git repository under $TMPDIR (audit.cjs lints the repository of its
# cwd): the PR worktree is never written. Each case prints `PASS: <id> <label>`; the ids are what the acceptance
# items grep. Needs `npm ci` and ruff at the version of ruff.toml on PATH.
# Cases: P-30 size budget, P-31 function length (plain, nested, template literal), P-32 naming (identifier, abbreviation,
# file name), P-33 baseline freeze and the hook-name exemption, P-34 ShellCheck, P-35 baseline-vs-origin (raised, bootstrap),
# P-36 fixtures out of scope, P-37 unreadable file, P-38 default list of guards.cjs, P-39 same verdict line through
# guards.cjs, P-40 clean repo (one line, timing), ruff-missing, ruff-version, baseline-missing.
# Ends with `[test-audit] status=<ok|fail> passed=<n> failed=<n>`.
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1
T="$(mktemp -d "${TMPDIR:-/tmp}/test-audit.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PASS_N=0; FAIL_N=0
ok() { echo "PASS: $1"; PASS_N=$((PASS_N + 1)); }
ko() { echo "FAIL: $1"; FAIL_N=$((FAIL_N + 1)); }
NODE="$(command -v node)"
OUT=""; RC=0

gitq() { git -c user.name=t -c user.email=t@t "$@"; }

# mkrepo <name> [baseline-json]: a throwaway repo with a bare origin; sets REPO. With a baseline argument the baseline is
# committed and pushed (origin holds it); without, the baseline `{}` is written after the push (origin has none).
mkrepo() {
  REPO="$T/$1"
  git init -q --bare "$T/$1.git" && git init -q "$REPO" && mkdir -p "$REPO/scripts"
  printf 'seed\n' > "$REPO/seed.txt"
  if [ $# -ge 2 ]; then printf '%s\n' "$2" > "$REPO/scripts/audit-baseline.json"; fi
  git -C "$REPO" add -A && gitq -C "$REPO" commit -qm seed && git -C "$REPO" branch -M main \
    && git -C "$REPO" remote add origin "$T/$1.git" && git -C "$REPO" push -q origin main && git -C "$REPO" fetch -q origin main
  if [ $# -lt 2 ]; then printf '{}\n' > "$REPO/scripts/audit-baseline.json"; fi
}

# run_audit <repo>: sets RC and OUT (stdout and stderr).
run_audit() { OUT="$(cd "$1" && "$NODE" "$REPO_ROOT/scripts/audit.cjs" --check 2>&1)"; RC=$?; }
has() { printf '%s\n' "$OUT" | grep -qF -- "$1"; }
# red_with <id> <label> <fixed text>: rc 1 and the text in the output.
red_with() { if [ "$RC" -eq 1 ] && has "$3"; then ok "$1 $2"; else ko "$1 $2 (rc=$RC, wanted '$3') $OUT"; fi; }
green() { if [ "$RC" -eq 0 ]; then ok "$1 $2"; else ko "$1 $2 (rc=$RC) $OUT"; fi; }

# put_lines <file> <prefix> <count>: a file of <count> lines.
put_lines() { awk -v n="$3" -v p="$2" 'BEGIN { for (k = 1; k <= n; k++) print p }' > "$1"; }
# body_lines <count>: <count> statement lines for a JS function body.
body_lines() { awk -v n="$1" 'BEGIN { for (k = 1; k <= n; k++) print "  void 0" }'; }

plant_size() {
  put_lines "$1/big.cjs" '// filler' 601
  put_lines "$1/big.sh" '# filler' 601
  put_lines "$1/big.py" '# filler' 601
}

plant_functions() {
  { echo 'function longOne() {'; body_lines 88; echo '}'; echo 'module.exports = longOne'; } > "$1/plain.cjs"
  { echo 'function outerOne() {'; echo '  const innerOne = () => {'; body_lines 88; echo '  }'; echo '  return innerOne'; echo '}'; echo 'module.exports = outerOne'; } > "$1/nested.cjs"
  { echo 'const text = `a}${[1].map(() => {'; body_lines 88; echo '})}b}`'; echo 'module.exports = text'; } > "$1/template.cjs"
}

plant_naming() {
  printf 'const my_value = 1\nmodule.exports = my_value\n' > "$1/snake.cjs"
  printf 'const cfgPath = 1\nmodule.exports = cfgPath\n' > "$1/cfgpath.cjs"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$1/Foo_bar.sh"
  printf '#!/usr/bin/env bash\nunused=1\n' > "$1/warn.sh"
}

case_plants() {
  mkrepo plants
  plant_size "$REPO"; plant_functions "$REPO"; plant_naming "$REPO"
  run_audit "$REPO"
  if [ "$RC" -eq 1 ] && has 'FAIL: audit: big.cjs max-lines 1 > baseline 0' && has 'FAIL: audit: big.sh max-lines 1 > baseline 0' && has 'FAIL: audit: big.py max-lines 1 > baseline 0'; then ok "P-30 a file over 600 lines outside the baseline is red, named with its rule (.cjs, .sh, .py)"; else ko "P-30 (rc=$RC) $OUT"; fi
  red_with P-31 "a plain 90-line JS function is red" 'FAIL: audit: plain.cjs max-lines-per-function 1 > baseline 0'
  red_with P-31 "a nested 90-line function is counted on its own (outer and inner)" 'FAIL: audit: nested.cjs max-lines-per-function 2 > baseline 0'
  red_with P-32 "a new snake_case identifier is red" 'FAIL: audit: snake.cjs camelcase '
  red_with P-32 "a new cfgPath identifier is red" 'FAIL: audit: cfgpath.cjs unicorn/name-replacements '
  red_with P-32 "a new file Foo_bar.sh is red" 'FAIL: audit: Foo_bar.sh ls-lint:.sh:kebabcase 1 > baseline 0'
  red_with P-34 "a new ShellCheck warning (SC2034) is red" 'FAIL: audit: warn.sh SC2034 1 > baseline 0'
  PLANTS_OUT="$OUT"; PLANTS_RC="$RC"
}

case_template() {
  # The template literal holding `}` and a 90-line arrow function is red (checked on the plants run); a short function whose
  # template literal contains `}` is green.
  mkrepo template
  printf 'function shortOne() {\n  return `}`\n}\nmodule.exports = shortOne\n' > "$REPO/short.cjs"
  run_audit "$REPO"
  if [ "$PLANTS_RC" -eq 1 ] && printf '%s\n' "$PLANTS_OUT" | grep -qF 'FAIL: audit: template.cjs max-lines-per-function 1 > baseline 0' && [ "$RC" -eq 0 ]; then ok "P-31 a 90-line function inside a template literal is red, a short function with } in a template is green"; else ko "P-31 template (rc=$RC) $OUT"; fi
}

case_baseline_freeze() {
  mkrepo freeze
  printf 'const cfg = 1\nmodule.exports = cfg\n' > "$REPO/old.cjs"
  (cd "$REPO" && "$NODE" "$REPO_ROOT/scripts/audit.cjs" --report > scripts/audit-baseline.json)
  run_audit "$REPO"
  green P-33 "a file in the baseline keeping the same findings is green"
  printf 'const cfg = 1\nmodule.exports = cfg\n' > "$REPO/fresh.cjs"
  run_audit "$REPO"
  red_with P-33 "the same identifier in a file outside the baseline is red" 'FAIL: audit: fresh.cjs unicorn/name-replacements '
  mkrepo hooks
  mkdir -p "$REPO/hooks"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$REPO/hooks/PostToolUse-x.sh"
  run_audit "$REPO"
  green P-33 "a hooks/PostToolUse-*.sh file name is exempt"
}

case_unreadable() {
  mkrepo locked
  printf 'module.exports = 1\n' > "$REPO/locked.cjs"; chmod 000 "$REPO/locked.cjs"
  run_audit "$REPO"
  chmod 644 "$REPO/locked.cjs"
  if [ "$(id -u)" -eq 0 ]; then echo "SKIP: P-37 (root reads mode 000)"; ok "P-37 unreadable file (skipped as root)"; return; fi
  red_with P-37 "an unreadable file is red and named" 'FAIL: audit: locked.cjs unreadable'
}

case_clean_and_guards() {
  mkrepo clean
  printf 'module.exports = 1\n' > "$REPO/ok.cjs"
  mkdir -p "$REPO/fixtures"; put_lines "$REPO/fixtures/huge.cjs" '// filler' 2000
  CLEAN="$REPO"
  local started ended direct_out direct_rc
  started=$(date +%s)
  direct_out="$(cd "$CLEAN" && "$NODE" "$REPO_ROOT/scripts/audit.cjs" --check 2>/dev/null)"; direct_rc=$?
  ended=$(date +%s)
  if [ "$direct_rc" -eq 0 ]; then ok "P-36 a 2000-line file under fixtures/ is out of scope"; else ko "P-36 (rc=$direct_rc) $direct_out"; fi
  if [ "$direct_rc" -eq 0 ] && [ "$(printf '%s\n' "$direct_out" | wc -l | tr -d ' ')" -eq 1 ] && printf '%s\n' "$direct_out" | grep -qxE 'PASS: audit: [0-9]+ findings, all under baseline'; then ok "P-40 a clean repo prints exactly one PASS line (elapsed $((ended - started))s)"; else ko "P-40 (rc=$direct_rc) $direct_out"; fi
  local guards_out guards_rc
  guards_out="$(GUARDS_ROOT="$CLEAN" GUARDS_ONLY=audit node scripts/guards.cjs 2>&1)"; guards_rc=$?
  if [ "$direct_rc" -eq 0 ] && [ "$guards_rc" -eq 0 ] && [ -n "$direct_out" ] && [ "$(printf '%s\n' "$guards_out" | grep '^PASS: audit')" = "$direct_out" ]; then ok "P-39 audit.cjs and guards.cjs print the same PASS: audit line"; else ko "P-39 (rc=$guards_rc) $direct_out / $guards_out"; fi
  BOOTSTRAP_OUT="$guards_out"; BOOTSTRAP_RC="$guards_rc"
}

case_origin() {
  mkrepo raised '{"a.sh":{"max-lines":1}}'
  printf '{"a.sh":{"max-lines":2}}\n' > "$REPO/scripts/audit-baseline.json"
  local only_out only_rc default_out default_rc
  only_out="$(GUARDS_ROOT="$REPO" GUARDS_ONLY=audit node scripts/guards.cjs 2>&1)"; only_rc=$?
  default_out="$(GUARDS_ROOT="$REPO" node scripts/guards.cjs 2>&1)"; default_rc=$?
  local wanted='FAIL: audit: baseline-vs-origin a.sh max-lines 2 > origin/main 1'
  if [ "$only_rc" -ne 0 ] && printf '%s\n' "$only_out" | grep -qF "$wanted" && [ "$BOOTSTRAP_RC" -eq 0 ] && printf '%s\n' "$BOOTSTRAP_OUT" | grep -qxF 'SKIP: baseline-vs-origin (no base baseline)'; then ok "P-35 a baseline raised vs origin/main is red; with no base baseline the check is skipped"; else ko "P-35 (rc=$only_rc/$BOOTSTRAP_RC) $only_out $BOOTSTRAP_OUT"; fi
  if [ "$default_rc" -ne 0 ] && printf '%s\n' "$default_out" | grep -qF "$wanted"; then ok "P-38 the default list of guards.cjs runs the audit check"; else ko "P-38 (rc=$default_rc) $default_out"; fi
}

case_tool_setup() {
  local bin="$T/nobin"
  mkdir -p "$bin" && ln -s "$NODE" "$bin/node" && ln -s "$(command -v git)" "$bin/git"
  OUT="$(cd "$CLEAN" && PATH="$bin" "$NODE" "$REPO_ROOT/scripts/audit.cjs" --check 2>&1)"; RC=$?
  red_with ruff-missing "ruff off PATH exits 1 naming ruff" 'FAIL: audit: ruff not found'
  mkdir -p "$T/fakeruff" && printf '#!/bin/sh\necho "ruff 0.0.1"\n' > "$T/fakeruff/ruff" && chmod +x "$T/fakeruff/ruff"
  OUT="$(cd "$CLEAN" && PATH="$T/fakeruff:$PATH" "$NODE" "$REPO_ROOT/scripts/audit.cjs" --check 2>&1)"; RC=$?
  red_with ruff-version "a ruff at another version exits 1 naming it" 'FAIL: audit: ruff 0.0.1 != required'
  mkrepo nobaseline && rm -f "$REPO/scripts/audit-baseline.json"
  run_audit "$REPO"
  red_with baseline-missing "no baseline file exits 1 naming it" 'FAIL: audit: scripts/audit-baseline.json missing or invalid'
}

case_plants
case_template
case_baseline_freeze
case_unreadable
case_clean_and_guards
case_origin
case_tool_setup

STATUS=ok; [ "$FAIL_N" -eq 0 ] || STATUS=fail
echo "[test-audit] status=${STATUS} passed=${PASS_N} failed=${FAIL_N}"
[ "$FAIL_N" -eq 0 ]
