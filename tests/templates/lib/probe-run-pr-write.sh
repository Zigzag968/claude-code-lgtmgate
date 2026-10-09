#!/usr/bin/env bash
# pr-write.sh end to end, case (k) (sourced by tests/templates/test-probe-run.sh, never executed).
# (k) pr-write.sh end to end (#85): a stub gh first on PATH logs every call and serves per-op state. Every op must
# READ before it writes, skip an already-applied write, and write nothing after a failed read. No network.
PW="$SCRIPT_DIR/pr-write.sh"
if command -v jq >/dev/null 2>&1; then
  PWD_="$WORK/pw"; mkdir -p "$PWD_/bin" "$PWD_/wt"
  GHLOG="$PWD_/gh.log"
  cat > "$PWD_/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
echo "$*" >> "$GHLOG"
case "$*" in
  *"pr edit"*)
    f=""; prev=""
    for a in "$@"; do [ "$prev" = "--body-file" ] && f="$a"; prev="$a"; done
    if [ -n "${GH_EDIT_TRUNCATE:-}" ] && [ ! -f "$GH_BODY_FILE.trunc" ]; then
      : > "$GH_BODY_FILE.trunc"; printf 'x\n' > "$GH_BODY_FILE"
    else
      cp "$f" "$GH_BODY_FILE"
    fi
    exit 0 ;;
  *"pr comment"*|*"issue comment"*|*"project item-edit"*|*minimizeComment*) exit 0 ;;
esac
[ -n "${GH_READ_FAIL:-}" ] && exit 1
[ -n "${GH_READ_ERR:-}" ] && { printf '%s\n' "$GH_READ_ERR" >&2; exit 1; }
case "$*" in
  *"pr view"*"--json body"*)
    cat "$GH_BODY_FILE"
    if [ -n "${GH_MUTATE_AFTER_READ:-}" ] && [ ! -f "$GH_BODY_FILE.mut" ]; then : > "$GH_BODY_FILE.mut"; printf 'edited by someone else\n' >> "$GH_BODY_FILE"; fi ;;
  *"api "*"/comments"*) printf '%s\n' "${GH_PAGINATED:-}" ;;
  *"--json comments"*) d='{"comments":[]}'; printf '%s\n' "${GH_COMMENTS:-$d}" ;;
  *"node(id"*) printf '%s\n' "${GH_MINIMIZED:-false}" ;;
  *projectItems*) printf '%s\n' "${GH_STATUS:-}" ;;
  *) exit 1 ;;
esac
GHEOF
  chmod +x "$PWD_/bin/gh"

  # run_pw <op> args... : runs pr-write.sh against the stub, fresh log; prints the single stdout line
  run_pw() {
    : > "$GHLOG"
    PATH="$PWD_/bin:$PATH" GHLOG="$GHLOG" GH_BODY_FILE="$PWD_/body.md" bash "$PW" "$@" --wt "$PWD_/wt" --repo o/r
  }
  first_line() { awk -v p="$1" 'index($0, p) { print NR; exit }' "$GHLOG"; }
  # read_first <read pattern> <write pattern>: both calls logged, the read strictly before the write
  read_first() {
    local r w
    r="$(first_line "$1")"; w="$(first_line "$2")"
    [ -n "$r" ] && [ -n "$w" ] && [ "$r" -lt "$w" ] && echo 1 || echo 0
  }
  no_call() { [ -z "$(first_line "$1")" ] && echo 1 || echo 0; }
  res() { printf '%s' "$1" | jq -r '[.result, (.reason // "-")] | join("/")'; }
  one_line() { [ "$(printf '%s\n' "$1" | wc -l | tr -d ' ')" = "1" ] && echo 1 || echo 0; }

  # issue-comment and pr-comment
  for kind in issue pr; do
    if [ "$kind" = "issue" ]; then FLAG="--number"; else FLAG="--pr"; fi
    MK='<!-- pipeline-reviewer-window pr=7 -->'
    OUT="$(GH_COMMENTS='{"comments":[{"body":"hello"}]}' run_pw "$kind-comment" "$FLAG" 501 --marker "$MK" --body "$MK
text")"
    ok=0; [ "$(res "$OUT")" = "written/-" ] && [ "$(one_line "$OUT")" = 1 ] && [ "$(read_first "$kind view" "$kind comment")" = 1 ] && ok=1
    check "pr-write.sh $kind-comment: read-before-write (view, then comment)" "$ok"
    OUT="$(GH_COMMENTS="{\"comments\":[{\"body\":\"$MK\\ntext\"}]}" run_pw "$kind-comment" "$FLAG" 501 --marker "$MK" --body "$MK
text")"
    ok=0; [ "$(res "$OUT")" = "skipped/marker-present" ] && [ "$(no_call "$kind comment")" = 1 ] && ok=1
    check "pr-write.sh $kind-comment: skips when already applied (marker present, no comment call)" "$ok"
    OUT="$(GH_READ_FAIL=1 run_pw "$kind-comment" "$FLAG" 501 --marker "$MK" --body "$MK
text")"
    ok=0; [ "$(res "$OUT")" = "failed/read-failed" ] && [ "$(no_call "$kind comment")" = 1 ] && ok=1
    check "pr-write.sh $kind-comment: read failure writes nothing" "$ok"
  done

  # [151] marker lookup past the 100-comment cap: the view serves 100 marker-less comments, REST serves 101
  C100="$(node -e 'console.log(JSON.stringify({comments:Array.from({length:100},(_, i)=>({body:"c"+i}))}))')"
  PAG="$(node -e 'const a=Array.from({length:100},(_, i)=>({body:"c"+i}));a.push({body:process.argv[1]+"\ntext"});a.forEach(o=>console.log(JSON.stringify(o)))' "$MK")"
  OUT="$(GH_COMMENTS="$C100" GH_PAGINATED="$PAG" run_pw issue-comment --number 501 --marker "$MK" --body "$MK
text")"
  ok=0; [ "$(res "$OUT")" = "skipped/marker-present" ] && [ "$(no_call 'issue comment')" = 1 ] && [ -n "$(first_line 'api repos/o/r/issues/501/comments')" ] && ok=1
  check "[151] pr-write.sh issue-comment: marker only in the 101st comment is found (paginated), no comment call" "$ok"
  OUT="$(GH_COMMENTS="$C100" GH_PAGINATED="$PAG" run_pw pr-comment --pr 501 --marker "$MK" --body "$MK
text")"
  ok=0; [ "$(res "$OUT")" = "skipped/marker-present" ] && [ "$(no_call 'pr comment')" = 1 ] && [ -n "$(first_line 'api repos/o/r/issues/501/comments')" ] && ok=1
  check "[151] pr-write.sh pr-comment: marker only in the 101st comment is found (paginated), no comment call" "$ok"

  # minimize
  OUT="$(GH_MINIMIZED=false run_pw minimize --id IC_1)"
  ok=0; [ "$(res "$OUT")" = "written/-" ] && [ "$(read_first 'node(id' 'minimizeComment')" = 1 ] && ok=1
  check "pr-write.sh minimize: read-before-write (isMinimized read, then the mutation)" "$ok"
  OUT="$(GH_MINIMIZED=true run_pw minimize --id IC_1)"
  ok=0; [ "$(res "$OUT")" = "skipped/already-minimized" ] && [ "$(no_call minimizeComment)" = 1 ] && ok=1
  check "pr-write.sh minimize: skips when already applied (already minimized)" "$ok"
  OUT="$(GH_READ_FAIL=1 run_pw minimize --id IC_1)"
  ok=0; [ "$(res "$OUT")" = "failed/read-failed" ] && [ "$(no_call minimizeComment)" = 1 ] && ok=1
  check "pr-write.sh minimize: read failure writes nothing" "$ok"

  # status
  ST_OLD='{"data":{"repository":{"issue":{"projectItems":{"nodes":[{"id":"PVTI_1","project":{"number":5},"fieldValues":{"nodes":[{},{"optionId":"opt-old","field":{"id":"F1"}}]}}]}}}}}'
  ST_SET='{"data":{"repository":{"issue":{"projectItems":{"nodes":[{"id":"PVTI_1","project":{"number":5},"fieldValues":{"nodes":[{"optionId":"opt-new","field":{"id":"F1"}}]}}]}}}}}'
  ST_NONE='{"data":{"repository":{"issue":{"projectItems":{"nodes":[]}}}}}'
  SARGS="--issue 85 --project-number 5 --project-id P1 --field-id F1 --option-id opt-new"
  OUT="$(GH_STATUS="$ST_OLD" run_pw status $SARGS)"
  ok=0; [ "$(res "$OUT")" = "written/-" ] && [ "$(read_first projectItems 'project item-edit')" = 1 ] && grep -q -- '--id PVTI_1 --field-id F1 --project-id P1 --single-select-option-id opt-new' "$GHLOG" && ok=1
  check "pr-write.sh status: read-before-write (item read, then item-edit with the read id)" "$ok"
  OUT="$(GH_STATUS="$ST_SET" run_pw status $SARGS)"
  ok=0; [ "$(res "$OUT")" = "skipped/already-set" ] && [ "$(no_call 'project item-edit')" = 1 ] && ok=1
  check "pr-write.sh status: skips when already applied (option already set)" "$ok"
  OUT="$(GH_STATUS="$ST_NONE" run_pw status $SARGS)"
  ok=0; [ "$(res "$OUT")" = "skipped/not-on-project" ] && [ "$(no_call 'project item-edit')" = 1 ] && ok=1
  check "pr-write.sh status: issue not on the project -> no edit with an empty id" "$ok"
  OUT="$(GH_READ_FAIL=1 run_pw status $SARGS)"
  ok=0; [ "$(res "$OUT")" = "failed/read-failed" ] && [ "$(no_call 'project item-edit')" = 1 ] && ok=1
  check "pr-write.sh status: read failure writes nothing" "$ok"

  # body-splice
  PRE_BODY='Closes #1

## Acceptance checklist
<!-- acceptance:start -->
- [ ] old
<!-- acceptance:end -->
<!-- decision-log:start -->
<!-- decision-log:end -->'
  DL='<!-- decision-log:start -->
## Decision log
- round 0 — LGTM
<!-- decision-log:end -->'
  printf '%s\n' "$PRE_BODY" > "$PWD_/body.md"
  OUT="$(run_pw body-splice --pr 9 --mode decision-log --text "$DL")"
  ok=0; [ "$(res "$OUT")" = "written/-" ] && [ "$(read_first 'pr view' 'pr edit')" = 1 ] && grep -q -- '- round 0 — LGTM' "$PWD_/body.md" && ok=1
  check "pr-write.sh body-splice: read-before-write (body read, spliced, then edit)" "$ok"
  OUT="$(run_pw body-splice --pr 9 --mode decision-log --text "$DL")"
  ok=0; [ "$(res "$OUT")" = "skipped/unchanged" ] && [ "$(no_call 'pr edit')" = 1 ] && ok=1
  check "pr-write.sh body-splice: skips when already applied (spliced body unchanged)" "$ok"
  OUT="$(run_pw body-splice --pr 9 --mode acceptance --text '- [ ] new one
- [ ] new two')"
  ok=0; [ "$(res "$OUT")" = "written/-" ] && grep -q -- '- \[ \] new two' "$PWD_/body.md" && ! grep -q -- '- \[ \] old' "$PWD_/body.md" && ok=1
  check "pr-write.sh body-splice: acceptance mode replaces the block contents" "$ok"
  printf 'no markers here, long enough body text to matter\n' > "$PWD_/body.md"
  OUT="$(run_pw body-splice --pr 9 --mode acceptance --text '- [ ] x')"
  ok=0; [ "$(res "$OUT")" = "failed/no-markers" ] && [ "$(no_call 'pr edit')" = 1 ] && ok=1
  check "pr-write.sh body-splice: acceptance markers absent -> failed, never appends, no edit" "$ok"
  OUT="$(GH_READ_FAIL=1 run_pw body-splice --pr 9 --mode decision-log --text "$DL")"
  ok=0; [ "$(res "$OUT")" = "failed/read-failed" ] && [ "$(no_call 'pr edit')" = 1 ] && ok=1
  check "pr-write.sh body-splice: read failure writes nothing" "$ok"
  printf '%s\n' "$PRE_BODY" > "$PWD_/body.md"
  OUT="$(GH_EDIT_TRUNCATE=1 run_pw body-splice --pr 9 --mode decision-log --text "$DL")"
  ok=0; [ "$(res "$OUT")" = "failed/guard-failed-restored" ] && [ "$(cat "$PWD_/body.md")" = "$PRE_BODY" ] && ok=1
  check "pr-write.sh body-splice: a lossy write trips the guard and the pre body is restored" "$ok"
  printf '%s\n' "$PRE_BODY" > "$PWD_/body.md"
  OUT="$(run_pw body-splice --pr 9 --mode decision-log --text "$DL" --expect-digest 000000000000)"
  ok=0; [ "$(res "$OUT")" = "failed/stale-read" ] && [ "$(no_call 'pr edit')" = 1 ] && [ "$(cat "$PWD_/body.md")" = "$PRE_BODY" ] && ok=1
  check "[151] pr-write.sh body-splice: a stale --expect-digest fails stale-read, no edit" "$ok"
  printf '%s\n' "$PRE_BODY" > "$PWD_/body.md"
  OUT="$(GH_MUTATE_AFTER_READ=1 run_pw body-splice --pr 9 --mode decision-log --text "$DL")"
  ok=0; [ "$(res "$OUT")" = "failed/stale-read" ] && [ "$(no_call 'pr edit')" = 1 ] && grep -q 'edited by someone else' "$PWD_/body.md" && ok=1
  check "[151] pr-write.sh body-splice: body changed between the first read and the edit fails stale-read, no edit" "$ok"

  # body-splice --mode tick (#183): the block re-spliced from the rendered checklist, boxes set by id
  TK_TXT='- [ ] <!-- ac:1 --> first
- [ ] <!-- ac:2 --> [human-gate] second
- [ ] <!-- ac:3 --> third'
  tk_body() { printf 'Closes #1\n\n## What this ships\n- a summary line long enough that rewording two boxes stays far under the ten percent guard\n- another summary line of the same kind, so the body is not only the checklist\n\n## Acceptance checklist\n<!-- acceptance:start -->\n%s\n<!-- acceptance:end -->\n<!-- decision-log:start -->\n<!-- decision-log:end -->\n' "$1" > "$PWD_/body.md"; }
  tk_body '- [ ] <!-- ac:1 --> first, stale wording
- [ ] <!-- ac:2 --> [human-gate] second
- [ ] <!-- ac:3 --> third, stale wording'
  OUT="$(run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1,3 --keep 2)"
  ok=0; [ "$(res "$OUT")" = "written/-" ] && [ "$(read_first 'pr view' 'pr edit')" = 1 ] \
    && grep -qxF -- '- [x] <!-- ac:1 --> first' "$PWD_/body.md" && grep -qxF -- '- [ ] <!-- ac:2 --> [human-gate] second' "$PWD_/body.md" \
    && grep -qxF -- '- [x] <!-- ac:3 --> third' "$PWD_/body.md" && ! grep -q 'stale wording' "$PWD_/body.md" && ok=1
  check "pr-write.sh body-splice: tick ticks the ids 1,3, leaves 2 open, restores the canonical text" "$ok"
  tk_body '- [ ] <!-- ac:1 --> first
- [x] <!-- ac:2 --> [human-gate] second
- [ ] <!-- ac:3 --> third'
  OUT="$(run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1,3 --keep 2,3)"
  ok=0; [ "$(res "$OUT")" = "written/-" ] \
    && grep -qxF -- '- [x] <!-- ac:1 --> first' "$PWD_/body.md" && grep -qxF -- '- [x] <!-- ac:2 --> [human-gate] second' "$PWD_/body.md" \
    && grep -qxF -- '- [ ] <!-- ac:3 --> third' "$PWD_/body.md" && ok=1
  check "pr-write.sh body-splice: tick keeps the state of a --keep id from the body ([x] stays, [ ] stays even when listed in --ids)" "$ok"
  tk_body '- [x] <!-- ac:1 --> first
- [ ] <!-- ac:2 --> [human-gate] second
- [ ] <!-- ac:3 --> third'
  OUT="$(run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 3 --keep '')"
  ok=0; [ "$(res "$OUT")" = "written/-" ] \
    && grep -qxF -- '- [ ] <!-- ac:1 --> first' "$PWD_/body.md" && grep -qxF -- '- [x] <!-- ac:3 --> third' "$PWD_/body.md" && ok=1
  check "pr-write.sh body-splice: tick reopens a stale [x] of an id in neither list" "$ok"
  OUT="$(run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 3 --keep '')"
  ok=0; [ "$(res "$OUT")" = "skipped/unchanged" ] && [ "$(no_call 'pr edit')" = 1 ] && ok=1
  check "[183] pr-write.sh tick that changes nothing: skipped/unchanged, no edit" "$ok"
  printf 'no markers here, long enough body text to matter\n' > "$PWD_/body.md"
  OUT="$(run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1 --keep 2)"
  ok=0; [ "$(res "$OUT")" = "failed/no-markers" ] && [ "$(no_call 'pr edit')" = 1 ] && ok=1
  check "pr-write.sh body-splice: tick with the markers absent -> failed/no-markers, never appends, no edit" "$ok"
  OUT="$(run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1,x --keep 2)"
  ok=0; [ "$(res "$OUT")" = "failed/bad-args" ] && [ "$(no_call 'pr view')" = 1 ] && ok=1
  check "[183] pr-write.sh tick with a non-digit id: failed/bad-args, nothing read" "$ok"
  # [183] review round: a line Nick added to the block survives, a fenced example is never the block, CRLF is kept
  R2L='- [ ] fixture `fixtures/incidents/9-*.json` present, replayed red on the base and green on the branch'
  tk_body "- [ ] <!-- ac:1 --> first
- [ ] <!-- ac:2 --> [human-gate] second
- [ ] <!-- ac:3 --> third
$R2L"
  OUT="$(run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1,3 --keep 2)"
  ok=0; [ "$(res "$OUT")" = "written/-" ] && grep -qxF -- '- [x] <!-- ac:3 --> third' "$PWD_/body.md" && grep -qxF -- "$R2L" "$PWD_/body.md" \
    && [ "$(awk -v l="$R2L" '$0 == l { n++ } END { print n + 0 }' "$PWD_/body.md")" = 1 ] \
    && [ "$(grep -n -F -- "$R2L" "$PWD_/body.md" | cut -d: -f1)" -gt "$(grep -n -F -- '- [x] <!-- ac:3 --> third' "$PWD_/body.md" | cut -d: -f1)" ] && ok=1
  check "[183] pr-write.sh tick keeps a box line without an id: once, open, after the rendered lines" "$ok"
  OUT="$(run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1,3 --keep 2)"
  ok=0; [ "$(res "$OUT")" = "skipped/unchanged" ] && [ "$(no_call 'pr edit')" = 1 ] && ok=1
  check "[183] pr-write.sh tick again over the kept line: skipped/unchanged, no edit" "$ok"
  # [tick-ids] (#257): --mode tick-ids ticks the listed ids of a 14-box body, no text on the command line
  ti_box() { # <id> <mark> : the line of box <id>, [human-gate] on box 5
    local g=""; [ "$1" = 5 ] && g="[human-gate] "
    printf -- '- [%s] <!-- ac:%s --> %sbox number %s `cmd %s` prints `%s`' "$2" "$1" "$g" "$1" "$1" "$1"
  }
  ti_block() { # <space-separated ids ticked> : the 14 box lines
    local i m out=""
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
      m=" "; case " $1 " in *" $i "*) m="x" ;; esac
      out="$out$(ti_box "$i" "$m")"$'\n'
    done
    printf '%s' "${out%$'\n'}"
  }
  tk_body "$(ti_block '1 3 14')"; cp "$PWD_/body.md" "$PWD_/ti-expected.md"
  tk_body "$(ti_block '')"
  OUT="$(run_pw body-splice --pr 9 --mode tick-ids --ids 1,3,14)"
  ok=0; [ "$(res "$OUT")" = "written/-" ] && [ "$(grep -c -- '^- \[x\]' "$PWD_/body.md")" = 3 ] && [ "$(grep -c -- '^- \[ \]' "$PWD_/body.md")" = 11 ] \
    && grep -qF -- '- [x] <!-- ac:1 --> ' "$PWD_/body.md" && grep -qF -- '- [x] <!-- ac:3 --> ' "$PWD_/body.md" && grep -qF -- '- [x] <!-- ac:14 --> ' "$PWD_/body.md" && ok=1
  check "[tick-ids] ids 1,3,14 of a 14-box body become [x], the other 11 stay open" "$ok"
  ok=0; cmp -s "$PWD_/body.md" "$PWD_/ti-expected.md" && ok=1
  check "[tick-ids] every other byte of the body is unchanged (the body equals the hand-built expected one)" "$ok"
  ok=0; [ "$(res "$OUT")" = "written/-" ] && [ "$(one_line "$OUT")" = 1 ] && ok=1
  check "[tick-ids] the output is the single line written/- as in text mode" "$ok"
  tk_body "$(ti_block '')"; cp "$PWD_/body.md" "$PWD_/ti-before.md"
  OUT="$(run_pw body-splice --pr 9 --mode tick-ids --ids 2,15)"
  ok=0; [ "$(res "$OUT")" = "failed/unknown-id" ] && cmp -s "$PWD_/body.md" "$PWD_/ti-before.md" && [ "$(no_call 'pr edit')" = 1 ] && ok=1
  check "[tick-ids] an unknown id (15) is refused: failed/unknown-id, body untouched, no edit (the valid id 2 is not ticked either)" "$ok"
  OUT="$(run_pw body-splice --pr 9 --mode tick-ids --ids 4,5)"
  ok=0; [ "$(res "$OUT")" = "failed/human-gate-id" ] && cmp -s "$PWD_/body.md" "$PWD_/ti-before.md" && [ "$(no_call 'pr edit')" = 1 ] && ok=1
  check "[tick-ids] a human-gate id (5) is refused: failed/human-gate-id, body untouched, no edit" "$ok"
  tk_body "$(ti_block '1 3 14')"
  OUT="$(run_pw body-splice --pr 9 --mode tick-ids --ids 1,3,14)"
  ok=0; [ "$(res "$OUT")" = "skipped/unchanged" ] && [ "$(no_call 'pr edit')" = 1 ] && ok=1
  check "[tick-ids] a second tick of the same ids is skipped/unchanged, no edit" "$ok"
  # [183] second review round (G1): the tick replaces only the id boxes; every other line of the block survives, once, in order
  while IFS= read -r FOREIGN <&3; do
    tk_body "- [ ] <!-- ac:1 --> first
$FOREIGN
- [ ] <!-- ac:2 --> [human-gate] second
- [ ] <!-- ac:3 --> third"
    OUT="$(run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1,3 --keep 2)"
    ok=0; [ "$(res "$OUT")" = "written/-" ] && grep -qxF -- '- [x] <!-- ac:3 --> third' "$PWD_/body.md" \
      && [ "$(awk -v l="$FOREIGN" '$0 == l { n++ } END { print n + 0 }' "$PWD_/body.md")" = 1 ] \
      && [ "$(grep -n -x -F -- "$FOREIGN" "$PWD_/body.md" | cut -d: -f1)" -gt "$(grep -n -F -- '- [x] <!-- ac:3 --> third' "$PWD_/body.md" | cut -d: -f1)" ] && ok=1
    OUT="$(run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1,3 --keep 2)"
    [ "$(res "$OUT")" = "skipped/unchanged" ] && [ "$(no_call 'pr edit')" = 1 ] || ok=0
    check "[183] pr-write.sh tick keeps the foreign block line '$FOREIGN' once, after the rendered lines, and again changes nothing" "$ok"
  done 3<<'EOF'
exception: skip lint -- migration pending -- #9
- exception: skip lint -- migration pending -- #9
Note: the migration plan is in the issue
* [ ] x
1. [ ] x
-[ ] x
- [ ] a box without an id
EOF
  tk_body "- [ ] <!-- ac:1 --> first

- [ ] <!-- ac:2 --> [human-gate] second
- [ ] <!-- ac:3 --> third"
  OUT="$(run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1,3 --keep 2)"
  ok=0; [ "$(res "$OUT")" = "written/-" ] && [ "$(sed -n '/ac:3 -->/{n;p;}' "$PWD_/body.md")" = "" ] && [ "$(sed -n '/ac:3 -->/{n;n;p;}' "$PWD_/body.md")" = "<!-- acceptance:end -->" ] && ok=1
  check "[183] pr-write.sh tick keeps a blank line of the block after the rendered lines" "$ok"
  FENCE='```
<!-- acceptance:start -->
- [ ] an example box
<!-- acceptance:end -->
```'
  tk_body '- [ ] <!-- ac:1 --> first
- [ ] <!-- ac:2 --> [human-gate] second
- [ ] <!-- ac:3 --> third'
  { printf '%s\n' "$FENCE"; cat "$PWD_/body.md"; printf '\n%s\n' "$FENCE"; } > "$PWD_/body2.md" && cp "$PWD_/body2.md" "$PWD_/body.md"
  OUT="$(run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1,3 --keep 2)"
  ok=0; [ "$(res "$OUT")" = "written/-" ] && grep -qxF -- '- [x] <!-- ac:1 --> first' "$PWD_/body.md" && grep -qxF -- '- [ ] an example box' "$PWD_/body.md" \
    && [ "$(grep -c -F -- '- [ ] an example box' "$PWD_/body.md")" = 2 ] && ok=1
  check "[183] pr-write.sh tick ignores marker pairs inside fenced code blocks (before and after the block)" "$ok"
  # [183] second review round (G4): the fence kinds the scanner knows, each holding an example pair AFTER the real block
  # (read unfenced, that example would be "the last pair" and the tick would hit it instead of the real block)
  EX='<!-- acceptance:start -->
- [ ] an example box
<!-- acceptance:end -->'
  while IFS='|' read -r FNAME FOPEN FINNER FCLOSE <&3; do
    tk_body '- [ ] <!-- ac:1 --> first
- [ ] <!-- ac:2 --> [human-gate] second
- [ ] <!-- ac:3 --> third'
    { cat "$PWD_/body.md"; printf '\n%s\n' "$FOPEN"; [ -z "$FINNER" ] || printf '%s\n' "$FINNER"; printf '%s\n%s\n' "$EX" "$FCLOSE"; } > "$PWD_/body2.md" && cp "$PWD_/body2.md" "$PWD_/body.md"
    OUT="$(run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1,3 --keep 2)"
    ok=0; [ "$(res "$OUT")" = "written/-" ] && grep -qxF -- '- [x] <!-- ac:1 --> first' "$PWD_/body.md" && grep -qxF -- '- [x] <!-- ac:3 --> third' "$PWD_/body.md" \
      && [ "$(grep -c -F -- 'ac:1' "$PWD_/body.md")" = 1 ] && [ "$(tail -n 4 "$PWD_/body.md" | head -n 3)" = "$EX" ] && ok=1
    check "[183] pr-write.sh tick: a $FNAME fence after the block keeps its example pair out of the tick" "$ok"
  done 3<<'EOF'
tilde|~~~||~~~
5-tilde|~~~~~||~~~~~
4-backtick holding a 3-backtick fence|````|```|````
backtick holding a tilde line|```|~~~|```
tilde holding a backtick line|~~~|```|~~~
EOF
  # a fence inside the block holds a marker pair and an id-looking line: neither cuts the block nor is a box
  tk_body '- [ ] <!-- ac:1 --> first
```
<!-- acceptance:start -->
- [ ] <!-- ac:2 --> fenced example
<!-- acceptance:end -->
```
- [ ] <!-- ac:2 --> [human-gate] second
- [ ] <!-- ac:3 --> third'
  OUT="$(run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1,3 --keep 2)"
  ok=0; [ "$(res "$OUT")" = "written/-" ] && grep -qxF -- '- [x] <!-- ac:3 --> third' "$PWD_/body.md" && grep -qxF -- '- [ ] <!-- ac:2 --> fenced example' "$PWD_/body.md" \
    && [ "$(grep -c -F -- 'ac:2' "$PWD_/body.md")" = 2 ] && ok=1
  check "[183] pr-write.sh tick: a fence inside the block keeps its marker pair and its id-looking line as they are" "$ok"
  # a fence never closed before the block swallows it: failed/no-markers, never appends, no edit
  { printf 'Closes #1\n\n```\nan example, never closed\n\n'; printf '<!-- acceptance:start -->\n%s\n<!-- acceptance:end -->\n' "$TK_TXT"; } > "$PWD_/body.md"
  OUT="$(run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1,3 --keep 2)"
  ok=0; [ "$(res "$OUT")" = "failed/no-markers" ] && [ "$(no_call 'pr edit')" = 1 ] && ok=1
  check "[183] pr-write.sh tick: a fence never closed before the block -> failed/no-markers, no edit" "$ok"
  tk_body '- [x] <!-- ac:1 --> first
- [ ] <!-- ac:2 --> [human-gate] second
- [x] <!-- ac:3 --> third'
  sed 's/$/\r/' "$PWD_/body.md" > "$PWD_/body2.md" && cp "$PWD_/body2.md" "$PWD_/body.md"
  OUT="$(run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1,3 --keep 2)"
  ok=0; [ "$(res "$OUT")" = "skipped/unchanged" ] && [ "$(no_call 'pr edit')" = 1 ] && ok=1
  check "[183] pr-write.sh tick over a CRLF body that is already right: skipped/unchanged, no edit" "$ok"
  sed 's/$/\r/' <<< "$(printf 'Closes #1\n\n## What this ships\n- a summary line long enough that rewording two boxes stays far under the ten percent guard\n- another summary line of the same kind, so the body is not only the checklist\n\n<!-- acceptance:start -->\n- [ ] <!-- ac:1 --> first\n- [ ] <!-- ac:2 --> [human-gate] second\n- [ ] <!-- ac:3 --> third\n<!-- acceptance:end -->')" > "$PWD_/body.md"
  OUT="$(run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1,3 --keep 2)"
  ok=0; [ "$(res "$OUT")" = "written/-" ] && grep -qxF -- "$(printf -- '- [x] <!-- ac:1 --> first\r')" "$PWD_/body.md" \
    && [ "$(tr -d '\r' < "$PWD_/body.md" | wc -c | tr -d ' ')" -lt "$(wc -c < "$PWD_/body.md" | tr -d ' ')" ] \
    && [ "$(grep -c "$(printf '\r$')" "$PWD_/body.md")" = "$(wc -l < "$PWD_/body.md" | tr -d ' ')" ] && ok=1
  check "[183] pr-write.sh tick over a CRLF body writes CRLF line breaks only" "$ok"

  # [212] the tick command is gated by its digest BEFORE it runs (--expect-cmd), and the block travels as ONE token (--text-b64)
  td_sha() { node -e 'process.stdout.write(require("crypto").createHash("sha256").update(process.argv[1]).digest("hex"))' "$1"; }
  td_field() { printf '%s\n' "$1" | awk -v k="$2" '{ for (i = 1; i <= NF; i++) if (index($i, k "=") == 1) { print substr($i, length(k) + 2); exit } }'; }
  td_pr() { PATH="$PWD_/bin:$PATH" GHLOG="$GHLOG" GH_BODY_FILE="$PWD_/body.md" node "$PR" "$@"; }
  TD_OUT="$WORK/td"
  TD_M1="$WORK/td-marker-wrong"; TD_M2="$WORK/td-marker-right"
  TD_CMD1="touch '$TD_M1'"; TD_CMD2="touch '$TD_M2'"
  TD_LINE="$(node "$PR" --label tdw --round 0 --out "$TD_OUT" --parser lines --no-reuse --expect-cmd "$(td_sha 'some other command')" --cmd "$TD_CMD1")"
  ok=0
  [ ! -e "$TD_M1" ] && [ "$(td_field "$TD_LINE" exit)" = "-1" ] && [ "$(td_field "$TD_LINE" cmd)" = "$(td_sha "refused:$TD_CMD1")" ] \
    && [ "$(printf '%s\n' "$TD_LINE" | wc -l | tr -d ' ')" = 1 ] && ok=1
  check "[tick-digest] a wrong --expect-cmd runs nothing: exit=-1 and cmd= is the digest of the refused: marker plus the typed command" "$ok"
  TD_LINE="$(node "$PR" --label tdr --round 0 --out "$TD_OUT" --parser lines --no-reuse --expect-cmd "$(td_sha "$TD_CMD2")" --cmd "$TD_CMD2")"
  ok=0
  [ -e "$TD_M2" ] && [ "$(td_field "$TD_LINE" exit)" = "0" ] && [ "$(td_field "$TD_LINE" cmd)" = "$(td_sha "$TD_CMD2")" ] && ok=1
  check "[tick-digest] the right --expect-cmd runs the command: exit=0 and cmd= equals the expected digest" "$ok"
  # the refusal never lets a stored failure answer a later call (exit != 0 is never reused)
  TD_LINE="$(node "$PR" --label tdw --round 0 --out "$TD_OUT" --parser lines --expect-cmd "$(td_sha "$TD_CMD1")" --cmd "$TD_CMD1")"
  ok=0
  [ -e "$TD_M1" ] && [ "$(td_field "$TD_LINE" exit)" = "0" ] && ok=1
  check "[tick-digest] a refused record is never reused: the same call with the right digest then runs" "$ok"
  # A refusal must always read as a digest mismatch to the engine: the PROBE line's cmd= never equals the digest it wanted,
  # whatever the token (wrong, truncated, empty, non-hex) and even when the copied --cmd is intact; the typed text stays visible.
  TD_CMD3="touch '$WORK/td-marker-3'"
  TD_WANT3="$(td_sha "$TD_CMD3")"
  td_refuse_case() { # <label> <token> <name>
    rm -f "$WORK/td-marker-3"
    TD_LINE="$(node "$PR" --label "$1" --round 0 --out "$TD_OUT" --parser pr-write --no-reuse --expect-cmd "$2" --cmd "$TD_CMD3")"
    TD_RC=$?
    ok=0
    [ "$TD_RC" -eq 0 ] && [ ! -e "$WORK/td-marker-3" ] && [ "$(printf '%s\n' "$TD_LINE" | wc -l | tr -d ' ')" = 1 ] \
      && [ "$(td_field "$TD_LINE" exit)" = "-1" ] && [ -n "$(td_field "$TD_LINE" cmd)" ] && [ "$(td_field "$TD_LINE" cmd)" != "$TD_WANT3" ] \
      && [ "$(node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(r.stderr+"|"+r.cmd.includes(process.argv[2])+"|"+r.cmd.startsWith("refused:"))' "$TD_OUT/$1-r0.json" "$TD_CMD3")" = "expect-cmd-mismatch|true|true" ] && ok=1
    check "[tick-digest] $3: nothing runs, exit 0 with a PROBE line of exit=-1 whose cmd= is not the wanted digest (record keeps the typed text)" "$ok"
  }
  td_refuse_case tdx1 "$(td_sha 'some other command')" "a wrong digest with an INTACT --cmd"
  td_refuse_case tdx2 "$(printf '%s' "$TD_WANT3" | cut -c1-40)" "a truncated digest with an intact --cmd"
  td_refuse_case tdx3 "" "an empty digest with an intact --cmd"
  td_refuse_case tdx4 "not-a-digest" "a non-hex digest with an intact --cmd"
  td_refuse_case tdx5 "$(printf '%s' "$TD_WANT3" | cut -c1-63)g" "a 64-character digest with a non-hex character with an intact --cmd"
  rm -f "$WORK/td-marker-3"
  TD_LINE="$(node "$PR" --label tdu --round 0 --out "$TD_OUT" --parser pr-write --no-reuse --expect-cmd "$(printf '%s' "$TD_WANT3" | tr 'a-f' 'A-F')" --cmd "$TD_CMD3")"
  ok=0
  [ -e "$WORK/td-marker-3" ] && [ "$(td_field "$TD_LINE" exit)" = "0" ] && [ "$(td_field "$TD_LINE" cmd)" = "$TD_WANT3" ] && ok=1
  check "[tick-digest] an UPPERCASE digest that matches the intact --cmd is normalised: the command runs and cmd= equals the digest" "$ok"
  # a write parser without --expect-cmd is refused too (a model that drops the flag must not get an unchecked write)
  rm -f "$WORK/td-marker-3"
  TD_LINE="$(node "$PR" --label tdn --round 0 --out "$TD_OUT" --parser pr-write --no-reuse --cmd "$TD_CMD3")"
  ok=0
  [ ! -e "$WORK/td-marker-3" ] && [ "$(td_field "$TD_LINE" exit)" = "-1" ] && [ "$(td_field "$TD_LINE" cmd)" != "$TD_WANT3" ] && ok=1
  check "[tick-digest] the pr-write parser without --expect-cmd is refused: nothing runs, cmd= is not the digest of the command" "$ok"
  TD_LINE="$(node "$PR" --label tdn2 --round 0 --out "$TD_OUT" --parser lines --no-reuse --cmd "$TD_CMD3")"
  ok=0
  [ -e "$WORK/td-marker-3" ] && [ "$(td_field "$TD_LINE" exit)" = "0" ] && [ "$(td_field "$TD_LINE" cmd)" = "$TD_WANT3" ] && ok=1
  check "[tick-digest] a read parser (lines) without --expect-cmd still runs the command" "$ok"
  # end to end: the composed command carries the whole block; a copy that re-flows it (boxes 2..N indented under box 1) is refused
  TD_TXT="$TK_TXT"
  TD_FLOW="$(printf '%s\n' "$TD_TXT" | awk 'NR == 1 { print; next } { print "  " $0 }')"
  tk_body '- [ ] <!-- ac:1 --> first
- [ ] <!-- ac:2 --> [human-gate] second
- [ ] <!-- ac:3 --> third, stale wording'
  cp "$PWD_/body.md" "$PWD_/body.before"
  TD_COMPOSED="bash '$PW' body-splice --pr 9 --mode tick --text '$TD_TXT' --ids 1,3 --keep 2 --wt '$PWD_/wt' --repo o/r"
  TD_TYPED="bash '$PW' body-splice --pr 9 --mode tick --text '$TD_FLOW' --ids 1,3 --keep 2 --wt '$PWD_/wt' --repo o/r"
  : > "$GHLOG"
  TD_LINE="$(td_pr --label tdf --round 0 --out "$TD_OUT" --parser pr-write --no-reuse --expect-cmd "$(td_sha "$TD_COMPOSED")" --cmd "$TD_TYPED")"
  ok=0
  [ "$TD_TYPED" != "$TD_COMPOSED" ] && cmp -s "$PWD_/body.md" "$PWD_/body.before" && [ "$(no_call 'pr edit')" = 1 ] && [ "$(no_call 'pr view')" = 1 ] \
    && [ "$(td_field "$TD_LINE" exit)" = "-1" ] && [ "$(td_field "$TD_LINE" cmd)" = "$(td_sha "refused:$TD_TYPED")" ] \
    && [ "$(td_field "$TD_LINE" cmd)" != "$(td_sha "$TD_COMPOSED")" ] && ok=1
  check "[tick-digest] a re-flowed copy of the tick command leaves the body byte-identical, no gh call, and its cmd= differs from the composed one" "$ok"
  # --text-b64: a long multi-line block (backticks, both quote kinds, id comments, non-ASCII) lands exactly as --text does
  TD_BLK="$(cat <<'BLKEOF'
- [ ] <!-- ac:1 --> run `node a.cjs | grep -c "x"` and expect '0'
- [ ] <!-- ac:2 --> [human-gate] café ok: $HOME and \n stay literal
- [ ] <!-- ac:3 --> third, with a "double" and a 'single' quote, then 100% done
- [ ] <!-- ac:4 --> fourth
BLKEOF
)"
  TD_B64="$(printf '%s' "$TD_BLK" | node -e 'process.stdout.write(require("fs").readFileSync(0).toString("base64"))')"
  tk_body '- [ ] <!-- ac:1 --> stale one
- [ ] <!-- ac:2 --> [human-gate] stale two
- [ ] <!-- ac:3 --> stale three
- [ ] <!-- ac:4 --> stale four'
  cp "$PWD_/body.md" "$PWD_/body.before"
  OUT_T="$(run_pw body-splice --pr 9 --mode tick --text "$TD_BLK" --ids 1,3 --keep 2)"
  cp "$PWD_/body.md" "$PWD_/body.via-text"
  cp "$PWD_/body.before" "$PWD_/body.md"
  OUT_B="$(run_pw body-splice --pr 9 --mode tick --text-b64 "$TD_B64" --ids 1,3 --keep 2)"
  ok=0
  [ "$(res "$OUT_T")" = "written/-" ] && [ "$(res "$OUT_B")" = "written/-" ] && cmp -s "$PWD_/body.via-text" "$PWD_/body.md" \
    && grep -qF -- 'café ok: $HOME and \n stay literal' "$PWD_/body.md" && grep -qxF -- "- [x] <!-- ac:3 --> third, with a \"double\" and a 'single' quote, then 100% done" "$PWD_/body.md" \
    && [ "$(printf '%s' "$TD_B64" | wc -l | tr -d ' ')" = 0 ] && ok=1
  check "[tick-digest] --text-b64 of a long multi-line block (backticks, quotes, id comments, non-ASCII) gives the same body as --text, in one token" "$ok"
  # end to end through probe-run with the RIGHT digest and --text-b64
  tk_body '- [ ] <!-- ac:1 --> stale one
- [ ] <!-- ac:2 --> [human-gate] stale two
- [ ] <!-- ac:3 --> stale three
- [ ] <!-- ac:4 --> stale four'
  TD_REAL="bash '$PW' body-splice --pr 9 --mode tick --text-b64 '$TD_B64' --ids 1,3 --keep 2 --wt '$PWD_/wt' --repo o/r"
  TD_LINE="$(td_pr --label tdb --round 0 --out "$TD_OUT" --parser pr-write --no-reuse --expect-cmd "$(td_sha "$TD_REAL")" --cmd "$TD_REAL")"
  TD_PARSED="$(printf '%s\n' "$TD_LINE" | node -e '
    const { PARSERS } = require(process.argv[1])
    const json = require("fs").readFileSync(0, "utf8").split(" json=")[1]
    const v = PARSERS["pr-write"](json, "", 0)
    process.stdout.write(v.error ? "ERR" : v.op + ":" + v.result)
  ' "$PR")"
  ok=0
  [ "$TD_PARSED" = "body-splice:written" ] && [ "$(td_field "$TD_LINE" cmd)" = "$(td_sha "$TD_REAL")" ] \
    && grep -qxF -- "- [x] <!-- ac:1 --> run \`node a.cjs | grep -c \"x\"\` and expect '0'" "$PWD_/body.md" && grep -qxF -- "- [x] <!-- ac:3 --> third, with a \"double\" and a 'single' quote, then 100% done" "$PWD_/body.md" && ok=1
  check "[tick-digest] the right digest with --text-b64 through probe-run: written, ids ticked, the PROBE line parses as written" "$ok"

  # [239] a failed READ names its cause: reason stays read-failed, `detail` is one of tls|auth|rate-limit|not-found|other,
  # never the stderr text; a silent failure and every non-failure keep today's exact line
  detail_of() { printf '%s' "$1" | jq -r '.detail // "-"'; }
  E_TLS='Post "https://api.github.com/graphql": tls: failed to verify certificate: x509: certificate signed by unknown authority'
  printf '%s\n' "$PRE_BODY" > "$PWD_/body.md"
  OUT="$(GH_READ_ERR="$E_TLS" run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1 --keep 2)"
  ok=0; [ "$(res "$OUT")" = "failed/read-failed" ] && [ "$(detail_of "$OUT")" = "tls" ] && [ "$(no_call 'pr edit')" = 1 ] && [ "$(one_line "$OUT")" = 1 ] && ok=1
  check "[239] pr-write.sh body-splice (tick): a TLS certificate failure on the body read -> failed/read-failed, detail tls, no edit" "$ok"
  OUT="$(GH_READ_ERR='HTTP 401: Bad credentials (https://api.github.com/graphql)
Try authenticating with:  gh auth login -h github.com' run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1 --keep 2)"
  ok=0; [ "$(res "$OUT")" = "failed/read-failed" ] && [ "$(detail_of "$OUT")" = "auth" ] && [ "$(no_call 'pr edit')" = 1 ] && ok=1
  check "[239] pr-write.sh body-splice: a 401 on the body read -> detail auth" "$ok"
  OUT="$(GH_READ_ERR='GraphQL: API rate limit already exceeded for user ID 1234' run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1 --keep 2)"
  ok=0; [ "$(res "$OUT")" = "failed/read-failed" ] && [ "$(detail_of "$OUT")" = "rate-limit" ] && ok=1
  check "[239] pr-write.sh body-splice: a rate limit on the body read -> detail rate-limit" "$ok"
  OUT="$(GH_READ_ERR='GraphQL: Could not resolve to a PullRequest with the number of 99999. (repository.pullRequest)' run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1 --keep 2)"
  ok=0; [ "$(res "$OUT")" = "failed/read-failed" ] && [ "$(detail_of "$OUT")" = "not-found" ] && ok=1
  check "[239] pr-write.sh body-splice: an unknown PR on the body read -> detail not-found" "$ok"
  OUT="$(GH_READ_ERR='dial tcp: lookup api.github.com: no such host' run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1 --keep 2)"
  ok=0; [ "$(res "$OUT")" = "failed/read-failed" ] && [ "$(detail_of "$OUT")" = "other" ] && ok=1
  check "[239] pr-write.sh body-splice: an unrecognised read error -> detail other" "$ok"
  OUT="$(GH_READ_FAIL=1 run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1 --keep 2)"
  OUT_OK="$(run_pw body-splice --pr 9 --mode decision-log --text "$DL")"
  ok=0
  [ "$OUT" = '{"op":"body-splice","result":"failed","reason":"read-failed","bytes":null}' ] && [ "$(printf '%s' "$OUT_OK" | jq -r 'has("detail")')" = "false" ] && ok=1
  check "[239] pr-write.sh: a failure with no stderr and a successful op print today's exact line (no detail key)" "$ok"
  OUT="$(GH_READ_ERR='tls: failed to verify certificate, token ghp_abcdefghijklmnopqrstuvwxyzabcdefghij sent to https://api.github.com/graphql' run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1 --keep 2)"
  ok=0; [ "$(detail_of "$OUT")" = "tls" ] && [ "$(printf '%s' "$OUT" | grep -c 'ghp_\|https://')" = 0 ] && ok=1
  check "[239] pr-write.sh: a token-shaped string and a URL in stderr never reach the output line (only the class does)" "$ok"
  OUT="$(GH_READ_ERR="$E_TLS" run_pw pr-comment --pr 501 --marker "$MK" --body "$MK
text")"
  ok=0; [ "$(res "$OUT")" = "failed/read-failed" ] && [ "$(detail_of "$OUT")" = "tls" ] && [ "$(no_call 'pr comment')" = 1 ] && ok=1
  check "[239] pr-write.sh pr-comment: a TLS failure on the comment read -> detail tls, no comment call" "$ok"
  OUT="$(GH_READ_ERR='HTTP 401: Bad credentials (https://api.github.com/graphql)' run_pw status $SARGS)"
  ok=0; [ "$(res "$OUT")" = "failed/read-failed" ] && [ "$(detail_of "$OUT")" = "auth" ] && [ "$(no_call 'project item-edit')" = 1 ] && ok=1
  check "[239] pr-write.sh status: a 401 on the project item read -> detail auth, no item-edit" "$ok"

  # parser round trip and the engine/helper block parity
  OUT="$(GH_MINIMIZED=true run_pw minimize --id IC_1)"
  out_rt="$(printf '%s\n' "$OUT" | node -e '
    const { PARSERS } = require(process.argv[1])
    const v = PARSERS["pr-write"](require("fs").readFileSync(0, "utf8"), "", 0)
    process.stdout.write(v.error ? "ERR" : v.op + ":" + v.result + ":" + v.reason)
  ' "$PR")"
  [ "$out_rt" = "minimize:skipped:already-minimized" ] && ok=1 || ok=0
  check "pr-write.sh output round-trips through the pr-write parser" "$ok"
else
  echo "SKIP - pr-write.sh e2e needs jq"
fi

