#!/usr/bin/env bash
# Lead merge gesture (#74): scripts/lead-merge.sh <pr> [-R owner/repo]
# Run from a checkout of the PR head branch (clean tree). Steps, each exit code checked:
#   1. acceptance checklist via scripts/lib/acceptance-check.sh (same lib as the merge hook):
#      any `- [ ]` between the acceptance markers, or missing markers, refuses.
#   2. bump patch of .claude-plugin/plugin.json + BUILD line of workflows/deliver-pipeline.js
#      (patch+1 over max(branch, origin/main)), commit `chore: bump X (lead-merge)`, push the head branch.
#      Idempotent: skipped when the branch is already above origin/main via such a bump commit.
#   3. gh pr update-branch (default merge method, never the history-rewriting one).
#   4. gh pr checks --watch --fail-fast.
#   5. gh pr merge --merge --delete-branch (never the auto-merge flag).
# Afterwards prints the manual step to sync the local main. The PR itself never bumps: this script does.
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

# --- preflight for the bump --------------------------------------------------
head_branch="$(gh pr view "$PR" -R "$REPO" --json headRefName -q .headRefName)" || die "cannot read PR #$PR head branch"
[ -n "$head_branch" ] || die "empty head branch for PR #$PR"
cur_branch="$(git rev-parse --abbrev-ref HEAD)"
[ "$cur_branch" = "$head_branch" ] || die "checkout is on '$cur_branch', PR #$PR head is '$head_branch': run from the PR worktree"
[ -z "$(git status --porcelain)" ] || die "working tree not clean"
git fetch origin main || die "git fetch origin main failed"

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

# --- 2. bump (idempotent) ----------------------------------------------------
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
  git push origin "HEAD:$head_branch" || die "push of the bump commit failed"
  echo "lead-merge: bumped $base_ver -> $new_ver"
fi

# --- 3. update-branch (merge, never the history-rewriting method) -------------
gh pr update-branch "$PR" -R "$REPO" || die "gh pr update-branch failed"

# --- 4. CI ---------------------------------------------------------------------
gh pr checks "$PR" -R "$REPO" --watch --fail-fast || die "CI checks failed; not merging"

# --- 5. merge ------------------------------------------------------------------
gh pr merge "$PR" -R "$REPO" --merge --delete-branch || die "gh pr merge failed"

echo "lead-merge: PR #$PR merged. Next manual step: in the main checkout run 'git fetch origin && git merge --ff-only origin/main'."
