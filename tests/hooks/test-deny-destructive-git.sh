#!/usr/bin/env bash
# Regression test for hooks/deny-destructive-git.sh — bash only, zero dependency
# beyond jq (which the hook itself needs to parse its stdin JSON contract; this
# test builds fixtures with printf, no jq required on the test side).
#
# Covers issue #94: remote-branch-delete equivalents (`git push --delete`/-d,
# the colon-refspec delete form, and `gh api -X DELETE`/--method DELETE on
# git/refs/heads/*) that previously passed the hook (exit 0) despite being the
# same effect class as the already-denied `git push --force` case. Every case
# is a synthetic JSON string fed to the hook's stdin — no real git/gh executed,
# no network touched.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../hooks" && pwd)"
HOOK="$SCRIPT_DIR/deny-destructive-git.sh"

pass_count=0
fail_count=0
total=0

# --- helpers -----------------------------------------------------------

# run_hook <command-string> -> prints exit code, stdout/stderr discarded
run_hook() {
  local command="$1"
  printf '%s' "{\"tool_input\":{\"command\":$(printf '%s' "$command" | jq -Rs .)}}" \
    | bash "$HOOK" >/dev/null 2>/dev/null
  echo "$?"
}

assert_exit() {
  local case_name="$1" expected="$2" actual="$3"
  total=$((total + 1))
  if [ "$actual" -eq "$expected" ]; then
    echo "PASS - $case_name (exit $actual)"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL - $case_name (expected exit $expected, got $actual)"
    fail_count=$((fail_count + 1))
  fi
}

# --- case 1: git push --delete (long flag) -> 2 -------------------------

assert_exit "git push --delete" 2 "$(run_hook "git push origin --delete feat/issue-61")"

# --- case 2: git push -d (short flag) -> 2 -------------------------------

assert_exit "git push -d (short flag)" 2 "$(run_hook "git push origin -d feat/issue-61")"

# --- case 3: git push <remote> :<ref> (colon-refspec delete) -> 2 -------

assert_exit "git push colon-refspec delete" 2 "$(run_hook "git push origin :feat/issue-61")"

# --- case 4: gh api -X DELETE .../git/refs/heads/* -> 2 -----------------
# Exact command from Theo's confirmed diagnosis.

assert_exit "gh api -X DELETE git/refs/heads" 2 \
  "$(run_hook "gh api -X DELETE repos/Zigzag968/claude-code-lgtmgate/git/refs/heads/feat/issue-61")"

# --- case 5: gh api --method DELETE (long flag form) -> 2 ---------------

assert_exit "gh api --method DELETE git/refs/heads" 2 \
  "$(run_hook "gh api --method DELETE repos/OWNER/REPO/git/refs/heads/foo")"

# --- case 6: regression — pre-existing --force-with-lease deny still 2 --

assert_exit "regression: --force-with-lease still denied" 2 \
  "$(run_hook "git push origin feat/issue-61 --force-with-lease")"

# --- case 7: compound command — deny still fires mid-chain -> 2 ---------

assert_exit "compound command: git push --delete inside &&" 2 \
  "$(run_hook "cd /tmp && git push origin --delete feat/x")"

# --- case 8: negative — plain push, no delete flag -> 0 ------------------

assert_exit "negative: plain git push" 0 "$(run_hook "git push origin feat/issue-61")"

# --- case 9: negative — gh api read (GET), no -X DELETE -> 0 ------------

assert_exit "negative: gh api GET on git/refs/heads stays allowed" 0 \
  "$(run_hook "gh api repos/OWNER/REPO/git/refs/heads/foo")"

# --- case 10: regression (#184) — cross-separator over-match, force -> 0 -
# A later command's unrelated -f flag, after a `;` separator, must not be
# misattributed to the earlier git push.

assert_exit "regression #184: -f after ; belongs to a later command" 0 \
  "$(run_hook "git push origin feat/issue-61 ; echo -f")"

# --- case 11: regression (#184) — cross-separator over-match, delete -> 0
# A later command's unrelated -d flag, after a `&&` separator, must not be
# misattributed to the earlier git push.

assert_exit "regression #184: -d after && belongs to a later command" 0 \
  "$(run_hook "git push origin feat/issue-61 && ls -d /tmp")"

# --- case 12: regression (#184) — cross-separator over-match, colon -> 0 -
# A later command's unrelated colon-prefixed token, after a `;` separator,
# must not be misattributed to the earlier git push as a colon-refspec
# delete.

assert_exit "regression #184: colon-prefixed token after ; belongs to a later command" 0 \
  "$(run_hook "git push origin feat/issue-61 ; echo :done")"

# --- case 13: git worktree remove --force -> 2 (issue #129) -------------

assert_exit "git worktree remove --force" 2 "$(run_hook "git worktree remove --force /tmp/x")"

# --- case 14: git worktree remove (no --force) -> 2 (issue #129) --------
# The risk exists even without --force on a "clean" worktree.

assert_exit "git worktree remove (no --force)" 2 "$(run_hook "git worktree remove /tmp/x")"

# --- case 15: git worktree prune -> 2 (issue #129) -----------------------

assert_exit "git worktree prune" 2 "$(run_hook "git worktree prune")"

# --- case 16: git worktree prune --expire now -> 2 (issue #129) ---------

assert_exit "git worktree prune --expire now" 2 "$(run_hook "git worktree prune --expire now")"

# --- case 17: negative — git worktree add stays allowed -> 0 ------------
# Legitimate Lead/provisioning usage must never be broken by this hook.

assert_exit "negative: git worktree add" 0 "$(run_hook "git worktree add -B feat/issue-61 /tmp/x")"

# --- case 18: negative — git worktree list stays allowed -> 0 -----------

assert_exit "negative: git worktree list" 0 "$(run_hook "git worktree list")"

# --- case 19: compound command — worktree remove deny still fires -> 2 --
# Same style as case 7: deny must still trigger mid-chain.

assert_exit "compound command: git worktree remove --force inside &&" 2 \
  "$(run_hook "cd /tmp && git worktree remove --force /tmp/x")"

# --- cases 20+: git reset --hard anchored on token boundaries (#41) ------

assert_exit "reset --hard bare" 2 "$(run_hook "git reset --hard")"
assert_exit "reset --hard HEAD~1" 2 "$(run_hook "git reset --hard HEAD~1")"
assert_exit "git -C path reset --hard" 2 "$(run_hook "git -C /tmp/x reset --hard")"
assert_exit "reset --hard after &&" 2 "$(run_hook "cd /tmp && git reset --hard")"
assert_exit "reset --hard; trailing semicolon" 2 "$(run_hook "git reset --hard;")"
assert_exit "reset --hard;; trailing" 2 "$(run_hook "git reset --hard;;")"
assert_exit "reset --hard&&ls no space" 2 "$(run_hook "git reset --hard&&ls")"
assert_exit "reset --hard|cat pipe" 2 "$(run_hook "git reset --hard|cat")"
assert_exit "reset --hard in subshell" 2 "$(run_hook "(git reset --hard)")"
assert_exit "reset --hard in bash -c quotes" 2 "$(run_hook 'bash -c "git reset --hard"')"

assert_exit "reset --soft; echo --hard is allowed" 0 "$(run_hook "git reset --soft HEAD; echo --hard")"
assert_exit "reset HEAD;echo --hard is allowed" 0 "$(run_hook "git reset HEAD;echo --hard")"
assert_exit "reset HEAD && rm x --hard is allowed" 0 "$(run_hook "git reset HEAD && rm x --hard")"
assert_exit "reset --soft HEAD~1 is allowed" 0 "$(run_hook "git reset --soft HEAD~1")"
assert_exit "reset HEAD file is allowed" 0 "$(run_hook "git reset HEAD file.txt")"
assert_exit "reset --hardware is allowed" 0 "$(run_hook "git reset --hardware")"

# --- cases: sanctioned cleanup script + bare recursive rm of a worktree (#34/#35) --
# The worktree root is pinned via the env so the rm rule is deterministic.

export LGTMGATE_WORKTREE_ROOT=/tmp/lgtmgate-wt-root

assert_exit "cleanup-worktree script allowed" 0 \
  "$(run_hook "bash scripts/cleanup-worktree.sh /tmp/lgtmgate-wt-root/issue-9")"

# No name-based early exit: a compound that smuggles a raw removal stays denied.
assert_exit "cleanup-worktree.sh; git worktree remove compound still denied" 2 \
  "$(run_hook "bash scripts/cleanup-worktree.sh /tmp/lgtmgate-wt-root/issue-9; git worktree remove --force /tmp/x")"

assert_exit "bare rm -rf of a worktree denied" 2 \
  "$(run_hook "rm -rf /tmp/lgtmgate-wt-root/issue-9")"
assert_exit "bare rm -rf -- of a worktree (trailing slash) denied" 2 \
  "$(run_hook "rm -rf -- /tmp/lgtmgate-wt-root/issue-9/")"
assert_exit "cd && rm -R of a worktree denied" 2 \
  "$(run_hook "cd /tmp && rm -R /tmp/lgtmgate-wt-root/issue-9")"
assert_exit "rm -r of a worktree followed by ; denied" 2 \
  "$(run_hook "rm -r /tmp/lgtmgate-wt-root/issue-9; ls")"

assert_exit "rm -rf inside a worktree (node_modules) allowed" 0 \
  "$(run_hook "rm -rf /tmp/lgtmgate-wt-root/issue-9/node_modules")"
assert_exit "rm -rf of an unrelated dir allowed" 0 \
  "$(run_hook "rm -rf /tmp/other/dir")"
assert_exit "rm -rf of a sibling with the root as name prefix allowed" 0 \
  "$(run_hook "rm -rf /tmp/lgtmgate-wt-root-other/issue-9")"
assert_exit "non-recursive rm under the root allowed" 0 \
  "$(run_hook "rm /tmp/lgtmgate-wt-root/issue-9")"

# --- cases: phrase only appears as text in -m/--body/heredoc arguments (#111) --
# Phrases are built by concatenation so this file never carries the literal phrase.

RS="git re""set --ha""rd"
CL="git cl""ean -f""d"
NL=$'\n'

assert_exit "#111 commit -m single-quoted phrase allowed" 0 "$(run_hook "git commit -m 'fix: mentions $RS in text'")"
assert_exit "#111 commit -m double-quoted phrase allowed" 0 "$(run_hook "git commit -m \"fix: mentions $RS in text\"")"
assert_exit "#111 commit --message= phrase allowed" 0 "$(run_hook "git commit --message=\"docs: $CL\"")"
assert_exit "#111 gh pr create --body phrase allowed" 0 "$(run_hook "gh pr create --title 'x' --body 'never run $RS'")"
assert_exit "#111 heredoc body (cat) phrase allowed" 0 "$(run_hook "cat > f.md <<'EOF'${NL}run $RS${NL}EOF")"
assert_exit "#111 commit -m with heredoc substitution phrase allowed" 0 \
  "$(run_hook "git commit -m \"\$(cat <<'EOF'${NL}docs: $RS${NL}EOF${NL})\"")"

assert_exit "#111 bare reset hard still denied" 2 "$(run_hook "$RS")"
assert_exit "#111 bare clean still denied" 2 "$(run_hook "$CL")"
assert_exit "#111 commit -m then executed phrase denied" 2 "$(run_hook "git commit -m 'x' && $RS")"
assert_exit "#111 bash -c executed phrase denied" 2 "$(run_hook "bash -c \"$RS\"")"
assert_exit "#111 command substitution in -m denied" 2 "$(run_hook "git commit -m \"\$($RS)\"")"
assert_exit "#111 shell heredoc body denied" 2 "$(run_hook "bash <<'EOF'${NL}$RS${NL}EOF")"
assert_exit "#111 command after heredoc terminator denied" 2 "$(run_hook "cat <<'EOF'${NL}text${NL}EOF${NL}$RS")"

# --- summary -------------------------------------------------------------

echo "${pass_count}/${total} PASS"
[ "$fail_count" -eq 0 ] || exit 1
exit 0
