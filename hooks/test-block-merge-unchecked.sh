#!/usr/bin/env bash
# Regression test for hooks/block-merge-unchecked.sh (#74): matches `gh pr merge` AND
# `lead-merge.sh <pr>`, refuses open boxes / missing end marker, allows checked boxes and
# unrelated commands. Fake `gh` on PATH returns the PR body from $FAKE_BODY. Review freshness (#157): the fake gh also
# serves the PR head ($FAKE_HEAD) and the REST comments ($FAKE_COMMENTS); a bare `gh pr merge` needs the latest
# sha-bearing review marker to name that head (default fixture: a review on the head, so the older cases are unaffected).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/hooks/block-merge-unchecked.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }
T="$(mktemp -d "${TMPDIR:-/tmp}/bmu-test.XXXXXX")"
mkdir -p "$T/bin"
# fake gh: the PR head (--json headRefOid) from $FAKE_HEAD, the PR number (--json number), the REST comments from $FAKE_COMMENTS, else the body
cat > "$T/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *headRefOid*) cat "$FAKE_HEAD" ;;
  *"--json number"*) echo 5 ;;
  */comments*) cat "$FAKE_COMMENTS" ;;
  *) cat "$FAKE_BODY" ;;
esac
FAKE
chmod +x "$T/bin/gh"
H1=1111111111111111111111111111111111111111; H0=0000000000000000000000000000000000000000
printf '%s\n' "$H1" > "$T/head"; : > "$T/nohead"
printf '[{"id":1,"body":"<!-- pipeline-review-round pr=5 sha=%s -->\\nLGTM\\nproven"}]\n' "$H1" > "$T/c-fresh.json"
printf '[{"id":1,"body":"<!-- pipeline-review-round pr=5 sha=%s -->\\nLGTM\\nproven"}]\n' "$H0" > "$T/c-old.json"
printf '[]\n' > "$T/c-none.json"
printf '[{"id":1,"body":"<!-- pipeline-review-round pr=5 -->\\nLGTM\\nno sha"}]\n' > "$T/c-bare.json"
printf 'x\n<!-- acceptance:start -->\n- [x] a\n<!-- acceptance:end -->\n' > "$T/ok.md"
printf 'x\n<!-- acceptance:start -->\n- [x] <!-- ac:1 --> a\n<!-- acceptance:end -->\n' > "$T/ok-id.md"
printf 'x\n<!-- acceptance:start -->\n- [x] <!-- ac:1 --> a\n- [ ] <!-- ac:2 --> b\n<!-- acceptance:end -->\n' > "$T/open-id.md"
printf 'x\n<!-- acceptance:start -->\n- [x] a\n- [ ] b\n<!-- acceptance:end -->\n' > "$T/open.md"
printf 'x\n<!-- acceptance:start -->\n- [x] a\n' > "$T/noend.md"
printf 'x\n- [ ] no acceptance section at all\n' > "$T/none.md"
PASS=0; FAIL=0
t() { # name expected-rc body cmd [comments-file (default: a review on the head)] [head-file] [expected-output-substring...]
  local out rc name="$1" want="$2" body="$3" cmd="$4" comments="${5:-c-fresh.json}" headf="${6:-head}" sub
  out="$(jq -n --arg c "$cmd" '{tool_input:{command:$c}}' | PATH="$T/bin:$PATH" FAKE_BODY="$T/$body" FAKE_COMMENTS="$T/$comments" FAKE_HEAD="$T/$headf" bash "$HOOK" 2>&1)"; rc=$?
  for sub in "${@:7}"; do case "$out" in *"$sub"*) ;; *) rc="missing '$sub'" ;; esac; done
  if [ "$rc" = "$want" ]; then echo "PASS: $name"; PASS=$((PASS+1)); else echo "FAIL: $name (rc=$rc want $want): $out"; FAIL=$((FAIL+1)); fi
}
t "gh pr merge, open box -> block"        2 open.md  "gh pr merge 5 --merge"
t "gh pr merge, all checked -> allow"     0 ok.md    "gh pr merge 5 --merge"
t "lead-merge.sh, open box -> block"      2 open.md  "bash scripts/lead-merge.sh 5"
t "lead-merge.sh -R, open box -> block"   2 open.md  "scripts/lead-merge.sh 5 -R o/r"
t "lead-merge.sh, all checked -> allow"   0 ok.md    "bash scripts/lead-merge.sh 5"
t "lead-merge.sh --tick-from-review, open box -> allow (script re-checks)" 0 open.md "bash scripts/lead-merge.sh 5 -R o/r --tick-from-review"
t "tick flag on another command does not unblock gh pr merge" 2 open.md "bash scripts/lead-merge.sh 5 --tick-from-review; gh pr merge 5"
t "id-format: an open id box blocks gh pr merge" 2 open-id.md "gh pr merge 5 --merge"
t "id-format: all id boxes checked allows gh pr merge" 0 ok-id.md "gh pr merge 5 --merge"
t "missing end marker -> block"           2 noend.md "gh pr merge 5"
t "no acceptance section -> fail-open"    0 none.md  "gh pr merge 5"
t "test-lead-merge.sh is not a merge"     0 open.md  "bash scripts/test-lead-merge.sh"
t "grep naming lead-merge.sh is not a merge" 0 open.md "grep -n permissions scripts/lead-merge.sh"
t "cd then lead-merge.sh, open box -> block" 2 open.md "cd wt && bash scripts/lead-merge.sh 5"
t "unrelated command -> allow"            0 open.md  "ls"
# review freshness (#157): a bare `gh pr merge` needs the latest sha-bearing review marker to name the PR head
t "review-stale: gh pr merge, review on the head -> allow"          0 ok.md "gh pr merge 5 --merge" c-fresh.json
t "review-stale: gh pr merge, review on an older sha -> block, names both shas" 2 ok.md "gh pr merge 5 --merge" c-old.json head "$H0" "$H1"
t "review-stale: gh pr merge, no review marker -> block"            2 ok.md "gh pr merge 5 --merge" c-none.json head "no review marker"
t "review-stale: gh pr merge, bare marker without a sha -> block"   2 ok.md "gh pr merge 5 --merge" c-bare.json head "no review marker"
t "review-stale: gh pr merge without a number resolves the PR -> block" 2 ok.md "gh pr merge --merge" c-old.json head "$H0" "$H1"
t "review-stale: head unreadable -> fail-open (like the body)"      0 ok.md "gh pr merge 5 --merge" c-old.json nohead
t "review-stale: lead-merge.sh is left to the script's own check -> allow" 0 ok.md "bash scripts/lead-merge.sh 5" c-old.json
echo "[block-merge-unchecked test] passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
