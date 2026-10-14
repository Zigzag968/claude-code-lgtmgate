#!/usr/bin/env bash
# self-reference cases (#455): a PR changing scripts/lead-merge.sh or scripts/lib/ is refused when the copy being run is not the PR's,
# and merges when the branch's own copy runs (sourced by tests/scripts/test-lead-merge.sh, never executed).
# Fixture: setup() branch feat/x gets the changed files committed and pushed; `run` uses the global $SCRIPT (overridden for the branch-copy case).

selfref_commit() { # <dir> <path> <content>: commit and push <path> on feat/x of the working clone
  ( cd "$1/work" && mkdir -p "$(dirname "$2")" && printf '%s\n' "$3" > "$2" && git add -A \
    && git commit -qm "feat: change $2" && git push -q origin feat/x ) >/dev/null 2>&1
}
selfref_no_side_effect() { # <dir>
  [ ! -s "$1/pushes" ] && ! grep -qE 'pr checks|pr merge' "$1/log" && [ -z "$(git -C "$1/work" log --format=%s | grep 'chore: bump')" ]
}

D="$(setup selfref-script)"; selfref_commit "$D" scripts/lead-merge.sh '# branch copy'; run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -ne 0 ] && grep -qF 'FAIL: self-reference' "$D/out" && grep -qF 'bash scripts/lead-merge.sh 7 -R o/r' "$D/out" && grep -qF 'scripts/lead-merge.sh' "$D/out" \
  && ok "self-reference: a PR changing scripts/lead-merge.sh run with another copy is refused, the output names the branch command" || bad "self-reference script refusal (rc=$rc): $(tail -3 "$D/out")"
selfref_no_side_effect "$D" && ok "self-reference: script refusal: no push, no CI poll, no merge call, no bump commit" || bad "self-reference script side effects: $(cat "$D/pushes")"

D="$(setup selfref-lib)"; selfref_commit "$D" scripts/lib/merge-gates.sh '# other lib content'; run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -ne 0 ] && grep -qF 'FAIL: self-reference' "$D/out" && grep -qF 'scripts/lib/merge-gates.sh' "$D/out" && selfref_no_side_effect "$D" \
  && ok "self-reference: a PR changing a file of scripts/lib/ is refused, the output names the file, nothing pushed or merged" || bad "self-reference lib refusal (rc=$rc): $(tail -3 "$D/out")"

D="$(setup selfref-branch-copy)"
( cd "$D/work" && mkdir -p scripts && cp "$ROOT/scripts/lead-merge.sh" scripts/lead-merge.sh && cp -R "$ROOT/scripts/lib" scripts/lib \
  && echo '# branch change' >> scripts/lead-merge.sh && git add -A && git commit -qm "feat: change the merge script" && git push -q origin feat/x ) >/dev/null 2>&1
SCRIPT_SAVED="$SCRIPT"; SCRIPT="$D/work/scripts/lead-merge.sh"; run "$D" "$BASE/good.md"; rc=$?; SCRIPT="$SCRIPT_SAVED"
[ "$rc" -eq 0 ] && [ "$(wc -l < "$D/pushes" | tr -d ' ')" -eq 1 ] && grep -q 'pr merge' "$D/log" && ! grep -qF 'FAIL: self-reference' "$D/out" \
  && ok "self-reference: the same kind of PR run with the branch's own copy merges" || bad "self-reference branch copy (rc=$rc): $(tail -3 "$D/out")"

D="$(setup selfref-unrelated)"; selfref_commit "$D" scripts/other.sh '# unrelated'; run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'pr merge' "$D/log" && ! grep -qF 'FAIL: self-reference' "$D/out" \
  && ok "self-reference: a PR changing scripts/other.sh only merges as before" || bad "self-reference unrelated (rc=$rc): $(tail -3 "$D/out")"
