#!/usr/bin/env bash
# Offline regression test for templates/provision-worktree.sh (claude-agent-pipeline#53 + #72),
# exercising the REAL script (not a stub) against throwaway git worktrees under $TMPDIR — the
# only level at which the containment-reorder (#53) and the PROVISION_ENV_SYMLINK seam (#72)
# can be proven, since templates/test-deliver-pipeline.js only asserts the composed COMMAND
# STRING (provisionCmdPreview), never runs the shell logic itself.
#
# Covers: #53 hostile-symlink rejection (a pre-existing symlinked intermediate directory in the
# worktree must not let a link escape it, and must leave no residual directory behind — the bug
# this fix closes: mkdir -p ran BEFORE the containment check) + #53 happy-path non-regression
# (an ordinary link still succeeds); #72 forbidden skips the implicit .env link + #72 default
# (unset) non-regression (implicit .env link still created).
#
# Fixtures are created fresh per case under mktemp -d and intentionally left in place afterwards
# — nothing in this file deletes them (.claude/rules/pr-acceptance.md: scratch vs in-place
# deletion), style modeled on tests/templates/test-blocked-by-check.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../templates" && pwd)"
PROVISION="$SCRIPT_DIR/provision-worktree.sh"
FIXTURE_ROOT="${FIXTURE_ROOT:-${TMPDIR:-/tmp}}"

pass_count=0
fail_count=0
total=0

# --- helpers -----------------------------------------------------------

# new_git_pair -> prints "<main_dir> <wt_dir>" — a real MAIN repo + a real linked worktree,
# both fresh under mktemp, so dir_contained's `cd`/`pwd -P` machinery has real git-worktree
# state to resolve (git -C <worktree> rev-parse --git-common-dir must succeed).
new_git_pair() {
  local root main worktree
  root="$(mktemp -d -p "$FIXTURE_ROOT" "provision-test.XXXXXX")"
  main="$root/main"
  worktree="$root/wt"
  mkdir -p "$main"
  git -C "$main" init -q
  git -C "$main" config user.email "test@example.com"
  git -C "$main" config user.name "Test"
  git -C "$main" commit -q --allow-empty -m "init"
  git -C "$main" worktree add -q "$worktree" -b "wt-branch-$(basename "$root")" >/dev/null
  printf '%s %s\n' "$main" "$worktree"
}

# assert_case <name> <0-or-1: condition already evaluated true/false> <detail>
# `ok` must be the LITERAL string "true" or "false" (never a compound string) — every
# comparison feeding into it is done by the caller BEFORE calling this, so this function
# never itself evaluates a `[ ... ]` against caller-composed text (that indirection is what
# caused a silent false-PASS bug during development: a non-numeric string fed into `-eq`/`-ne`
# makes `[` itself error out, which bash treats as a false `if` condition — masking a real
# failure as a pass).
assert_case() {
  local case_name="$1" ok="$2" detail="$3"
  total=$((total + 1))
  if [ "$ok" = "true" ]; then
    echo "PASS - $case_name ($detail)"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL - $case_name ($detail)"
    fail_count=$((fail_count + 1))
  fi
}

bool() { if "$@"; then echo true; else echo false; fi; }

# --- case 1: #53 hostile-symlink rejection — no residual dir created outside WORKTREE ------------
#
# dst "escaped/newdir/target" where "escaped" is a symlink OUT of the worktree (pointing at a
# sibling directory) and "newdir" does NOT yet exist under it. This is the shape that actually
# exercises the #53 ordering bug: `dirname(abs_dst)` = "$wt1/escaped/newdir" does not exist, so
# `mkdir -p "$(dirname "$abs_dst")"` — when it ran BEFORE the containment check (pre-fix) —
# actually created "newdir" INSIDE the escaped (outside-WORKTREE) location before the check ever ran.
# Post-fix, existing_ancestor() walks up to the nearest existing ancestor ("$wt1/escaped", which
# resolves outside WORKTREE via the symlink) and dir_contained() rejects it BEFORE any mkdir happens,
# so no "newdir" is ever created outside the worktree. Verified this session: reverting the #53
# fix makes this case observe residual=yes (a real regression-detection, not just a green light).

pair1="$(new_git_pair)"
main1="${pair1% *}"; wt1="${pair1#* }"
outside1="$(dirname "$wt1")/outside-$(basename "$wt1")"
mkdir -p "$outside1"
ln -s "$outside1" "$wt1/escaped"
echo "hostile-src-content" > "$main1/hostile.txt"

out1="$(bash "$PROVISION" "$wt1" "hostile.txt" "escaped/newdir/target" 2>&1)"
exit1=$?
rejected1="$(bool test "$exit1" -eq 2)"
reported1="$(bool bash -c 'printf "%s" "$1" | grep -q "destination escapes WT"' _ "$out1")"
no_residual1="$(bool test ! -e "$outside1/newdir")"
ok1="false"
[ "$rejected1" = "true" ] && [ "$reported1" = "true" ] && [ "$no_residual1" = "true" ] && ok1="true"
assert_case "#53 hostile symlinked dst rejected, no residual dir created outside WORKTREE" "$ok1" \
  "exit=$exit1 (want 2), reported=$reported1, no_residual=$no_residual1"

# --- case 2: #53 happy-path non-regression — an ordinary nested link still works ------------

pair2="$(new_git_pair)"
main2="${pair2% *}"; wt2="${pair2#* }"
mkdir -p "$main2/nested/dir"
echo "real-content" > "$main2/nested/dir/file.txt"

out2="$(bash "$PROVISION" "$wt2" "nested/dir" "linked/dir" 2>&1)"
exit2=$?
linked2="$(bool bash -c 'printf "%s" "$1" | grep -q "^LINKED "' _ "$out2")"
resolves2="$(bool test -e "$wt2/linked/dir/file.txt")"
ok2="false"
[ "$exit2" -eq 0 ] && [ "$linked2" = "true" ] && [ "$resolves2" = "true" ] && ok2="true"
assert_case "#53 ordinary nested link non-regression" "$ok2" \
  "exit=$exit2 (want 0), linked_line=$linked2, resolves_to_real_content=$resolves2"

# --- case 3: #72 forbidden skips the implicit .env link ---------------------

pair3="$(new_git_pair)"
main3="${pair3% *}"; wt3="${pair3#* }"
echo "SECRET=1" > "$main3/.env"

PROVISION_ENV_SYMLINK=forbidden bash "$PROVISION" "$wt3" >/dev/null 2>&1
exit3=$?
no_env3="$(bool test ! -e "$wt3/.env")"
ok3="false"
[ "$exit3" -eq 0 ] && [ "$no_env3" = "true" ] && ok3="true"
assert_case "#72 PROVISION_ENV_SYMLINK=forbidden skips implicit .env link" "$ok3" \
  "exit=$exit3 (want 0), .env_absent=$no_env3"

# --- case 4: #72 default (unset) non-regression — implicit .env link still made ------------

pair4="$(new_git_pair)"
main4="${pair4% *}"; wt4="${pair4#* }"
echo "SECRET=1" > "$main4/.env"

bash "$PROVISION" "$wt4" >/dev/null 2>&1
exit4=$?
env_linked4="$(bool test -L "$wt4/.env")"
ok4="false"
[ "$exit4" -eq 0 ] && [ "$env_linked4" = "true" ] && ok4="true"
assert_case "#72 default (unset PROVISION_ENV_SYMLINK) implicit .env link non-regression" "$ok4" \
  "exit=$exit4 (want 0), .env_linked=$env_linked4"

# --- case 5: #82 PROVISION-VERSION:2 is the first stdout line (also on a usage-error path) ----

pair5="$(new_git_pair)"
wt5="${pair5#* }"
first5="$(bash "$PROVISION" "$wt5" 2>/dev/null | head -n 1)"
first5b="$(bash "$PROVISION" 2>/dev/null | head -n 1)"
ok5="false"
[ "$first5" = "PROVISION-VERSION:2" ] && [ "$first5b" = "PROVISION-VERSION:2" ] && ok5="true"
assert_case "#82 PROVISION-VERSION:2 is the first stdout line on every path" "$ok5" \
  "normal='$first5', usage-error='$first5b'"

# --- summary -------------------------------------------------------------

status="ok"
[ "$fail_count" -eq 0 ] || status="fail"
echo "[test-provision-worktree] status=${status} passed=${pass_count} failed=${fail_count}"
[ "$fail_count" -eq 0 ] || exit 1
exit 0
