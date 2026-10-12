#!/usr/bin/env bash
# audit-collision cases (#526): the audit runs on the tree merged from origin/main, before the bump and the push (sourced by tests/scripts/test-lead-merge.sh, never executed).
# Fixture: a stub scripts/guards.cjs (the real one is never used) fails when big.txt exceeds 600 lines; the branch and main each add one line to a 599-line big.txt.
AUDIT_STUB="$(cat <<'STUB'
const fs = require('fs')
if (process.env.GUARDS_ONLY !== 'audit') process.exit(3)
const n = fs.readFileSync('big.txt', 'utf8').split('\n').filter(Boolean).length
if (n > 600) { console.log('FAIL: audit: big.txt max-lines ' + (n - 600) + ' > baseline 0'); process.exit(1) }
console.log('PASS: audit')
STUB
)"

audit_fixture() { # <name> <main-side append 0|1>: both sides start from the same 599-line big.txt, each side adds one line at a different end
  local d
  d="$(setup "$1")"
  main_commit "$d" 0 g0.txt seed # clones the second checkout, in which main_commit cannot create scripts/ itself
  mkdir -p "$d/other/scripts"
  main_commit "$d" 0 scripts/guards.cjs "$AUDIT_STUB"
  main_commit "$d" 0 scripts/audit-baseline.json '{}'
  main_commit "$d" 0 big.txt "$(seq 1 599)"
  ( cd "$d/work" && git fetch -q origin && git merge -q --no-edit origin/main \
    && { echo head; cat big.txt; } > big.new && mv big.new big.txt && git add -A && git commit -qm "feat: branch line" \
    && git push -q origin feat/x ) >/dev/null 2>&1
  [ "$2" -eq 0 ] || main_commit "$d" 0 big.txt "$(seq 1 599; echo tail)"
  echo "$d"
}

D="$(audit_fixture audit-collision 1)"; run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -ne 0 ] && grep -qF 'FAIL: audit: big.txt max-lines 1 > baseline 0' "$D/out" \
  && ok "audit-collision: refused, the output names the file and the count over" || bad "audit-collision refusal (rc=$rc): $(tail -3 "$D/out")"
[ ! -s "$D/pushes" ] && ! grep -qE 'pr checks|pr merge' "$D/log" \
  && [ -z "$(git -C "$D/work" log --format=%s | grep 'chore: bump')" ] \
  && ok "audit-collision: no push, no CI poll, no merge call, no bump commit" || bad "audit-collision side effects: $(cat "$D/pushes")"

D="$(audit_fixture audit-clean 0)"; run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && [ "$(wc -l < "$D/pushes" | tr -d ' ')" -eq 1 ] && grep -q 'pr merge' "$D/log" \
  && ok "audit-collision: a clean merged tree still pushes once and merges" || bad "audit-collision clean tree (rc=$rc): $(tail -3 "$D/out")"
