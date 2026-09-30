#!/usr/bin/env bash
# Regression test for hooks/block-merge-unchecked.sh (#74): matches `gh pr merge` AND
# `lead-merge.sh <pr>`, refuses open boxes / missing end marker, allows checked boxes and
# unrelated commands. Fake `gh` on PATH returns the PR body from $FAKE_BODY.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/hooks/block-merge-unchecked.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }
T="$(mktemp -d "${TMPDIR:-/tmp}/bmu-test.XXXXXX")"
mkdir -p "$T/bin"
printf '#!/usr/bin/env bash\ncat "$FAKE_BODY"\n' > "$T/bin/gh"; chmod +x "$T/bin/gh"
printf 'x\n<!-- acceptance:start -->\n- [x] a\n<!-- acceptance:end -->\n' > "$T/ok.md"
printf 'x\n<!-- acceptance:start -->\n- [x] a\n- [ ] b\n<!-- acceptance:end -->\n' > "$T/open.md"
printf 'x\n<!-- acceptance:start -->\n- [x] a\n' > "$T/noend.md"
printf 'x\n- [ ] no acceptance section at all\n' > "$T/none.md"
PASS=0; FAIL=0
t() { # name expected-rc body cmd
  local out rc
  out="$(jq -n --arg c "$4" '{tool_input:{command:$c}}' | PATH="$T/bin:$PATH" FAKE_BODY="$T/$3" bash "$HOOK" 2>&1)"; rc=$?
  if [ "$rc" -eq "$2" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (rc=$rc want $2): $out"; FAIL=$((FAIL+1)); fi
}
t "gh pr merge, open box -> block"        2 open.md  "gh pr merge 5 --merge"
t "gh pr merge, all checked -> allow"     0 ok.md    "gh pr merge 5 --merge"
t "lead-merge.sh, open box -> block"      2 open.md  "bash scripts/lead-merge.sh 5"
t "lead-merge.sh -R, open box -> block"   2 open.md  "scripts/lead-merge.sh 5 -R o/r"
t "lead-merge.sh, all checked -> allow"   0 ok.md    "bash scripts/lead-merge.sh 5"
t "missing end marker -> block"           2 noend.md "gh pr merge 5"
t "no acceptance section -> fail-open"    0 none.md  "gh pr merge 5"
t "test-lead-merge.sh is not a merge"     0 open.md  "bash scripts/test-lead-merge.sh"
t "unrelated command -> allow"            0 open.md  "ls"
echo "[block-merge-unchecked test] passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
