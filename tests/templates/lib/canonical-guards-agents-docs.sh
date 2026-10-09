#!/usr/bin/env bash
# Invariants 20 to 34: reviewer window, agents and docs parity (sourced by tests/templates/test-canonical-guards.sh, never executed).
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
# (`openIssuesTruncated`, pr-state.sh), replayed in tests/templates/test-probe-run.sh.
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
# #33 (RC-5): Nick's Dev-stage prompt told him to force-reset the expected branch, which
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
# Invariant 26 — stories-covered
# =============================================================================
# docs/specifics-stories.md (#262, epic #261): each story row (`| US-<x><n> | ... | <issue> | <proof> |`) is proven,
# or `doc`. Proven = a fixture $SPECIFICS_FIXTURES_DIR/us-<lowercase id>-*.json, or the id spelled
# (whole word) in a test file or one of its sourced parts under tests/*/lib; the Proof column is never read as evidence. A fixture whose id has no row is a FAIL.
# STORIES_FILE / SPECIFICS_FIXTURES_DIR are overrides used
# only by negative tests on throwaway copies under .pipeline/. This file is in the grep target set: never spell a real
# story id here, only the `US-<x><n>` placeholder.
STORIES_FILE="${STORIES_FILE:-docs/specifics-stories.md}"
SPECIFICS_FIXTURES_DIR="${SPECIFICS_FIXTURES_DIR:-fixtures/specifics}"
if [ ! -f "$STORIES_FILE" ]; then
  fail "stories-covered" "$STORIES_FILE missing"
else
  ST_COUNT=0
  ST_MISSING=""
  ST_IDS=" "
  while IFS= read -r st_line; do
    ST_COUNT=$((ST_COUNT + 1))
    st_id="$(printf '%s\n' "$st_line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}')"
    st_proof="$(printf '%s\n' "$st_line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $(NF-1)); print $(NF-1)}')"
    ST_IDS="$ST_IDS$st_id "
    if [ "$st_proof" = "doc" ]; then
      continue
    fi
    st_lower="$(printf '%s' "$st_id" | tr 'A-Z' 'a-z')"
    if ls "$SPECIFICS_FIXTURES_DIR"/${st_lower}-*.json >/dev/null 2>&1; then
      continue
    elif grep -qEw -- "$st_id" tests/scripts/test-*.sh tests/templates/test-*.sh tests/scripts/lib/*.sh tests/templates/lib/*.sh templates/test-*.js scripts/guards.cjs 2>/dev/null; then
      continue
    fi
    ST_MISSING="$ST_MISSING $st_id"
  done < <(grep -E '^\| US-[A-Z][0-9]+ \|' "$STORIES_FILE")
  ST_ORPHAN=""
  if [ -d "$SPECIFICS_FIXTURES_DIR" ]; then
    for st_f in "$SPECIFICS_FIXTURES_DIR"/us-*.json; do
      [ -e "$st_f" ] || continue
      st_base="$(basename "$st_f")"
      st_fid="$(printf '%s' "$st_base" | sed -E 's/^(us-[a-z][0-9]+)-.*/\1/' | tr 'a-z' 'A-Z')"
      case "$ST_IDS" in *" $st_fid "*) ;; *) ST_ORPHAN="$ST_ORPHAN $st_fid($st_base)";; esac
    done
  fi
  if [ "$ST_COUNT" -eq 0 ]; then
    fail "stories-covered" "$STORIES_FILE has no story row"
  elif [ -n "$ST_MISSING" ]; then
    fail "stories-covered" "no proof and not doc:$ST_MISSING"
  elif [ -n "$ST_ORPHAN" ]; then
    fail "stories-covered" "proof without a story:$ST_ORPHAN"
  else
    pass "stories-covered: $ST_COUNT stories, each proven or doc"
  fi
fi

# =============================================================================
# Invariant 27 — agent-neutrality
# =============================================================================
# #263 (epic #261), stories US-C10 and US-R4: the plugin agents carry no pointer to one maintainer's rule files and no
# stack-specific text. The bare word "tracking" and references to pr-acceptance.md stay allowed. AGENTS_DIR is an
# override used only by negative tests on throwaway copies under .pipeline/.
AGENTS_DIR="${AGENTS_DIR:-agents}"
AGENT_NEUTRALITY_RE='\.claude/rules/(external-sources|git-workflow|tracking-obligatoire|concision|code-review-impartial|verification-ci-results)|verification-ci-results\.md|Tracking section|tracking emission|force unwrap|[Ss]wift|[Ss]imulator|codebase index'
AN_FILES=0
AN_HITS=""
for an_f in "$AGENTS_DIR"/*.md; do
  [ -f "$an_f" ] || continue
  AN_FILES=$((AN_FILES + 1))
  an_hit="$(grep -nE "$AGENT_NEUTRALITY_RE" "$an_f" 2>/dev/null | head -n 1 | cut -c1-80)"
  if [ -n "$an_hit" ]; then
    AN_HITS="$AN_HITS $(basename "$an_f"): $an_hit;"
  fi
done
if [ "$AN_FILES" -eq 0 ]; then
  fail "agent-neutrality" "no agent file found in $AGENTS_DIR"
elif [ -n "$AN_HITS" ]; then
  fail "agent-neutrality" "stack or private-rule text in agents:$AN_HITS"
else
  pass "agent-neutrality: $AN_FILES agent files carry no stack or private-rule text"
fi

# =============================================================================
# Invariant 28 — project-specifics-slot
# =============================================================================
# #263: each of the five agents declares the <project_specifics> slot in one sentence, as part of its
# "Project context (provided by the orchestrator)" section, whose next `## ` header is "## Hard rules". The slot line
# carries no engine word (mirror of ENGINE_WORDS_RE, scripts/guards.cjs, keep in sync).
PS_BAD=""
PS_N=0
for ps_a in mia sam nick morgan theo; do
  ps_f="$AGENTS_DIR/$ps_a.md"
  if [ ! -f "$ps_f" ]; then
    PS_BAD="$PS_BAD $ps_a(missing)"
    continue
  fi
  PS_N=$((PS_N + 1))
  ps_res="$(awk '
    BEGIN { fm = 0; role = 0; ctx = 0; slot = 0; nctx = 0; nxt = "" }
    NR == 1 && $0 == "---" { fm = 1; next }
    fm == 1 { if ($0 == "---") fm = 2; next }
    {
      if (ctx == 0 && role == 0 && $0 !~ /^## / && $0 ~ /[^ \t]/) role = 1
      if ($0 == "## Project context (provided by the orchestrator)") { nctx++; if (nctx == 1 && role == 1) ctx = 1; next }
      if (ctx == 1 && $0 ~ /^## /) { nxt = $0; ctx = 2; next }
      if (ctx == 1 && slot == 0 && index($0, "<project_specifics>") > 0) { slot = 1; slotline = $0 }
    }
    END {
      if (nctx != 1) { print "context-header"; exit }
      if (ctx == 0) { print "no-role-line-before-context"; exit }
      if (slot == 0) { print "no-slot-line"; exit }
      if (nxt != "## Hard rules") { print "next-header"; exit }
      if (slotline ~ /(^|[^A-Za-z0-9_])(simulate|seam)([^A-Za-z0-9_]|$)/ || index(slotline, "agent()") > 0 || index(slotline, "fixtures/incidents") > 0) { print "engine-word"; exit }
      print "ok"
    }' "$ps_f")"
  if [ "$ps_res" != "ok" ]; then
    PS_BAD="$PS_BAD $ps_a($ps_res)"
  fi
done
if [ -n "$PS_BAD" ]; then
  fail "project-specifics-slot" "slot declaration wrong in:$PS_BAD"
else
  pass "project-specifics-slot: $PS_N agents declare the <project_specifics> slot before Hard rules"
fi

# =============================================================================
# Invariant 29 — no-plugin-copy-in-specifics
# =============================================================================
# #267 (epic #261), story US-C8: the owner's folder .claude/lgtmgate/ holds the owner's rules, never a copy of a plugin
# file (a copy drifts from the plugin). FAIL when a regular file there has the basename of a file under templates/ or
# the same sha256 as one. SPECIFICS_DIR is an override used only by negative tests on throwaway copies. bash 3.2 floor.
SPECIFICS_DIR="${SPECIFICS_DIR:-.claude/lgtmgate}"
if [ ! -d "$SPECIFICS_DIR" ]; then
  pass "no-plugin-copy-in-specifics: no $SPECIFICS_DIR folder"
else
  NP_SUMS="$(find templates -type f -exec shasum -a 256 {} + 2>/dev/null | awk '{print $1}')"
  NP_NAMES="$(find templates -type f -exec basename {} \; 2>/dev/null)"
  NP_N=0
  NP_BAD=""
  while IFS= read -r np_f; do
    [ -n "$np_f" ] || continue
    NP_N=$((NP_N + 1))
    np_base="$(basename "$np_f")"
    np_sum="$(shasum -a 256 "$np_f" | awk '{print $1}')"
    if printf '%s\n' "$NP_NAMES" | grep -qxF -- "$np_base"; then
      NP_BAD="$NP_BAD $np_base(name)"
    elif printf '%s\n' "$NP_SUMS" | grep -qxF -- "$np_sum"; then
      NP_BAD="$NP_BAD $np_base(content)"
    fi
  done < <(find "$SPECIFICS_DIR" -type f)
  if [ -n "$NP_BAD" ]; then
    fail "no-plugin-copy-in-specifics" "copy of a templates/ file under $SPECIFICS_DIR:$NP_BAD"
  else
    pass "no-plugin-copy-in-specifics: $NP_N files, none copied from templates/"
  fi
fi

# =============================================================================
# Invariant 30 — runbook-fail-open
# =============================================================================
# #334 (R.4.1): the runbook says what the code does: provisioning fails closed, the freshness / behind-count probes fail
# open. FAIL when the runbook claims every probe fails closed, when it no longer says the freshness probe is fail-open,
# or when the workflow no longer carries its fail-open wording. DELIVER_SKILL_FILE is an override for negative runs.
DELIVER_SKILL_FILE="${DELIVER_SKILL_FILE:-skills/deliver/SKILL.md}"
if [ ! -f "$DELIVER_SKILL_FILE" ] || [ ! -f "$WORKFLOW_FILE" ]; then
  fail "runbook-fail-open" "missing $DELIVER_SKILL_FILE or $WORKFLOW_FILE"
elif grep -qE 'fails closed, never[ ]open' "$DELIVER_SKILL_FILE"; then
  fail "runbook-fail-open" "$DELIVER_SKILL_FILE says every probe fails closed; freshness and the behind-count fail open in $WORKFLOW_FILE"
elif ! grep -qE 'freshness.*fail-open' "$DELIVER_SKILL_FILE"; then
  fail "runbook-fail-open" "$DELIVER_SKILL_FILE no longer says the freshness probe is fail-open"
elif ! grep -qF 'fail-open on any probe hiccup' "$WORKFLOW_FILE"; then
  fail "runbook-fail-open" "$WORKFLOW_FILE no longer carries the 'fail-open on any probe hiccup' wording"
else
  pass "runbook-fail-open: runbook says freshness / behind-count fail open, workflow carries the fail-open wording"
fi

# =============================================================================
# Invariant 31 — bash-rule-parity
# =============================================================================
# #335 (R.4.6): the Bash rule is stated in one short form in seven files (the cause is written once, in agents/sam.md).
# FAIL when the short form is not exactly once in any of them. AGENTS_DIR is an override for negative runs.
AGENTS_DIR="${AGENTS_DIR:-agents}"
BASH_SHORT='Bash: absolute path, 1 command/call, no `cd`/`&&`/`|`'
BR_BAD=""
for br_f in "$AGENTS_DIR/nick.md" "$AGENTS_DIR/sam.md" "$AGENTS_DIR/mia.md" "$AGENTS_DIR/morgan.md" \
  skills/deliver/SKILL.md skills/init/SKILL.md skills/context/SKILL.md; do
  br_n=$(grep -cF -- "$BASH_SHORT" "$br_f" 2>/dev/null || true)
  [ "$br_n" = "1" ] || BR_BAD="$BR_BAD $br_f"
done
if [ -n "$BR_BAD" ]; then
  fail "bash-rule-parity" "short form not exactly once in:$BR_BAD"
else
  pass "bash-rule-parity: short form exactly once in 7 files"
fi

# =============================================================================
# Invariant 32 — retry-cap-parity
# =============================================================================
# #335 (R.4.14): one cap for a blocked agent, the rule file wording, in nick / theo / mia and both rule file copies.
RC_CAP='Maximum 2-3 DIFFERENT approaches per blocker'
RC_BAD=""
for rc_f in "$AGENTS_DIR/nick.md" "$AGENTS_DIR/theo.md" "$AGENTS_DIR/mia.md" \
  templates/pr-acceptance.md .claude/rules/pr-acceptance.md; do
  if ! tr -d '*' < "$rc_f" 2>/dev/null | grep -qF -- "$RC_CAP"; then
    RC_BAD="$RC_BAD $rc_f"
  fi
done
if [ -n "$RC_BAD" ]; then
  fail "retry-cap-parity" "cap '$RC_CAP' missing in:$RC_BAD"
else
  pass "retry-cap-parity: cap '$RC_CAP' in 3 agents and both rule file copies"
fi

# =============================================================================
# Invariant 33 — frictions-parity
# =============================================================================
# #335 (R.4.17): the FRICTIONS heading and its 5-line template are identical in the five agents.
FR_BAD=""
FR_REF=""
for fr_a in nick sam morgan mia theo; do
  fr_f="$AGENTS_DIR/$fr_a.md"
  fr_head=$(grep -cxF '## FRICTIONS (3) before shutdown' "$fr_f" 2>/dev/null || true)
  fr_tpl=$(grep -A4 -xF 'FRICTIONS (3):' "$fr_f" 2>/dev/null || true)
  if [ -z "$FR_REF" ]; then FR_REF="$fr_tpl"; fi
  if [ "$fr_head" != "1" ] || [ -z "$fr_tpl" ] || [ "$fr_tpl" != "$FR_REF" ]; then
    FR_BAD="$FR_BAD $fr_a"
  fi
done
if [ -n "$FR_BAD" ]; then
  fail "frictions-parity" "FRICTIONS heading or template differs in:$FR_BAD"
else
  pass "frictions-parity: heading and 5-line template identical in 5 agents"
fi

# =============================================================================
# Invariant 34 — project-specifics-paragraph-parity
# =============================================================================
# #335 (R.4.18): the <project_specifics> paragraph is byte-identical in the five agents.
PP_REF='Project-specific rules, when the repo provides any, arrive in a `<project_specifics>` block delivered below this header; they come on top of the generic rules here and never replace them.'
PP_BAD=""
for pp_a in nick sam morgan mia theo; do
  pp_n=$(grep -cxF -- "$PP_REF" "$AGENTS_DIR/$pp_a.md" 2>/dev/null || true)
  [ "$pp_n" = "1" ] || PP_BAD="$PP_BAD $pp_a"
done
if [ -n "$PP_BAD" ]; then
  fail "project-specifics-paragraph-parity" "paragraph differs or missing in:$PP_BAD"
else
  pass "project-specifics-paragraph-parity: byte-identical in 5 agents"
fi

