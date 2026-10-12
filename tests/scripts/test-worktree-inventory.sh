#!/usr/bin/env bash
# Regression test for scripts/worktree-inventory.sh (#168) — bash + git + jq, offline. A throwaway repo gets one worktree per
# class (merged, closed-unmerged, no-pr-empty, ahead, dirty, in-flight, open-pr, detached) plus one outside the root; a stub `gh`
# answers the REST pulls lookup from $PULLS_DIR/<branch with / as _> through the real jq. Asserts the CLASS, PR, TREE, AHEAD,
# RUN columns of each line, that nothing is removed, and that -C lists the worktrees of another repository.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../scripts" && pwd)"
SCRIPT="$SCRIPT_DIR/worktree-inventory.sh"

TMP_BASE="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
WORK="$(mktemp -d "$TMP_BASE/wt-inventory-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

MAIN="$WORK/main"
OTHER="$WORK/other"
ROOT="$WORK/root"
BIN="$WORK/bin"
PULLS_DIR="$WORK/pulls"
mkdir -p "$MAIN" "$OTHER" "$ROOT" "$BIN" "$PULLS_DIR"
export PULLS_DIR

cat >"$BIN/gh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "api" ] || { echo "stub gh: unexpected: $*" >&2; exit 99; }
b="${2#*head=}"; b="${b#*:}"; b="${b%%&*}"
f="$PULLS_DIR/$(printf '%s' "$b" | tr '/' '_')"
json='[]'; [ -f "$f" ] && json="$(cat "$f")"
expr=""
while [ $# -gt 0 ]; do if [ "$1" = "--jq" ]; then expr="$2"; fi; shift; done
printf '%s' "$json" | jq -r "$expr"
STUB
chmod +x "$BIN/gh"

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export LGTMGATE_WORKTREE_ROOT="$ROOT"
export PATH="$BIN:$PATH"

pulls_json() {
  case "$1" in
    merged) echo '[{"number":3,"state":"closed","merged_at":"2026-01-01T00:00:00Z"}]' ;;
    closed) echo '[{"number":3,"state":"closed","merged_at":null}]' ;;
    open) echo '[{"number":3,"state":"open","merged_at":null}]' ;;
    *) echo '[]' ;;
  esac
}
setpr() { pulls_json "$2" >"$PULLS_DIR/feat_$1"; } # setpr <branch suffix> <kind>

git -C "$MAIN" init -q -b main
git -C "$MAIN" commit -q --allow-empty -m init
mkwt() { git -C "$MAIN" worktree add -q -b "feat/$1" "$ROOT/$1" main; }
commit_in() { git -C "$1" commit -q --allow-empty -m work; }

mkwt merged; setpr merged merged
mkwt closed; setpr closed closed; commit_in "$ROOT/closed"
mkwt empty; setpr empty none
mkwt ahead; setpr ahead none; commit_in "$ROOT/ahead"
mkwt dirty; setpr dirty merged; : >"$ROOT/dirty/untracked.txt"
mkwt open; setpr open open
git -C "$MAIN" worktree add -q -b feat/issue-55 "$ROOT/flight" main; setpr issue-55 merged
mkdir -p "$MAIN/.pipeline"; printf '{"status":"review"}\n' >"$MAIN/.pipeline/issue-55.json"
git -C "$MAIN" worktree add -q --detach "$ROOT/detached" main
git -C "$MAIN" worktree add -q -b feat/outside "$WORK/outside" main

git -C "$OTHER" init -q -b main
git -C "$OTHER" commit -q --allow-empty -m init
git -C "$OTHER" worktree add -q -b feat/o1 "$ROOT/o1" main; setpr o1 merged

pass_count=0
fail_count=0
total=0
check() {
  local name="$1" ok="$2"
  total=$((total + 1))
  if [ "$ok" -eq 1 ]; then echo "PASS - $name"; pass_count=$((pass_count + 1))
  else echo "FAIL - $name"; fail_count=$((fail_count + 1)); fi
}

OUT="$(cd "$MAIN" && bash "$SCRIPT" 2>&1)"; RC=$?
printf '%s\n' "$OUT"
# line_of <dir name>: the inventory line whose PATH ends with /<name>
line_of() { printf '%s\n' "$OUT" | awk -F'\t' -v n="$1" '$8 ~ ("/" n "$")'; }
# row_is <dir name> <CLASS> <ISSUE> <PR> <TREE> <AHEAD> <RUN>
row_is() {
  line_of "$1" | awk -F'\t' -v c="$2" -v i="$3" -v p="$4" -v t="$5" -v a="$6" -v r="$7" \
    'BEGIN{ok=0} $1==c && $2==i && $4==p && $5==t && $6==a && $7==r {ok=1} END{exit ok?0:1}'
}

check "inventory exit code is 0 and a header is printed" \
  "$([ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | head -n 1 | grep -q '^CLASS	ISSUE	BRANCH	PR	TREE	AHEAD	RUN	PATH$' && echo 1 || echo 0)"
check "inventory merged: class merged, PR merged, clean, 0 ahead" "$(row_is merged merged - merged clean 0 no && echo 1 || echo 0)"
check "inventory closed-unmerged: PR closed, 1 commit ahead" "$(row_is closed closed-unmerged - closed clean 1 no && echo 1 || echo 0)"
check "inventory no-pr-empty: no PR and 0 ahead" "$(row_is empty no-pr-empty - none clean 0 no && echo 1 || echo 0)"
check "inventory ahead: no PR and 1 ahead" "$(row_is ahead ahead - none clean 1 no && echo 1 || echo 0)"
check "inventory dirty: untracked file, even with a merged PR" "$(row_is dirty dirty - merged dirty 0 no && echo 1 || echo 0)"
check "inventory open-pr: open PR" "$(row_is open open-pr - open clean 0 no && echo 1 || echo 0)"
check "inventory in-flight: run state file in the main tree, issue number read from the branch" "$(row_is flight in-flight 55 merged clean 0 yes && echo 1 || echo 0)"
check "inventory detached: no branch" \
  "$(line_of detached | awk -F'\t' '$1=="detached" && $3=="-" && $4=="-" {ok=1} END{exit ok?0:1}' && echo 1 || echo 0)"
check "inventory outside-root: a worktree outside the root is not listed" \
  "$(printf '%s\n' "$OUT" | grep -q '/outside' && echo 0 || echo 1)"
check "inventory summary: 8 worktrees, 3 removable (merged 1, closed-unmerged 1, no-pr-empty 1), 5 kept, no pipe character" \
  "$(printf '%s\n' "$OUT" | grep -qxF '8 worktrees: 3 removable (merged 1, closed-unmerged 1, no-pr-empty 1), 5 kept' && echo 1 || echo 0)"
check "inventory is read-only: every worktree and branch is still there" \
  "$([ "$(git -C "$MAIN" worktree list | wc -l | tr -d ' ')" -eq 10 ] && [ -d "$ROOT/merged" ] && [ -d "$ROOT/dirty" ] && echo 1 || echo 0)"

# -C points at a checkout of another repository: only that repository's worktrees
OUT="$(cd "$WORK" && bash "$SCRIPT" -C "$OTHER" 2>&1)"; RC=$?
check "inventory -C: lists the worktree of the other repository and none of the first" \
  "$([ "$RC" -eq 0 ] && row_is o1 merged - merged clean 0 no && ! printf '%s\n' "$OUT" | grep -q "$ROOT/merged" && printf '%s\n' "$OUT" | grep -qxF '1 worktrees: 1 removable (merged 1, closed-unmerged 0, no-pr-empty 0), 0 kept' && echo 1 || echo 0)"

OUT="$(cd "$MAIN" && bash "$SCRIPT" --bogus 2>&1)"; RC=$?
check "inventory usage: an unknown option exits 2" "$([ "$RC" -eq 2 ] && echo 1 || echo 0)"

echo "${pass_count}/${total} PASS"
[ "$fail_count" -eq 0 ] || exit 1
exit 0
