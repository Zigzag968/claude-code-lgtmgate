#!/usr/bin/env bash
# fake gh, setup/run helpers and the gate cases 1 to 13 (sourced by tests/scripts/test-lead-merge.sh, never executed).
# shellcheck source=lead-merge-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/lead-merge-fixture.sh"

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
[ "$seq" = "pr view 7 -R o/r --json headRefOid,pr checks,pr checks,pr merge," ] && ok "order: base merge+bump+push (one push) < poll < required-checks probe < checks < merge" || bad "order: $seq"
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

# 3b. id-format bodies (#183): boxes carry an <!-- ac:N --> id after their checkbox; the gate counts them like any box
printf 'Closes #1\n<!-- acceptance:start -->\n- [x] <!-- ac:1 --> a\n- [ ] <!-- ac:2 --> b\n<!-- acceptance:end -->\n' > "$BASE/open-id.md"
printf 'Closes #1\n<!-- acceptance:start -->\n- [x] <!-- ac:1 --> a\n- [x] <!-- ac:2 --> b\n<!-- acceptance:end -->\n- [ ] outside\n' > "$BASE/good-id.md"
D="$(setup open-id)"; run "$D" "$BASE/open-id.md"; rc=$?
[ "$rc" -ne 0 ] && ! grep -qE 'update-branch|pr merge|pr checks' "$D/log" && [ "$(git -C "$D/work" log --format=%s | head -1)" = feat ] \
  && ok "id-format: an open id box is refused, no bump, no update-branch/checks/merge" || bad "id-format open box (rc=$rc)"
D="$(setup happy-id)"; run "$D" "$BASE/good-id.md"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'pr merge 7 -R o/r --merge' "$D/log" && ! grep -q -e '--auto' -e '--squash' "$D/log" \
  && ok "id-format: an all-checked id body merges (rc=0, --merge)" || bad "id-format happy path rc=$rc: $(tail -3 "$D/out")"
D_AFTER_3B="$D"

# 3c. fenced examples (#202): a marker pair inside a fenced code block is not the acceptance block (the engine's rule,
# scripts/runtime/pr-body-splice.cjs), so the gate reads the same block the engine ticked
fx='```\n<!-- acceptance:start -->\n- [ ] an example box\n<!-- acceptance:end -->\n```\n'
fx4='````\n```\n<!-- acceptance:start -->\n- [ ] an example box\n<!-- acceptance:end -->\n```\n````\n'
fxt='~~~\n<!-- acceptance:start -->\n- [ ] an example box\n<!-- acceptance:end -->\n~~~\n'
fxu='```\nan example, never closed\n<!-- acceptance:start -->\n- [ ] an example box\n<!-- acceptance:end -->\n'
real_ok='<!-- acceptance:start -->\n- [x] a\n<!-- acceptance:end -->\n'
real_open='<!-- acceptance:start -->\n- [x] a\n- [ ] b\n<!-- acceptance:end -->\n'
printf 'Closes #1\n%b%b' "$fx" "$real_ok" > "$BASE/fx-before-ok.md"
printf 'Closes #1\n%b%b' "$real_ok" "$fx" > "$BASE/fx-after-ok.md"
printf 'Closes #1\n%b%b' "$fx" "$real_open" > "$BASE/fx-before-open.md"
printf 'Closes #1\n%b%b' "$real_open" "$fx" > "$BASE/fx-after-open.md"
printf 'Closes #1\n%b%b%b' "$fx4" "$real_ok" "$fxt" > "$BASE/fx-long-tilde-ok.md"
printf 'Closes #1\n%b%b' "$fxu" "$real_ok" > "$BASE/fx-unclosed-before.md"
printf 'Closes #1\n%b%b' "$real_ok" "$fxu" > "$BASE/fx-unclosed-after.md"
printf 'Closes #1\n%b' "$fx" > "$BASE/fx-only.md"
for c in before after; do
  D="$(setup "fx-$c-ok")"; run "$D" "$BASE/fx-$c-ok.md"; rc=$?
  [ "$rc" -eq 0 ] && grep -q 'pr merge 7 -R o/r --merge' "$D/log" \
    && ok "fenced-example $c a ticked real block: merges (rc=0, --merge)" || bad "fenced-example $c ticked (rc=$rc): $(tail -3 "$D/out")"
  D="$(setup "fx-$c-open")"; run "$D" "$BASE/fx-$c-open.md"; rc=$?
  [ "$rc" -ne 0 ] && grep -qF -- '- [ ] b' "$D/out" && ! grep -qF 'an example box' "$D/out" && ! grep -qE 'update-branch|pr merge|pr checks' "$D/log" \
    && [ "$(git -C "$D/work" log --format=%s | head -1)" = feat ] \
    && ok "fenced-example $c an open real block: refused naming only the real box, no bump/checks/merge" || bad "fenced-example $c open (rc=$rc): $(tail -3 "$D/out")"
done
D="$(setup fx-long-tilde)"; run "$D" "$BASE/fx-long-tilde-ok.md"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'pr merge 7 -R o/r --merge' "$D/log" \
  && ok "fenced-example ~~~ and a 4-backtick fence around a 3-backtick one: merges" || bad "fenced-example long/tilde (rc=$rc): $(tail -3 "$D/out")"
D="$(setup fx-unclosed-after)"; run "$D" "$BASE/fx-unclosed-after.md"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'pr merge 7 -R o/r --merge' "$D/log" \
  && ok "fenced-example fence never closed after the real block: merges (the real pair comes first)" || bad "fenced-example unclosed after (rc=$rc): $(tail -3 "$D/out")"
D="$(setup fx-unclosed-before)"; run "$D" "$BASE/fx-unclosed-before.md"; rc=$?
[ "$rc" -ne 0 ] && grep -qF 'acceptance markers missing' "$D/out" && grep -qF 'fence' "$D/out" && ! grep -qE 'update-branch|pr merge|pr checks' "$D/log" \
  && ok "fenced-example fence never closed before the real block: refused with the readable reason, nothing bumped" || bad "fenced-example unclosed before (rc=$rc): $(tail -3 "$D/out")"
# 3d. NUL byte (#203/#211): lead-merge reads the body through a file, so a NUL is seen and refused (`$(...)` dropped it, which let a
# fence the engine reads differently hide an open block)
printf 'Closes #1\n```\n<!-- acceptance:start -->\n- [ ] open\n<!-- acceptance:end -->\n```\0\n<!-- acceptance:start -->\n- [x] ok\n<!-- acceptance:end -->\n' > "$BASE/nul-body.md"
D="$(setup nul-body)"; run "$D" "$BASE/nul-body.md"; rc=$?
[ "$rc" -ne 0 ] && grep -qi 'NUL' "$D/out" && ! grep -qE 'update-branch|pr merge|pr checks' "$D/log" && [ ! -s "$D/pushes" ] \
  && ok "nul-body: a body holding a NUL byte is refused naming the NUL, no push/checks/merge" || bad "nul-body (rc=$rc): $(tail -3 "$D/out")"
# engine parity: the block the lib finds is the one pr-body-splice.cjs replaces (the splice of a sentinel, put back as the lib's block, gives the body again)
if command -v node >/dev/null 2>&1; then
  # shellcheck source=lib/acceptance-check.sh
  . "$ACC_LIB"
  printf 'SENT' > "$BASE/sent.txt"
  for f in fx-before-ok fx-after-ok fx-before-open fx-after-open fx-long-tilde-ok fx-unclosed-before fx-unclosed-after fx-only good open; do
    node "$ROOT/scripts/runtime/pr-body-splice.cjs" splice acceptance "$BASE/$f.md" "$BASE/sent.txt" "$BASE/sent.out" >/dev/null 2>&1; erc=$?
    acceptance_extract_block < "$BASE/$f.md" > "$BASE/blk.txt"; lrc=$?
    if [ "$erc" -eq 3 ]; then
      [ "$lrc" -eq 3 ] && ok "fenced-example parity $f: no block, as in the engine" || bad "fenced-example parity $f: engine finds no block, lib rc=$lrc"
    else
      awk -v blk="$BASE/blk.txt" '$0 == "SENT" { while ((getline l < blk) > 0) print l; next } { print }' "$BASE/sent.out" > "$BASE/rebuilt.md"
      [ "$erc" -eq 0 ] && [ "$lrc" -eq 0 ] && cmp -s "$BASE/rebuilt.md" "$BASE/$f.md" \
        && ok "fenced-example parity $f: same block as the engine" || bad "fenced-example parity $f: engine rc=$erc lib rc=$lrc"
    fi
  done
else
  bad "fenced-example parity: node missing"
fi
D="$D_AFTER_3B"

# 4. idempotent re-run: no second bump
: > "$D/log"
( cd "$D/work" && PATH="$BASE/bin:$PATH" FAKE_LOG="$D/log" FAKE_BODY="$BASE/good.md" FAKE_BRANCH=feat/x FAKE_REMOTE="$D/origin.git" FAKE_COMMENTS="$D/comments.json" bash "$SCRIPT" 7 -R o/r ) > "$D/out" 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ "$(git -C "$D/work" log --format=%s | grep -c 'chore: bump')" -eq 1 ] && ok "re-run does not bump twice" || bad "second bump created (rc=$rc)"

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
D="$(setup reqlate)"; FAKE_NOREQ=2 run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'pr merge' "$D/log" && ok "required checks registered late: keeps polling, then merges" || bad "reqlate (rc=$rc): $(tail -3 "$D/out")"
D="$(setup reqnever)"; FAKE_NOREQ=99 LEAD_MERGE_POLL_MAX=3 run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -ne 0 ] && ! grep -q 'pr merge' "$D/log" && ok "required checks never registered: bounded, no merge" || bad "reqnever (rc=$rc)"

# 11. gh without --required: watch without it
D="$(setup noreq)"; FAKE_HAS_REQUIRED=0 run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q -- '--required' "$D/log" && ok "no --required when unsupported" || bad "noreq (rc=$rc)"

# 11b. base without required checks (#156): protection probe 404/403 and no ruleset rule -> watch the head's checks, never --required
cfg_ci() { # <dir> <json-list>: commit .claude/pipeline.config.json with ciChecks on the head branch (the script wants a clean tree)
  ( cd "$1/work" && mkdir -p .claude && printf '{"ciChecks": %s}\n' "$2" > .claude/pipeline.config.json \
    && git add -A && git commit -qm cfg && git push -q origin feat/x ) >/dev/null 2>&1
}
nrc_merged() { # <label>: merged without --required/--watch, mode named, head checks polled as JSON
  [ "$rc" -eq 0 ] && grep -q 'pr merge 7 -R o/r --merge' "$D/log" && ! grep -qE -- '--required|--watch' "$D/log" \
    && grep -q 'pr checks 7 -R o/r --json name,bucket' "$D/log" && grep -qF '(mode: no-required-checks)' "$D/out" \
    && ok "$1" || bad "$1 (rc=$rc): $(tail -3 "$D/out")"
}
D="$(setup nrc-404)"; FAKE_PROTECTION=none404 run "$D" "$BASE/good.md"; rc=$?
nrc_merged "no required checks (protection 404, no ruleset): merges without --required"
D="$(setup nrc-403)"; FAKE_PROTECTION=none403 run "$D" "$BASE/good.md"; rc=$?
nrc_merged "no required checks (protection and rulesets 403, private Free): merges without --required"
D="$(setup nrc-ruleset)"; FAKE_PROTECTION=ruleset run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'pr checks 7 -R o/r --required' "$D/log" && ! grep -q -- '--json name,bucket' "$D/log" && ! grep -qF 'no-required-checks' "$D/out" \
  && ok "ruleset-only required checks (protection 404): keeps --required" || bad "ruleset-only (rc=$rc): $(tail -3 "$D/out")"
D="$(setup nrc-error)"; FAKE_PROTECTION=error run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -ne 0 ] && ! grep -qE 'pr merge|pr checks' "$D/log" && grep -qF 'cannot tell whether main requires status checks' "$D/out" \
  && ok "protection probe inconclusive (HTTP 500): refused, no checks, no merge" || bad "probe error (rc=$rc): $(tail -3 "$D/out")"
D="$(setup nrc-ratelimit)"; FAKE_PROTECTION=ratelimit run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -ne 0 ] && ! grep -qE 'pr merge|pr checks' "$D/log" && grep -qF 'cannot tell whether main requires status checks' "$D/out" \
  && ok "protection probe rate-limited (HTTP 403): inconclusive, not read as none: refused" || bad "rate-limit probe (rc=$rc): $(tail -3 "$D/out")"
D="$(setup nrc-scoped)"; cfg_ci "$D" '["ci"]'
FAKE_PROTECTION=none404 FAKE_CHECKS_JSON='[{"name":"ci","bucket":"pass"},{"name":"codeql","bucket":"fail"}]' run "$D" "$BASE/good.md"; rc=$?
nrc_merged "no required checks, ciChecks set: a failing check outside ciChecks does not gate the merge"
D="$(setup nrc-named-fail)"; cfg_ci "$D" '["ci"]'
FAKE_PROTECTION=none404 FAKE_CHECKS_JSON='[{"name":"ci","bucket":"fail"}]' run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -ne 0 ] && ! grep -q 'pr merge' "$D/log" && grep -qF 'CI checks failed (ci)' "$D/out" \
  && ok "no required checks, named check failing: no merge" || bad "named fail (rc=$rc): $(tail -3 "$D/out")"
D="$(setup nrc-all-fail)"
FAKE_PROTECTION=none404 FAKE_CHECKS_JSON='[{"name":"ci","bucket":"pass"},{"name":"codeql","bucket":"cancel"}]' run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -ne 0 ] && ! grep -q 'pr merge' "$D/log" && grep -qF 'CI checks failed (codeql)' "$D/out" \
  && ok "no required checks, ciChecks unset: every reported check gates (cancel refuses)" || bad "all-fail (rc=$rc): $(tail -3 "$D/out")"
D="$(setup nrc-pending)"; FAKE_PROTECTION=none404 FAKE_PENDING=2 run "$D" "$BASE/good.md"; rc=$?
[ "$(grep -c 'pr checks 7 -R o/r --json' "$D/log")" -eq 3 ] && nrc_merged "no required checks, pending then green: waits (3 polls), then merges" || bad "pending polls: $(grep -c 'pr checks' "$D/log")"
D="$(setup nrc-never)"; cfg_ci "$D" '["ci","lint"]'
FAKE_PROTECTION=none404 LEAD_MERGE_POLL_MAX=3 run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -ne 0 ] && ! grep -q 'pr merge' "$D/log" && grep -qF '(mode: no-required-checks)' "$D/out" && grep -qF 'lint' "$D/out" && grep -q 'never reported its checks' "$D/out" \
  && ok "no required checks, named check never reported: bounded die names the mode and the check" || bad "never reported (rc=$rc): $(tail -3 "$D/out")"
D="$(setup req-mode-msg)"; FAKE_NOREQ=99 LEAD_MERGE_POLL_MAX=3 run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -ne 0 ] && grep -qF '(mode: required-checks on main)' "$D/out" && ok "required checks never registered: timeout message names the mode" || bad "required-mode message (rc=$rc): $(tail -3 "$D/out")"

# 12. issue closing after a verified merge (#109)
printf 'Closes #5\nfixes: #6, Resolved #8 and closes #5 again; Refs #9; Fixes o/other#77\n<!-- acceptance:start -->\n- [x] a\n<!-- acceptance:end -->\n' > "$BASE/close.md"
mut() { grep -cE 'gh api -X (POST|PATCH) repos/o/r/issues/' "$1/log" | tr -d ' '; }
D="$(setup cl-fail)"; FAKE_MERGE_RC=1 run "$D" "$BASE/close.md"; rc=$?
[ "$rc" -ne 0 ] && [ "$(mut "$D")" = 0 ] && ! grep -qE 'repos/o/r/issues/[0-9]+( |$)' "$D/log" && ok "merge failure: non-zero, no issue call" || bad "merge failure (rc=$rc)"
D="$(setup cl-unmerged)"; FAKE_MERGED=false run "$D" "$BASE/close.md"; rc=$?
[ "$rc" -ne 0 ] && [ "$(mut "$D")" = 0 ] && ! grep -qE 'repos/o/r/issues/[0-9]+( |$)' "$D/log" && ok "not read back as merged: non-zero, no issue call" || bad "unmerged (rc=$rc)"
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

