#!/usr/bin/env bash
# Lead merge gesture (#74): scripts/lead-merge.sh <pr> [-R owner/repo]
# Run from a checkout of the PR head branch. Steps, each exit code checked:
#   1. acceptance checklist via scripts/lib/acceptance-check.sh (same lib as the merge hook):
#      any `- [ ]` between the acceptance markers, or missing markers, refuses.
#   2. sync: refuse unless on the PR head branch with a clean tree; fetch the head branch and
#      fast-forward when the remote is ahead (a previous partial run), refuse when diverged.
#   3. bring the base in LOCALLY: fetch origin/main, `git merge --no-edit origin/main`. On conflict:
#      abort the merge and die. Exception: when only the version files (plugin.json, BUILD line)
#      conflict (main bumped too), take main's copy; step 4 recomputes them. No `gh pr update-branch`:
#      the local merge already makes the branch current, and bumping before it always conflicted.
#   4. bump from the merged tree: patch+1 over max(branch, origin/main) in .claude-plugin/plugin.json
#      + BUILD line of workflows/deliver-pipeline.js (cutFrom = origin/main short sha), commit
#      `chore: bump X (lead-merge)`. Idempotent: skipped when the branch is already above origin/main
#      via such a bump commit.
#   5. push once (only when local HEAD differs from the remote head).
#   6. wait until the PR reports the pushed sha with at least one check (bounded poll, cli/cli#7401),
#      then gh pr checks --watch --fail-fast (--required when supported).
#   7. gh pr merge --merge --delete-branch (never the auto-merge flag).
# Afterwards prints the manual step to sync the local main. The PR itself never bumps: this script does.
# Env: LEAD_MERGE_POLL_MAX (default 30), LEAD_MERGE_POLL_SLEEP seconds (default 10).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/acceptance-check.sh
. "$SCRIPT_DIR/lib/acceptance-check.sh"

MANIFEST=".claude-plugin/plugin.json"
WORKFLOW="workflows/deliver-pipeline.js"

die() { echo "lead-merge: $*" >&2; exit 1; }

PR=""; REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    -R|--repo) [ $# -ge 2 ] || die "$1 needs a value"; REPO="$2"; shift 2 ;;
    -*) die "unknown option: $1" ;;
    *) [ -z "$PR" ] || die "unexpected argument: $1"; PR="$1"; shift ;;
  esac
done
case "$PR" in ''|*[!0-9]*) die "usage: scripts/lead-merge.sh <pr-number> [-R owner/repo]" ;; esac

# Repo resolution: -R flag, else .claude/pipeline.config.json "repo", else gh repo view.
if [ -z "$REPO" ] && [ -f .claude/pipeline.config.json ]; then
  REPO="$(python3 -c "import json; print(json.load(open('.claude/pipeline.config.json')).get('repo',''))" 2>/dev/null || true)"
fi
if [ -z "$REPO" ]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)" || die "cannot resolve the repo (pass -R owner/repo)"
fi
[ -n "$REPO" ] || die "cannot resolve the repo (pass -R owner/repo)"

# --- 1. acceptance checklist -------------------------------------------------
body="$(gh pr view "$PR" -R "$REPO" --json body -q .body)" || die "cannot read PR #$PR body"
rc=0
printf '%s\n' "$body" | acceptance_check_body || rc=$?
[ "$rc" -eq 0 ] || die "PR #$PR acceptance gate failed (rc=$rc); nothing bumped, nothing merged"

# --- 2. sync with the remote head branch ---------------------------------------
head_branch="$(gh pr view "$PR" -R "$REPO" --json headRefName -q .headRefName)" || die "cannot read PR #$PR head branch"
[ -n "$head_branch" ] || die "empty head branch for PR #$PR"
cur_branch="$(git rev-parse --abbrev-ref HEAD)"
[ "$cur_branch" = "$head_branch" ] || die "checkout is on '$cur_branch', PR #$PR head is '$head_branch': run from the PR worktree"
[ -z "$(git status --porcelain)" ] || die "working tree not clean"
git fetch origin "+refs/heads/$head_branch:refs/remotes/origin/$head_branch" || die "git fetch origin $head_branch failed"
local_sha="$(git rev-parse HEAD)"; remote_sha="$(git rev-parse "refs/remotes/origin/$head_branch")"
if [ "$local_sha" != "$remote_sha" ]; then
  if git merge-base --is-ancestor "$local_sha" "$remote_sha"; then
    git merge --ff-only "origin/$head_branch" || die "fast-forward to origin/$head_branch failed"
  elif git merge-base --is-ancestor "$remote_sha" "$local_sha"; then
    echo "lead-merge: local branch is ahead of origin/$head_branch (will be pushed)"
  else
    die "local $head_branch and origin/$head_branch have diverged; reconcile by hand"
  fi
fi

# --- 3. bring the base in locally (merge only) -----------------------------------
git fetch origin "+refs/heads/main:refs/remotes/origin/main" || die "git fetch origin main failed"
if ! git merge --no-edit origin/main; then
  conflicts="$(git diff --name-only --diff-filter=U)"
  other="$(printf '%s\n' "$conflicts" | grep -vxF -e "$MANIFEST" -e "$WORKFLOW" | grep -v '^$' || true)"
  if [ -n "$conflicts" ] && [ -z "$other" ]; then
    # main bumped as well: take its copy (stage 3) of the version files; the bump step recomputes them
    for f in $conflicts; do git show ":3:$f" > "$f" && git add -- "$f" || { git merge --abort 2>/dev/null || true; die "cannot resolve the version-file conflict in $f"; }; done
    git commit --no-edit || { git merge --abort 2>/dev/null || true; die "merge commit failed"; }
  else
    git merge --abort 2>/dev/null || true
    die "merging origin/main conflicts (${conflicts:-unknown}); resolve in the worktree, push, re-run. Nothing pushed."
  fi
fi

ver_of() { python3 -c "import json,sys; print(json.load(sys.stdin).get('version',''))"; }
# semver_gt A B -> rc 0 iff A > B (numeric x.y.z)
semver_gt() {
  local IFS=.; set -- $1 $2
  local a1=${1:-0} a2=${2:-0} a3=${3:-0} b1=${4:-0} b2=${5:-0} b3=${6:-0}
  [ "$a1" -ne "$b1" ] && { [ "$a1" -gt "$b1" ]; return; }
  [ "$a2" -ne "$b2" ] && { [ "$a2" -gt "$b2" ]; return; }
  [ "$a3" -gt "$b3" ]
}

main_ver="$(git show "origin/main:$MANIFEST" | ver_of)"
branch_ver="$(ver_of < "$MANIFEST")"
[ -n "$main_ver" ] && [ -n "$branch_ver" ] || die "cannot read versions (main='$main_ver' branch='$branch_ver')"

# --- 4. bump from the merged tree (idempotent) ---------------------------------
if semver_gt "$branch_ver" "$main_ver" && git log -n 50 --format=%s origin/main..HEAD | grep -qxF "chore: bump $branch_ver (lead-merge)"; then
  echo "lead-merge: bump commit for $branch_ver already on the branch, skipping bump"
else
  base_ver="$main_ver"
  if semver_gt "$branch_ver" "$main_ver"; then base_ver="$branch_ver"; fi
  IFS=. read -r v1 v2 v3 <<EOV
$base_ver
EOV
  new_ver="$v1.$v2.$((v3 + 1))"
  cut_from="$(git rev-parse --short origin/main)"
  NEW_VER="$new_ver" CUT_FROM="$cut_from" MANIFEST="$MANIFEST" WORKFLOW="$WORKFLOW" python3 - <<'PY' || die "bump edit failed"
import os, re, sys
v, cut = os.environ["NEW_VER"], os.environ["CUT_FROM"]
def edit(path, pat, repl):
    s = open(path).read()
    out, n = re.subn(pat, repl, s, count=1)
    if n != 1:
        sys.exit("pattern not found in " + path)
    open(path, "w").write(out)
edit(os.environ["MANIFEST"], r'("version"\s*:\s*")[^"]*(")', lambda m: m.group(1) + v + m.group(2))
edit(os.environ["WORKFLOW"], r"const BUILD = \{[^}]*\}",
     "const BUILD = { plugin: 'lgtmgate', version: '%s', cutFrom: '%s' }" % (v, cut))
PY
  git add "$MANIFEST" "$WORKFLOW"
  git commit -m "chore: bump $new_ver (lead-merge)" || die "bump commit failed"
  echo "lead-merge: bumped $base_ver -> $new_ver"
fi

# --- 5. push once --------------------------------------------------------------
pushed_sha="$(git rev-parse HEAD)"
if [ "$pushed_sha" != "$(git rev-parse "refs/remotes/origin/$head_branch")" ]; then
  git push origin "HEAD:$head_branch" || die "push to $head_branch failed"
else
  echo "lead-merge: origin/$head_branch already at HEAD, nothing to push"
fi

# --- 6. CI on the pushed sha ---------------------------------------------------
# cli/cli#7401: right after a push `gh pr checks` can exit 1 ("no checks reported") or show the
# previous sha. Poll until the PR head is the pushed sha and at least one check is reported.
poll_max="${LEAD_MERGE_POLL_MAX:-30}"; poll_sleep="${LEAD_MERGE_POLL_SLEEP:-10}"
seen=0; n=0
while [ "$n" -lt "$poll_max" ]; do
  n=$((n + 1))
  if gh pr view "$PR" -R "$REPO" --json headRefOid,statusCheckRollup 2>/dev/null | PUSHED="$pushed_sha" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
sys.exit(0 if d.get("headRefOid") == os.environ["PUSHED"] and len(d.get("statusCheckRollup") or []) > 0 else 1)' 2>/dev/null; then
    seen=1; break
  fi
  sleep "$poll_sleep"
done
[ "$seen" -eq 1 ] || die "PR #$PR never reported checks for $pushed_sha after $poll_max polls; not merging"
req=""
if gh pr checks --help 2>&1 | grep -q -- --required; then req="--required"; fi
# shellcheck disable=SC2086
gh pr checks "$PR" -R "$REPO" --watch --fail-fast $req || die "CI checks failed; not merging"

# --- 7. merge ------------------------------------------------------------------
gh pr merge "$PR" -R "$REPO" --merge --delete-branch || die "gh pr merge failed"

echo "lead-merge: PR #$PR merged. Next manual step: in the main checkout run 'git fetch origin && git merge --ff-only origin/main'."
