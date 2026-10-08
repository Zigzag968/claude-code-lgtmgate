#!/usr/bin/env bash
# Regression test for scripts/cleanup-worktree.sh — bash + git only. Builds a temp repo and
# linked worktrees under $TMPDIR, exports LGTMGATE_WORKTREE_ROOT, and puts a stub `gh` first
# on PATH (its `pr view` answer comes from FAKE_PR_STATE). No network, no real gh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../scripts" && pwd)"
SCRIPT="$SCRIPT_DIR/cleanup-worktree.sh"

TMP_BASE="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
WORK="$(mktemp -d "$TMP_BASE/cleanup-wt-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

MAIN="$WORK/main"
ROOT="$WORK/root"
BIN="$WORK/bin"
mkdir -p "$MAIN" "$ROOT" "$BIN"

# Stub gh: `gh pr view <branch> --json state --jq .state` -> $FAKE_PR_STATE
cat >"$BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_PR_STATE:-OPEN}"
STUB
chmod +x "$BIN/gh"

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export LGTMGATE_WORKTREE_ROOT="$ROOT"
export PATH="$BIN:$PATH"

git -C "$MAIN" init -q -b main
git -C "$MAIN" commit -q --allow-empty -m init

mkwt() { git -C "$MAIN" worktree add -q -b "feat/$1" "$ROOT/$1" main; }

pass_count=0
fail_count=0
total=0

check() {
  local name="$1" ok="$2"
  total=$((total + 1))
  if [ "$ok" -eq 1 ]; then echo "PASS - $name"; pass_count=$((pass_count + 1))
  else echo "FAIL - $name"; fail_count=$((fail_count + 1)); fi
}

# run_script <cwd> <path> -> sets RC and OUT
run_script() {
  OUT="$(cd "$1" && bash "$SCRIPT" "$2" 2>&1)"; RC=$?
}

# --- refusal cases (each leaves the target in place) ------------------------------

mkwt wt-open
export FAKE_PR_STATE=MERGED

# outside root
OUTSIDE="$WORK/outside"
git -C "$MAIN" worktree add -q -b feat/outside "$OUTSIDE" main
run_script "$MAIN" "$OUTSIDE"
check "refuses a worktree outside the root" "$([ "$RC" -eq 1 ] && [ -d "$OUTSIDE" ] && echo 1 || echo 0)"

# main tree
# (root widened to $WORK so the main tree passes the root guard and hits the main-tree guard)
LGTMGATE_WORKTREE_ROOT="$WORK" run_script "$WORK" "$MAIN"
check "refuses the main tree" "$([ "$RC" -eq 1 ] && [ -d "$MAIN/.git" ] && printf '%s' "$OUT" | grep -q 'main tree' && echo 1 || echo 0)"

# unregistered directory under the root
mkdir -p "$ROOT/not-a-worktree"
run_script "$MAIN" "$ROOT/not-a-worktree"
check "refuses an unregistered directory" "$([ "$RC" -eq 1 ] && [ -d "$ROOT/not-a-worktree" ] && echo 1 || echo 0)"

# missing path
run_script "$MAIN" "$ROOT/does-not-exist"
check "refuses a missing path" "$([ "$RC" -eq 1 ] && echo 1 || echo 0)"

# cwd inside the path
run_script "$ROOT/wt-open" "$ROOT/wt-open"
check "refuses when cwd is inside the worktree" "$([ "$RC" -eq 1 ] && [ -d "$ROOT/wt-open" ] && echo 1 || echo 0)"

# dirty tree
mkwt wt-dirty
: >"$ROOT/wt-dirty/untracked.txt"
run_script "$MAIN" "$ROOT/wt-dirty"
check "refuses a dirty worktree" "$([ "$RC" -eq 1 ] && [ -d "$ROOT/wt-dirty" ] && echo 1 || echo 0)"

# PR not merged
FAKE_PR_STATE=OPEN run_script "$MAIN" "$ROOT/wt-open"
check "refuses when the PR is not MERGED (worktree still present)" "$([ "$RC" -eq 1 ] && [ -d "$ROOT/wt-open" ] && echo 1 || echo 0)"

# --- happy path --------------------------------------------------------------------

mkwt wt-done
run_script "$MAIN" "$ROOT/wt-done"
check "merged + clean worktree is removed and REMOVED is printed" \
  "$([ "$RC" -eq 0 ] && [ ! -d "$ROOT/wt-done" ] && printf '%s' "$OUT" | grep -q '^REMOVED ' && echo 1 || echo 0)"
check "removed worktree is no longer registered" \
  "$(git -C "$MAIN" worktree list --porcelain | grep -q 'wt-done' && echo 0 || echo 1)"

# --- static guard: never --force ---------------------------------------------------

check "script never passes --force to worktree remove" \
  "$(grep -E 'worktree remove' "$SCRIPT" | grep -vE '^[[:space:]]*#' | grep -q -- '--force' && echo 0 || echo 1)"

echo "${pass_count}/${total} PASS"
[ "$fail_count" -eq 0 ] || exit 1
exit 0
