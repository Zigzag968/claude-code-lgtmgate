#!/usr/bin/env bash
# Regression test for scripts/lead-merge.sh (#74). Offline: a fake `gh` on PATH logs every call
# to a file; the git side is a throwaway repo + bare origin under $TMPDIR (the real worktree is
# never touched). Cases: open box, missing markers, happy path order, no auto-merge flag,
# --merge used, CI failure, idempotent re-run.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/lead-merge.sh"
BASE="$(mktemp -d "${TMPDIR:-/tmp}/lead-merge-test.XXXXXX")"
PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

mkdir -p "$BASE/bin"
cat > "$BASE/bin/gh" <<'FAKE'
#!/usr/bin/env bash
echo "gh $*" >> "$FAKE_LOG"
case "$1 $2" in
  "pr view")
    case "$*" in
      *headRefName*) echo "$FAKE_BRANCH" ;;
      *) cat "$FAKE_BODY" ;;
    esac ;;
  "pr update-branch")
    echo "REMOTE-HEAD-AT-UPDATE: $(git --git-dir="$FAKE_REMOTE" log -1 --format=%s "$FAKE_BRANCH")" >> "$FAKE_LOG" ;;
  "pr checks") [ "${FAKE_CHECKS_RC:-0}" -eq 0 ] || exit "$FAKE_CHECKS_RC" ;;
  "pr merge") ;;
  *) echo "fake gh: unexpected: $*" >&2; exit 99 ;;
esac
exit 0
FAKE
chmod +x "$BASE/bin/gh"

# fixture: bare origin + working clone on feat/x one commit ahead of main
setup() {
  local d="$BASE/$1"
  mkdir -p "$d"
  git init -q --bare -b main "$d/origin.git"
  git clone -q "$d/origin.git" "$d/work" 2>/dev/null
  ( cd "$d/work" && git config user.email t@t && git config user.name t \
    && mkdir -p .claude-plugin workflows \
    && printf '{\n  "name": "lgtmgate",\n  "version": "0.8.80",\n  "x": 1\n}\n' > .claude-plugin/plugin.json \
    && printf "const BUILD = { plugin: 'lgtmgate', version: '0.8.80', cutFrom: 'abc1234' }\n" > workflows/deliver-pipeline.js \
    && git add -A && git commit -qm init && git push -q origin HEAD:main \
    && git checkout -q -b feat/x && echo change > f.txt && git add -A && git commit -qm feat \
    && git push -q origin feat/x ) >/dev/null 2>&1
  echo "$d"
}

run() { # <dir> <body-file> [checks-rc]
  local d="$1"
  : > "$d/log"
  ( cd "$d/work" && PATH="$BASE/bin:$PATH" FAKE_LOG="$d/log" FAKE_BODY="$2" FAKE_BRANCH=feat/x \
      FAKE_REMOTE="$d/origin.git" FAKE_CHECKS_RC="${3:-0}" bash "$SCRIPT" 7 -R o/r ) > "$d/out" 2>&1
}

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
grep -q '^REMOTE-HEAD-AT-UPDATE: chore: bump 0.8.81 (lead-merge)$' "$D/log" \
  && ok "bump commit pushed before pr update-branch" || bad "bump not on remote at update-branch: $(cat "$D/log")"
seq="$(grep -oE 'pr (update-branch|checks|merge)' "$D/log" | tr '\n' ',')"
[ "$seq" = "pr update-branch,pr checks,pr merge," ] && ok "order update-branch < checks < merge" || bad "order: $seq"
grep -q -- '--watch --fail-fast' "$D/log" && ok "checks use --watch --fail-fast" || bad "checks flags"
grep -q 'pr merge 7 -R o/r --merge' "$D/log" && ok "merge uses --merge" || bad "merge flag"
! grep -q -e '--auto' -e '--squash' "$D/log" && ok "no auto/squash flag in any gh call" || bad "forbidden flag in log"
grep -q '"version": "0.8.81"' "$D/work/.claude-plugin/plugin.json" \
  && grep -q "version: '0.8.81', cutFrom: '$(git -C "$D/work" rev-parse --short origin/main)'" "$D/work/workflows/deliver-pipeline.js" \
  && ok "plugin.json + BUILD bumped (cutFrom = origin/main short sha)" || bad "bump content"

# 4. idempotent re-run: no second bump
: > "$D/log"
( cd "$D/work" && PATH="$BASE/bin:$PATH" FAKE_LOG="$D/log" FAKE_BODY="$BASE/good.md" FAKE_BRANCH=feat/x FAKE_REMOTE="$D/origin.git" bash "$SCRIPT" 7 -R o/r ) > "$D/out" 2>&1
[ "$(git -C "$D/work" log --format=%s | grep -c 'chore: bump')" -eq 1 ] && ok "re-run does not bump twice" || bad "second bump created"

# 5. CI failure -> no merge
D="$(setup ci)"; run "$D" "$BASE/good.md" 1; rc=$?
[ "$rc" -ne 0 ] && grep -q 'pr checks' "$D/log" && ! grep -q 'pr merge' "$D/log" && ok "checks failure: no merge" || bad "checks failure (rc=$rc)"

echo "[lead-merge test] passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
