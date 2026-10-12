#!/usr/bin/env bash
# Regression test for scripts/cleanup-worktree.sh (and the classification of scripts/lib/worktree-state.sh, #168) — bash + git + jq.
# Builds a temp repo and linked worktrees under $TMPDIR, exports LGTMGATE_WORKTREE_ROOT, and puts a stub `gh` first on PATH:
# `gh api ... --jq EXPR` pipes a canned pulls JSON ($FAKE_PULLS, or the file $PULLS_DIR/<branch with / as _>) through the real
# `jq -r EXPR`; FAKE_GH_FAIL=1 makes it fail. No network, no real gh.
# Also covers the consumer layout: the script run from a plugin folder on a repo without scripts/.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../scripts" && pwd)"
SCRIPT="$SCRIPT_DIR/cleanup-worktree.sh"

TMP_BASE="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
WORK="$(mktemp -d "$TMP_BASE/cleanup-wt-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

MAIN="$WORK/main"
ROOT="$WORK/root"
BIN="$WORK/bin"
PULLS_DIR="$WORK/pulls"
mkdir -p "$MAIN" "$ROOT" "$BIN" "$PULLS_DIR"
export PULLS_DIR

# Stub gh: `gh api <endpoint> --jq <expr>` -> canned pulls JSON through the real jq.
cat >"$BIN/gh" <<'STUB'
#!/usr/bin/env bash
[ "${FAKE_GH_FAIL:-0}" -eq 0 ] || { echo "gh: HTTP 502" >&2; exit 1; }
[ "$1" = "api" ] || { echo "stub gh: unexpected: $*" >&2; exit 99; }
b="${2#*head=}"; b="${b#*:}"; b="${b%%&*}"
f="$PULLS_DIR/$(printf '%s' "$b" | tr '/' '_')"
if [ -f "$f" ]; then json="$(cat "$f")"; else json="${FAKE_PULLS:-[]}"; fi
expr=""
while [ $# -gt 0 ]; do if [ "$1" = "--jq" ]; then expr="$2"; fi; shift; done
printf '%s' "$json" | jq -r "$expr"
STUB
chmod +x "$BIN/gh"

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export LGTMGATE_WORKTREE_ROOT="$ROOT"
export PATH="$BIN:$PATH"

pulls_json() { # merged | closed | open | none
  case "$1" in
    merged) echo '[{"number":3,"state":"closed","merged_at":"2026-01-01T00:00:00Z"}]' ;;
    closed) echo '[{"number":3,"state":"closed","merged_at":null}]' ;;
    open) echo '[{"number":3,"state":"open","merged_at":null}]' ;;
    *) echo '[]' ;;
  esac
}

git -C "$MAIN" init -q -b main
git -C "$MAIN" commit -q --allow-empty -m init

mkwt() { git -C "$MAIN" worktree add -q -b "feat/$1" "$ROOT/$1" main; }
commit_in() { git -C "$1" commit -q --allow-empty -m "work"; } # a commit of its own on the worktree's branch
branch_exists() { git -C "$MAIN" show-ref --verify --quiet "refs/heads/$1"; }

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
export FAKE_PULLS="$(pulls_json merged)"

# outside root
OUTSIDE="$WORK/outside"
git -C "$MAIN" worktree add -q -b feat/outside "$OUTSIDE" main
run_script "$MAIN" "$OUTSIDE"
check "refusal outside-root: a worktree outside the root is refused and stays" \
  "$([ "$RC" -eq 1 ] && [ -d "$OUTSIDE" ] && printf '%s' "$OUT" | grep -q 'not under the worktree root' && echo 1 || echo 0)"

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

# usage errors
OUT="$(cd "$MAIN" && bash "$SCRIPT" 2>&1)"; RC=$?
check "no argument is a usage error (exit 2)" "$([ "$RC" -eq 2 ] && echo 1 || echo 0)"
OUT="$(cd "$MAIN" && bash "$SCRIPT" --class bogus 2>&1)"; RC=$?
check "--class with an unknown class is a usage error (exit 2)" "$([ "$RC" -eq 2 ] && echo 1 || echo 0)"
OUT="$(cd "$MAIN" && bash "$SCRIPT" --dry-run "$ROOT/wt-open" 2>&1)"; RC=$?
check "--dry-run without --class is a usage error (exit 2)" "$([ "$RC" -eq 2 ] && [ -d "$ROOT/wt-open" ] && echo 1 || echo 0)"

# dirty tree
mkwt wt-dirty
: >"$ROOT/wt-dirty/untracked.txt"
run_script "$MAIN" "$ROOT/wt-dirty"
check "refusal dirty: uncommitted or untracked changes keep the worktree (class named)" \
  "$([ "$RC" -eq 1 ] && [ -d "$ROOT/wt-dirty" ] && printf '%s' "$OUT" | grep -q 'class dirty' && echo 1 || echo 0)"

# PR still open
FAKE_PULLS="$(pulls_json open)" run_script "$MAIN" "$ROOT/wt-open"
check "refusal open-pr: an open PR keeps the worktree (class named)" \
  "$([ "$RC" -eq 1 ] && [ -d "$ROOT/wt-open" ] && printf '%s' "$OUT" | grep -q 'class open-pr' && echo 1 || echo 0)"

# PR state unreadable
FAKE_GH_FAIL=1 run_script "$MAIN" "$ROOT/wt-open"
check "refusal unknown: a failed PR lookup keeps the worktree (class named)" \
  "$([ "$RC" -eq 1 ] && [ -d "$ROOT/wt-open" ] && printf '%s' "$OUT" | grep -q 'class unknown' && echo 1 || echo 0)"

# no PR, commits ahead of the base
mkwt wt-ahead
commit_in "$ROOT/wt-ahead"
FAKE_PULLS="$(pulls_json none)" run_script "$MAIN" "$ROOT/wt-ahead"
check "refusal ahead: no PR and a commit ahead of the base keeps the worktree and the branch" \
  "$([ "$RC" -eq 1 ] && [ -d "$ROOT/wt-ahead" ] && branch_exists feat/wt-ahead && printf '%s' "$OUT" | grep -q 'class ahead' && echo 1 || echo 0)"

# run in flight: state file in the main tree
git -C "$MAIN" worktree add -q -b feat/issue-77 "$ROOT/wt-flight" main
mkdir -p "$MAIN/.pipeline"
printf '{"status":"dev"}\n' >"$MAIN/.pipeline/issue-77.json"
run_script "$MAIN" "$ROOT/wt-flight"
check "refusal in-flight: a run in flight (state file status dev) keeps the worktree, even merged" \
  "$([ "$RC" -eq 1 ] && [ -d "$ROOT/wt-flight" ] && printf '%s' "$OUT" | grep -q 'class in-flight' && echo 1 || echo 0)"

# run in flight: no state file, a fresh file under <worktree>/.pipeline
mkwt wt-flight2
mkdir -p "$ROOT/wt-flight2/.pipeline"
: >"$ROOT/wt-flight2/.pipeline/activity.json"
run_script "$MAIN" "$ROOT/wt-flight2"
check "refusal in-flight: no state file but a fresh file under the worktree .pipeline keeps it" \
  "$([ "$RC" -eq 1 ] && [ -d "$ROOT/wt-flight2" ] && printf '%s' "$OUT" | grep -q 'class in-flight' && echo 1 || echo 0)"

# --- removable classes -------------------------------------------------------------

# merged: the branch is merged into main, so branch -d deletes it
mkwt wt-done
commit_in "$ROOT/wt-done"
git -C "$MAIN" merge -q --no-ff -m "merge wt-done" feat/wt-done
run_script "$MAIN" "$ROOT/wt-done"
check "class merged: a merged clean worktree is removed, REMOVED printed, the merged branch deleted" \
  "$([ "$RC" -eq 0 ] && [ ! -d "$ROOT/wt-done" ] && printf '%s' "$OUT" | grep -q '^REMOVED ' && printf '%s' "$OUT" | grep -q '^BRANCH-DELETED feat/wt-done' && ! branch_exists feat/wt-done && echo 1 || echo 0)"
check "removed worktree is no longer registered" \
  "$(git -C "$MAIN" worktree list --porcelain | grep -q 'wt-done' && echo 0 || echo 1)"

# merged, with a finished run state file: not in flight
git -C "$MAIN" worktree add -q -b feat/issue-78 "$ROOT/wt-finished" main
printf '{"status":"merged"}\n' >"$MAIN/.pipeline/issue-78.json"
run_script "$MAIN" "$ROOT/wt-finished"
check "class merged: a terminal run state file does not block the removal" \
  "$([ "$RC" -eq 0 ] && [ ! -d "$ROOT/wt-finished" ] && echo 1 || echo 0)"

# merged but git branch -d refuses (the branch carries a commit main does not have): the worktree goes, the branch stays
mkwt wt-unsynced
commit_in "$ROOT/wt-unsynced"
run_script "$MAIN" "$ROOT/wt-unsynced"
check "class merged: a branch -d refusal prints BRANCH-KEPT and is not an error" \
  "$([ "$RC" -eq 0 ] && [ ! -d "$ROOT/wt-unsynced" ] && printf '%s' "$OUT" | grep -q '^BRANCH-KEPT feat/wt-unsynced' && branch_exists feat/wt-unsynced && echo 1 || echo 0)"

# closed unmerged, with a commit of its own: removed, the branch is never touched
mkwt wt-closed
commit_in "$ROOT/wt-closed"
FAKE_PULLS="$(pulls_json closed)" run_script "$MAIN" "$ROOT/wt-closed"
check "class closed-unmerged: the worktree is removed and the branch with its commit is kept" \
  "$([ "$RC" -eq 0 ] && [ ! -d "$ROOT/wt-closed" ] && printf '%s' "$OUT" | grep -q '^BRANCH-KEPT feat/wt-closed' && branch_exists feat/wt-closed && echo 1 || echo 0)"

# no PR and nothing ahead: removed, the empty branch deleted
mkwt wt-empty
FAKE_PULLS="$(pulls_json none)" run_script "$MAIN" "$ROOT/wt-empty"
check "class no-pr-empty: no PR and no commit ahead is removed, the empty branch deleted" \
  "$([ "$RC" -eq 0 ] && [ ! -d "$ROOT/wt-empty" ] && printf '%s' "$OUT" | grep -q '^BRANCH-DELETED feat/wt-empty' && ! branch_exists feat/wt-empty && echo 1 || echo 0)"

# --- --class mode (own repo and root: only the worktrees built here) ------------------

MAIN2="$WORK/main2"
ROOT2="$WORK/root2"
mkdir -p "$MAIN2" "$ROOT2"
git -C "$MAIN2" init -q -b main
git -C "$MAIN2" commit -q --allow-empty -m init
export LGTMGATE_WORKTREE_ROOT="$ROOT2"
mkwt2() { git -C "$MAIN2" worktree add -q -b "feat/$1" "$ROOT2/$1" main; }
setpr() { pulls_json "$2" >"$PULLS_DIR/feat_$1"; } # setpr <name> <kind>
unset FAKE_PULLS
rm -f "$PULLS_DIR"/*

mkwt2 k-merged; setpr k-merged merged
mkwt2 k-closed; setpr k-closed closed; commit_in "$ROOT2/k-closed"
mkwt2 k-empty; setpr k-empty none
mkwt2 k-dirty; setpr k-dirty merged; : >"$ROOT2/k-dirty/x.txt"
mkwt2 k-open; setpr k-open open

OUT="$(cd "$MAIN2" && bash "$SCRIPT" --class closed-unmerged --dry-run 2>&1)"; RC=$?
check "class closed-unmerged: --dry-run lists the closed worktree and removes nothing" \
  "$([ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "^WOULD-REMOVE $ROOT2/k-closed\$" && [ "$(printf '%s\n' "$OUT" | grep -c '^WOULD-REMOVE')" -eq 1 ] && [ -d "$ROOT2/k-closed" ] && [ -d "$ROOT2/k-merged" ] && echo 1 || echo 0)"

OUT="$(cd "$MAIN2" && bash "$SCRIPT" --class all 2>&1)"; RC=$?
check "class all: --class all removes merged, closed-unmerged and no-pr-empty and leaves dirty and open-pr" \
  "$([ "$RC" -eq 0 ] && [ ! -d "$ROOT2/k-merged" ] && [ ! -d "$ROOT2/k-closed" ] && [ ! -d "$ROOT2/k-empty" ] && [ -d "$ROOT2/k-dirty" ] && [ -d "$ROOT2/k-open" ] && printf '%s' "$OUT" | grep -q '^REMOVED 3, REFUSED 0$' && echo 1 || echo 0)"

# a candidate whose guard refuses (cwd inside it) is counted and sets exit 1; the others still go
mkwt2 k-cwd; setpr k-cwd merged
mkwt2 k-other; setpr k-other merged
OUT="$(cd "$ROOT2/k-cwd" && bash "$SCRIPT" --class merged 2>&1)"; RC=$?
check "class merged: --class counts a refused candidate (exit 1) and still removes the others" \
  "$([ "$RC" -eq 1 ] && [ -d "$ROOT2/k-cwd" ] && [ ! -d "$ROOT2/k-other" ] && printf '%s' "$OUT" | grep -q '^REMOVED 1, REFUSED 1$' && echo 1 || echo 0)"
export LGTMGATE_WORKTREE_ROOT="$ROOT"

# --- consumer layout: script called from a plugin folder, repo has no scripts/ ------

PLUGIN="$WORK/plugin"
mkdir -p "$PLUGIN/scripts/lib" "$PLUGIN/hooks"
cp "$SCRIPT" "$PLUGIN/scripts/cleanup-worktree.sh"
cp "$SCRIPT_DIR/lib/worktree-state.sh" "$PLUGIN/scripts/lib/worktree-state.sh"
cp "$SCRIPT_DIR/../hooks/lib-worktree-root.sh" "$PLUGIN/hooks/lib-worktree-root.sh"
CONSUMER="$WORK/consumer"
mkdir -p "$CONSUMER"
git -C "$CONSUMER" init -q -b main
git -C "$CONSUMER" commit -q --allow-empty -m init
git -C "$CONSUMER" worktree add -q -b feat/wt-consumer "$ROOT/wt-consumer" main
OUT="$(cd "$CONSUMER" && export CLAUDE_PLUGIN_ROOT="$PLUGIN" FAKE_PULLS="$(pulls_json merged)" && bash "$CLAUDE_PLUGIN_ROOT/scripts/cleanup-worktree.sh" "$ROOT/wt-consumer" 2>&1)"; RC=$?
printf '%s\n' "$OUT"
check "consumer layout: script called from the plugin folder removes a merged clean worktree" \
  "$([ "$RC" -eq 0 ] && [ ! -e "$CONSUMER/scripts/cleanup-worktree.sh" ] && [ ! -d "$ROOT/wt-consumer" ] && printf '%s' "$OUT" | grep -q '^REMOVED ' && echo 1 || echo 0)"

# --- static guards: never --force, never branch -D, no GraphQL ------------------------

check "script never passes --force to worktree remove" \
  "$(grep -E 'worktree remove' "$SCRIPT" | grep -vE '^[[:space:]]*#' | grep -q -- '--force' && echo 0 || echo 1)"
for f in cleanup-worktree.sh worktree-inventory.sh lib/worktree-state.sh lib/post-merge-cleanup.sh; do
  check "static guard: $f has no --force, no branch -D, no GraphQL call" \
    "$(grep -vE '^[[:space:]]*#' "$SCRIPT_DIR/$f" | grep -qE -- '--force|branch -D|gh (pr|issue|project) ' && echo 0 || echo 1)"
done

echo "${pass_count}/${total} PASS"
[ "$fail_count" -eq 0 ] || exit 1
exit 0
