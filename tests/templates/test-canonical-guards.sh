#!/usr/bin/env bash
# Canonical guard net for lgtmgate (#54). Guards what a plugin-workflow-component release
# depends on: version stamp parity (the bump itself is done by scripts/lead-merge.sh), marketplace pin, persona-fallback anchors, retired copies,
# CI wiring, prompt/agent-definition invariants (see the list below), the backlog plugin's
# bump/pin/suite, the no-private-refs sweep, and (via scripts/guards.cjs) the R1 ratchet
# against origin/main, all-tests-wired and the version floor.
#
# Evaluates ALL invariants below (never exits on the first violation), prints exactly one
# `FAIL: <invariant-name>: <detail>` line per violation, prints `ALL CHECKS PASSED` when the
# failure set is empty, and ALWAYS ends with the fixed trailer
# `[guards] status=<ok|fail> passed=<n> failed=<n>` as its last line — the same
# collect-then-report + trailer shape as scripts/run-flow-suite.cjs, so a caller can
# `tail -n 1` to prove the run completed rather than died mid-script. Exit is non-zero iff
# failed>0.
#
# MANIFEST env var overrides the manifest path read for invariants 1/2/3 — used by the two
# negative tests (acceptance item 6) so they run against throwaway copies under .pipeline/
# (gitignored) and NEVER mutate the tracked manifest in the review worktree.
#
# WORKFLOW_FILE env var overrides the workflow path read for invariants 2/4/5/14 — used by
# stamp-placement's negative test (acceptance items 2/3/4/5) so it runs against a throwaway
# copy under .pipeline/ (gitignored) and NEVER mutates the tracked workflow file in the
# review worktree.
#
# HEADLESS_SCRIPT env var overrides the script path read for invariant 9 — same purpose,
# lets a negative test point at a throwaway copy under .pipeline/ (gitignored) without ever
# mutating the tracked scripts/run-workflow-headless.sh.
#
# Invariants: 1 (retired, #74; see scripts/lead-merge.sh), 2 stamp-parity, 3 marketplace-pin, 4 stamp-placement,
# 5 persona-anchors, 6 retired-copies, 7 ci-wired, 8 self-reference-doctrine,
# 9 headless-empty-argv, 10 pr-body-structure, 11 worktree-root-resolver,
# 12 blocked-by-signal, 13 single-export, 14 project-item-lookup, 15 bash-3.2-floor,
# 16 backlog-bump-required, 17 backlog-marketplace-pin, 18 backlog-suite, 19 no-private-refs,
# 20 reviewer-window-scan-bounded, 21 gitdir-probe-no-rm, 22 no-destructive-checkout,
# 23 guards-cjs (scripts/guards.cjs: R1 ratchet, 25 all-tests-wired, 1-relaxed version floor,
# sam-parity, doc-budgets, instructions-wired), 24 critical-paths-proven, 26 stories-covered,
# 27 agent-neutrality, 28 project-specifics-slot, 29 no-plugin-copy-in-specifics.
#
# Enforcement note: this repo is public (since 2026-09-29) and the `main-protection` ruleset
# requires the `guards` check (job in `.github/workflows/guards.yml`, which runs this script
# on every PR to main) to succeed before a merge. The acceptance-checklist line for this
# script's verdict stays as a second layer; `.githooks/pre-commit` is a local pre-check only
# (per-clone `core.hooksPath` opt-in), not the enforcement.
#
# Fully offline / non-interactive. Run from anywhere; resolves the repo root itself:
#   bash tests/templates/test-canonical-guards.sh

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

MANIFEST="${MANIFEST:-.claude-plugin/plugin.json}"
WORKFLOW_FILE="${WORKFLOW_FILE:-workflows/deliver-pipeline.js}"

# =============================================================================
# no-private-refs pattern table (invariant 19 below) — extend here, NEVER hardcode a new
# motif inline inside a fail() call (#276: "centralized pattern list ... to stay
# maintainable"). Each pattern is an extended regex, matched case-insensitively with
# `git grep -nEi` (no revision arg — working tree, tracked files only) against the FULL
# TRACKED TREE (not just the diff against origin/main — a leak already sitting on main must
# be caught too, #276: "scope: full tree"). Parallel
# indexed arrays (bash 3.2, invariant 15, has no associative arrays) — same index across
# both arrays is the same table entry. NO_PRIVATE_REFS_ALLOW is an extra exclude-regex run
# on the candidate hits for that entry only (empty string = no exception); it exists so a
# legitimate placeholder already used elsewhere in this repo's own docs (e.g. /Users/you,
# /Users/dev, /home/user, or this repo naming itself) is never flagged.
# -----------------------------------------------------------------------------
NO_PRIVATE_REFS_PATTERNS=(
  'growth-os'                                  # known private-repo issue-tracker shorthand
  'tapp-in\.tv'                                 # private sibling repo domain/slug
  'tapp-in-growth-os'                           # private sibling repo slug variant
  'Zigzag968/nightly'                           # private sibling repo (the nightly tracker)
  'velibz'                                      # private sibling repo slug
  'impots-fr-de'                                # private sibling repo slug
  'Zigzag968/[A-Za-z0-9._-]+'                   # Zigzag968/<repo> other than this repo's own slug
  'github\.com/Zigzag968/[A-Za-z0-9._-]+'       # same, full github.com URL form
  '/Volumes/[A-Za-z0-9_-]+'                     # absolute machine path (this machine's disk layout)
  '/Users/[A-Za-z0-9._-]+'                      # absolute machine path with a real username
  '/home/[A-Za-z0-9._-]+'                       # absolute machine path with a real username (Linux)
  'nightly-state'                               # nightly-dispatch state-blob marker (can carry wtPath/local paths)
  'wtPath":"'                                   # worktree-path key ALREADY SERIALIZED with a value (a pasted-in
                                                 # state/log blob, e.g. '<!-- nightly-state:v1 ... wtPath":"/Volumes/..." -->')
                                                 # — deliberately NOT bare `wtPath`, which is this repo's own,
                                                 # completely legitimate, pervasive variable name (verified this run:
                                                 # a bare-`wtPath` motif hits 60+ sites in workflows/deliver-pipeline.js
                                                 # alone, all of them the parameter/variable itself, zero leaks)
  'nightly-issue-'                              # nightly-dispatch state-blob marker
)
NO_PRIVATE_REFS_ALLOW=(
  ''
  ''
  ''
  ''
  ''
  ''
  'Zigzag968/claude-code-lgtmgate'              # this repo naming itself is not a leak
  'github\.com/Zigzag968/claude-code-lgtmgate'  # same, full URL form
  ''
  '/Users/(you|dev)([^A-Za-z0-9._-]|$)'         # documented generic placeholders, not real usernames
  '/home/user([^A-Za-z0-9._-]|$)'               # documented CI placeholder, not a real username
  ''
  ''
  "branchCheckRaw: 'nightly-issue-1'"           # reviewed repo-local test fixture (this repo's own nightly-branch
                                                 # naming convention exercised by T-series branch-check cases), not
                                                 # a reference to the private nightly repo — a DIFFERENT nightly-issue-
                                                 # value appearing anywhere else still fails and needs review
)

PASS_N=0
FAIL_N=0

pass() { echo "PASS: $1"; PASS_N=$((PASS_N + 1)); }
fail() { echo "FAIL: $1: $2"; FAIL_N=$((FAIL_N + 1)); }

if [ ! -f "$MANIFEST" ]; then
  fail "manifest-missing" "MANIFEST path '$MANIFEST' does not exist"
fi

# Invariant 1 (bump-required) is RETIRED (#74): the version bump now happens at merge time in
# scripts/lead-merge.sh, so PRs no longer bump. The floor (branch >= origin/main) lives in
# scripts/guards.cjs (invariant 23); stamp-parity below still checks plugin.json vs BUILD.
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)"
. "$LIB/canonical-guards-release.sh"

# =============================================================================
# Invariant 15 — bash-3.2-floor
# =============================================================================
# #78 (shell-portability half only — the bump-required exclusion-list half of #78 is a
# human call per that issue's own body, not actioned here). macOS ships bash 3.2
# (/bin/bash, /usr/bin/env bash) — this repo has already been bitten twice by bash4+-only
# constructs slipping into a tracked *.sh file (scripts/provision-worktree.sh,
# scripts/run-workflow-headless.sh, both #57). Static, zero-external-dependency grep across
# every `git ls-files '*.sh'` result for the four textbook bash4+-only constructs: `declare
# -A` (associative arrays), `mapfile`/`readarray`, `${var,,}`/`${var^^}` case-conversion, and
# `${arr[-1]}` negative array indexing. FAIL lists every offending file on a single line
# (comma-joined), never one FAIL per file, matching this script's own "exactly one line per
# violation" contract (line 11). This invariant's own doc comment above and its pattern
# definition below necessarily spell out the four literal constructs as documentation/regex
# text (same "earlier illustrative occurrence" class Invariant 10's comment already names) —
# THIS file is therefore excluded from the scanned set below; every other tracked *.sh file
# is still checked in full.
BASH32_SELF="tests/templates/test-canonical-guards.sh"
BASH32_PATTERN='declare[[:space:]]+-A|\<mapfile\>|\<readarray\>|\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?,,|\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\^\^|\$\{[A-Za-z_][A-Za-z0-9_]*\[-[0-9]+\]'
BASH32_OFFENDERS=""
for f in $(git ls-files '*.sh'); do
  if [ "$f" = "$BASH32_SELF" ]; then
    continue
  fi
  if [ -f "$f" ] && grep -qE "$BASH32_PATTERN" "$f"; then
    if [ -z "$BASH32_OFFENDERS" ]; then
      BASH32_OFFENDERS="$f"
    else
      BASH32_OFFENDERS="$BASH32_OFFENDERS, $f"
    fi
  fi
done
if [ -n "$BASH32_OFFENDERS" ]; then
  fail "bash-3.2-floor" "bash4+-only construct(s) found in: $BASH32_OFFENDERS"
else
  pass "bash-3.2-floor: no declare -A / mapfile / readarray / \${var,,}-\${var^^} case-conversion / \${arr[-1]} negative index across all tracked *.sh files"
fi

. "$LIB/canonical-guards-backlog.sh"

# =============================================================================
# Invariant 19 — no-private-refs
# =============================================================================
# #276 (absorbed into #256): grep the pattern table above against the FULL TRACKED TREE, not
# just the diff — a leak already sitting on main must be caught too. `git grep` (no revision
# argument) reads the WORKING TREE content of tracked files, not the last commit — in CI the
# two are identical (a fresh checkout has no uncommitted diff), but reading the working tree
# is what lets a maintainer sanity-check the invariant locally per the documented negative-test
# recipe (temporarily edit a tracked file, rerun this script uncommitted, see the FAIL line,
# then restore the file — never committing the reintroduced motif). This script itself is
# excluded from the scan: it necessarily spells out the literal patterns it screens for (the
# table above), so scanning it would make the invariant fail permanently on its own
# definition. Also asserts `.pipeline/` (gitignored, see .gitignore) never ends up tracked
# by accident (claude-agent-pipeline#256: a `.pipeline/plans/*.md` was tracked on main
# despite the ignore rule, from before the ignore rule existed).
NO_PRIVATE_REFS_HITS=""
NPR_I=0
while [ "$NPR_I" -lt "${#NO_PRIVATE_REFS_PATTERNS[@]}" ]; do
  NPR_PATTERN="${NO_PRIVATE_REFS_PATTERNS[$NPR_I]}"
  NPR_ALLOW="${NO_PRIVATE_REFS_ALLOW[$NPR_I]}"
  NPR_MATCHES="$(git grep -nEi "$NPR_PATTERN" -- . ':(exclude)tests/templates/test-canonical-guards.sh' 2>/dev/null)"
  if [ -n "$NPR_ALLOW" ] && [ -n "$NPR_MATCHES" ]; then
    NPR_MATCHES="$(echo "$NPR_MATCHES" | grep -vEi "$NPR_ALLOW")"
  fi
  if [ -n "$NPR_MATCHES" ]; then
    NO_PRIVATE_REFS_HITS="$NO_PRIVATE_REFS_HITS
$NPR_MATCHES"
  fi
  NPR_I=$((NPR_I + 1))
done
NPR_PIPELINE_TRACKED="$(git ls-files .pipeline | wc -l | tr -d ' ')"
if [ -n "$NO_PRIVATE_REFS_HITS" ]; then
  NPR_SITES="$(echo "$NO_PRIVATE_REFS_HITS" | grep -v '^$' | cut -d: -f1,2 | sort -u | tr '\n' ' ')"
  fail "no-private-refs" "${NPR_SITES}— remove the reference or replace it with a placeholder; never add to the allowlist without review"
elif [ "$NPR_PIPELINE_TRACKED" != "0" ]; then
  fail "no-private-refs" ".pipeline/ has $NPR_PIPELINE_TRACKED tracked file(s) despite .gitignore — git rm it, never leave it tracked"
else
  pass "no-private-refs: pattern table (${#NO_PRIVATE_REFS_PATTERNS[@]} entries) clean across the tracked tree; .pipeline/ untracked"
fi

. "$LIB/canonical-guards-agents-docs.sh"

# =============================================================================
# Trailer
# =============================================================================
if [ "$FAIL_N" -eq 0 ]; then
  echo "ALL CHECKS PASSED"
  VERDICT="ok"
else
  echo "SOME CHECKS FAILED"
  VERDICT="fail"
fi
echo "[guards] status=${VERDICT} passed=${PASS_N} failed=${FAIL_N}"
if [ "$FAIL_N" -eq 0 ]; then exit 0; else exit 1; fi
