#!/usr/bin/env bash
# Regression test for scripts/lib/post-merge-install.sh and its call in scripts/lead-merge.sh (#731). Offline: a fake `claude` on PATH
# prints a canned `plugin list --json` payload and logs every call as `<cwd> :: <argv>`; the git side is a throwaway repo (main checkout
# plus one linked worktree) under $TMPDIR. The real `claude`, the network and the real tree are never touched.
# Cases: a stale local install of the main checkout is updated from that directory and its session listed for restart, a stale user-scope
# install is updated, a stale install scoped to a worktree is NOT updated (its manual command and directory are printed), a clean list makes
# no update call, a refused update and an undecidable listing print the manual hint and return 0, and the real lead-merge.sh happy path
# ends with the update call logged and the merge exit code unchanged.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/harness.sh
. "$ROOT/tests/scripts/lib/harness.sh"
BASE="$(mktemp -d "${TMPDIR:-/tmp}/lead-merge-install-test.XXXXXX")"
# shellcheck source=lib/lead-merge-fixture.sh
. "$ROOT/tests/scripts/lib/lead-merge-fixture.sh"   # fake gh and claude on $BASE/bin, setup/run (defines SCRIPT)
. "$ROOT/scripts/lib/post-merge-install.sh"
SCRIPT_DIR="$ROOT/scripts"
export CLAUDE_CONFIG_DIR="$BASE/userclaude"; mkdir -p "$CLAUDE_CONFIG_DIR"
export FAKE_CLAUDE_LOG="$BASE/claude.log"

BETA='lgtmgate@zigzag-plugins-beta'
T='0.8.81'
# the checkout the helper judges: a main checkout with one linked worktree
REPO="$BASE/repo"; WT="$BASE/wt"
mkdir -p "$REPO"
( cd "$REPO" && git init -q -b main && git config user.email t@t && git config user.name t && echo a > a && git add -A && git commit -qm init \
  && git worktree add -q "$WT" -b wtbranch ) >/dev/null 2>&1
REPO="$(cd "$REPO" && pwd -P)"; WT="$(cd "$WT" && pwd -P)"

# entry <id> <version> <scope> <enabled> [<projectPath>]: one object of the payload
entry() {
  local proj=""
  [ -z "${5:-}" ] || proj=",\"projectPath\":\"$5\""
  printf '{"id":"%s","version":"%s","scope":"%s","enabled":%s,"installPath":"/cache/%s/%s"%s}' "$1" "$2" "$3" "$4" "$1" "$2" "$proj"
}
list() { local f="$1" sep=""; shift; printf '[' > "$f"; while [ $# -gt 0 ]; do printf '%s%s' "$sep" "$1" >> "$f"; sep=","; shift; done; printf ']\n' >> "$f"; }

OUT=""; RC=0
# helper <list-file> [update-rc]: run lm_post_merge_install from the worktree (as lead-merge does); OUT = stdout, RC = exit code
helper() {
  : > "$FAKE_CLAUDE_LOG"
  OUT="$(cd "$WT" && PATH="$BASE/bin:$PATH" FAKE_CLAUDE_LIST="$1" FAKE_UPDATE_RC="${2:-0}" LM_MAIN_CHECKOUT="$REPO" lm_post_merge_install lgtmgate "$T" 2>&1)"; RC=$?
}
has() { case "$OUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
updates() { grep -c ' :: plugin update ' "$FAKE_CLAUDE_LOG"; }

# 1. stale local install of the main checkout: updated from that directory, its session listed for restart
list "$BASE/l1.json" "$(entry "$BETA" 0.8.80 local true "$REPO")"
helper "$BASE/l1.json"
grep -qxF "$REPO :: plugin update $BETA --scope local" "$FAKE_CLAUDE_LOG" && [ "$(updates)" = 1 ] && [ "$RC" -eq 0 ] \
  && has "lead-merge: updated $BETA scope=local to $T" && has "lead-merge: restart these sessions: $REPO" \
  && ok "stale local install of the main checkout: updated from it, restart line names it" || bad "local update (rc=$RC): $OUT :: $(cat "$FAKE_CLAUDE_LOG")"

# 2. stale user-scope install: updated, every user-scope session to restart
list "$BASE/l2.json" "$(entry "$BETA" 0.8.80 user true)"
helper "$BASE/l2.json"
grep -q " :: plugin update $BETA --scope user$" "$FAKE_CLAUDE_LOG" && [ "$RC" -eq 0 ] && has "updated $BETA scope=user to $T" && has "restart these sessions: (all user-scope sessions)" \
  && ok "stale user-scope install: updated, restart line names the user-scope sessions" || bad "user update (rc=$RC): $OUT"

# 3. stale install scoped to a worktree of the repository: listed with its manual command and directory, never updated
list "$BASE/l3.json" "$(entry "$BETA" 0.8.80 local true "$WT")"
helper "$BASE/l3.json"
[ "$(updates)" = 0 ] && [ "$RC" -eq 0 ] && has "still stale (local install of $WT, channel zigzag-plugins-beta): run from $WT: claude plugin update $BETA --scope local" && has "restart these sessions: $WT" \
  && ok "stale worktree install: no update call, manual command and directory printed, restart line names it" || bad "worktree install (rc=$RC): $OUT :: $(cat "$FAKE_CLAUDE_LOG")"

# 4. nothing stale: no update call
list "$BASE/l4.json" "$(entry "$BETA" "$T" local true "$REPO")"
helper "$BASE/l4.json"
[ "$(updates)" = 0 ] && [ "$RC" -eq 0 ] && has "no stale install of the plugin found" && ! has "restart these sessions" \
  && ok "clean list: no update call, no restart line" || bad "clean list (rc=$RC): $OUT"

# 5. a refused update: the manual command is printed, the exit code stays 0
helper "$BASE/l1.json" 1
[ "$RC" -eq 0 ] && has "update refused or failed for $BETA scope=local; run by hand from $REPO: claude plugin update $BETA --scope local" && ! has "lead-merge: updated" \
  && ok "claude plugin update exit 1: manual command printed, helper returns 0" || bad "refused update (rc=$RC): $OUT"

# 6. an undecidable listing (the payload is not JSON, plugin-versions exits 2): the manual hint with the reason, return 0
printf 'not json\n' > "$BASE/l6.json"
helper "$BASE/l6.json"
[ "$(updates)" = 0 ] && [ "$RC" -eq 0 ] && has "update the install (plugin-versions.sh --check could not decide" && has "claude plugin update lgtmgate@<marketplace> --scope <scope>" \
  && ok "undecidable listing: no update call, old manual hint with the reason, returns 0" || bad "undecidable listing (rc=$RC): $OUT"

# 7. no claude CLI on PATH: the manual hint, return 0 (PATH reduced to the tools the helper needs, none of them claude)
: > "$FAKE_CLAUDE_LOG"
OUT="$(cd "$WT" && PATH="/usr/bin:/bin" LM_MAIN_CHECKOUT="$REPO" lm_post_merge_install lgtmgate "$T" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && has "the claude CLI is not on PATH" && ok "no claude on PATH: manual hint, returns 0" || bad "no claude (rc=$RC): $OUT"

# 8. the real lead-merge.sh: bump 0.8.80 -> 0.8.81, then the update of the stale local install of the checkout it ran from
printf 'Closes #1\n<!-- acceptance:start -->\n- [x] a\n<!-- acceptance:end -->\n' > "$BASE/good.md"
D="$(setup install-happy)"
D_WORK="$(cd "$D/work" && pwd -P)"
list "$BASE/l8.json" "$(entry "$BETA" 0.8.80 local true "$D_WORK")"
: > "$FAKE_CLAUDE_LOG"
FAKE_CLAUDE_LIST="$BASE/l8.json" run "$D" "$BASE/good.md"; rc=$?
ml="$(grep -n 'PR #7 merged' "$D/out" | head -1 | cut -d: -f1)"; ul="$(grep -n "lead-merge: updated $BETA scope=local to 0.8.81" "$D/out" | head -1 | cut -d: -f1)"
[ "$rc" -eq 0 ] && grep -qxF "$D_WORK :: plugin update $BETA --scope local" "$FAKE_CLAUDE_LOG" && [ -n "$ml" ] && [ -n "$ul" ] && [ "$ul" -gt "$ml" ] \
  && grep -qF "lead-merge: restart these sessions: $D_WORK" "$D/out" \
  && ok "lead-merge.sh: after the verified merge the local-scope update runs and the session to restart is printed, rc=0" || bad "lead-merge happy path (rc=$rc): $(tail -5 "$D/out") :: $(cat "$FAKE_CLAUDE_LOG")"
# a refused update never changes the merge exit code
D="$(setup install-refused)"
D_WORK="$(cd "$D/work" && pwd -P)"
list "$BASE/l9.json" "$(entry "$BETA" 0.8.80 local true "$D_WORK")"
FAKE_CLAUDE_LIST="$BASE/l9.json" FAKE_UPDATE_RC=1 run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'pr merge 7 -R o/r --merge' "$D/log" && grep -qF "update refused or failed for $BETA scope=local" "$D/out" \
  && ok "lead-merge.sh: a refused update prints the manual command and the merge exit code stays 0" || bad "lead-merge refused update (rc=$rc): $(tail -5 "$D/out")"

echo "[lead-merge-install test] passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
