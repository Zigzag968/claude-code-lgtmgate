#!/usr/bin/env bash
# pr-write.sh and the personal-data guard (#167): issue-comment, pr-comment and body-splice refuse a text that matches a
# pattern of the repository's .pii-patterns with failed/pii-refused:<name> and write nothing; the same ops write a clean text;
# a repository without the file writes exactly as before. Offline: a fake `gh` on PATH logs its calls.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PW="$ROOT/scripts/runtime/pr-write.sh"
GUARD="$ROOT/scripts/runtime/pii-guard.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }
pass=0; fail=0
check() { if [ "$2" = 1 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }

AREA="$(mktemp -d "${TMPDIR:-/tmp}/pii-write.XXXXXX")"
mkdir -p "$AREA/bin"
export GHSTATE="$AREA/ghstate"; mkdir -p "$GHSTATE"
cat > "$AREA/bin/gh" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$GHSTATE/calls.log"
case "$1 $2" in
  "issue view"|"pr view")
    case "$*" in
      *"--json comments"*) echo '{"comments":[]}' ;;
      *"--json body"*) cat "$GHSTATE/body.md" ;;
    esac ;;
  "issue comment"|"pr comment") echo "WRITE $*" >> "$GHSTATE/writes.log" ;;
  "pr edit")
    echo "WRITE $*" >> "$GHSTATE/writes.log"
    f=""; while [ $# -gt 0 ]; do [ "$1" = "--body-file" ] && f="$2"; shift; done
    cp "$f" "$GHSTATE/body.md" ;;
esac
exit 0
FAKE
chmod +x "$AREA/bin/gh"
export PATH="$AREA/bin:$PATH"

reset_state() {
  : > "$GHSTATE/calls.log"; : > "$GHSTATE/writes.log"
  { for i in 1 2 3 4 5 6 7 8 9 10 11 12; do printf 'intro line %s of a body long enough for the 90 percent guard\n' "$i"; done
  printf '<!-- acceptance:start -->\n- [ ] <!-- ac:1 --> a\n<!-- acceptance:end -->\n<!-- decision-log:start -->\n<!-- decision-log:end -->\nfooter line\n'; } > "$GHSTATE/body.md"
}

# a main checkout holding the patterns, a worktree of it without
mkrepo() { # <dir> <with-patterns 0|1>
  mkdir -p "$1"; git -C "$1" init -q 2>/dev/null
  git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null
  [ "$2" = 1 ] && printf '# fixture\nssn :: [0-9]{3}-[0-9]{2}-[0-9]{4}\n' > "$1/.pii-patterns"
}
WITH="$(cd "$AREA" && mkdir with && cd with && pwd -P)"; mkrepo "$WITH" 1
NONE="$(cd "$AREA" && mkdir none && cd none && pwd -P)"; mkrepo "$NONE" 0
WT="$AREA/wt"; git -C "$WITH" worktree add -q "$WT" -b feat/issue-9 2>/dev/null

LEAK='see 123-45-6789 please'; FINE='nothing personal here'
res() { jq -r '.result + "/" + (.reason // "")'; }

for op in issue-comment pr-comment; do
  flag=--number; [ "$op" = pr-comment ] && flag=--pr
  reset_state
  out="$(bash "$PW" "$op" $flag 4 --marker "<!-- m -->" --body "$LEAK" --worktree "$WITH")"
  [ "$(printf '%s' "$out" | res)" = "failed/pii-refused:ssn" ] && ok=1 || ok=0; check "$op match -> failed/pii-refused:ssn ($out)" "$ok"
  [ ! -s "$GHSTATE/writes.log" ] && [ ! -s "$GHSTATE/calls.log" ] && ok=1 || ok=0; check "$op match: no gh call at all" "$ok"
  printf '%s' "$out" | grep -q '123-45-6789' && ok=0 || ok=1; check "$op match: matched text never printed" "$ok"
  reset_state
  out="$(bash "$PW" "$op" $flag 4 --marker "<!-- m -->" --body "$FINE" --worktree "$WITH")"
  [ "$(printf '%s' "$out" | res)" = "written/" ] && [ -s "$GHSTATE/writes.log" ] && ok=1 || ok=0; check "$op clean text written ($out)" "$ok"
  reset_state
  out="$(bash "$PW" "$op" $flag 4 --marker "<!-- m -->" --body "$LEAK" --worktree "$NONE")"
  [ "$(printf '%s' "$out" | res)" = "written/" ] && ok=1 || ok=0; check "$op without .pii-patterns: matching text written as before ($out)" "$ok"
done

# worktree of the repo holding the file: resolved through the main checkout
reset_state
out="$(bash "$PW" issue-comment --number 4 --marker "<!-- m -->" --body "$LEAK" --worktree "$WT")"
[ "$(printf '%s' "$out" | res)" = "failed/pii-refused:ssn" ] && ok=1 || ok=0; check "worktree resolves .pii-patterns through the main checkout ($out)" "$ok"

# body-splice: decision-log, acceptance, tick
reset_state; before="$(cat "$GHSTATE/body.md")"
out="$(bash "$PW" body-splice --pr 3 --mode decision-log --text "$LEAK" --worktree "$WITH")"
[ "$(printf '%s' "$out" | res)" = "failed/pii-refused:ssn" ] && ok=1 || ok=0; check "body-splice decision-log match refused ($out)" "$ok"
[ ! -s "$GHSTATE/writes.log" ] && [ "$(cat "$GHSTATE/body.md")" = "$before" ] && ok=1 || ok=0; check "body-splice match: body untouched, no edit" "$ok"
grep -q 'pr view' "$GHSTATE/calls.log" && ok=0 || ok=1; check "body-splice match: nothing read from GitHub" "$ok"
reset_state
out="$(bash "$PW" body-splice --pr 3 --mode acceptance --text "- [ ] <!-- ac:1 --> $LEAK" --worktree "$WITH")"
[ "$(printf '%s' "$out" | res)" = "failed/pii-refused:ssn" ] && ok=1 || ok=0; check "body-splice acceptance match refused ($out)" "$ok"
reset_state
out="$(bash "$PW" body-splice --pr 3 --mode decision-log --text "$FINE" --worktree "$WITH")"
[ "$(printf '%s' "$out" | res)" = "written/" ] && grep -q "$FINE" "$GHSTATE/body.md" && ok=1 || ok=0; check "body-splice clean text written ($out)" "$ok"
reset_state
out="$(bash "$PW" body-splice --pr 3 --mode decision-log --text "$LEAK" --worktree "$NONE")"
[ "$(printf '%s' "$out" | res)" = "written/" ] && ok=1 || ok=0; check "body-splice without .pii-patterns: matching text written as before ($out)" "$ok"
reset_state
out="$(bash "$PW" body-splice --pr 3 --mode tick-ids --ids 1 --worktree "$WITH")"
[ "$(printf '%s' "$out" | res)" = "written/" ] && ok=1 || ok=0; check "body-splice tick-ids carries no text: not checked ($out)" "$ok"

# the lib: labels, invalid regex, absent file
out="$(printf '%s\n' "$LEAK" | bash "$GUARD" check --dir "$WITH")"; rc=$?
[ "$rc" = 1 ] && [ "$out" = "pii-refused:ssn" ] && ok=1 || ok=0; check "lib: match -> exit 1 and the label only" "$ok"
printf 'x\n' | bash "$GUARD" check --dir "$NONE" >/dev/null; [ "$?" = 0 ] && ok=1 || ok=0; check "lib: no file -> exit 0" "$ok"
BAD="$AREA/bad"; mkdir -p "$BAD"; printf 'good :: zzz\n(unclosed\n' > "$BAD/.pii-patterns"
out="$(printf 'x\n' | bash "$GUARD" check --dir "$BAD")"; rc=$?
[ "$rc" = 1 ] && [ "$out" = "pii-refused:line-2-invalid-pattern" ] && ok=1 || ok=0; check "lib: invalid regex fails closed ($out)" "$ok"

# lead-merge.sh checks the tick body before the PATCH
pl="$(grep -n 'runtime/pii-guard.sh' "$ROOT/scripts/lead-merge.sh" | head -1 | cut -d: -f1)"
pp="$(grep -n 'api -X PATCH "repos/$REPO/pulls/$PR"' "$ROOT/scripts/lead-merge.sh" | head -1 | cut -d: -f1)"
[ -n "$pl" ] && [ -n "$pp" ] && [ "$pl" -lt "$pp" ] && ok=1 || ok=0; check "lead-merge.sh calls pii-guard.sh before the tick PATCH (lines $pl < $pp)" "$ok"

echo "[test-pii-write] status=$([ "$fail" -eq 0 ] && echo ok || echo fail) passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
