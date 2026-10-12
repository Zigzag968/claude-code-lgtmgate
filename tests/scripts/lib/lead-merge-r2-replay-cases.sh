#!/usr/bin/env bash
# case 25: the R2 gate replays the PR's fixture (green on the branch, red on base) and reads its scope from r2Scope on origin/main (#200).
# Sourced by tests/scripts/test-lead-merge.sh after lead-merge-release-cases.sh (uses its r2_* helpers), never executed.
# Real runner + real workflow + real fixture: "red on base" is a base workflow that cannot even load (any failing replay is red).
rc=0
RP_RUNNER="$ROOT/scripts/run-offline.cjs"; RP_WF="$ROOT/workflows/deliver-pipeline.js"; RP_FX="$ROOT/fixtures/incidents/10-pr-write-probe.json"
RP_BROKEN="$BASE/rp-broken.js"; { cat "$RP_WF"; echo '}}} not javascript'; } > "$RP_BROKEN"
RP_SAME="$BASE/rp-same.js"; { cat "$RP_WF"; echo '// harmless comment'; } > "$RP_SAME"
rp_cfg() { # <fixtureDir> <paths-json>: an engine config carrying that r2Scope
  printf '{"engineRepo": true, "r2Scope": {"issueType": "bug", "paths": %s, "fixtureDir": "%s"}}' "$2" "$1"
}
RP_CFG="$(rp_cfg fixtures/incidents '["workflows/"]')"
rp_main() { # <dir> <workflow-file> <with-runner 0|1>: origin/main gets the workflow (and the runner), then the branch is brought up to date with it
  ( cd "$1/other" && git checkout -q main && mkdir -p workflows scripts && cp "$2" workflows/deliver-pipeline.js \
    && if [ "$3" = 1 ]; then cp "$RP_RUNNER" scripts/run-offline.cjs; fi \
    && git add -A && git commit -qm "main: engine files" && git push -q origin main ) >/dev/null 2>&1
  r2_pull_main "$1"
}
rp_branch() { # <dir> <workflow-file> <fixture-dir> [fixture-source]: feat/x gets that workflow and fixture <dir>/30-replay.json, pushed
  ( cd "$1/work" && cp "$2" workflows/deliver-pipeline.js && mkdir -p "$3" && cp "${4:-$RP_FX}" "$3/30-replay.json" \
    && git add -A && git commit -qm "fix: r2 replay" && git push -q origin feat/x ) >/dev/null 2>&1
}
rp_case() { # <name> <main-workflow> <with-runner> <tip-workflow> <config> [fixture-dir] [fixture-source]: sets D, rc
  r2_prep "$1" 'Refs #30' '' 'open type:bug'; r2_main_cfg "$D" "$5"
  rp_main "$D" "$2" "$3"; rp_branch "$D" "$4" "${6:-fixtures/incidents}" "${7:-}"; r2_go
}
rp_refused() { # <label> <substring-of-the-FAIL-line>
  [ "$rc" -ne 0 ] && grep -q 'FAIL: r2-waiver:' "$D/out" && grep -qF -- "$2" "$D/out" \
    && [ ! -s "$D/pushes" ] && ! grep -qE 'pr merge|pr checks' "$D/log" \
    && ok "r2-replay: $1" || bad "r2-replay: $1 (rc=$rc): $(tail -3 "$D/out")"
}
rp_merges() { # <label>
  [ "$rc" -eq 0 ] && grep -q 'pr merge' "$D/log" && ! grep -q 'FAIL: r2-waiver' "$D/out" \
    && ok "r2-replay: $1" || bad "r2-replay: $1 (rc=$rc): $(tail -3 "$D/out")"
}
# (a) green on the branch, red on base: merges
rp_case rp-ok "$RP_BROKEN" 1 "$RP_WF" "$RP_CFG"
rp_merges "fixture green on the branch and red on base: merges"
# (b) green on both: the fixture does not reproduce the bug
rp_case rp-both-green "$RP_WF" 1 "$RP_SAME" "$RP_CFG"
rp_refused "fixture green on both base and branch: refused, it does not reproduce the bug" "not red on base"
# (c) red on the branch
rp_case rp-tip-red "$RP_WF" 1 "$RP_BROKEN" "$RP_CFG"
rp_refused "fixture red on the branch: refused" "not green on the branch"
# (c2) the fixture file is valid JSON but no run of it passes on the branch: still refused
rp_case rp-tip-garbage "$RP_BROKEN" 1 "$RP_WF" "$RP_CFG" fixtures/incidents "$ROOT/package.json"
rp_refused "valid JSON that is not a replayable fixture: refused" "r2-replay"
# (d) no runner on origin/main yet: skipped with a NOTE, the file-presence rule still holds
rp_case rp-norunner "$RP_BROKEN" 0 "$RP_WF" "$RP_CFG"
{ rp_merges "no runner on origin/main: replay skipped, merges" && grep -qF 'NOTE: r2-replay skipped' "$D/out"; } || bad "r2-replay: no-runner NOTE missing: $(tail -3 "$D/out")"
# (e) the scope comes from origin/main's r2Scope, not from constants
rp_case rp-dir "$RP_BROKEN" 0 "$RP_WF" "$(rp_cfg fixtures/other '["workflows/"]')"
rp_refused "fixtureDir moved on origin/main: a fixture in the old folder no longer counts" "fixtures/other/30-"
rp_case rp-dir-ok "$RP_BROKEN" 0 "$RP_WF" "$(rp_cfg fixtures/other '["workflows/"]')" fixtures/other
rp_merges "fixtureDir moved on origin/main: a fixture in the new folder counts"
rp_case rp-paths "$RP_BROKEN" 0 "$RP_WF" "$(rp_cfg fixtures/incidents '["agents/"]')" fixtures/elsewhere
rp_merges "paths moved on origin/main to agents/: a workflows/ change is out of scope"
rp_case rp-paths-in "$RP_BROKEN" 0 "$RP_WF" "$(rp_cfg fixtures/incidents '["workflows/","agents/"]')" fixtures/elsewhere
rp_refused "paths hold several entries: workflows/ stays in scope, no fixture, refused" "fixtures/incidents/30-"
# (f) engineRepo with an invalid r2Scope fails closed (shape table shared by value with T200a in templates/test-deliver-pipeline.js)
rp_invalid() { # <label> <config-json>
  r2_prep "rp-bad-$(printf '%s' "$1" | tr -c 'a-zA-Z0-9' '_')" 'Refs #30' '' 'open type:bug'; r2_main_cfg "$D" "$2"; r2_branch "$D" 30-x.json; r2_go
  [ "$rc" -ne 0 ] && grep -qF 'r2Scope' "$D/out" && [ ! -s "$D/pushes" ] && ! grep -qE 'pr merge|pr checks' "$D/log" \
    && ok "r2-replay: engineRepo with an invalid r2Scope ($1): refused, the message names r2Scope" || bad "r2-replay: invalid r2Scope ($1) (rc=$rc): $(tail -3 "$D/out")"
}
rp_invalid "missing" '{"engineRepo": true}'
rp_invalid "empty paths" '{"engineRepo": true, "r2Scope": {"issueType": "bug", "paths": [], "fixtureDir": "fixtures/incidents"}}'
rp_invalid "non-string fixtureDir" '{"engineRepo": true, "r2Scope": {"issueType": "bug", "paths": ["workflows/"], "fixtureDir": 42}}'
rp_invalid "empty path entry" '{"engineRepo": true, "r2Scope": {"issueType": "bug", "paths": [""], "fixtureDir": "fixtures/incidents"}}'
rp_invalid "empty issueType" '{"engineRepo": true, "r2Scope": {"issueType": "", "paths": ["workflows/"], "fixtureDir": "fixtures/incidents"}}'
