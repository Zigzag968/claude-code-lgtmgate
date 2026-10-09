#!/usr/bin/env bash
# Invariants 2 to 14: stamp, pin, placement, anchors, CI wiring, workflow shape (sourced by tests/templates/test-canonical-guards.sh, never executed).
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
  ARGS_LINE="$(grep -n '^const argsIn = (typeof args === .string.' "$WORKFLOW_FILE" | head -1 | cut -d: -f1)"
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
SELF_REF_SITES="templates/pr-acceptance.md .claude/rules/pr-acceptance.md agents/sam.md agents/nick.md agents/morgan.md skills/deliver/SKILL.md $WORKFLOW_FILE"
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
# #85: both PR-body composition sites (the Dev-stage Nick prompt in $WORKFLOW_FILE, and the
# generic persona doc agents/nick.md) must name the artifact-first section order,
# left-to-right: Closes #N -> ## What this ships -> ## Acceptance checklist (markers)
# -> decision-log markers -> Technical detail fold. Character-offset (not line-number)
# comparison is required because both sites are single-line/single-template-literal strings
# today — a line-number check would tie on every token. Uses the LAST occurrence of each token
# (str.rfind, not str.find): $WORKFLOW_FILE's decision-log composer (DECISION_LOG_START/
# DECISION_LOG_START_RE and its own comment illustrating "## What this ships") legitimately
# contains earlier, unrelated occurrences of two of these five tokens ABOVE the Dev-stage
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
# wiring (call site + the Dev-stage `worktree root: ${worktreeRoot}` interpolation) and purity (no
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
    fail "worktree-root-resolver" "Dev-stage interpolation 'worktree root: \${worktreeRoot}' missing in $WORKFLOW_FILE"
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
        pass "worktree-root-resolver: sentinel body verbatim (no require/readFileSync/import fs/__dirname), call site + Dev-stage interpolation wired, 13/13 resolution-order cases pass (env wins/trimmed/blank, configLocal layer, config pin, empty-string/missing-key/relative fallthrough, wtPath-parent, filesystem-root edge, a real-world case, this run's own real case)"
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
# slot named in skills/init/SKILL.md) + runs tests/templates/test-blocked-by-check.sh itself (offline, no
# network, no real `gh` — probe is BLOCKED_BY_PROBE_CMD-stubbed) and requires its own
# "N/N PASS" summary with zero FAIL lines.
BBC_SCRIPT="templates/blocked-by-check.sh"
BBC_TEST="tests/templates/test-blocked-by-check.sh"
if [ ! -f "$BBC_SCRIPT" ]; then
  fail "blocked-by-signal" "$BBC_SCRIPT does not exist"
elif ! grep -q 'none' "$BBC_SCRIPT" || ! grep -q 'resolved' "$BBC_SCRIPT" \
     || ! grep -q 'pending' "$BBC_SCRIPT" || ! grep -q 'abandoned' "$BBC_SCRIPT" \
     || ! grep -q 'unknown' "$BBC_SCRIPT"; then
  fail "blocked-by-signal" "$BBC_SCRIPT is missing one of the five verdict tokens (none/resolved/pending/abandoned/unknown)"
elif [ ! -f "$BBC_TEST" ]; then
  fail "blocked-by-signal" "$BBC_TEST does not exist"
elif ! grep -q 'templates/blocked-by-check.sh' skills/init/SKILL.md 2>/dev/null; then
  fail "blocked-by-signal" "skills/init/SKILL.md does not name templates/blocked-by-check.sh as an install slot"
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
      pass "blocked-by-signal: $BBC_SCRIPT + $BBC_TEST present, install slot wired in skills/init/SKILL.md, offline suite green ($BBC_LAST)"
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

