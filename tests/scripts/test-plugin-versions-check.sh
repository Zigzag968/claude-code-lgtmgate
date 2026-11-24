#!/usr/bin/env bash
# Regression test for `scripts/plugin-versions.sh --check` (#731). Offline: a fake `claude` on PATH prints a canned
# `claude plugin list --json` payload and logs its argv; the script runs from a throwaway git repo with one linked worktree under
# $TMPDIR, with --target (the real origin/main and the real `claude` are never used).
# Cases: one stale enabled install -> exit 1 naming it; none stale -> exit 0; a stale install scoped to a worktree of the repository ->
# exit 1 with WORKTREE-INSTALL under --check, while the same payload without --check keeps the OTHER-PROJECT line and exits 0;
# a current worktree install -> exit 0 (counted, no problem); a stale install of an unrelated project -> exit 0 under --check;
# outside a git repository --check adds nothing; the fake claude only ever sees `plugin list --json`.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/plugin-versions.sh"
BASE="$(mktemp -d "${TMPDIR:-/tmp}/plugin-versions-check-test.XXXXXX")"
# shellcheck source=lib/harness.sh
. "$ROOT/tests/scripts/lib/harness.sh"

mkdir -p "$BASE/bin"
cat > "$BASE/bin/claude" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_LOG"
if [ "$*" = "plugin list --json" ]; then cat "$FAKE_LIST"; exit 0; fi
echo "fake claude: unexpected: $*" >&2
exit 99
FAKE
chmod +x "$BASE/bin/claude"
FAKE_LOG="$BASE/claude.log"; : > "$FAKE_LOG"; export FAKE_LOG
export CLAUDE_CONFIG_DIR="$BASE/userclaude"; mkdir -p "$CLAUDE_CONFIG_DIR"

# the repository of the current directory: a main checkout and one linked worktree; plus an unrelated directory
REPO="$BASE/repo"; WT="$BASE/wt"; OTHER="$BASE/other"; NOREPO="$BASE/norepo"
mkdir -p "$REPO" "$OTHER" "$NOREPO"
( cd "$REPO" && git init -q -b main && git config user.email t@t && git config user.name t && echo a > a && git add -A && git commit -qm init \
  && git worktree add -q "$WT" -b wtbranch ) >/dev/null 2>&1
REPO="$(cd "$REPO" && pwd -P)"; WT="$(cd "$WT" && pwd -P)"; OTHER="$(cd "$OTHER" && pwd -P)"

entry() {
  local proj=""
  [ -z "${5:-}" ] || proj=",\"projectPath\":\"$5\""
  printf '{"id":"%s","version":"%s","scope":"%s","enabled":%s,"installPath":"/cache/%s/%s"%s}' "$1" "$2" "$3" "$4" "$1" "$2" "$proj"
}
list() { local f="$1" sep=""; shift; printf '[' > "$f"; while [ $# -gt 0 ]; do printf '%s%s' "$sep" "$1" >> "$f"; sep=","; shift; done; printf ']\n' >> "$f"; }

OUT=""
# pv <dir> <list-file> [args...]: run the script from <dir>; OUT = stdout+stderr followed by `exit=<code>`
pv() {
  local d="$1" f="$2"; shift 2
  OUT="$(cd "$d" && PATH="$BASE/bin:$PATH" FAKE_LIST="$f" bash "$SCRIPT" --target "$T" "$@" 2>&1; echo "exit=$?")"
}
has() { case "$OUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

BETA='lgtmgate@zigzag-plugins-beta'; T='1.0.0-beta.27'

# 1. one stale enabled install of the project: --check exits 1 and names it
list "$BASE/l1.json" "$(entry "$BETA" 1.0.0-beta.3 local true "$REPO")"
pv "$REPO" "$BASE/l1.json" --check
has 'MISMATCH: found 1.0.0-beta.3, target 1.0.0-beta.27' && has 'exit=1' \
  && ok "--check, one stale install: exit=1, the line names the version found and the target" || bad "stale install: $OUT"

# 2. none stale: exit 0
list "$BASE/l2.json" "$(entry "$BETA" "$T" local true "$REPO")"
pv "$REPO" "$BASE/l2.json" --check
has 'exit=0' && ! has MISMATCH && ! has WORKTREE-INSTALL && ok "--check, no stale install: exit=0" || bad "clean: $OUT"

# 3. a stale install scoped to a worktree of the repository: counted under --check
list "$BASE/l3.json" "$(entry "$BETA" 1.0.0-beta.3 local true "$WT")"
pv "$REPO" "$BASE/l3.json" --check
has " WORKTREE-INSTALL MISMATCH: found 1.0.0-beta.3, target $T" && has '1 problem(s)' && has 'exit=1' \
  && ok "--check, stale worktree install: WORKTREE-INSTALL + MISMATCH, exit=1" || bad "worktree install: $OUT"
# run from the worktree that owns the install: it is that project's own install (default rule), counted without the WORKTREE-INSTALL tag
pv "$WT" "$BASE/l3.json" --check
has 'MISMATCH: found 1.0.0-beta.3' && ! has WORKTREE-INSTALL && has 'exit=1' \
  && ok "--check run from the owning worktree: the project's own stale install, exit=1" || bad "from the worktree: $OUT"

# 4. the same payload without --check: the worktree install stays OTHER-PROJECT, exit 0 (default output unchanged)
pv "$REPO" "$BASE/l3.json"
has 'OTHER-PROJECT: not loaded for this project, not counted' && ! has WORKTREE-INSTALL && has 'exit=0' \
  && ok "without --check: the worktree install stays OTHER-PROJECT, exit=0" || bad "without --check: $OUT"

# 5. a current worktree install: listed as WORKTREE-INSTALL, no problem
list "$BASE/l5.json" "$(entry "$BETA" "$T" local true "$WT")"
pv "$REPO" "$BASE/l5.json" --check
has " WORKTREE-INSTALL" && ! has MISMATCH && has '0 problem(s)' && has 'exit=0' && ok "--check, current worktree install: WORKTREE-INSTALL, no problem, exit=0" || bad "current worktree install: $OUT"

# 6. a stale install of an unrelated project: still not counted under --check
list "$BASE/l6.json" "$(entry "$BETA" 1.0.0-beta.3 local true "$OTHER")"
pv "$REPO" "$BASE/l6.json" --check
has 'OTHER-PROJECT' && ! has WORKTREE-INSTALL && has 'exit=0' && ok "--check, stale install of an unrelated project: OTHER-PROJECT, exit=0" || bad "unrelated project: $OUT"

# 7. outside a git repository --check adds no worktree: the same payload keeps its default reading
pv "$NOREPO" "$BASE/l3.json" --check
has 'OTHER-PROJECT' && has 'exit=0' && ok "--check outside a git repository: no worktree known, default reading, exit=0" || bad "no repo: $OUT"

# 8. a disabled stale worktree install never counts; a project-scope one does
list "$BASE/l8.json" "$(entry "$BETA" 1.0.0-beta.3 local false "$WT")"
pv "$REPO" "$BASE/l8.json" --check
has 'exit=0' && ! has WORKTREE-INSTALL && ok "--check, disabled stale worktree install: not counted, exit=0" || bad "disabled: $OUT"
list "$BASE/l8b.json" "$(entry "$BETA" 1.0.0-beta.3 project true "$WT")"
pv "$REPO" "$BASE/l8b.json" --check
has 'project project=' && has ' WORKTREE-INSTALL MISMATCH' && has 'exit=1' && ok "--check, stale project-scope install of a worktree: counted, exit=1" || bad "project scope: $OUT"

# 9. read-only: the fake only ever saw `plugin list --json`
if [ -s "$FAKE_LOG" ] && [ "$(sort -u "$FAKE_LOG")" = "plugin list --json" ]; then ok "read-only: the only claude call is plugin list --json"; else bad "claude calls: $(sort -u "$FAKE_LOG")"; fi

echo "[plugin-versions-check test] passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
