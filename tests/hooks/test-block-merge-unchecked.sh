#!/usr/bin/env bash
# Regression test for hooks/block-merge-unchecked.sh (#74): matches `gh pr merge` AND
# `lead-merge.sh <pr>`, refuses open boxes / missing end marker, allows checked boxes and
# unrelated commands. Fake `gh` on PATH returns the PR body from $FAKE_BODY. Review freshness (#157): the fake gh also
# serves the PR head ($FAKE_HEAD) and the REST comments ($FAKE_COMMENTS); a bare `gh pr merge` needs the latest
# sha-bearing review marker to name that head (default fixture: a review on the head, so the older cases are unaffected).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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
# fenced examples (#202): a marker pair inside a fenced code block is not the acceptance block (the engine's rule, templates/pr-body-splice.cjs)
FX='```\n<!-- acceptance:start -->\n- [ ] an example box\n<!-- acceptance:end -->\n```\n'
FX4='````\n```\n<!-- acceptance:start -->\n- [ ] an example box\n<!-- acceptance:end -->\n```\n````\n'
FXT='~~~\n<!-- acceptance:start -->\n- [ ] an example box\n<!-- acceptance:end -->\n~~~\n'
FXU='```\nan example, never closed\n<!-- acceptance:start -->\n- [ ] an example box\n<!-- acceptance:end -->\n'
REAL_OK='<!-- acceptance:start -->\n- [x] a\n<!-- acceptance:end -->\n'
REAL_OPEN='<!-- acceptance:start -->\n- [x] a\n- [ ] b\n<!-- acceptance:end -->\n'
printf 'x\n%b%b' "$FX" "$REAL_OK" > "$T/fx-before-ok.md"
printf 'x\n%b%b' "$REAL_OK" "$FX" > "$T/fx-after-ok.md"
printf 'x\n%b%b' "$FX" "$REAL_OPEN" > "$T/fx-before-open.md"
printf 'x\n%b%b' "$REAL_OPEN" "$FX" > "$T/fx-after-open.md"
printf 'x\n%b%b%b' "$FX4" "$REAL_OK" "$FXT" > "$T/fx-long-tilde-ok.md"
printf 'x\n%b%b' "$FXU" "$REAL_OK" > "$T/fx-unclosed-before.md"
printf 'x\n%b%b' "$REAL_OK" "$FXU" > "$T/fx-unclosed-after.md"
printf 'x\n%b' "$FX" > "$T/fx-only.md"
# ambiguous lines (#202): the shell reads fences and markers byte-wise where the engine trims Unicode whitespace; a body with a
# marker look-alike, or a fence/marker line holding a byte outside printable ASCII, is refused (fail-closed), never waved through
AS='<!-- acceptance:start -->'; AE='<!-- acceptance:end -->'; NB=$'\xc2\xa0'; FF=$'\f'
mkb() { local f="$1"; shift; printf '%s\n' "$@" > "$T/$f"; }
mkb amb-r1-ff.md      "$AS" '- [x] <!-- ac:1 --> a' "$AE" '```' x '```'"$FF" "$AS" '- [x] <!-- ac:1 --> a' '- [ ] <!-- ac:2 --> open' "$AE"
mkb amb-r1-nbsp.md    "$AS" '- [x] <!-- ac:1 --> a' "$AE" '```' x '```'"$NB" "$AS" '- [x] <!-- ac:1 --> a' '- [ ] <!-- ac:2 --> open' "$AE"
mkb amb-r2-nbsp-indent.md "$AS" '- [x] <!-- ac:1 --> a' '- [ ] <!-- ac:2 --> open' "$AE" "$NB"'```' "$AS" "$AE" '```'
mkb amb-r3-nospace.md "$AS" '- [ ] <!-- ac:1 --> open' "$AE" '<!--acceptance:start-->' "$AE"
mkb amb-r3-twospace.md "$AS" '- [ ] <!-- ac:1 --> open' "$AE" '<!--  acceptance:start -->' "$AE"
mkb amb-r5-ff-marker.md "$AS" '- [ ] <!-- ac:1 --> open' "$AE" "$AS$FF" "$AE"
mkb amb-r6-two-pairs.md "$AS" '- [ ] <!-- ac:1 --> open' "$AE" "$AS" "$AE"
mkb amb-three-pairs.md  "$AS" '- [ ] <!-- ac:1 --> open' "$AE" "$AS" '- [x] a' "$AE" "$AS" '- [x] b' "$AE"
mkb amb-unicode-ok.md   'Résumé: ✅ le correctif est livré 🚀' "$AS" '- [x] <!-- ac:1 --> vérifié, ça marche — ✅' "$AE" 'fin'
mkb amb-fenced-lookalike-ok.md '```' '<!--acceptance:start-->' '<!--  acceptance:end -->' '```' "$AS" '- [x] a' "$AE"
mkb amb-empty-block.md  "$AS" "$AE"
mkb amb-fenced-box-in-block.md "$AS" '- [x] a' '```' '- [ ] an example box' '```' "$AE"
# F1: a start marker only indented or preceded by text still opens a pair (the reading before #202); F3: ordinary lines that mention the markers
EMD=$'\xe2\x80\x94'; ARW=$'\xe2\x86\x92'
mkb amb-f1-indented.md "$AS" '- [x] a' "$AE" " $AS" '- [ ] open' "$AE" "$AS" '- [x] a' "$AE"
mkb amb-f1-text.md     "x $AS" '- [ ] open' "$AE" "$AS" '- [x] a' "$AE"
mkb amb-f1-empty-after.md " $AS" '- [ ] open' "$AE" "$AS" "$AE"
mkb amb-f1-ticked.md   " $AS" '- [x] a' "$AE" "$AS" '- [x] a' "$AE"
mkb amb-f3-prose.md    "$AS and $AE delimit it" "$AS" '- [x] a' "$AE"
mkb amb-f3-dash.md     "- the gate reads \`acceptance:start\` $EMD as the engine" "$AS" '- [x] <!-- ac:1 --> `grep -c "acceptance:" f` '"$ARW"' 3' "$AE"
mkb amb-f3-accent-fence.md "$AS" '- [x] a' "$AE" $'```swift \xc3\xa9' "$AS" '- [ ] example' "$AE" '```'
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
# fenced examples (#202): the hook and lead-merge.sh read the same block as the engine
t "fenced-example: example before a ticked real block -> allow"       0 fx-before-ok.md    "gh pr merge 5 --merge"
t "fenced-example: example after a ticked real block -> allow"        0 fx-after-ok.md     "gh pr merge 5 --merge"
t "fenced-example: example before an open real block -> block"        2 fx-before-open.md  "gh pr merge 5 --merge"
t "fenced-example: example after an open real block -> block"         2 fx-after-open.md   "gh pr merge 5 --merge"
t "fenced-example: ~~~ and a 4-backtick fence around a 3-backtick one -> allow" 0 fx-long-tilde-ok.md "gh pr merge 5 --merge"
t "fenced-example: fence never closed after the real block -> allow (the real pair comes first)" 0 fx-unclosed-after.md "gh pr merge 5 --merge"
t "fenced-example: fence never closed before the real block -> block (it hides the block)" 2 fx-unclosed-before.md "gh pr merge 5 --merge" c-fresh.json head "BLOCKED by pr-acceptance gate"
t "fenced-example: only a fenced pair, no real block -> block"        2 fx-only.md         "gh pr merge 5 --merge" c-fresh.json head "BLOCKED by pr-acceptance gate"
t "fenced-example: lead-merge.sh, example before a ticked real block -> allow" 0 fx-before-ok.md "bash scripts/lead-merge.sh 5"
# ambiguous lines (#202)
t "fenced-example: closing fence followed by a form feed -> block (R1)"       2 amb-r1-ff.md       "gh pr merge 5 --merge"
t "fenced-example: closing fence followed by a no-break space -> block (R1)"  2 amb-r1-nbsp.md     "gh pr merge 5 --merge"
t "fenced-example: opening fence indented by a no-break space -> block (R2)"  2 amb-r2-nbsp-indent.md "gh pr merge 5 --merge"
t "fenced-example: marker look-alike without spaces -> block (R3)"            2 amb-r3-nospace.md  "gh pr merge 5 --merge"
t "fenced-example: marker look-alike with two spaces -> block (R3)"           2 amb-r3-twospace.md "gh pr merge 5 --merge"
t "fenced-example: start marker followed by a form feed -> block (R5)"        2 amb-r5-ff-marker.md "gh pr merge 5 --merge"
t "fenced-example: two exact pairs, first open, last empty -> block (R6)"     2 amb-r6-two-pairs.md "gh pr merge 5 --merge"
t "fenced-example: three exact pairs, first open -> block"                    2 amb-three-pairs.md "gh pr merge 5 --merge"
t "fenced-example: accents and emoji in an ordinary body -> allow"            0 amb-unicode-ok.md  "gh pr merge 5 --merge"
t "fenced-example: fenced look-alikes before a ticked real block -> allow"    0 amb-fenced-lookalike-ok.md "gh pr merge 5 --merge"
t "fenced-example: empty block is accepted (behaviour of the base, I1)"       0 amb-empty-block.md "gh pr merge 5 --merge"
t "fenced-example: an unticked box inside a fence inside the block -> block (I4)" 2 amb-fenced-box-in-block.md "gh pr merge 5 --merge"
t "F1: an indented start marker holds an open box, a later pair is ticked -> block"      2 amb-f1-indented.md "gh pr merge 5 --merge"
t "F1: a start marker preceded by text holds an open box, a later pair is ticked -> block" 2 amb-f1-text.md "gh pr merge 5 --merge"
t "F1: an indented start marker holds an open box, a later pair is empty -> block"       2 amb-f1-empty-after.md "gh pr merge 5 --merge"
t "F1: an indented start marker, everything ticked -> allow"                              0 amb-f1-ticked.md "gh pr merge 5 --merge"
t "F3: a prose line mentioning both markers -> allow"                                     0 amb-f3-prose.md "gh pr merge 5 --merge"
t "F3: an em dash and an arrow next to acceptance: in and outside the block -> allow"    0 amb-f3-dash.md "gh pr merge 5 --merge"
t "F3: a fence whose info string carries an accent hides the open pair after it -> allow" 0 amb-f3-accent-fence.md "gh pr merge 5 --merge"
echo "[block-merge-unchecked test] passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
