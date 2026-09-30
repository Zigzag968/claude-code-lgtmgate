#!/usr/bin/env bash
# Regression test for scripts/lead-merge.sh (#74). Offline: a fake `gh` on PATH logs every call
# to a file; the git side is a throwaway repo + bare origin under $TMPDIR (the real worktree is
# never touched). Cases: open box, missing markers, happy path order, no auto-merge flag,
# --merge used, CI failure, idempotent re-run, main moved (own bump + unrelated commit) after the
# branch was cut, conflicting main, remote head ahead of local, stale/no-checks polling.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/lead-merge.sh"
BASE="$(mktemp -d "${TMPDIR:-/tmp}/lead-merge-test.XXXXXX")"
PASS=0; FAIL=0; RUN_FLAGS=""
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

mkdir -p "$BASE/bin"
cat > "$BASE/bin/gh" <<'FAKE'
#!/usr/bin/env bash
if [ "$1 $2 $3" = "pr checks --help" ]; then
  [ "${FAKE_HAS_REQUIRED:-1}" -eq 1 ] && echo "      --required   Only show checks that are required"
  exit 0
fi
echo "gh $*" >> "$FAKE_LOG"
case "$1 $2" in
  "pr view")
    case "$*" in
      *headRefOid*)
        stale="$(cat "$FAKE_LOG.stale" 2>/dev/null || echo "${FAKE_STALE:-0}")"
        if [ "$stale" -gt 0 ]; then
          echo $((stale - 1)) > "$FAKE_LOG.stale"
          echo '{"headRefOid":"0000000","statusCheckRollup":[]}'
        else
          echo "{\"headRefOid\":\"$(git --git-dir="$FAKE_REMOTE" rev-parse "$FAKE_BRANCH")\",\"statusCheckRollup\":[{\"name\":\"ci\"}]}"
        fi ;;
      *headRefName*) echo "$FAKE_BRANCH" ;;
      *) cat "$FAKE_BODY" ;;
    esac ;;
  "pr update-branch") echo "fake gh: update-branch must not be called" >&2; exit 98 ;;
  "pr checks") [ "${FAKE_CHECKS_RC:-0}" -eq 0 ] || exit "$FAKE_CHECKS_RC" ;;
  "pr merge") [ "${FAKE_MERGE_RC:-0}" -eq 0 ] || exit "$FAKE_MERGE_RC" ;;
  "api repos/o/r/commits/"*) echo "${FAKE_HEAD_DATE:-2025-12-31T00:00:00Z}" ;; # --tick-from-review head date (#9)
  "api repos/o/r/pulls/7")
    case "$*" in
      *head.sha*) echo "abc1234" ;;
      *merged_at*) [ "${FAKE_MERGED:-true}" = true ] && echo "2026-10-01T00:00:00Z" || echo null ;;
      *) echo "${FAKE_MERGED:-true}" ;;
    esac ;;
  "api repos/o/r/issues/"*)
    case "$*" in
      *comments*) cat "$FAKE_COMMENTS" 2>/dev/null || echo '[]' ;; # --tick-from-review (#9)
      *labels*) n="${2##*/}"; cat "$FAKE_ISSUES/$n.labels" 2>/dev/null || echo "closed" ;; # declared-exception lookup (#122)
      *) n="${2##*/}"; cat "$FAKE_ISSUES/$n" 2>/dev/null || echo open ;;
    esac ;;
  "api -X") case "$*" in
      *"PATCH repos/o/r/pulls/7"*) # --tick-from-review (#9): record the PATCH, update the served body
        all="$*"; f="${all##*body=@}"; cp "$f" "$FAKE_BODY" && cp "$f" "$FAKE_LOG.patch" ;;
      *"issues/"*) ;; *) echo "fake gh: unexpected: $*" >&2; exit 99 ;; esac ;;
  *) echo "fake gh: unexpected: $*" >&2; exit 99 ;;
esac
exit 0
FAKE
chmod +x "$BASE/bin/gh"

# fixture: bare origin + working clone on feat/x one commit ahead of main
setup() {
  local d="$BASE/$1"
  mkdir -p "$d"
  git init -q --bare -b main "$d/origin.git"
  git clone -q "$d/origin.git" "$d/work" 2>/dev/null
  ( cd "$d/work" && git config user.email t@t && git config user.name t \
    && mkdir -p .claude-plugin workflows \
    && printf '{\n  "name": "lgtmgate",\n  "version": "0.8.80",\n  "x": 1\n}\n' > .claude-plugin/plugin.json \
    && printf "const BUILD = { plugin: 'lgtmgate', version: '0.8.80', cutFrom: 'abc1234' }\n" > workflows/deliver-pipeline.js \
    && git add -A && git commit -qm init && git push -q origin HEAD:main \
    && git checkout -q -b feat/x && echo change > f.txt && git add -A && git commit -qm feat \
    && git push -q origin feat/x ) >/dev/null 2>&1
  echo "$d"
}

run() { # <dir> <body-file> [checks-rc]
  local d="$1"
  : > "$d/log"; : > "$d/pushes"; rm -f "$d/log.stale" "$d/log.patch"; mkdir -p "$d/issues"
  [ -n "${FAKE_STALE:-}" ] && echo "$FAKE_STALE" > "$d/log.stale"
  printf '#!/bin/sh\necho "$1" >> "%s/pushes"\n' "$d" > "$d/origin.git/hooks/update"; chmod +x "$d/origin.git/hooks/update"
  ( cd "$d/work" && PATH="$BASE/bin:$PATH" FAKE_LOG="$d/log" FAKE_BODY="$2" FAKE_BRANCH=feat/x \
      FAKE_REMOTE="$d/origin.git" FAKE_CHECKS_RC="${3:-0}" FAKE_ISSUES="$d/issues" FAKE_COMMENTS="$d/comments.json" LEAD_MERGE_POLL_SLEEP=0 bash "$SCRIPT" 7 -R o/r $RUN_FLAGS ) > "$d/out" 2>&1
}
# push a commit to origin/main from a second clone: main_commit <dir> <bump 0|1> <file> <content>
main_commit() {
  local d="$1" bump="$2"
  [ -d "$d/other" ] || git clone -q "$d/origin.git" "$d/other" 2>/dev/null
  ( cd "$d/other" && git config user.email t@t && git config user.name t && git checkout -q main \
    && if [ "$bump" = 1 ]; then
         sed -i.bak 's/"version": "0.8.80"/"version": "0.8.81"/' .claude-plugin/plugin.json
         sed -i.bak "s/version: '0.8.80'/version: '0.8.81'/" workflows/deliver-pipeline.js; rm -f ./*.bak .claude-plugin/*.bak workflows/*.bak
       fi \
    && printf '%s\n' "$4" > "$3" && git add -A && git commit -qm "main: $3" && git push -q origin main ) >/dev/null 2>&1
}

printf 'Closes #1\n<!-- acceptance:start -->\n- [x] a\n- [ ] b\n<!-- acceptance:end -->\n' > "$BASE/open.md"
printf 'Closes #1\n- [x] a\n' > "$BASE/nomark.md"
printf 'Closes #1\n<!-- acceptance:start -->\n- [x] a\n- [x] b\n<!-- acceptance:end -->\n- [ ] outside\n' > "$BASE/good.md"

# 1. unchecked box
D="$(setup open)"; run "$D" "$BASE/open.md"; rc=$?
[ "$rc" -ne 0 ] && ! grep -qE 'update-branch|pr merge|pr checks' "$D/log" && [ "$(git -C "$D/work" log --format=%s | head -1)" = feat ] \
  && ok "unchecked box: refused, no bump, no update-branch/checks/merge" || bad "unchecked box (rc=$rc)"

# 2. missing markers
D="$(setup nomark)"; run "$D" "$BASE/nomark.md"; rc=$?
[ "$rc" -ne 0 ] && ! grep -qE 'update-branch|pr merge' "$D/log" && ok "missing markers: refused" || bad "missing markers (rc=$rc)"

# 3. happy path
D="$(setup happy)"; run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && ok "happy path rc=0" || bad "happy path rc=$rc: $(tail -3 "$D/out")"
seq="$(grep -oE 'pr (update-branch|checks|merge)|pr view 7 -R o/r --json headRefOid' "$D/log" | tr '\n' ',')"
[ "$seq" = "pr view 7 -R o/r --json headRefOid,pr checks,pr merge," ] && ok "order: base merge+bump+push (one push) < poll < checks < merge" || bad "order: $seq"
[ "$(wc -l < "$D/pushes" | tr -d ' ')" = 1 ] && ok "exactly one push" || bad "push count: $(cat "$D/pushes")"
! grep -q 'update-branch' "$D/log" && ok "no gh pr update-branch" || bad "update-branch called"
git -C "$D/origin.git" log -1 --format=%s feat/x | grep -qx 'chore: bump 0.8.81 (lead-merge)' && ok "bump commit is the pushed head" || bad "remote head not the bump"
grep -q -- '--required' "$D/log" && ok "checks use --required when supported" || bad "--required missing"
grep -q -- '--watch --fail-fast' "$D/log" && ok "checks use --watch --fail-fast" || bad "checks flags"
grep -q 'pr merge 7 -R o/r --merge' "$D/log" && ok "merge uses --merge" || bad "merge flag"
! grep -q -e '--auto' -e '--squash' "$D/log" && ok "no auto/squash flag in any gh call" || bad "forbidden flag in log"
grep -q '"version": "0.8.81"' "$D/work/.claude-plugin/plugin.json" \
  && grep -q "version: '0.8.81', cutFrom: '$(git -C "$D/work" rev-parse --short origin/main)'" "$D/work/workflows/deliver-pipeline.js" \
  && ok "plugin.json + BUILD bumped (cutFrom = origin/main short sha)" || bad "bump content"

# 4. idempotent re-run: no second bump
: > "$D/log"
( cd "$D/work" && PATH="$BASE/bin:$PATH" FAKE_LOG="$D/log" FAKE_BODY="$BASE/good.md" FAKE_BRANCH=feat/x FAKE_REMOTE="$D/origin.git" bash "$SCRIPT" 7 -R o/r ) > "$D/out" 2>&1
[ "$(git -C "$D/work" log --format=%s | grep -c 'chore: bump')" -eq 1 ] && ok "re-run does not bump twice" || bad "second bump created"

# 5. CI failure -> no merge
D="$(setup ci)"; run "$D" "$BASE/good.md" 1; rc=$?
[ "$rc" -ne 0 ] && grep -q 'pr checks' "$D/log" && ! grep -q 'pr merge' "$D/log" && ok "checks failure: no merge" || bad "checks failure (rc=$rc)"

# 6. main moved after the branch was cut: own bump + unrelated commit
D="$(setup moved)"; main_commit "$D" 1 g.txt other; run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && ok "moved main: rc=0" || bad "moved main rc=$rc: $(tail -3 "$D/out")"
head_sha="$(git -C "$D/origin.git" rev-parse feat/x)"
git -C "$D/origin.git" show "$head_sha:.claude-plugin/plugin.json" | grep -q '"version": "0.8.82"' \
  && git -C "$D/origin.git" show "$head_sha:workflows/deliver-pipeline.js" | grep -q "version: '0.8.82'" \
  && ok "version = max(branch, main)+1 = 0.8.82" || bad "moved main version"
git -C "$D/origin.git" merge-base --is-ancestor "$(git -C "$D/origin.git" rev-parse main)" "$head_sha" \
  && ok "pushed branch contains origin/main" || bad "main not merged into branch"
git -C "$D/origin.git" show "$head_sha:g.txt" >/dev/null 2>&1 && ok "unrelated main commit present" || bad "g.txt missing"
[ "$(wc -l < "$D/pushes" | tr -d ' ')" = 1 ] && grep -q 'pr merge' "$D/log" && ok "moved main: one push, merged" || bad "moved main push/merge: $(cat "$D/pushes")"

# 7. main conflicts in a non-version file: dies before any push, no merge call
D="$(setup conflict)"; main_commit "$D" 0 f.txt other; run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -ne 0 ] && [ ! -s "$D/pushes" ] && ! grep -qE 'pr merge|pr checks' "$D/log" \
  && [ -z "$(git -C "$D/work" status --porcelain)" ] && ok "conflict: died, no push, merge aborted, no merge call" || bad "conflict case (rc=$rc)"

# 8. main bumped after our bump was pushed (version-only conflict): main's copy taken, re-bumped
D="$(setup vconf)"; run "$D" "$BASE/good.md"; main_commit "$D" 1 g.txt other; run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && grep -q '"version": "0.8.82"' "$D/work/.claude-plugin/plugin.json" \
  && ok "version-only conflict resolved, re-bumped to 0.8.82" || bad "vconf rc=$rc: $(tail -3 "$D/out")"

# 9. remote head ahead of local (previous run pushed): fast-forward, no second bump
D="$(setup ahead)"; run "$D" "$BASE/good.md"
git -C "$D/work" checkout -q -B feat/x HEAD~1 >/dev/null 2>&1
run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && [ "$(git -C "$D/work" log --format=%s | grep -c 'chore: bump')" -eq 1 ] && [ ! -s "$D/pushes" ] \
  && ok "remote ahead: fast-forwarded, no second bump, no push" || bad "ahead case (rc=$rc): $(tail -3 "$D/out")"

# 9b. diverged local vs remote: refused before any push
D="$(setup diverged)"; ( cd "$D/work" && echo more > h.txt && git add -A && git commit -qm local-only ) >/dev/null 2>&1
main_commit "$D" 0 k.txt k >/dev/null 2>&1
( cd "$D/other" && git checkout -q feat/x && echo r > r.txt && git add -A && git commit -qm remote-only && git push -q origin feat/x ) >/dev/null 2>&1
run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -ne 0 ] && [ ! -s "$D/pushes" ] && grep -q diverged "$D/out" && ok "diverged: refused" || bad "diverged (rc=$rc)"

# 10. checks race: first polls report the old sha / no checks
D="$(setup race)"; FAKE_STALE=3 run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && [ "$(grep -c 'json headRefOid' "$D/log")" -eq 4 ] && ok "polls until pushed sha + checks reported (4 polls)" || bad "race (rc=$rc): $(cat "$D/log")"
D="$(setup never)"; FAKE_STALE=99 LEAD_MERGE_POLL_MAX=3 run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -ne 0 ] && ! grep -q 'pr merge' "$D/log" && ok "never reports checks: bounded, no merge" || bad "never (rc=$rc)"

# 11. gh without --required: watch without it
D="$(setup noreq)"; FAKE_HAS_REQUIRED=0 run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q -- '--required' "$D/log" && ok "no --required when unsupported" || bad "noreq (rc=$rc)"

# 12. issue closing after a verified merge (#109)
printf 'Closes #5\nfixes: #6, Resolved #8 and closes #5 again; Refs #9; Fixes o/other#77\n<!-- acceptance:start -->\n- [x] a\n<!-- acceptance:end -->\n' > "$BASE/close.md"
mut() { grep -cE 'gh api -X (POST|PATCH) repos/o/r/issues/' "$1/log" | tr -d ' '; }
D="$(setup cl-fail)"; FAKE_MERGE_RC=1 run "$D" "$BASE/close.md"; rc=$?
[ "$rc" -ne 0 ] && [ "$(mut "$D")" = 0 ] && ! grep -q 'repos/o/r/issues' "$D/log" && ok "merge failure: non-zero, no issue call" || bad "merge failure (rc=$rc)"
D="$(setup cl-unmerged)"; FAKE_MERGED=false run "$D" "$BASE/close.md"; rc=$?
[ "$rc" -ne 0 ] && [ "$(mut "$D")" = 0 ] && ! grep -q 'repos/o/r/issues' "$D/log" && ok "not read back as merged: non-zero, no issue call" || bad "unmerged (rc=$rc)"
D="$(setup cl-ok)"; mkdir -p "$D/issues"; echo closed > "$D/issues/8"; run "$D" "$BASE/close.md"; rc=$?
[ "$rc" -eq 0 ] && ok "merged with closing refs: rc=0" || bad "closing rc=$rc: $(tail -3 "$D/out")"
for n in 5 6; do
  [ "$(grep -c "gh api -X POST repos/o/r/issues/$n/comments -f body=Fixed by #7 (merged)\." "$D/log")" = 1 ] \
    && [ "$(grep -c "gh api -X PATCH repos/o/r/issues/$n -f state=closed -f state_reason=completed" "$D/log")" = 1 ] \
    && ok "open Closes #$n: one comment + one close" || bad "issue #$n calls: $(grep "issues/$n" "$D/log")"
done
! grep -qE 'X (POST|PATCH) repos/o/r/issues/8' "$D/log" && ok "already-closed #8: no call" || bad "closed issue touched"
! grep -qE 'repos/o/r/issues/(9|77)' "$D/log" && ok "Refs #9 and other-repo ref: no call" || bad "Refs/other-repo touched"
[ "$(mut "$D")" = 4 ] && ok "dedup: 4 mutating calls total" || bad "mutating calls: $(mut "$D")"

# 13. closing keywords parsed in the header block only (#119)
printf 'Closes #5\n\nAlso `Fixes #7` inline\n```\nResolves #12\n```\n## What this ships\n- Fixes #10\n## Acceptance checklist\n<!-- acceptance:start -->\n- [x] fixture body `Closes #5`, Fixes #6, Closes #11\n<!-- acceptance:end -->\n' > "$BASE/hdr.md"
D="$(setup hdr)"; run "$D" "$BASE/hdr.md"; rc=$?
[ "$rc" -eq 0 ] && ok "header-only body: rc=0" || bad "header rc=$rc: $(tail -3 "$D/out")"
[ "$(grep -c "gh api -X PATCH repos/o/r/issues/5 -f state=closed" "$D/log")" = 1 ] && ok "Closes #5 on first line: closed once" || bad "issue #5: $(grep 'issues/5' "$D/log")"
for n in 6 7 10 11 12; do
  ! grep -qE "X (POST|PATCH) repos/o/r/issues/$n( |/)" "$D/log" && ok "keyword outside header or in code ($n): no close call" || bad "issue #$n touched"
done
[ "$(mut "$D")" = 2 ] && ok "header-only: 2 mutating calls total" || bad "mutating calls: $(mut "$D")"

# 14. declared exceptions (#122): exception: <what> — <why> — #N
exc_body() { printf 'Closes #1\n<!-- acceptance:start -->\n- [x] a\n%s\n<!-- acceptance:end -->\n' "$1" > "$2"; }
exc_run() { # <name> <exception-line> <issue-file-content|""> <debt-marker|""> -> sets D, rc
  D="$(setup "$1")"; exc_body "$2" "$BASE/$1.md"; mkdir -p "$D/issues"
  [ -n "$3" ] && printf '%s\n' "$3" > "$D/issues/9.labels"
  if [ -n "$4" ]; then ( cd "$D/work" && echo "// DEBT(#$4): skipped" >> f.txt && git add -A && git commit -qm debt && git push -q origin feat/x ) >/dev/null 2>&1; fi
  run "$D" "$BASE/$1.md"; rc=$?
}
exc_refused() { # <label> <reason-substring>
  [ "$rc" -ne 0 ] && grep -q 'FAIL: declared-exception:' "$D/out" && grep -q -- "$2" "$D/out" \
    && [ ! -s "$D/pushes" ] && ! grep -qE 'pr merge|pr checks' "$D/log" && [ "$(git -C "$D/work" log --format=%s | head -1)" != "chore: bump 0.8.81 (lead-merge)" ] \
    && ok "$1: refused, FAIL line, no push/checks/merge" || bad "$1 (rc=$rc): $(tail -3 "$D/out")"
}
EXC='- [x] exception: skip the lint pass \xe2\x80\x94 needs a config migration \xe2\x80\x94 #9'
EXC="$(printf -- "$EXC")"
exc_run exc-ok "$EXC" "open tech-debt,other" 9
[ "$rc" -eq 0 ] && grep -q 'pr merge' "$D/log" && ok "valid exception: merge proceeds" || bad "valid exception (rc=$rc): $(tail -3 "$D/out")"
exc_run exc-ascii "exception: skip lint -- migration pending -- #9" "open tech-debt" 9
[ "$rc" -eq 0 ] && ok "valid exception with ' -- ' separator and no box prefix" || bad "ascii separator (rc=$rc)"
exc_run exc-bad "- [x] exception: skip the lint pass, no reason" "open tech-debt" 9; exc_refused "malformed line" "malformed"
exc_run exc-closed "$EXC" "closed tech-debt" 9; exc_refused "follow-up issue closed" "not open"
exc_run exc-nolabel "$EXC" "open bug,other" 9; exc_refused "issue without tech-debt" "tech-debt label"
exc_run exc-nomarker "$EXC" "open tech-debt" ""; exc_refused "no DEBT(#N) in the diff" "DEBT(#9)"
exc_run exc-wrongn "$EXC" "open tech-debt" 5; exc_refused "DEBT marker with another N" "DEBT(#9)"

# 15. --tick-from-review (#9)
MK='<!-- pipeline-review-round pr=7 -->'
mkc() { # <dir> <review-file> [push-note] -> $D/comments.json (review, then optional Nick push-note)
  python3 - "$1/comments.json" "$2" "${3:-}" <<'PY'
import json, sys
c = [{"id": 1, "created_at": "2026-01-01T00:00:00Z", "body": open(sys.argv[2]).read()}]
if sys.argv[3]:
    c.append({"id": 2, "created_at": "2026-01-02T00:00:00Z", "body": "<!-- pipeline-review-round pr=7 -->\n" + sys.argv[3]})
with open(sys.argv[1], "w") as f:  # concatenated pages, like gh --paginate
    json.dump(c[:1], f)
    if c[1:]:
        json.dump(c[1:], f)
PY
}
tick_body() { printf 'Closes #1\n## Acceptance checklist\n<!-- acceptance:start -->\n%s\n<!-- acceptance:end -->\n' "$1" > "$2"; }
tick_run() { cp "$2" "$1/body.md"; RUN_FLAGS="${RUN_FLAGS_OVERRIDE---tick-from-review}" run "$1" "$1/body.md"; } # per-run copy: the fake PATCH rewrites it
B1='- [ ] `bash t.sh` exits 0'; B2='- [ ] grep -c foo f.txt prints 1'
printf '%s\n%s\n%s\n' "$MK" 'Verified, tick pending (permissions).' \
  '- [ ] **`bash t.sh` exits 0** — verified, tick pending (permissions): `bash t.sh` -> exit 0, `PASS 5/5`' > "$BASE/rv1.md"

# 15a. proven box ticked, then the normal merge sequence
D="$(setup tk-ok)"; tick_body "$B1" "$BASE/tk1.md"; mkc "$D" "$BASE/rv1.md"; tick_run "$D" "$BASE/tk1.md"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'pr merge 7 -R o/r --merge' "$D/log" && ok "tick-from-review: proven box ticked, merge proceeds" || bad "tick ok (rc=$rc): $(tail -3 "$D/out")"
grep -qF -- '- [x] `bash t.sh` exits 0 — ticked by lead-merge from Morgan'"'"'s review' "$D/log.patch" 2>/dev/null \
  && [ "$(grep -c 'pulls/7 -F body' "$D/log")" = 1 ] && ok "tick: REST PATCH pulls/7, line ticked with suffix" || bad "tick patch: $(cat "$D/log.patch" 2>/dev/null)"
[ "$(grep -n 'PATCH repos/o/r/pulls/7' "$D/log" | cut -d: -f1)" -lt "$(grep -n 'pr merge' "$D/log" | cut -d: -f1)" ] && ok "tick happens before the merge" || bad "tick order"

# 15b. box without proof stays open, merge refused; proven one is ticked
tick_body "$B1
$B2" "$BASE/tk2.md"; D="$(setup tk-noproof)"; mkc "$D" "$BASE/rv1.md"; tick_run "$D" "$BASE/tk2.md"; rc=$?
[ "$rc" -ne 0 ] && ! grep -qE 'pr merge|pr checks' "$D/log" && [ ! -s "$D/pushes" ] && grep -qF -- '- [ ] grep -c foo f.txt prints 1' "$D/log.patch" \
  && grep -qF -- '- [x] `bash t.sh` exits 0' "$D/log.patch" && ok "box without proof stays open: refused, no push/merge" || bad "noproof (rc=$rc): $(tail -3 "$D/out")"

# 15c. [human-gate] is never ticked even if Morgan lists it as proven
HG='- [ ] [human-gate] Alex confirms the UI'
tick_body "$HG" "$BASE/tk3.md"; printf '%s\n%s\n%s\n' "$MK" 'Verified.' '- [ ] **[human-gate] Alex confirms the UI** — verified, tick pending (permissions): `look` -> ok' > "$BASE/rv3.md"
D="$(setup tk-hg)"; mkc "$D" "$BASE/rv3.md"; tick_run "$D" "$BASE/tk3.md"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$D/log.patch" ] && ! grep -q 'pr merge' "$D/log" && ok "human-gate box never ticked: no PATCH, refused" || bad "human-gate (rc=$rc)"

# 15d. no review comment -> refused (also when only a one-line push-note exists)
D="$(setup tk-none)"; tick_run "$D" "$BASE/tk1.md"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$D/log.patch" ] && ! grep -qE 'pr merge|pr checks' "$D/log" && grep -q 'no Morgan review comment' "$D/out" && ok "no review comment: refused" || bad "no review (rc=$rc): $(tail -3 "$D/out")"
D="$(setup tk-note)"; printf '%s\n%s\n' "$MK" 'only a push-note' > "$BASE/note.md"; mkc "$D" "$BASE/note.md"; tick_run "$D" "$BASE/tk1.md"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$D/log.patch" ] && ok "one-line marker comment is not a verdict: refused" || bad "push-note only (rc=$rc)"

# 15e. without the flag nothing is ticked
D="$(setup tk-noflag)"; mkc "$D" "$BASE/rv1.md"; RUN_FLAGS_OVERRIDE="" tick_run "$D" "$BASE/tk1.md"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$D/log.patch" ] && ! grep -q 'comments' "$D/log" && ! grep -qE 'pr merge|pr checks' "$D/log" && ok "no flag: nothing ticked, refused as before" || bad "noflag (rc=$rc)"

# 15f. stale proofs (#9): a marker comment after the verdict, or a head commit newer than the verdict
D="$(setup tk-stale-note)"; mkc "$D" "$BASE/rv1.md" "push-note: nothing new"; tick_run "$D" "$BASE/tk1.md"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$D/log.patch" ] && ! grep -qE 'pr merge|pr checks' "$D/log" \
  && grep -qF "FAIL: tick-from-review: a push followed Morgan's verdict; re-review first" "$D/out" && ok "push-note after the verdict: refused, nothing ticked" || bad "stale note (rc=$rc): $(tail -3 "$D/out")"
D="$(setup tk-stale-date)"; mkc "$D" "$BASE/rv1.md"; FAKE_HEAD_DATE="2026-01-03T00:00:00Z" tick_run "$D" "$BASE/tk1.md"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$D/log.patch" ] && ! grep -qE 'pr merge|pr checks' "$D/log" \
  && grep -qF "FAIL: tick-from-review: a push followed Morgan's verdict; re-review first" "$D/out" && ok "head commit newer than the verdict: refused, nothing ticked" || bad "stale date (rc=$rc): $(tail -3 "$D/out")"

echo "[lead-merge test] passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
