#!/usr/bin/env bash
# Regression test of the fetch form of skills/deliver/SKILL.md (issue #476): under the tooling sandbox an SSH remote
# cannot fetch, so the skill documents ONE HTTPS fetch through the gh credential helper (section 0), and the
# step 3 and post-merge fetch mentions point to it. The command is extracted by its quoted text (never a line
# number), the HTTPS URL is replaced by a local path, and it runs for real in a scratch repo.
# SKILL_FILE points the test at another copy of the skill (negative runs); the harness always comes from the repo.
# bash 3.2 compatible. Trailer: [test-deliver-fetch-form] passed=<n> failed=<n>
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export ROOT="$REPO_ROOT"
# shellcheck source=lib/harness.sh
. "$REPO_ROOT/tests/scripts/lib/harness.sh"
SKILL="${SKILL_FILE:-$REPO_ROOT/skills/deliver/SKILL.md}"
[ -f "$SKILL" ] || { bad "skill file missing: $SKILL"; echo "[test-deliver-fetch-form] passed=$PASS failed=$FAIL"; exit 1; }

FORM_RE='^ *git -c credential\.helper= -c credential\.helper=.!gh auth git-credential. fetch https://github\.com/<owner>/<repo>\.git \+refs/heads/<base>:refs/remotes/origin/<base>$'
COUNT="$(grep -c -E "$FORM_RE" "$SKILL")"
[ "$COUNT" -eq 1 ] && ok "the HTTPS fetch form is documented exactly once" || bad "HTTPS fetch form count is $COUNT, expected 1"
FORM="$(grep -m1 -E "$FORM_RE" "$SKILL" | sed -E 's/^ +//')"

# the form sits next to the first fetch: the plain `git fetch origin main` line of section 0 precedes it within 8 lines
FIRST="$(grep -n -m1 'git fetch origin main' "$SKILL" | cut -d: -f1)"
FORMLN="$(grep -n -m1 -E "$FORM_RE" "$SKILL" | cut -d: -f1)"
if [ -n "$FIRST" ] && [ -n "$FORMLN" ] && [ "$FORMLN" -gt "$FIRST" ] && [ $((FORMLN - FIRST)) -le 8 ]; then ok "the form is next to the first fetch"
else bad "the form is not within 8 lines after the first plain fetch (first=${FIRST:-none} form=${FORMLN:-none})"; fi

# the step 3 and the post-merge fetch lines point to the form (the `§0` pointer)
for key in 'git fetch origin <baseBranch>' 'git fetch origin && git merge --ff-only origin/main'; do
  LINE="$(grep -F -m1 -- "$key" "$SKILL")"
  case "$LINE" in
    *'§0'*) ok "fetch mention points to §0: $key" ;;
    *) bad "fetch mention has no §0 pointer: $key" ;;
  esac
done

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/fetch476.XXXXXX")"
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q --bare "$SCRATCH/remote.git"
git init -q "$SCRATCH/seed"
git -C "$SCRATCH/seed" checkout -q -b main
git -C "$SCRATCH/seed" commit -q --allow-empty -m init
git -C "$SCRATCH/seed" push -q "$SCRATCH/remote.git" main
git init -q "$SCRATCH/consumer"
git -C "$SCRATCH/consumer" remote add origin git@github.com:o/r.git

if [ -n "$FORM" ]; then
  CMD="$(printf '%s\n' "$FORM" | sed -e "s#https://github.com/<owner>/<repo>.git#$SCRATCH/remote.git#" -e 's#<base>#main#g')"
  if (cd "$SCRATCH/consumer" && eval "$CMD") >/dev/null 2>&1; then ok "the documented form runs"
  else bad "the documented form failed: $CMD"; fi
  WANT="$(git -C "$SCRATCH/seed" rev-parse main)"
  GOT="$(git -C "$SCRATCH/consumer" rev-parse --verify -q refs/remotes/origin/main)"
  [ -n "$GOT" ] && [ "$GOT" = "$WANT" ] && ok "refs/remotes/origin/main is created at the remote tip" || bad "refs/remotes/origin/main is '$GOT', expected '$WANT'"
fi

rm -rf "$SCRATCH"
echo "[test-deliver-fetch-form] passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
