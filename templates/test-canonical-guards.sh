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
# sam-parity, doc-budgets), 24 critical-paths-proven.
#
# Enforcement note (#54 MANDATORY 2, human decision 2026-08-23): this repo is PRIVATE on a
# plan where branch protection and rulesets are both unavailable (verified this session:
# `gh api repos/Zigzag968/claude-code-lgtmgate/branches/main/protection` and
# `.../rulesets` both return 403 "Upgrade to GitHub Pro or make this repository public to
# enable this feature"). `.github/workflows/guards.yml` runs this script on every PR to
# main and REPORTS; it CANNOT be a required check on this repo. Enforcement is therefore
# human: this script's verdict is a mandatory acceptance-checklist line on every PR that
# touches the shipped surface, and no PR merges with a red `guards` line — the acceptance
# box stays unticked and block-merge-unchecked.sh refuses the merge. The pre-commit hook
# below is a local pre-check only (per-clone `core.hooksPath` opt-in), not the enforcement.
#
# Fully offline / non-interactive. Run from anywhere; resolves the repo root itself:
#   bash templates/test-canonical-guards.sh

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
# =============================================================================
# Invariant 2 — stamp-parity
# =============================================================================
if [ -f "$WORKFLOW_FILE" ] && [ -f "$MANIFEST" ]; then
  BUILD_VERSION="$(python3 -c "
import re
src = open('$WORKFLOW_FILE').read()
m = re.search(r\"const BUILD = \{[^}]*version: '([^']+)'\", src)
print(m.group(1) if m else '')
" 2>/dev/null)"
  MANIFEST_VERSION="$(python3 -c "import json; print(json.load(open('$MANIFEST')).get('version',''))" 2>/dev/null)"
  if [ -z "$BUILD_VERSION" ]; then
    fail "stamp-parity" "could not find const BUILD = { ... version: '...' } in $WORKFLOW_FILE"
  elif [ "$BUILD_VERSION" != "$MANIFEST_VERSION" ]; then
    fail "stamp-parity" "BUILD.version ($BUILD_VERSION) != $MANIFEST version ($MANIFEST_VERSION)"
  else
    pass "stamp-parity: BUILD.version ($BUILD_VERSION) == $MANIFEST version"
  fi
else
  fail "stamp-parity" "$WORKFLOW_FILE or $MANIFEST missing"
fi

# =============================================================================
# Invariant 3 — marketplace-pin
# =============================================================================
MARKETPLACE=".claude-plugin/marketplace.json"
if [ -f "$MARKETPLACE" ]; then
  PIN_SHA="$(python3 -c "
import json
d = json.load(open('$MARKETPLACE'))
entries = [p for p in d.get('plugins', []) if p.get('name') == 'lgtmgate']
print(entries[0].get('source', {}).get('sha', '') if entries else '')
" 2>/dev/null)"
  if [ -z "$PIN_SHA" ]; then
    fail "marketplace-pin" "no 'lgtmgate' entry (selected by name) with a source.sha in $MARKETPLACE"
  elif ! echo "$PIN_SHA" | grep -qE '^[0-9a-f]{40}$'; then
    fail "marketplace-pin" "source.sha '$PIN_SHA' is not a 40-hex commit SHA"
  elif ! git cat-file -e "${PIN_SHA}^{commit}" 2>/dev/null; then
    fail "marketplace-pin" "source.sha $PIN_SHA does not resolve to a commit in this repo"
  else
    pass "marketplace-pin: lgtmgate source.sha $PIN_SHA is a 40-hex commit that resolves"
  fi
else
  fail "marketplace-pin" "$MARKETPLACE missing"
fi

# =============================================================================
# Invariant 4 — stamp-placement
# =============================================================================
if [ -f "$WORKFLOW_FILE" ]; then
  LOG_LINE="$(grep -n '^log(BUILD_STAMP)' "$WORKFLOW_FILE" | head -1 | cut -d: -f1)"
  ARGS_LINE="$(grep -n '} = (typeof args === .string.' "$WORKFLOW_FILE" | head -1 | cut -d: -f1)"
  DRYRUN_LINE="$(grep -n '^if (dryRun) return' "$WORKFLOW_FILE" | head -1 | cut -d: -f1)"
  FINISH_PRESENT="$(grep -c 'const finish = ' "$WORKFLOW_FILE")"
  BARE_RETURNS="$(python3 -c "
import re
src = open('$WORKFLOW_FILE').read()
print(len(re.findall(r'return\s*\{\s*status:', src)))
" 2>/dev/null)"
  if [ -z "$LOG_LINE" ] || [ -z "$ARGS_LINE" ] || [ -z "$DRYRUN_LINE" ]; then
    fail "stamp-placement" "could not locate log(BUILD_STAMP) / args destructure / dryRun return in $WORKFLOW_FILE"
  elif [ "$LOG_LINE" -ge "$ARGS_LINE" ] || [ "$LOG_LINE" -ge "$DRYRUN_LINE" ]; then
    fail "stamp-placement" "log(BUILD_STAMP) at line $LOG_LINE is not before the args destructure ($ARGS_LINE) and the dryRun return ($DRYRUN_LINE)"
  elif [ "$FINISH_PRESENT" -eq 0 ]; then
    fail "stamp-placement" "no 'const finish = ' found in $WORKFLOW_FILE"
  elif [ -z "$BARE_RETURNS" ] || ! echo "$BARE_RETURNS" | grep -qE '^[0-9]+$'; then
    fail "stamp-placement" "could not count bare 'return { status:' sites in $WORKFLOW_FILE"
  elif [ "$BARE_RETURNS" -ne 0 ]; then
    fail "stamp-placement" "$BARE_RETURNS bare unstamped 'return { status:' site(s) (whitespace/newline tolerant) remain unwrapped in $WORKFLOW_FILE"
  else
    pass "stamp-placement: log(BUILD_STAMP) precedes the args destructure + dryRun return; finish() present; 0 bare status returns (whitespace/newline tolerant)"
  fi
else
  fail "stamp-placement" "$WORKFLOW_FILE missing"
fi

# =============================================================================
# Invariant 5 — persona-anchors
# =============================================================================
if [ -f "$WORKFLOW_FILE" ]; then
  MISSING=""
  for anchor in AGENT_TYPE_UNRESOLVED personaFallback THEO_PERSONA; do
    if ! grep -q "$anchor" "$WORKFLOW_FILE"; then
      MISSING="$MISSING $anchor"
    fi
  done
  if [ -n "$MISSING" ]; then
    fail "persona-anchors" "missing anchor(s) in $WORKFLOW_FILE:$MISSING"
  else
    pass "persona-anchors: AGENT_TYPE_UNRESOLVED, personaFallback, THEO_PERSONA all present"
  fi
else
  fail "persona-anchors" "$WORKFLOW_FILE missing"
fi

# =============================================================================
# Invariant 6 — retired-copies
# =============================================================================
# Path built via concatenation, never as a literal contiguous string: this repo's own
# "zero dangling references to the retired templates/ path" acceptance check greps the
# tracked tree for exactly that substring, and this invariant's own job is to assert its
# ABSENCE, not reference it as a live caller would.
OLD_TEMPLATES_PATH="templates""/deliver-pipeline.js"
STILL_PRESENT=""
for retired in .claude/workflows/deliver-pipeline.js .claude/workflows/test-deliver-pipeline.js "$OLD_TEMPLATES_PATH"; do
  if [ -e "$retired" ]; then
    STILL_PRESENT="$STILL_PRESENT $retired"
  fi
done
if [ -n "$STILL_PRESENT" ]; then
  fail "retired-copies" "still present:$STILL_PRESENT"
else
  pass "retired-copies: .claude/workflows/deliver-pipeline.js, .claude/workflows/test-deliver-pipeline.js, and the retired templates/ copy all absent"
fi

# =============================================================================
# Invariant 7 — ci-wired
# =============================================================================
GUARDS_YML=".github/workflows/guards.yml"
PRE_COMMIT=".githooks/pre-commit"
if [ ! -f "$GUARDS_YML" ]; then
  fail "ci-wired" "$GUARDS_YML does not exist"
elif ! grep -q 'test-canonical-guards.sh' "$GUARDS_YML"; then
  fail "ci-wired" "$GUARDS_YML does not name test-canonical-guards.sh"
elif ! grep -q 'run-flow-suite.cjs' "$GUARDS_YML"; then
  fail "ci-wired" "$GUARDS_YML does not name run-flow-suite.cjs"
elif ! grep -q 'test-Stop-supervise-runs.sh' "$GUARDS_YML"; then
  fail "ci-wired" "$GUARDS_YML does not name test-Stop-supervise-runs.sh"
elif ! grep -q 'test-verify-workflow-launch.sh' "$GUARDS_YML"; then
  fail "ci-wired" "$GUARDS_YML does not name test-verify-workflow-launch.sh"
elif [ ! -f "$PRE_COMMIT" ]; then
  fail "ci-wired" "$PRE_COMMIT does not exist"
elif grep -qE '^[[:space:]]*exit 0[[:space:]]*$' "$PRE_COMMIT"; then
  fail "ci-wired" "$PRE_COMMIT still contains a bare 'exit 0' body"
else
  pass "ci-wired: $GUARDS_YML wired to all 4 scripts; $PRE_COMMIT no longer a bare exit 0"
fi

# =============================================================================
# Invariant 8 — self-reference-doctrine
# =============================================================================
# #83: the self-reference-preflight false-positive doctrine must be present on every doctrine
# site, and the two pr-acceptance.md copies must stay byte-identical mirrors.
SELF_REF_TOKEN="self-reference-preflight"
SELF_REF_SITES="templates/pr-acceptance.md .claude/rules/pr-acceptance.md agents/sam.md agents/nick.md agents/morgan.md commands/deliver.md $WORKFLOW_FILE"
SELF_REF_MISSING=""
for site in $SELF_REF_SITES; do
  if [ ! -f "$site" ] || ! grep -q "$SELF_REF_TOKEN" "$site"; then
    SELF_REF_MISSING="$SELF_REF_MISSING $site"
  fi
done
if [ -n "$SELF_REF_MISSING" ]; then
  fail "self-reference-doctrine" "missing '$SELF_REF_TOKEN' in:$SELF_REF_MISSING"
elif ! diff -q templates/pr-acceptance.md .claude/rules/pr-acceptance.md > /dev/null 2>&1; then
  fail "self-reference-doctrine" "templates/pr-acceptance.md and .claude/rules/pr-acceptance.md are not byte-identical"
else
  pass "self-reference-doctrine: $SELF_REF_TOKEN present on all doctrine sites; pr-acceptance.md mirrors identical"
fi

# =============================================================================
# Invariant 9 — headless-empty-argv
# =============================================================================
# Regression guard for claude-agent-pipeline#57: an empty PLUGIN_DIR_ARGS expansion under
# 'set -u' on bash 3.2 (macOS /usr/bin/env bash) aborts the script with "unbound variable"
# before it ever builds the claude argv — the no-flag invocation is the installed-cache
# control run MAINTAINING.md §1 prescribes, so this is not a corner case. Static anchor +
# offline smoke, no real claude/network/agent involved.
HEADLESS="${HEADLESS_SCRIPT:-scripts/run-workflow-headless.sh}"
if [ ! -f "$HEADLESS" ]; then
  fail "headless-empty-argv" "$HEADLESS does not exist"
elif ! grep -q 'PLUGIN_DIR_ARGS\[@\]+' "$HEADLESS"; then
  fail "headless-empty-argv" "$HEADLESS does not contain the guarded expansion PLUGIN_DIR_ARGS[@]+"
else
  HA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/headless-argv-guard.XXXXXXXX")"
  mkdir -p "$HA_DIR/bin"
  cat > "$HA_DIR/bin/claude" <<'STUB'
#!/bin/sh
printf "ARGV:"
for a in "$@"; do printf " <%s>" "$a"; done
printf "\n"
STUB
  chmod +x "$HA_DIR/bin/claude"
  HA_SH="/bin/bash"
  [ -x "$HA_SH" ] || HA_SH="bash"
  PATH="$HA_DIR/bin:$PATH" "$HA_SH" "$HEADLESS" --out "$HA_DIR/out.json" </dev/null > "$HA_DIR/log" 2>&1
  if grep -q 'unbound variable' "$HA_DIR/log"; then
    HA_DETAIL="$(grep -m1 'unbound variable' "$HA_DIR/log")"
    fail "headless-empty-argv" "$HEADLESS aborted with 'unbound variable' on a no-plugin-dir invocation: $HA_DETAIL"
  elif ! grep -q '\[wf-headless\] status=' "$HA_DIR/log"; then
    HA_DETAIL="$(tail -1 "$HA_DIR/log" | tr -d '\n')"
    fail "headless-empty-argv" "$HEADLESS produced no [wf-headless] status= trailer: $HA_DETAIL"
  else
    pass "headless-empty-argv: $HEADLESS survives an empty PLUGIN_DIR_ARGS under set -u and prints its trailer"
  fi
  rm -rf "$HA_DIR"
fi

# =============================================================================
# Invariant 10 — pr-body-structure
# =============================================================================
# #85: both PR-body composition sites (the Dev-phase Nick prompt in $WORKFLOW_FILE, and the
# generic persona doc agents/nick.md) must name the artifact-first section order,
# left-to-right: Closes #N -> ## What this ships -> ## Acceptance checklist (markers)
# -> decision-log markers -> Technical detail fold. Character-offset (not line-number)
# comparison is required because both sites are single-line/single-template-literal strings
# today — a line-number check would tie on every token. Uses the LAST occurrence of each token
# (str.rfind, not str.find): $WORKFLOW_FILE's decision-log composer (DECISION_LOG_START/
# DECISION_LOG_START_RE and its own comment illustrating "## What this ships") legitimately
# contains earlier, unrelated occurrences of two of these five tokens ABOVE the Dev-phase
# prompt — the exact same "earlier illustrative/example occurrence" problem
# DECISION_LOG_START_RE itself solves by anchoring on the LAST match (see the comment at its
# definition). The optional "## <Human> — N gestures" H2 is intentionally NOT one of the five
# checked tokens — it is conditional on a [human-gate] item existing in the checklist, so its
# absence in a given PR body is correct, not a violation.
PR_BODY_STRUCT_SITES="$WORKFLOW_FILE agents/nick.md"
for site in $PR_BODY_STRUCT_SITES; do
  if [ ! -f "$site" ]; then
    fail "pr-body-structure" "$site does not exist"
    continue
  fi
  RESULT="$(python3 -c "
tokens = ['Closes #', '## What this ships', '## Acceptance checklist', 'decision-log:start', '<details><summary>Technical detail']
src = open('$site').read()
offsets = [src.rfind(t) for t in tokens]
missing = [t for t, o in zip(tokens, offsets) if o == -1]
if missing:
    print('MISSING:' + '|'.join(missing))
elif offsets != sorted(offsets):
    print('ORDER')
else:
    print('OK')
" 2>/dev/null)"
  case "$RESULT" in
    OK)
      pass "pr-body-structure: $site names Closes #/What this ships/Acceptance checklist/decision-log markers/Technical detail fold in order"
      ;;
    MISSING:*)
      fail "pr-body-structure" "$site: missing token(s) ${RESULT#MISSING:}"
      ;;
    ORDER)
      fail "pr-body-structure" "$site: sections out of order"
      ;;
    *)
      fail "pr-body-structure" "$site: could not parse (python3 error or empty result)"
      ;;
  esac
done

# =============================================================================
# Invariant 11 — worktree-root-resolver
# =============================================================================
# #100/#61: resolveWorktreeRoot({env, configLocal, config, wtPath}) — layered, machine-free
# resolution. Base body ported verbatim from an internal reference implementation (env > config > wtPath's
# parent) so consumer projects can delete their repo-local pipeline copy without silently regressing the
# de-machined worktreeRoot; #61 adds the configLocal layer (gitignored, Lead-read
# .claude/pipeline.config.local.json) between env and the versioned config default, and requires
# the winning candidate to be an ABSOLUTE path (a relative/blank winner falls through to wtPath's
# parent instead of leaking a relative root into agent briefs). Extracts the sentinel-delimited
# resolver window from $WORKFLOW_FILE (same python3-regex technique as invariants 2/4), asserts
# wiring (call site + the Dev-phase `worktree root: ${worktreeRoot}` interpolation) and purity (no
# require(/readFileSync/import fs/__dirname in the window), then runs the EXTRACTED source itself
# (never a re-implementation) under one offline `node -e` subprocess against a resolution-order
# case table — proving a real-world case and this run's own real case both resolve
# correctly.
if [ -f "$WORKFLOW_FILE" ]; then
  WRR_WINDOW="$(python3 -c "
import re
src = open('$WORKFLOW_FILE').read()
m = re.search(r'// --- resolveWorktreeRoot:start ---.*?// --- resolveWorktreeRoot:end ---', src, re.S)
print(m.group(0) if m else '')
" 2>/dev/null)"
  if [ -z "$WRR_WINDOW" ]; then
    fail "worktree-root-resolver" "sentinel window resolveWorktreeRoot:start/:end not found in $WORKFLOW_FILE"
  elif ! grep -q 'const worktreeRoot = resolveWorktreeRoot({ env: runtimeEnv, configLocal, config, wtPath })' "$WORKFLOW_FILE"; then
    fail "worktree-root-resolver" "call site 'const worktreeRoot = resolveWorktreeRoot({ env: runtimeEnv, configLocal, config, wtPath })' missing in $WORKFLOW_FILE"
  elif ! grep -q 'worktree root: ${worktreeRoot}' "$WORKFLOW_FILE"; then
    fail "worktree-root-resolver" "Dev-phase interpolation 'worktree root: \${worktreeRoot}' missing in $WORKFLOW_FILE"
  elif echo "$WRR_WINDOW" | grep -qE 'require\(|readFileSync|import fs|__dirname'; then
    fail "worktree-root-resolver" "sentinel window contains a forbidden fs/require token (require(/readFileSync/import fs/__dirname)"
  else
    WRR_DIR="$(mktemp -d "${TMPDIR:-/tmp}/worktree-root-resolver.XXXXXXXX")"
    WRR_SRC="$WRR_DIR/resolver.js"
    printf '%s\n' "$WRR_WINDOW" > "$WRR_SRC"
    WRR_OUT="$(REPO_ROOT_CASE="$REPO_ROOT" node -e "
      const fs = require('fs')
      delete process.env.LGTMGATE_WORKTREE_ROOT
      eval(fs.readFileSync(process.argv[1], 'utf8'))
      const repoRoot = process.env.REPO_ROOT_CASE
      const repoRootParent = repoRoot.slice(0, repoRoot.lastIndexOf('/')) || '/'
      const cases = [
        ['env wins over configLocal and config', '/from/env',     {worktreeRoot: '/from/local'},  {worktreeRoot: '/from/config'}, '/a/b/c', '/from/env'],
        ['env trimmed',                          '  /from/env  ', {},                              {},                              '/a/b/c', '/from/env'],
        ['env unset falls to configLocal',       null,            {worktreeRoot: '/from/local'},  {worktreeRoot: '/pinned'},       '/a/b/c', '/from/local'],
        ['env blank falls to configLocal',       '   ',           {worktreeRoot: '/from/local'},  {worktreeRoot: '/pinned'},       '/a/b/c', '/from/local'],
        ['configLocal empty falls to config pin', null,           {worktreeRoot: ''},              {worktreeRoot: '/pinned'},       '/a/b/c', '/pinned'],
        ['configLocal missing falls to config pin', null,         {},                              {worktreeRoot: '/pinned'},       '/a/b/c', '/pinned'],
        ['config empty string falls through',    null,            {},                              {worktreeRoot: ''},              '/a/b/c', '/a/b'],
        ['missing key falls to wtPath parent',   null,            {},                              {},                              '/a/b/c', '/a/b'],
        ['relative config falls to wtPath parent', null,          {},                              {worktreeRoot: '../worktrees/repo'}, '/a/b/c', '/a/b'],
        ['filesystem-root edge',                 null,            {},                              {},                              '/onlyroot', '/'],
        ['config w/o worktreeRoot key',          null,            {},                              {baseBranch: 'develop'},         '/x/y/proj-issue-763', '/x/y'],
        ['a real-world case',                    null,            {},                              {},                              '/Users/dev/Worktrees/my-project/issue-799', '/Users/dev/Worktrees/my-project'],
        ['this run own real case',               null,            {},                              {},                              repoRoot, repoRootParent],
      ]
      const failures = []
      for (const [name, env, configLocal, config, wtPath, expected] of cases) {
        if (env === null) delete process.env.LGTMGATE_WORKTREE_ROOT
        else process.env.LGTMGATE_WORKTREE_ROOT = env
        const got = resolveWorktreeRoot({ env: process.env, configLocal, config, wtPath })
        if (got !== expected) failures.push(name + ': expected ' + JSON.stringify(expected) + ', got ' + JSON.stringify(got))
        delete process.env.LGTMGATE_WORKTREE_ROOT
      }
      console.log(failures.length ? ('FAIL:' + failures.join(' ;; ')) : 'OK')
    " "$WRR_SRC" 2>&1)"
    rm -rf "$WRR_DIR"
    case "$WRR_OUT" in
      OK)
        pass "worktree-root-resolver: sentinel body verbatim (no require/readFileSync/import fs/__dirname), call site + Dev-phase interpolation wired, 13/13 resolution-order cases pass (env wins/trimmed/blank, configLocal layer, config pin, empty-string/missing-key/relative fallthrough, wtPath-parent, filesystem-root edge, a real-world case, this run's own real case)"
        ;;
      FAIL:*)
        fail "worktree-root-resolver" "${WRR_OUT#FAIL:}"
        ;;
      *)
        fail "worktree-root-resolver" "could not evaluate extracted resolver (node error): $WRR_OUT"
        ;;
    esac
  fi
else
  fail "worktree-root-resolver" "$WORKFLOW_FILE missing"
fi

# =============================================================================
# Invariant 12 — blocked-by-signal
# =============================================================================
# #104: the read-only cross-repo `blockedBy` resolver + its offline test, wired into this
# repo's own guard net. Static anchor (script exists, all five verdict tokens present, install
# slot named in commands/init.md) + runs templates/test-blocked-by-check.sh itself (offline, no
# network, no real `gh` — probe is BLOCKED_BY_PROBE_CMD-stubbed) and requires its own
# "N/N PASS" summary with zero FAIL lines.
BBC_SCRIPT="templates/blocked-by-check.sh"
BBC_TEST="templates/test-blocked-by-check.sh"
if [ ! -f "$BBC_SCRIPT" ]; then
  fail "blocked-by-signal" "$BBC_SCRIPT does not exist"
elif ! grep -q 'none' "$BBC_SCRIPT" || ! grep -q 'resolved' "$BBC_SCRIPT" \
     || ! grep -q 'pending' "$BBC_SCRIPT" || ! grep -q 'abandoned' "$BBC_SCRIPT" \
     || ! grep -q 'unknown' "$BBC_SCRIPT"; then
  fail "blocked-by-signal" "$BBC_SCRIPT is missing one of the five verdict tokens (none/resolved/pending/abandoned/unknown)"
elif [ ! -f "$BBC_TEST" ]; then
  fail "blocked-by-signal" "$BBC_TEST does not exist"
elif ! grep -q 'templates/blocked-by-check.sh' commands/init.md 2>/dev/null; then
  fail "blocked-by-signal" "commands/init.md does not name templates/blocked-by-check.sh as an install slot"
else
  BBC_OUT="$(bash "$BBC_TEST" 2>&1)"
  BBC_EXIT=$?
  BBC_LAST="$(echo "$BBC_OUT" | tail -1)"
  if [ "$BBC_EXIT" -ne 0 ]; then
    fail "blocked-by-signal" "$BBC_TEST exited $BBC_EXIT: $(echo "$BBC_OUT" | tail -5)"
  elif ! echo "$BBC_LAST" | grep -qE '^([0-9]+)/([0-9]+) PASS$'; then
    fail "blocked-by-signal" "$BBC_TEST did not print a final 'N/N PASS' summary (last line: $BBC_LAST)"
  elif echo "$BBC_OUT" | grep -q '^FAIL'; then
    fail "blocked-by-signal" "$BBC_TEST printed a FAIL line despite exit 0: $(echo "$BBC_OUT" | grep '^FAIL' | head -3)"
  else
    BBC_GOT="$(echo "$BBC_LAST" | sed -E 's#^([0-9]+)/([0-9]+) PASS$#\1 \2#')"
    BBC_P="${BBC_GOT% *}"; BBC_TOT="${BBC_GOT#* }"
    if [ "$BBC_P" != "$BBC_TOT" ]; then
      fail "blocked-by-signal" "$BBC_TEST summary is not N/N (some cases failed): $BBC_LAST"
    else
      pass "blocked-by-signal: $BBC_SCRIPT + $BBC_TEST present, install slot wired in commands/init.md, offline suite green ($BBC_LAST)"
    fi
  fi
fi

# =============================================================================
# Invariant 13 — single-export
# =============================================================================
# #132: the real Workflow tool's script loader tolerates exactly ONE top-level `export`
# (the `export const meta = {...}` header every workflow script requires) and throws
# `SyntaxError: Unexpected keyword 'export'` on a second one — confirmed live: 0.8.14 added
# `export const reviewerWindowCandidates` alongside `meta` and was unlaunchable via the
# Workflow tool. scripts/run-flow-suite.cjs's own `stripExports` (`/^export\s+/mg`) strips
# EVERY top-level export unconditionally, so the offline flow-suite and CI stayed green on a
# script the real tool could not run at all — a stricter check than the offline harness is
# exactly what this invariant adds, so this exact regression class cannot ship green again.
# Counts top-level `^export\b` lines in $WORKFLOW_FILE: must be exactly 1, and that one line
# must be the `export const meta = {` header.
if [ -f "$WORKFLOW_FILE" ]; then
  SE_COUNT="$(grep -cE '^export\b' "$WORKFLOW_FILE")"
  SE_LINE="$(grep -E '^export\b' "$WORKFLOW_FILE" | head -1)"
  if [ "$SE_COUNT" -eq 0 ]; then
    fail "single-export" "$WORKFLOW_FILE has zero top-level exports — 'export const meta = {' header is missing"
  elif [ "$SE_COUNT" -gt 1 ]; then
    fail "single-export" "$WORKFLOW_FILE has $SE_COUNT top-level exports (must be exactly 1 — the 'meta' header); the real Workflow tool's loader throws on a second one"
  elif ! echo "$SE_LINE" | grep -q '^export const meta'; then
    fail "single-export" "the sole top-level export in $WORKFLOW_FILE is not 'export const meta = {' (found: $SE_LINE)"
  else
    pass "single-export: exactly 1 top-level export in $WORKFLOW_FILE ('export const meta = {')"
  fi
else
  fail "single-export" "$WORKFLOW_FILE missing"
fi

# =============================================================================
# Invariant 14 — project-item-lookup
# =============================================================================
# #137: updateStatus() must resolve a GH Project item id from the ISSUE's own projectItems
# connection, NEVER by scanning the board with `gh project item-list` (the board scan
# defaults to 30 items and returns nothing for any issue past the first page). The
# repo-agnostic gh-pipeline-status.sh helpers are a deliberate exception (no owner/repo to
# query an issue-side connection with) and are bounded with --limit instead — checked here
# too, plus their required byte-identity as mirrored copies.
GH_STATUS_A="templates/gh-pipeline-status.sh"
GH_STATUS_B=".claude/scripts/gh-pipeline-status.sh"
if [ -f "$WORKFLOW_FILE" ] && grep -q 'gh project item-list' "$WORKFLOW_FILE"; then
  fail "project-item-lookup" "$WORKFLOW_FILE still calls 'gh project item-list' (board scan) — updateStatus() must use the issue's own projectItems connection instead"
elif [ -f "templates/pr-write.sh" ] && grep -q 'gh project item-list' "templates/pr-write.sh"; then
  fail "project-item-lookup" "templates/pr-write.sh still calls 'gh project item-list' (board scan)"
elif [ ! -f "templates/pr-write.sh" ] || ! grep -q 'projectItems(first:' "templates/pr-write.sh" || ! grep -q 'select(.project.number==' "templates/pr-write.sh"; then
  # #85: the status write moved from updateStatus()'s haiku prompt into templates/pr-write.sh (op status).
  fail "project-item-lookup" "templates/pr-write.sh is missing the issue-side GraphQL projectItems lookup (projectItems(first: / select(.project.number==)"
elif [ ! -f "$GH_STATUS_A" ] || [ ! -f "$GH_STATUS_B" ]; then
  fail "project-item-lookup" "one or both of $GH_STATUS_A / $GH_STATUS_B is missing"
elif ! cmp -s "$GH_STATUS_A" "$GH_STATUS_B"; then
  fail "project-item-lookup" "$GH_STATUS_A and $GH_STATUS_B are not byte-identical"
elif ! grep -q 'gh project item-list.*--limit' "$GH_STATUS_A" || ! grep -q 'gh project item-list.*--limit' "$GH_STATUS_B"; then
  fail "project-item-lookup" "the 'gh project item-list' call in $GH_STATUS_A / $GH_STATUS_B is missing --limit"
else
  pass "project-item-lookup: $WORKFLOW_FILE uses the issue's own projectItems connection (no board scan); $GH_STATUS_A/$GH_STATUS_B remain identical board-scan mirrors, both bounded with --limit"
fi

# =============================================================================
# Invariant 15 — bash-3.2-floor
# =============================================================================
# #78 (shell-portability half only — the bump-required exclusion-list half of #78 is a
# human call per that issue's own body, not actioned here). macOS ships bash 3.2
# (/bin/bash, /usr/bin/env bash) — this repo has already been bitten twice by bash4+-only
# constructs slipping into a tracked *.sh file (scripts/provision_worktree.sh,
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
BASH32_SELF="templates/test-canonical-guards.sh"
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

# =============================================================================
# Invariant 16 — backlog-bump-required
# =============================================================================
# #218: plugins/backlog/ is a SEPARATE plugin with its own manifest and version, excluded from
# invariant 1 by name. Same delivery rule, scoped to it: a change to its shipped surface without a
# bump of ITS version delivers nothing to an installed cache. Watched = everything under
# plugins/backlog/ except tests/ and README.md (no execution surface). A brand-new plugin (manifest
# absent on origin/main) passes with its initial version.
BL_DIR="plugins/backlog"
BL_MANIFEST="$BL_DIR/.claude-plugin/plugin.json"
if [ ! -f "$BL_MANIFEST" ]; then
  fail "backlog-bump-required" "$BL_MANIFEST does not exist"
elif ! git rev-parse --verify origin/main >/dev/null 2>&1; then
  fail "backlog-bump-required" "origin/main not resolvable in this checkout — run 'git fetch origin main' first"
else
  BL_NEW_VERSION="$(python3 -c "import json; print(json.load(open('$BL_MANIFEST')).get('version',''))" 2>/dev/null)"
  if [ -z "$BL_NEW_VERSION" ]; then
    fail "backlog-bump-required" "could not read the version of $BL_MANIFEST"
  elif ! git cat-file -e "origin/main:$BL_MANIFEST" 2>/dev/null; then
    pass "backlog-bump-required: new plugin (no $BL_MANIFEST on origin/main), initial version $BL_NEW_VERSION"
  elif git diff --quiet origin/main -- "$BL_DIR" ":(exclude)$BL_DIR/tests/" ":(exclude)$BL_DIR/README.md"; then
    pass "backlog-bump-required: no watched-surface diff under $BL_DIR against origin/main (inert on this checkout)"
  else
    BL_CHANGED="$(git diff --name-only origin/main -- "$BL_DIR" ":(exclude)$BL_DIR/tests/" ":(exclude)$BL_DIR/README.md" | head -1)"
    BL_OLD_VERSION="$(git show "origin/main:$BL_MANIFEST" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('version',''))" 2>/dev/null)"
    if [ -z "$BL_OLD_VERSION" ]; then
      fail "backlog-bump-required" "could not read origin/main's $BL_MANIFEST version"
    elif [ "$BL_OLD_VERSION" = "$BL_NEW_VERSION" ]; then
      fail "backlog-bump-required" "$BL_CHANGED changed without a version bump (still $BL_NEW_VERSION)"
    else
      pass "backlog-bump-required: watched surface changed, version bumped $BL_OLD_VERSION -> $BL_NEW_VERSION"
    fi
  fi
fi

# =============================================================================
# Invariant 17 — backlog-marketplace-pin
# =============================================================================
# #218: the `backlog` catalog entry is a git-subdir source scoped to plugins/backlog with a 40-hex
# sha that resolves in this repo, and its name matches the plugin manifest. Until the human's
# publish PR moves it, the sha is the lgtmgate's current pin (a commit that has no
# plugins/backlog/), so an install FAILS CLOSED instead of tracking main unpinned.
if [ ! -f "$MARKETPLACE" ] || [ ! -f "$BL_MANIFEST" ]; then
  fail "backlog-marketplace-pin" "$MARKETPLACE or $BL_MANIFEST missing"
else
  BL_PIN="$(python3 -c "
import json
d = json.load(open('$MARKETPLACE'))
m = json.load(open('$BL_MANIFEST'))
entries = [p for p in d.get('plugins', []) if p.get('name') == 'backlog']
if not entries:
    print('ERR:no entry named backlog')
else:
    e = entries[0]
    s = e.get('source')
    if not isinstance(s, dict):
        print('ERR:source is not an object')
    elif s.get('source') != 'git-subdir':
        print('ERR:source.source is ' + repr(s.get('source')) + ', not git-subdir')
    elif s.get('path') != 'plugins/backlog':
        print('ERR:source.path is ' + repr(s.get('path')) + ', not plugins/backlog')
    elif e.get('name') != m.get('name'):
        print('ERR:entry name differs from the manifest name')
    else:
        print('SHA:' + str(s.get('sha', '')))
" 2>/dev/null)"
  case "$BL_PIN" in
    ERR:*)
      fail "backlog-marketplace-pin" "${BL_PIN#ERR:}"
      ;;
    SHA:*)
      BL_SHA="${BL_PIN#SHA:}"
      if ! echo "$BL_SHA" | grep -qE '^[0-9a-f]{40}$'; then
        fail "backlog-marketplace-pin" "source.sha '$BL_SHA' is not a 40-hex commit SHA"
      elif ! git cat-file -e "${BL_SHA}^{commit}" 2>/dev/null; then
        fail "backlog-marketplace-pin" "source.sha $BL_SHA does not resolve to a commit in this repo"
      else
        pass "backlog-marketplace-pin: backlog is a git-subdir source at plugins/backlog pinned to $BL_SHA (a 40-hex commit that resolves)"
      fi
      ;;
    *)
      fail "backlog-marketplace-pin" "could not evaluate the backlog entry of $MARKETPLACE (python3 error or empty result)"
      ;;
  esac
fi

# =============================================================================
# Invariant 18 — backlog-suite
# =============================================================================
# #218: every backlog skill ships `disable-model-invocation: true` (zero always-loaded context), the
# manifest's hooks file exists, and the plugin's own offline unittest suite (fake gh on PATH, no
# network) is green. The suite's stderr carries the unittest summary; its last line must start with OK.
BL_SKILLS="$(ls "$BL_DIR"/skills/*/SKILL.md 2>/dev/null)"
BL_BAD_SKILLS=""
for f in $BL_SKILLS; do
  if ! grep -q '^disable-model-invocation: true$' "$f"; then
    BL_BAD_SKILLS="$BL_BAD_SKILLS $f"
  fi
done
BL_HOOKS_REL="$(python3 -c "import json; print(json.load(open('$BL_MANIFEST')).get('hooks',''))" 2>/dev/null)"
if [ -z "$BL_SKILLS" ]; then
  fail "backlog-suite" "no $BL_DIR/skills/*/SKILL.md found"
elif [ -n "$BL_BAD_SKILLS" ]; then
  fail "backlog-suite" "skill(s) without 'disable-model-invocation: true':$BL_BAD_SKILLS"
elif [ -z "$BL_HOOKS_REL" ] || [ ! -f "$BL_DIR/$BL_HOOKS_REL" ]; then
  fail "backlog-suite" "manifest hooks file '$BL_HOOKS_REL' does not exist under $BL_DIR"
else
  BL_OUT="$(PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover -s "$BL_DIR/tests" 2>&1 >/dev/null)"
  BL_EXIT=$?
  BL_LAST="$(echo "$BL_OUT" | tail -1)"
  BL_RAN="$(echo "$BL_OUT" | grep -E '^Ran [0-9]+ tests? ' | head -1)"
  if [ "$BL_EXIT" -ne 0 ]; then
    fail "backlog-suite" "unittest exited $BL_EXIT: $(echo "$BL_OUT" | tail -5 | tr '\n' ' ')"
  elif ! echo "$BL_LAST" | grep -qE '^OK'; then
    fail "backlog-suite" "unittest output does not end with OK (last line: $BL_LAST)"
  else
    pass "backlog-suite: skills all disable-model-invocation, hooks file present, offline suite green ($BL_RAN; $BL_LAST)"
  fi
fi

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
  NPR_MATCHES="$(git grep -nEi "$NPR_PATTERN" -- . ':(exclude)templates/test-canonical-guards.sh' 2>/dev/null)"
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

# =============================================================================
# Invariant 20 — reviewer-window-scan-bounded
# =============================================================================
# lgtmgate#18: flagReviewerWindowIssues() used to scan open issues with a flat `--limit 1000`
# and NO server-side date bound — past 1000 open issues on the target repo, `gh issue list`
# silently truncates (no error, no warning) and the downstream reviewerWindowCandidates()
# filter treated that partial page as exhaustive. Fixed by bounding the query with the GitHub
# search `created:>=<windowStart>` qualifier, so the result set is scoped to the review round's
# (minutes-to-hours-wide) window instead of the whole open-issue backlog. E2.5 (#84) moved the scan
# out of the workflow into templates/pr-state.sh (the workflow no longer builds any `gh` command for
# it); this is a STATIC guard (grep against that script, not a live `gh` call) and stays the durable
# regression guard. The runtime belt-and-suspenders assertion is the script's own exact-limit check
# (`openIssuesTruncated`, pr-state.sh), replayed in templates/test-probe-run.sh.
RWS_FILE="${RWS_FILE:-templates/pr-state.sh}"
if [ -f "$RWS_FILE" ]; then
  SCAN_LINE="$(grep -n 'gh issue list --state open' "$RWS_FILE" | head -1)"
  if [ -z "$SCAN_LINE" ]; then
    fail "reviewer-window-scan-bounded" "no 'gh issue list --state open' call found in $RWS_FILE"
  elif ! echo "$SCAN_LINE" | grep -q -- '--search "created:>='; then
    fail "reviewer-window-scan-bounded" "reviewer-window issue scan is missing a '--search \"created:>=\"' bound — a flat --limit alone silently truncates past the limit (lgtmgate#18): $SCAN_LINE"
  elif ! grep -q 'REVIEWER_WINDOW_SCAN_SAFETY_LIMIT' "$RWS_FILE"; then
    fail "reviewer-window-scan-bounded" "REVIEWER_WINDOW_SCAN_SAFETY_LIMIT (exact-limit truncation guard) not found in $RWS_FILE"
  else
    pass "reviewer-window-scan-bounded: reviewer-window issue scan ($RWS_FILE) is date-bounded via --search \"created:>=\"; safety-limit truncation guard present"
  fi
else
  fail "reviewer-window-scan-bounded" "$RWS_FILE missing"
fi

# =============================================================================
# Invariant 21 — gitdir-probe-no-rm
# =============================================================================
# #99: the git-dir write probe ran `touch ... && rm -f ...`; a repo whose settings deny
# `Bash(rm *)` refused the whole command and the haiku agent answered with prose, escalating
# the run. The probe must use `unlink`, never an `rm` token. Since #83 the probe lives in
# templates/preflight.sh (run by probe-run.cjs), no longer in a prompt of the workflow.
# Static grep on the probe lines.
GDP_FILE="${GDP_FILE:-templates/preflight.sh}"
if [ -f "$GDP_FILE" ]; then
  GDP_LINES="$(grep -n 'pipeline-write-probe' -A1 "$GDP_FILE")"
  if [ -z "$GDP_LINES" ]; then
    fail "gitdir-probe-no-rm" "no 'pipeline-write-probe' command found in $GDP_FILE"
  elif echo "$GDP_LINES" | grep -qE '\brm\b'; then
    fail "gitdir-probe-no-rm" "git-dir write probe contains an rm token (denied by Bash(rm *) settings, #99) — use unlink: $GDP_LINES"
  else
    pass "gitdir-probe-no-rm: git-dir write probe has no rm token (unlink)"
  fi
else
  fail "gitdir-probe-no-rm" "$GDP_FILE missing"
fi

# =============================================================================
# Invariant 22 — no-destructive-checkout
# =============================================================================
# #33 (RC-5): Nick's Dev-phase prompt told him to force-reset the expected branch, which
# silently discarded commits on a canonical branch. The destructive form must never come back
# in the prompt or the agent definitions. Static grep over tracked files (test-* files excluded:
# they spell the literal), plus $WORKFLOW_FILE explicitly so a negative test on a throwaway
# copy can fire.
NDC_HITS=""
NDC_FILES="$(git ls-files workflows agents templates .claude 2>/dev/null)"
for ndc_f in $NDC_FILES; do
  case "$(basename "$ndc_f")" in test-*) continue ;; esac
  [ -f "$ndc_f" ] || continue
  ndc_out="$(grep -n 'checkout -B' "$ndc_f" 2>/dev/null)" || ndc_out=""
  if [ -n "$ndc_out" ]; then NDC_HITS="${NDC_HITS}${ndc_f}: ${ndc_out}; "; fi
done
if [ -f "$WORKFLOW_FILE" ]; then
  ndc_out="$(grep -n 'checkout -B' "$WORKFLOW_FILE" 2>/dev/null)" || ndc_out=""
  case "$NDC_HITS" in
    *"${WORKFLOW_FILE}: "*) ;;
    *) if [ -n "$ndc_out" ]; then NDC_HITS="${NDC_HITS}${WORKFLOW_FILE}: ${ndc_out}; "; fi ;;
  esac
  if [ -n "$NDC_HITS" ]; then
    fail "no-destructive-checkout" "destructive branch reset found — use switch/switch -c (#33): ${NDC_HITS}"
  else
    pass "no-destructive-checkout: no force-reset checkout in workflows/agents/templates/.claude"
  fi
else
  fail "no-destructive-checkout" "$WORKFLOW_FILE missing"
fi

# =============================================================================
# Invariant 23 — guards-cjs
# =============================================================================
# scripts/guards.cjs prints its own PASS:/R1 lines; a non-zero exit is one FAIL here.
# Needs origin/main (CI checks out with fetch-depth: 0 / runs `git fetch origin main`).
if [ -f scripts/guards.cjs ]; then
  if command -v node >/dev/null 2>&1; then
    G_OUT="$(node scripts/guards.cjs 2>&1)"; G_RC=$?
    echo "$G_OUT"
    if [ "$G_RC" -eq 0 ]; then
      pass "guards-cjs: R1 ratchet, all-tests-wired and version floor ok"
    else
      fail "guards-cjs" "scripts/guards.cjs exited $G_RC (see lines above; run 'git fetch origin main' if origin/main is missing)"
    fi
  else
    fail "guards-cjs" "node not found"
  fi
else
  fail "guards-cjs" "scripts/guards.cjs missing"
fi

# =============================================================================
# Invariant 24 — critical-paths-proven
# =============================================================================
# docs/critical-paths.md (#77): every `- CP-<n>` line names a proof that exists — a flow-suite test
# id present in templates/test-deliver-pipeline.js, or a fixture/script path present in the repo.
# A declared critical path without its proof is a FAIL; the file itself is a one-way door (R3).
CP_FILE="docs/critical-paths.md"
if [ -f "$CP_FILE" ]; then
  CP_MISSING=""
  CP_COUNT=0
  while IFS= read -r cp_line; do
    CP_COUNT=$((CP_COUNT + 1))
    cp_proof="$(printf '%s\n' "$cp_line" | sed -nE 's/.*proof: `([^`]+)`.*/\1/p')"
    if [ -z "$cp_proof" ]; then
      CP_MISSING="$CP_MISSING $(printf '%s' "$cp_line" | cut -d' ' -f2)(no-proof)"
    elif [ -e "$cp_proof" ]; then
      :
    elif grep -qF "testCase('$cp_proof " templates/test-deliver-pipeline.js 2>/dev/null; then
      :
    else
      CP_MISSING="$CP_MISSING $(printf '%s' "$cp_line" | cut -d' ' -f2)($cp_proof)"
    fi
  done < <(grep -E '^- CP-[0-9]+ ' "$CP_FILE")
  if [ "$CP_COUNT" -eq 0 ]; then
    fail "critical-paths-proven" "$CP_FILE declares no '- CP-<n>' line"
  elif [ -n "$CP_MISSING" ]; then
    fail "critical-paths-proven" "proof missing for:$CP_MISSING"
  else
    pass "critical-paths-proven: $CP_COUNT critical paths, every proof exists"
  fi
else
  fail "critical-paths-proven" "$CP_FILE missing"
fi

# =============================================================================
# Trailer
# =============================================================================
if [ "$FAIL_N" -eq 0 ]; then
  echo "ALL CHECKS PASSED"
  STATUS="ok"
else
  echo "SOME CHECKS FAILED"
  STATUS="fail"
fi
echo "[guards] status=${STATUS} passed=${PASS_N} failed=${FAIL_N}"
if [ "$FAIL_N" -eq 0 ]; then exit 0; else exit 1; fi
