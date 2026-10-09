#!/usr/bin/env bash
# cases 14 to 24: exceptions, tick, freshness, prerelease, R2 waivers and visibility sections (sourced by tests/scripts/test-lead-merge.sh, never executed).
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
MK='<!-- pipeline-review-round pr=7 sha=@HEAD@ -->' # @HEAD@ = the head sha at fixture time (mkc)
mkc() { # <dir> <review-file> [push-note] -> $D/comments.json (review, then optional Nick push-note); pinned: run() keeps it
  : > "$1/comments.keep"
  python3 - "$1/comments.json" "$2" "${3:-}" "$(head_of "$1")" <<'PY'
import json, sys
c = [{"id": 1, "created_at": "2026-01-01T00:00:00Z", "body": open(sys.argv[2]).read().replace("@HEAD@", sys.argv[4])}]
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

# 15a2. Morgan's template proof without backticks (`<command> -> <output>`) is accepted
printf '%s\n%s\n%s\n' "$MK" 'Tick pending.' \
  '- [ ] **`bash t.sh` exits 0** — verified, tick pending (permissions): bash t.sh -> exit 0, PASS 5/5' > "$BASE/rv1b.md"
D="$(setup tk-arrow)"; tick_body "$B1" "$BASE/tk1b.md"; mkc "$D" "$BASE/rv1b.md"; tick_run "$D" "$BASE/tk1b.md"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'pr merge 7 -R o/r --merge' "$D/log" && ok "tick-from-review: arrow-form proof accepted" || bad "tick arrow (rc=$rc): $(tail -3 "$D/out")"

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
D="$(setup tk-none)"; echo '[]' > "$D/comments.json"; : > "$D/comments.keep"; tick_run "$D" "$BASE/tk1.md"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$D/log.patch" ] && ! grep -qE 'pr merge|pr checks' "$D/log" && grep -q 'FAIL: review-stale' "$D/out" && ok "no review comment: refused" || bad "no review (rc=$rc): $(tail -3 "$D/out")"
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

# 16. consumer repo (#145): no plugin manifest in the merged tree -> bump skipped, the rest of the gesture runs
rm_files() { # <dir> <clone> <branch> <files...>: remove tracked files in a clone and push the branch
  local d="$1" clone="$2" br="$3"; shift 3
  [ -d "$d/$clone" ] || git clone -q "$d/origin.git" "$d/$clone" 2>/dev/null
  ( cd "$d/$clone" && git config user.email t@t && git config user.name t && git checkout -q "$br" \
    && git rm -q -- "$@" && git commit -qm "drop plugin files" && git push -q origin "$br" ) >/dev/null 2>&1
}
D="$(setup consumer)"
rm_files "$D" work feat/x .claude-plugin/plugin.json workflows/deliver-pipeline.js
rm_files "$D" other main .claude-plugin/plugin.json workflows/deliver-pipeline.js
run "$D" "$BASE/close.md"; rc=$?
[ "$rc" -eq 0 ] && ok "consumer repo without manifest: rc=0" || bad "consumer repo rc=$rc: $(tail -3 "$D/out")"
grep -qF 'lead-merge: no plugin manifest, version bump skipped' "$D/out" && ok "consumer repo: skip line logged" || bad "consumer repo: no skip line"
[ "$(git -C "$D/work" log --format=%s | grep -c 'chore: bump')" = 0 ] && ok "consumer repo: no bump commit" || bad "consumer repo: bump commit created"
grep -q 'pr merge 7 -R o/r --merge' "$D/log" && grep -qE 'gh api -X PATCH repos/o/r/issues/5 -f state=closed' "$D/log" \
  && ok "consumer repo: merged and issue closed" || bad "consumer repo: merge/close missing: $(cat "$D/log")"
D="$(setup consumer-nobuild)"
rm_files "$D" work feat/x workflows/deliver-pipeline.js
rm_files "$D" other main workflows/deliver-pipeline.js
run "$D" "$BASE/close.md"; rc=$?
[ "$rc" -eq 0 ] && grep -q '"version": "0.8.81"' "$D/work/.claude-plugin/plugin.json" \
  && ok "consumer with manifest but no BUILD line: plugin.json bumped, rc=0" || bad "consumer nobuild (rc=$rc): $(tail -3 "$D/out")"

# 17. review freshness (#157): the latest sha-bearing review marker must name the PR head as read BEFORE the script's own commits
pin_review() { review_at "$1" "$2"; : > "$1/comments.keep"; } # <dir> <sha>: pin the fixture (run() would regenerate it on the head)
late_commit() { # <dir> [subject] [file]: push a commit to feat/x after the review
  ( cd "$1/work" && echo late > "${3:-late.txt}" && git add -A && git commit -qm "${2:-late}" && git push -q origin feat/x ) >/dev/null 2>&1
}
stale_refused() { # <reviewed-sha> <head-sha>: refused with the review-stale line naming both, before any push/checks/merge
  [ "$rc" -ne 0 ] && grep -qF 'FAIL: review-stale' "$D/out" && grep -qF "$1" "$D/out" && grep -qF "$2" "$D/out" \
    && [ ! -s "$D/pushes" ] && ! grep -qE 'pr merge|pr checks' "$D/log"
}
D="$(setup rs-head)"; run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'pr merge 7 -R o/r --merge' "$D/log" && grep -q 'issues/7/comments' "$D/log" \
  && ok "review-stale: review on the head sha: merge proceeds" || bad "review-stale: review on the head sha (rc=$rc): $(tail -3 "$D/out")"
D="$(setup rs-late)"; R="$(head_of "$D")"; pin_review "$D" "$R"; late_commit "$D"; H="$(head_of "$D")"; run "$D" "$BASE/good.md"; rc=$?
stale_refused "$R" "$H" && [ "$(git -C "$D/work" log --format=%s | head -1)" = late ] \
  && ok "review-stale: commit after the review: refused naming both shas, no bump" || bad "review-stale: commit after the review (rc=$rc): $(tail -3 "$D/out")"
D="$(setup rs-none)"; echo '[]' > "$D/comments.json"; : > "$D/comments.keep"; run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -ne 0 ] && grep -qF 'FAIL: review-stale' "$D/out" && grep -qF 'no review marker' "$D/out" && [ ! -s "$D/pushes" ] && ! grep -qE 'pr merge|pr checks' "$D/log" \
  && ok "review-stale: no review marker: refused" || bad "review-stale: no review marker (rc=$rc): $(tail -3 "$D/out")"
D="$(setup rs-bare)"; printf '[{"id":1,"created_at":"2026-01-01T00:00:00Z","body":"<!-- pipeline-review-round pr=7 -->\\nLGTM\\nno sha in the marker"}]\n' > "$D/comments.json"; : > "$D/comments.keep"
run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -ne 0 ] && grep -qF 'no review marker' "$D/out" && ! grep -qE 'pr merge|pr checks' "$D/log" \
  && ok "review-stale: a bare marker (no sha) is not a review: refused" || bad "review-stale: bare marker (rc=$rc): $(tail -3 "$D/out")"
D="$(setup rs-latest)"; H="$(head_of "$D")"
printf '[{"id":1,"created_at":"2026-01-01T00:00:00Z","body":"<!-- pipeline-review-round pr=7 sha=%s -->\\nold\\nverdict"}][{"id":2,"created_at":"2026-01-02T00:00:00Z","body":"<!-- pipeline-review-round pr=7 sha=%s -->\\nnew\\nverdict"},{"id":3,"created_at":"2026-01-03T00:00:00Z","body":"<!-- pipeline-review-round pr=7 -->\\nNick push-note"}]\n' \
  "1111111111111111111111111111111111111111" "$H" > "$D/comments.json"; : > "$D/comments.keep"
run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'pr merge' "$D/log" && ok "review-stale: the latest verdict wins over an older one; a bare push-note after it is ignored" || bad "review-stale: latest verdict (rc=$rc): $(tail -3 "$D/out")"
D="$(setup rs-own)"; main_commit "$D" 1 g.txt other; run "$D" "$BASE/good.md" 1; : > "$D/comments.keep"; run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'pr merge' "$D/log" && grep -qF "only adds lead-merge's own commits" "$D/out" && [ ! -s "$D/pushes" ] \
  && ok "review-stale: re-run after a partial run (own merge + bump commits after the review): tolerated" || bad "review-stale: own commits (rc=$rc): $(tail -3 "$D/out")"
D="$(setup rs-foreign)"; R="$(head_of "$D")"; run "$D" "$BASE/good.md" 1; : > "$D/comments.keep"; late_commit "$D"; H="$(head_of "$D")"; run "$D" "$BASE/good.md"; rc=$?
stale_refused "$R" "$H" && ok "review-stale: a foreign commit on top of the script's own commits: refused naming both shas" || bad "review-stale: foreign commit (rc=$rc): $(tail -3 "$D/out")"
D="$(setup rs-forged)"; R="$(head_of "$D")"; pin_review "$D" "$R"; late_commit "$D" "chore: bump 9.9.9 (lead-merge)" evil.txt; H="$(head_of "$D")"; run "$D" "$BASE/good.md"; rc=$?
stale_refused "$R" "$H" && ok "review-stale: a bump-looking commit touching another file: refused" || bad "review-stale: forged bump (rc=$rc): $(tail -3 "$D/out")"
D="$(setup rs-moved)"; R="$(head_of "$D")"; late_commit "$D"; H="$(head_of "$D")"; pin_review "$D" "$R"; FAKE_HEAD_SHA="$R" run "$D" "$BASE/good.md"; rc=$?
stale_refused "$R" "$H" && grep -qF 'head moved' "$D/out" && ok "review-stale: head moved after the check read it: refused" || bad "review-stale: head moved (rc=$rc): $(tail -3 "$D/out")"
D="$(setup rs-tick)"; tick_body "$B1" "$BASE/tk1.md"; R="$(head_of "$D")"; mkc "$D" "$BASE/rv1.md"; late_commit "$D"; H="$(head_of "$D")"; tick_run "$D" "$BASE/tk1.md"; rc=$?
stale_refused "$R" "$H" && [ ! -e "$D/log.patch" ] && ok "review-stale: --tick-from-review on a stale review: refused before anything is ticked" || bad "review-stale: tick on stale (rc=$rc): $(tail -3 "$D/out")"

# 18. prerelease versions (the 1.0.0-beta.N channel): the bump follows semver 2.0.0 precedence, never a broken string or a patch
set_version() { # <dir> <clone> <branch> <ver> [subject]: set the version in plugin.json + BUILD of a clone, commit and push <branch>
  local d="$1" clone="$2" br="$3" v="$4"
  [ -d "$d/$clone" ] || git clone -q "$d/origin.git" "$d/$clone" 2>/dev/null
  ( cd "$d/$clone" && git config user.email t@t && git config user.name t && git checkout -q "$br" \
    && sed -i.bak -E "s/\"version\": \"[^\"]*\"/\"version\": \"$v\"/" .claude-plugin/plugin.json \
    && sed -i.bak -E "s/version: '[^']*'/version: '$v'/" workflows/deliver-pipeline.js && rm -f .claude-plugin/*.bak workflows/*.bak \
    && git add -A && git commit -qm "${5:-main: version $v}" && git push -q origin "$br" ) >/dev/null 2>&1
}
bumped_to() { # <dir> <ver>: plugin.json + BUILD read <ver>, the pushed head is `chore: bump <ver> (lead-merge)`, one bump commit, merged
  grep -q "\"version\": \"$2\"" "$1/work/.claude-plugin/plugin.json" && grep -q "version: '$2', cutFrom: " "$1/work/workflows/deliver-pipeline.js" \
    && [ "$(git -C "$1/origin.git" log -1 --format=%s feat/x)" = "chore: bump $2 (lead-merge)" ] \
    && [ "$(git -C "$1/work" log --format=%s | grep -c 'chore: bump')" = 1 ] && grep -q 'pr merge 7 -R o/r --merge' "$1/log"
}
D="$(setup pre-next)"; set_version "$D" other main 1.0.0-beta.1; run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && bumped_to "$D" 1.0.0-beta.2 && ok "prerelease: main at 1.0.0-beta.1 -> the next merge bumps to 1.0.0-beta.2" || bad "prerelease next (rc=$rc): $(tail -3 "$D/out")"
D="$(setup pre-num)"; set_version "$D" other main 1.0.0-beta.9; run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && bumped_to "$D" 1.0.0-beta.10 && ok "prerelease: the counter is numeric (beta.9 -> beta.10)" || bad "prerelease numeric (rc=$rc): $(tail -3 "$D/out")"
D="$(setup pre-bare)"; set_version "$D" other main 1.0.0-rc; run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && bumped_to "$D" 1.0.0-rc.1 && ok "prerelease without a numeric tail: 1.0.0-rc -> 1.0.0-rc.1 (a greater version)" || bad "prerelease bare (rc=$rc): $(tail -3 "$D/out")"
# the release gesture: the Lead bumps by hand with lead-merge's own subject; the merge gesture must recognise a prerelease above main and not bump again
D="$(setup pre-hand)"; set_version "$D" work feat/x 1.0.0-beta.1 'chore: bump 1.0.0-beta.1 (lead-merge)'; run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && bumped_to "$D" 1.0.0-beta.1 && grep -qF 'bump commit for 1.0.0-beta.1 already on the branch, skipping bump' "$D/out" && [ ! -s "$D/pushes" ] \
  && ok "hand bump 0.8.80 -> 1.0.0-beta.1 on the branch: recognised as above main, merged as is, no second bump" || bad "prerelease hand bump (rc=$rc): $(tail -3 "$D/out")"
D="$(setup pre-junk)"; set_version "$D" other main banana; run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -ne 0 ] && grep -qF 'not semver' "$D/out" && [ ! -s "$D/pushes" ] && ! grep -qE 'pr merge|pr checks' "$D/log" \
  && ok "non-semver version on main: refused before any bump, push or merge" || bad "non-semver version (rc=$rc): $(tail -3 "$D/out")"

# 19. R2 waivers must be declared (#174): in an engine repo (engineRepo on origin/main), a PR that closes/refs a type:bug issue
# and changes workflows/ must add fixtures/incidents/<N>-*.json, or carry a valid declared exception (step 1b validates it)
r2_main_cfg() { # <dir> <json>: commit .claude/pipeline.config.json on origin/main (second clone, like main_commit)
  local d="$1"
  [ -d "$d/other" ] || git clone -q "$d/origin.git" "$d/other" 2>/dev/null
  ( cd "$d/other" && git config user.email t@t && git config user.name t && git checkout -q main \
    && mkdir -p .claude && printf '%s\n' "$2" > .claude/pipeline.config.json && git add -A && git commit -qm "main: config" && git push -q origin main ) >/dev/null 2>&1
}
r2_branch() { # <dir> [fixture-file] [debt-n]: feat/x touches workflows/, optionally adds a fixture and a DEBT marker
  local d="$1"
  ( cd "$d/work" && echo '// fix' >> workflows/deliver-pipeline.js \
    && if [ -n "${3:-}" ]; then echo "// DEBT(#$3): fixture owed" >> workflows/deliver-pipeline.js; fi \
    && if [ -n "${2:-}" ]; then mkdir -p fixtures/incidents && echo '{}' > "fixtures/incidents/$2"; fi \
    && git add -A && git commit -qm "fix: r2" && git push -q origin feat/x ) >/dev/null 2>&1
}
r2_prep() { # <name> <first-line> <exception-line|""> <labels-of-issue-30> -> sets D and the body file $R2_BODY
  D="$(setup "$1")"; mkdir -p "$D/issues"
  printf '%s\n' "$4" > "$D/issues/30.labels"
  R2_BODY="$BASE/$1.md"
  printf '%s\n<!-- acceptance:start -->\n- [x] a\n%s\n<!-- acceptance:end -->\n' "$2" "$3" > "$R2_BODY"
}
r2_go() { run "$D" "$R2_BODY"; rc=$?; }
r2_refused() { # <label>
  [ "$rc" -ne 0 ] && grep -q 'FAIL: r2-waiver:' "$D/out" && grep -q '#30' "$D/out" \
    && [ ! -s "$D/pushes" ] && ! grep -qE 'pr merge|pr checks' "$D/log" && [ "$(git -C "$D/work" log --format=%s | head -1)" != "chore: bump 0.8.81 (lead-merge)" ] \
    && ok "r2-waiver: $1" || bad "r2-waiver: $1 (rc=$rc): $(tail -3 "$D/out")"
}
r2_merges() { # <label>
  [ "$rc" -eq 0 ] && grep -q 'pr merge' "$D/log" && ! grep -q 'FAIL: r2-waiver' "$D/out" \
    && ok "r2-waiver: $1" || bad "r2-waiver: $1 (rc=$rc): $(tail -3 "$D/out")"
}
R2_ENGINE='{"engineRepo": true}'
R2_EXC="$(printf -- '- [x] exception: R2 fixture waived \xe2\x80\x94 replay needs a recorded run \xe2\x80\x94 #9')"
r2_prep r2-nofix 'Refs #30' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"; r2_branch "$D"; r2_go
r2_refused "no fixture, no exception: refused"
r2_prep r2-exc 'Refs #30' "$R2_EXC" 'open type:bug'; printf 'open tech-debt\n' > "$D/issues/9.labels"; r2_main_cfg "$D" "$R2_ENGINE"; r2_branch "$D" "" 9; r2_go
r2_merges "no fixture, valid exception line and open tech-debt follow-up: merges"
r2_prep r2-fix 'Refs #30' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"; r2_branch "$D" 30-replay.json; r2_go
r2_merges "fixture fixtures/incidents/30-*.json in the diff: merges"
r2_prep r2-otherfix 'Refs #30' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"; r2_branch "$D" 31-x.json; r2_go
r2_refused "fixture for another issue: refused"
r2_prep r2-closes 'Closes #30' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"; r2_branch "$D"; r2_go
r2_refused "closing keyword (Closes #30) is covered like Refs: refused"
r2_prep r2-feature 'Refs #30' '' 'open type:feature'; r2_main_cfg "$D" "$R2_ENGINE"; r2_branch "$D"; r2_go
r2_merges "issue not type:bug: merges"
r2_prep r2-outside 'Refs #30' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"; r2_go
r2_merges "diff outside workflows/: merges"
r2_prep r2-consumer 'Refs #30' '' 'open type:bug'; r2_branch "$D"; r2_go
r2_merges "consumer repo (no engineRepo on main): merges"
r2_prep r2-tamper 'Refs #30' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"; r2_branch "$D"
( cd "$D/work" && mkdir -p .claude && echo '{"engineRepo": false}' > .claude/pipeline.config.json && git add -A && git commit -qm "cfg off" && git push -q origin feat/x ) >/dev/null 2>&1
r2_go
r2_refused "PR switches engineRepo off in its own config: still refused (config read from origin/main)"

# 20. R2 waiver gate, adversarial-review hardening (#174)
r2_commit() { # <dir> <message> [append-line]: feat/x gets one more workflows/ edit (or a doc.md edit when no workflows/ line is wanted), pushed
  ( cd "$1/work" && echo '// fix' >> workflows/deliver-pipeline.js && git add -A && git commit -qm "$2" && git push -q origin feat/x ) >/dev/null 2>&1
}
r2_doc() { ( cd "$1/work" && echo docs > doc.md && git add -A && git commit -qm "docs: r2" && git push -q origin feat/x ) >/dev/null 2>&1; }
r2_remote() { # <dir> <shell snippet>: a commit pushed to feat/x from the second clone (the local branch falls behind the remote head)
  ( cd "$1/other" && git fetch -q origin && git checkout -q -B feat/x origin/feat/x && eval "$2" && git add -A && git commit -qm "remote: r2" \
    && git push -q origin feat/x && git checkout -q main ) >/dev/null 2>&1
}
r2_main_file() { # <dir> <path> <content>: a commit pushed to origin/main from the second clone
  ( cd "$1/other" && git checkout -q main && mkdir -p "$(dirname "$2")" && printf '%s\n' "$3" > "$2" && git add -A && git commit -qm "main: $2" && git push -q origin main ) >/dev/null 2>&1
}
r2_pull_main() { ( cd "$1/work" && git fetch -q origin && git merge -q --no-edit origin/main ) >/dev/null 2>&1; }
r2_pr_fixture() { # <dir> <path> <content>: feat/x touches workflows/ and writes a fixture file, pushed
  ( cd "$1/work" && echo '// fix' >> workflows/deliver-pipeline.js && mkdir -p "$(dirname "$2")" && printf '%s\n' "$3" > "$2" \
    && git add -A && git commit -qm "fix: r2 fixture" && git push -q origin feat/x ) >/dev/null 2>&1
}
# F1 the script's own bump (BUILD line) is not a workflows/ change: a docs-only PR is not refused on its re-run
r2_prep r2-rerun 'Closes #30' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"; r2_doc "$D"; run "$D" "$R2_BODY" 1; rc1=$?; r2_go
{ [ "$rc1" -ne 0 ] && [ "$(git -C "$D/work" log --format=%s | grep -c 'chore: bump')" -eq 1 ]; } && r2_merges "docs-only PR re-run after its own bump (BUILD line): merges" || bad "r2-waiver: re-run setup (rc1=$rc1, bumps=$(git -C "$D/work" log --format=%s | grep -c 'chore: bump')): $(tail -3 "$D/out")"
r2_prep r2-disguised 'Closes #30' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"; r2_commit "$D" "chore: bump 0.8.99 (lead-merge)"; r2_go
r2_refused "workflows/ code under a commit subject imitating the bump: refused (BUILD-only lines are exempt, subjects are not)"
# F2 the gate reads the remote head of the PR, not the lagging local branch
r2_prep r2-lag-wf 'Closes #30' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"; r2_remote "$D" "echo '// fix' >> workflows/deliver-pipeline.js"; r2_go
r2_refused "local branch behind: the remote head adds workflows/ code with no fixture: refused"
r2_prep r2-lag-fix 'Closes #30' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"; r2_commit "$D" "fix: r2"; r2_remote "$D" "mkdir -p fixtures/incidents && echo '{}' > fixtures/incidents/30-r.json"; r2_go
r2_merges "local branch behind: the fixture exists only on the remote head: merges"
r2_prep r2-lag-debt 'Refs #30' "$R2_EXC" 'open type:bug'; printf 'open tech-debt\n' > "$D/issues/9.labels"; r2_main_cfg "$D" "$R2_ENGINE"; r2_commit "$D" "fix: r2"
r2_remote "$D" "echo '// DEBT(#9): owed' >> workflows/deliver-pipeline.js"; r2_go
r2_merges "local branch behind: the DEBT(#9) marker (step 1b) exists only on the remote head: merges"
# F3 renames: git's rename detection must not hide a path
r2_prep r2-rename-out 'Closes #30' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"
( cd "$D/work" && git mv workflows/deliver-pipeline.js engine.js && echo '// fix' >> engine.js && git add -A && git commit -qm "mv" && git push -q origin feat/x ) >/dev/null 2>&1; r2_go
r2_refused "workflows/ file renamed out of the folder and edited: refused"
r2_prep r2-delete 'Closes #30' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"
( cd "$D/work" && git rm -q workflows/deliver-pipeline.js && git commit -qm "del" && git push -q origin feat/x ) >/dev/null 2>&1; r2_go
r2_refused "workflows/ file deleted: refused"
r2_prep r2-fix-renamed 'Closes #30' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"
r2_main_file "$D" fixtures/incidents/29-old.json '{"payload":"long enough content to keep the rename similarity high xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}'; r2_pull_main "$D"
( cd "$D/work" && echo '// fix' >> workflows/deliver-pipeline.js && git mv fixtures/incidents/29-old.json fixtures/incidents/30-new.json && git add -A && git commit -qm "fix: r2" && git push -q origin feat/x ) >/dev/null 2>&1; r2_go
r2_merges "fixture added by a rename (29-old.json -> 30-new.json): counts as added"
# F4 every reference form GitHub treats as closing, anywhere in the body or the commit messages
for form in 'Closes o/r#30' 'closes O/R#30' 'Fixes https://github.com/o/r/issues/30' 'Resolves: https://github.com/o/r/issues/30'; do
  r2_prep "r2-form-$(printf '%s' "$form" | tr -c 'a-zA-Z0-9' '_')" "$form" '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"; r2_branch "$D"; r2_go
  r2_refused "reference form '$form': refused"
done
for form in 'Closes o/other#30' 'Closes https://github.com/o/other/issues/30' 'Related to #30'; do
  r2_prep "r2-other-$(printf '%s' "$form" | tr -c 'a-zA-Z0-9' '_')" "$form" '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"; r2_branch "$D"; r2_go
  r2_merges "not a reference to this repo's issue ('$form'): merges"
done
r2_prep r2-late-ref $'## What this ships\nCloses #30' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"; r2_branch "$D"; r2_go
r2_refused "Closes #30 after the first '## ' heading: refused"
r2_prep r2-code-ref $'Refs #1\n## What this ships\nquoting `Closes #30` and\n```\nFixes #30\n```' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"; r2_branch "$D"; r2_go
r2_merges "keywords quoted in code spans or fences are not references: merges"
r2_prep r2-commit-ref 'Refs #1' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"; r2_commit "$D" "fix: x"; ( cd "$D/work" && git commit -q --allow-empty -m "fix: y" -m "Fixes #30" && git push -q origin feat/x ) >/dev/null 2>&1; r2_go
r2_refused "commit message body 'Fixes #30', PR body 'Refs #1': refused"
r2_prep r2-two-uncovered $'Closes #29\nCloses #30' '' 'open type:bug'; printf 'open type:bug\n' > "$D/issues/29.labels"; r2_main_cfg "$D" "$R2_ENGINE"; r2_pr_fixture "$D" fixtures/incidents/29-a.json '{}'; r2_go
r2_refused "two bug issues, fixture for #29 only: #30 is refused"
r2_prep r2-two-covered $'Closes #29\nCloses #30' '' 'open type:bug'; printf 'open type:bug\n' > "$D/issues/29.labels"; r2_main_cfg "$D" "$R2_ENGINE"; r2_pr_fixture "$D" fixtures/incidents/29-a.json '{}'; r2_pr_fixture "$D" fixtures/incidents/30-b.json '{}'; r2_go
r2_merges "two bug issues, one fixture each: merges"
# F5 fixture accounting: added or modified by the PR, valid JSON at the PR head
r2_prep r2-fix-modified 'Closes #30' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"; r2_main_file "$D" fixtures/incidents/30-old.json '{}'; r2_pull_main "$D"
r2_pr_fixture "$D" fixtures/incidents/30-old.json '{"a":1}'; r2_go
r2_merges "fixture already on main and modified by the PR: counts"
r2_prep r2-fix-untouched 'Closes #30' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"; r2_main_file "$D" fixtures/incidents/30-old.json '{}'; r2_pull_main "$D"; r2_branch "$D"; r2_go
r2_refused "fixture already on main and not touched by the PR: does not count"
r2_prep r2-fix-deleted 'Closes #30' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"; r2_main_file "$D" fixtures/incidents/30-old.json '{}'; r2_pull_main "$D"
( cd "$D/work" && echo '// fix' >> workflows/deliver-pipeline.js && git rm -q fixtures/incidents/30-old.json && git add -A && git commit -qm "fix: r2" && git push -q origin feat/x ) >/dev/null 2>&1; r2_go
r2_refused "fixture deleted by the PR: does not count"
r2_prep r2-fix-garbage 'Closes #30' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"; r2_pr_fixture "$D" fixtures/incidents/30-x.json 'garbage not json'; r2_go
r2_refused "fixture that is not valid JSON: does not count"
r2_prep r2-fix-empty 'Closes #30' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"
( cd "$D/work" && echo '// fix' >> workflows/deliver-pipeline.js && mkdir -p fixtures/incidents && : > fixtures/incidents/30-x.json && git add -A && git commit -qm "fix: r2" && git push -q origin feat/x ) >/dev/null 2>&1; r2_go
r2_refused "empty fixture file: does not count"
r2_prep r2-fix-ext 'Closes #30' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"; r2_pr_fixture "$D" fixtures/incidents/30-x.txt '{}'; r2_go
r2_refused "valid JSON in a file without the .json extension: does not count"
# F6 fail closed, exact matching, scope
r2_prep r2-gh-error 'Closes #30' '' 'open type:bug'; touch "$D/issues/30.fail"; r2_main_cfg "$D" "$R2_ENGINE"; r2_branch "$D"; r2_go
[ "$rc" -ne 0 ] && grep -q 'FAIL: r2-waiver: cannot read issue #30' "$D/out" && [ ! -s "$D/pushes" ] && ! grep -qE 'pr merge|pr checks' "$D/log" \
  && ok "r2-waiver: gh error reading the issue: fail closed with a readable reason" || bad "r2-waiver: gh error (rc=$rc): $(tail -3 "$D/out")"
r2_prep r2-bugfix 'Closes #30' '' 'open type:bugfix'; r2_main_cfg "$D" "$R2_ENGINE"; r2_branch "$D"; r2_go
r2_merges "label type:bugfix is not type:bug: merges"
r2_prep r2-truthy 'Closes #30' '' 'open type:bug'; r2_main_cfg "$D" '{"engineRepo": "true"}'; r2_branch "$D"; r2_go
r2_merges "engineRepo as the string \"true\" does not switch the gate on: merges"
r2_prep r2-main-moved 'Closes #30' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"; r2_main_file "$D" workflows/other.js '// main only'; r2_doc "$D"; r2_go
r2_merges "workflows/ changed on main after the branch was cut, not by the PR: merges"

# 21. R2 waiver gate, second adversarial review (#174)
r2_local() { ( cd "$1/work" && eval "$2" && git add -A && git commit -qm "local: r2" ) >/dev/null 2>&1; } # <dir> <shell snippet>: a commit left UNPUSHED on the local branch
r2_build() { ( cd "$1/work" && printf '%s\n' "$2" > workflows/deliver-pipeline.js && git add -A && git commit -qm "build: r2" && git push -q origin feat/x ) >/dev/null 2>&1; }
r2_exc_refused() { # <label>
  [ "$rc" -ne 0 ] && grep -q 'FAIL: declared-exception:' "$D/out" && [ ! -s "$D/pushes" ] && ! grep -qE 'pr merge|pr checks' "$D/log" \
    && ok "declared-exception: $1" || bad "declared-exception: $1 (rc=$rc): $(tail -3 "$D/out")"
}
R2_WF_LINE="echo '// local fix' >> workflows/deliver-pipeline.js"
R2_FIX_LINE="mkdir -p fixtures/incidents && echo '{}' > fixtures/incidents/30-l.json"
# F1 the gate judges the tip that WILL be merged: the local commits step 2 pushes count, the remote head alone is not enough
r2_prep r2-ahead-wf 'Closes #30' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"; r2_doc "$D"; r2_local "$D" "$R2_WF_LINE"; r2_go
r2_refused "local branch ahead: an unpushed commit changes workflows/ with no fixture: refused"
r2_prep r2-ahead-fix 'Closes #30' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"; r2_commit "$D" "fix: r2"; r2_local "$D" "$R2_FIX_LINE"; r2_go
r2_merges "local branch ahead: the fixture is in the unpushed commit, the remote head changes workflows/: merges"
r2_prep r2-ahead-badfix 'Closes #30' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"; r2_commit "$D" "fix: r2"
r2_local "$D" "mkdir -p fixtures/incidents && echo 'garbage' > fixtures/incidents/30-l.json"; r2_go
r2_refused "local branch ahead: the fixture of the unpushed commit is not valid JSON: refused"
r2_prep r2-div-local-wf 'Closes #30' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"; r2_remote "$D" "echo docs > doc2.md"; r2_local "$D" "$R2_WF_LINE"; r2_go
r2_refused "local and remote diverged: the local side changes workflows/ with no fixture: refused"
r2_prep r2-div-remote-wf 'Closes #30' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"; r2_remote "$D" "echo '// fix' >> workflows/deliver-pipeline.js"; r2_local "$D" "$R2_FIX_LINE"; r2_go
r2_refused "local and remote diverged: the remote side changes workflows/ with no fixture (the local fixture does not cover it): refused"
r2_prep r2-div-both-wf-a 'Closes #30' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"
r2_remote "$D" "echo '// fix' >> workflows/deliver-pipeline.js && mkdir -p fixtures/incidents && echo '{}' > fixtures/incidents/30-r.json"; r2_local "$D" "$R2_WF_LINE"; r2_go
r2_refused "local and remote diverged, both change workflows/: the fixture is on the remote side only: refused"
r2_prep r2-div-both-wf-b 'Closes #30' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"
r2_remote "$D" "echo '// fix' >> workflows/deliver-pipeline.js"; r2_local "$D" "$R2_WF_LINE && $R2_FIX_LINE"; r2_go
r2_refused "local and remote diverged, both change workflows/: the fixture is on the local side only: refused"
r2_prep r2-div-ok 'Closes #30' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"; r2_remote "$D" "echo docs > doc2.md"; r2_local "$D" "$R2_WF_LINE && $R2_FIX_LINE"; r2_go
{ [ "$rc" -ne 0 ] && grep -q 'have diverged' "$D/out" && ! grep -q 'FAIL: r2-waiver' "$D/out"; } \
  && ok "r2-waiver: diverged branch with both sides covered: the gate passes, step 2 refuses the divergence" || bad "r2-waiver: diverged, covered (rc=$rc): $(tail -3 "$D/out")"
# F1 (step 1b) the DEBT marker must be visible on the tip that will be merged
R2_DEBT_LINE="echo '// DEBT(#9): owed' >> workflows/deliver-pipeline.js"
r2_prep exc-ahead-marker 'Refs #30' "$R2_EXC" 'open type:bug'; printf 'open tech-debt\n' > "$D/issues/9.labels"; r2_main_cfg "$D" "$R2_ENGINE"; r2_commit "$D" "fix: r2"; r2_local "$D" "$R2_DEBT_LINE"; r2_go
r2_merges "local branch ahead: the DEBT(#9) marker is in the unpushed commit only: merges"
r2_prep exc-ahead-removed 'Refs #30' "$R2_EXC" 'open type:bug'; printf 'open tech-debt\n' > "$D/issues/9.labels"; r2_main_cfg "$D" "$R2_ENGINE"
( cd "$D/work" && eval "$R2_DEBT_LINE" && git add -A && git commit -qm "fix: r2" && git push -q origin feat/x ) >/dev/null 2>&1
r2_local "$D" "sed -i.bak '/DEBT(#9)/d' workflows/deliver-pipeline.js && rm -f workflows/*.bak"; r2_go
r2_exc_refused "local branch ahead: an unpushed commit removes the DEBT(#9) marker the remote head has: refused"
r2_prep exc-div-remote-marker 'Refs #30' "$R2_EXC" 'open type:bug'; printf 'open tech-debt\n' > "$D/issues/9.labels"; r2_main_cfg "$D" "$R2_ENGINE"
r2_remote "$D" "$R2_DEBT_LINE"; r2_local "$D" "echo docs > doc3.md"; r2_go
r2_exc_refused "diverged: the DEBT(#9) marker exists on the remote side only: refused"
# F2 the BUILD exemption pins the exact line the bump writes: nothing executable fits in it
i=0
while IFS= read -r bl; do
  i=$((i + 1))
  r2_prep "r2-build-bad$i" 'Closes #30' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"; r2_build "$D" "$bl"; r2_go
  r2_refused "BUILD-shaped line that is not the bump's ($bl): refused"
done <<'EOB'
const BUILD = { plugin: 'lgtmgate', version: '0.8.80', cutFrom: (process.exit(3), 'x') }
const BUILD = { plugin: 'lgtmgate', version: '0.8.80', cutFrom: 'abc1234', evil: 1 }
const BUILD = { version: '0.8.80', plugin: 'lgtmgate', cutFrom: 'abc1234' }
const BUILD = { plugin: 'lgtmgate', version: '1.0', cutFrom: 'abc1234' }
const BUILD = { plugin: 'lgtmgate', version: '0.8.80' + g(), cutFrom: 'abc1234' }
const BUILD = { plugin: 'lgtmgate', version: '0.8.80', cutFrom: 'a(b)' }
const BUILD = { plugin: 'lgtmgate', version: '0.8.80', cutFrom: '${x}' }
const BUILD = { plugin: 'lgtmgate', version: '0.8.80', cutFrom: '`x`' }
const BUILD = { plugin: 'lgtmgate', version: '0.8.80', cutFrom: "abc1234" }
const BUILD = { plugin: 'lgtmgate', version: '0.8.80', cutFrom: 'abc1234' }; evil()
const BUILD = { plugin: 'lgtmgate', version: '0.8.80', cutFrom: 'abc1234' } // hi
EOB
i=0
while IFS= read -r bl; do
  i=$((i + 1))
  r2_prep "r2-build-ok$i" 'Closes #30' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"; r2_build "$D" "$bl"; r2_go
  r2_merges "the line the bump writes is exempt ($bl): merges"
done <<'EOB'
const BUILD = { plugin: 'lgtmgate', version: '0.9.0-beta.12', cutFrom: '0123abc' }
const BUILD = { plugin: 'lgtmgate', version: '0.8.81', cutFrom: 'abc1234' };
EOB
r2_prep r2-build-otherfile 'Closes #30' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"
r2_main_file "$D" workflows/other.js "const BUILD = { plugin: 'lgtmgate', version: '0.8.80', cutFrom: 'abc1234' }"; r2_pull_main "$D"
( cd "$D/work" && echo "const BUILD = { plugin: 'lgtmgate', version: '0.8.81', cutFrom: 'abc1234' }" > workflows/other.js && git add -A && git commit -qm "other" && git push -q origin feat/x ) >/dev/null 2>&1; r2_go
r2_refused "a BUILD-shaped line in another workflows/ file is a real change: refused"
# F5 paths with non-ASCII characters are not quoted by git
r2_prep r2-fix-accent 'Closes #30' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"; r2_pr_fixture "$D" 'fixtures/incidents/30-é.json' '{"a":1}'; r2_go
r2_merges "valid fixture with a non-ASCII file name: merges"
# F6 leading zeros: #030 is issue 30
r2_prep r2-zero-fix 'Closes #030' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"; r2_pr_fixture "$D" fixtures/incidents/30-x.json '{}'; r2_go
r2_merges "Closes #030 with fixtures/incidents/30-x.json: merges"
r2_prep r2-zero-nofix 'Closes #030' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"; r2_branch "$D"; r2_go
r2_refused "Closes #030 without a fixture: refused, naming issue #30"
# G the fixture name is matched whole: suffix, prefix and subfolder do not count
r2_prep r2-fix-bak 'Closes #30' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"; r2_pr_fixture "$D" fixtures/incidents/30-x.json.bak '{}'; r2_go
r2_refused "fixtures/incidents/30-x.json.bak does not count"
r2_prep r2-fix-prefixed 'Closes #30' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"; r2_pr_fixture "$D" docs/fixtures/incidents/30-x.json '{}'; r2_go
r2_refused "docs/fixtures/incidents/30-x.json does not count"
r2_prep r2-fix-subdir 'Closes #30' '' 'open type:bug'; r2_main_cfg "$D" "$R2_ENGINE"; r2_pr_fixture "$D" fixtures/incidents/30-a/b.json '{}'; r2_go
r2_refused "fixtures/incidents/30-a/b.json (a subfolder) does not count"

# 22. plugin update hint (#233): a merge of a plugin repo ends with ONE line naming the merged plugin version and the command that
# updates the install (a running session keeps the engine it started with until the plugin is updated and the session restarted)
hint_lines() { grep -c '^lead-merge: plugin ' "$D/out"; } # the number of hint lines of the last run
D="$(setup hint-happy)"; run "$D" "$BASE/good.md"; rc=$?
hl="$(grep -n '^lead-merge: plugin lgtmgate 0.8.81 merged' "$D/out" | head -1 | cut -d: -f1)"; ml="$(grep -n 'PR #7 merged' "$D/out" | head -1 | cut -d: -f1)"
hint="$(grep '^lead-merge: plugin ' "$D/out" | head -1)"
[ "$rc" -eq 0 ] && [ "$(hint_lines)" = 1 ] && [ -n "$hl" ] && [ -n "$ml" ] && [ "$hl" -gt "$ml" ] \
  && case "$hint" in *'claude plugin update lgtmgate@<marketplace> --scope <scope>'*restart*) true ;; *) false ;; esac \
  && ok "plugin-update hint: a merge that bumps the plugin version prints one line with the version and the update command, after the merge readback" \
  || bad "plugin-update hint happy path (rc=$rc, hint lines=$(hint_lines), at $hl vs readback $ml): $(tail -4 "$D/out")"
grep -q 'pr merge 7 -R o/r --merge' "$D/log" && [ "$(wc -l < "$D/pushes" | tr -d ' ')" = 1 ] \
  && ok "plugin-update hint: the merge itself is unchanged (--merge, one push)" || bad "plugin-update hint: merge or push changed: $(cat "$D/log")"
D="$(setup hint-hand)"; set_version "$D" work feat/x 1.0.0-beta.1 'chore: bump 1.0.0-beta.1 (lead-merge)'; run "$D" "$BASE/good.md"; rc=$?
hint="$(grep '^lead-merge: plugin ' "$D/out" | head -1)"
[ "$rc" -eq 0 ] && [ "$(hint_lines)" = 1 ] && case "$hint" in 'lead-merge: plugin lgtmgate 1.0.0-beta.1 merged'*'claude plugin update lgtmgate@<marketplace> --scope <scope>'*) true ;; *) false ;; esac \
  && ok "plugin-update hint: a hand-bumped branch (bump skipped) names the version already on the branch" || bad "plugin-update hint hand bump (rc=$rc, lines=$(hint_lines)): $(tail -4 "$D/out")"
D="$(setup hint-consumer)"
rm_files "$D" work feat/x .claude-plugin/plugin.json workflows/deliver-pipeline.js
rm_files "$D" other main .claude-plugin/plugin.json workflows/deliver-pipeline.js
run "$D" "$BASE/close.md"; rc=$?
[ "$rc" -eq 0 ] && [ "$(hint_lines)" = 0 ] && grep -qF 'lead-merge: no plugin manifest, version bump skipped' "$D/out" \
  && ok "plugin-update hint: a consumer without a manifest prints no hint" || bad "plugin-update hint consumer (rc=$rc, lines=$(hint_lines)): $(tail -4 "$D/out")"
D="$(setup hint-refused)"; run "$D" "$BASE/open.md"; rc=$?
[ "$rc" -ne 0 ] && [ "$(hint_lines)" = 0 ] && ! grep -q 'pr merge' "$D/log" \
  && ok "plugin-update hint: a refused run (open box) prints no hint" || bad "plugin-update hint refused run (rc=$rc, lines=$(hint_lines)): $(tail -3 "$D/out")"
D="$(setup hint-ci)"; run "$D" "$BASE/good.md" 1; rc=$?
[ "$rc" -ne 0 ] && [ "$(hint_lines)" = 0 ] && ok "plugin-update hint: a run whose checks fail (no merge) prints no hint" || bad "plugin-update hint failed checks (rc=$rc, lines=$(hint_lines)): $(tail -3 "$D/out")"

# 23. project specifics visibility (#265): a section is printed (not blocking) when the PR changes the specifics folder; none otherwise
D="$(setup spec-changed)"
( cd "$D/work" && mkdir -p .claude/lgtmgate && echo "NICK-RULE use tabs" > .claude/lgtmgate/nick.md && git add -A && git commit -qm "specifics" && git push -q origin feat/x ) >/dev/null 2>&1
run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && grep -qF 'lead-merge: Project specifics changed' "$D/out" && grep -qF 'NICK-RULE use tabs' "$D/out" && grep -q 'pr merge 7 -R o/r --merge' "$D/log" \
  && ok "specifics-visibility: the section is printed with the diff and the merge still goes through" || bad "specifics-visibility changed (rc=$rc): $(tail -5 "$D/out")"
D="$(setup spec-unchanged)"; run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && ! grep -qF 'Project specifics changed' "$D/out" && grep -q 'pr merge 7 -R o/r --merge' "$D/log" \
  && ok "specifics-visibility: no section when nothing relevant changed" || bad "specifics-visibility unchanged (rc=$rc): $(tail -5 "$D/out")"

# 24. guard surface visibility (#308): printed (not blocking) when the PR changes a guard file or the commands / oneWayDoorPaths config keys; none otherwise
D="$(setup guard-changed)"
( cd "$D/work" && echo "// guard-surface-marker" > eslint.config.js && git add -A && git commit -qm "guard file" && git push -q origin feat/x ) >/dev/null 2>&1
run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && grep -qF 'lead-merge: Guard surface changed' "$D/out" && grep -qF 'guard-surface-marker' "$D/out" && grep -q 'pr merge 7 -R o/r --merge' "$D/log" \
  && ok "guard-surface: a changed guard file is printed with its diff and the merge still goes through" || bad "guard-surface file (rc=$rc): $(tail -5 "$D/out")"
D="$(setup guard-config)"
( cd "$D/work" && mkdir -p .claude && echo '{"commands":{"test":"x"},"oneWayDoorPaths":["a"]}' > .claude/pipeline.config.json && git add -A && git commit -qm "guard config" && git push -q origin feat/x ) >/dev/null 2>&1
run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && grep -qF 'lead-merge: Guard surface changed' "$D/out" && grep -qF '"test": "x"' "$D/out" && grep -q 'pr merge 7 -R o/r --merge' "$D/log" \
  && ok "guard-surface: changed commands / oneWayDoorPaths keys are printed and the merge still goes through" || bad "guard-surface config (rc=$rc): $(tail -5 "$D/out")"
D="$(setup guard-unchanged)"; run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && ! grep -qF 'Guard surface changed' "$D/out" && grep -q 'pr merge 7 -R o/r --merge' "$D/log" \
  && ok "guard-surface: no section when nothing relevant changed" || bad "guard-surface unchanged (rc=$rc): $(tail -5 "$D/out")"

