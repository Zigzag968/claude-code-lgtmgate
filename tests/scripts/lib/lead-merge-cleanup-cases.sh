#!/usr/bin/env bash
# post-merge worktree cleanup cases (#168), sourced by tests/scripts/test-lead-merge.sh after the gate and release cases.
# The merge is run from a linked worktree of the fixture repo (feat/x checked out under a temp worktree root, main checked out
# in the main tree); the fake gh answers the cleanup's PR lookup with $FAKE_PR_STATE (default MERGED).

# cl_setup <name>: fixture whose feat/x lives in a linked worktree $D/wtroot/wt; prints the fixture dir
cl_setup() {
  local d
  d="$(setup "$1")"
  git -C "$d/work" checkout -q main
  mkdir -p "$d/wtroot"
  git -C "$d/work" worktree add -q "$d/wtroot/wt" feat/x
  echo "$d"
}
# cl_run <dir> [extra run flags]: lead-merge from the linked worktree, the worktree root exported
cl_run() {
  local d="$1"
  RUN_CWD="$d/wtroot/wt" RUN_FLAGS="${2:-}" LGTMGATE_WORKTREE_ROOT="$d/wtroot" run "$d" "$BASE/good.md"
}

D="$(cl_setup cm-offer)"; cl_run "$D"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'to remove this merged worktree' "$D/out" && grep -q 'cleanup-worktree.sh' "$D/out" && [ -d "$D/wtroot/wt" ] \
  && ok "post-merge cleanup: no flag, merged from a linked worktree: offer line printed, worktree still present, rc=0" \
  || bad "post-merge cleanup offer (rc=$rc): $(tail -4 "$D/out")"

D="$(cl_setup cm-flag)"; cl_run "$D" --cleanup; rc=$?
[ "$rc" -eq 0 ] && [ ! -d "$D/wtroot/wt" ] && grep -q 'lead-merge: REMOVED ' "$D/out" && ! git -C "$D/work" worktree list | grep -q 'wtroot/wt' \
  && ok "post-merge cleanup: --cleanup removes the merged worktree after the verified read-back, rc=0" \
  || bad "post-merge cleanup --cleanup (rc=$rc): $(tail -4 "$D/out")"

D="$(cl_setup cm-unmerged)"; FAKE_MERGED=false cl_run "$D" --cleanup; rc=$?
[ "$rc" -ne 0 ] && [ -d "$D/wtroot/wt" ] && ! grep -qE 'worktree cleanup|to remove this merged worktree|REMOVED' "$D/out" \
  && ok "post-merge cleanup: a merge not read back as merged: non-zero, no offer, no removal" \
  || bad "post-merge cleanup unverified merge (rc=$rc): $(tail -4 "$D/out")"

D="$(setup cm-main-tree)"; RUN_FLAGS="--cleanup" run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'worktree cleanup skipped (not a linked worktree)' "$D/out" && [ -d "$D/work" ] \
  && ok "post-merge cleanup: run from a non-linked checkout: skip line, rc=0" \
  || bad "post-merge cleanup main tree (rc=$rc): $(tail -4 "$D/out")"

D="$(cl_setup cm-dirty)"; FAKE_DIRTY_FILE="$D/wtroot/wt/left-behind.txt" cl_run "$D" --cleanup; rc=$?
[ "$rc" -eq 0 ] && [ -d "$D/wtroot/wt" ] && grep -q 'class dirty' "$D/out" && grep -q 'to remove this merged worktree' "$D/out" \
  && ok "post-merge cleanup: a dirty worktree refuses the removal, reason printed, merge rc=0" \
  || bad "post-merge cleanup dirty (rc=$rc): $(tail -5 "$D/out")"
