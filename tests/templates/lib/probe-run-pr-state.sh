#!/usr/bin/env bash
# pr-state.sh end to end, case (j) (sourced by tests/templates/test-probe-run.sh, never executed).
# (j) pr-state.sh end to end (#84): stub gh first on PATH. No network.
PS="$SCRIPT_DIR/pr-state.sh"
if command -v jq >/dev/null 2>&1; then
  PSD="$WORK/ps"; mkdir -p "$PSD/bin" "$PSD/wt"
  cat > "$PSD/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
[ -n "${GH_FAIL:-}" ] && exit 1
case "$*" in
  *"pr view"*)
    if [ -n "${GH_ACC:-}" ]; then
      jq -nc --arg b "$GH_ACC" '{headRefName:"feat/issue-84",headRefOid:"abc123",body:$b,commits:[],comments:[]}'
      exit 0
    fi
    if [ -n "${GH_CI:-}" ]; then
      # [184] the statusCheckRollup served for the ciState cases: failing, pending, empty or absent (the field not returned)
      case "$GH_CI" in
        failing) ROLL='[{"__typename":"CheckRun","conclusion":"SUCCESS","name":"a","status":"COMPLETED"},{"__typename":"CheckRun","conclusion":"FAILURE","name":"b","status":"COMPLETED"}]' ;;
        pending) ROLL='[{"__typename":"CheckRun","conclusion":"SUCCESS","name":"a","status":"COMPLETED"},{"__typename":"CheckRun","conclusion":"","name":"b","status":"IN_PROGRESS"}]' ;;
        context-failing) ROLL='[{"__typename":"StatusContext","context":"ci","state":"FAILURE"}]' ;;
        context-pending) ROLL='[{"__typename":"StatusContext","context":"ci","state":"PENDING"}]' ;;
        cancelled) ROLL='[{"__typename":"CheckRun","conclusion":"CANCELLED","name":"a","status":"COMPLETED"}]' ;;
        timed-out) ROLL='[{"__typename":"CheckRun","conclusion":"TIMED_OUT","name":"a","status":"COMPLETED"}]' ;;
        mixed) ROLL='[{"__typename":"CheckRun","conclusion":"SUCCESS","name":"guards","status":"COMPLETED"},{"__typename":"CheckRun","conclusion":"NEUTRAL","name":"neutral","status":"COMPLETED"},{"__typename":"CheckRun","conclusion":"","name":"CodeQL","status":"IN_PROGRESS"},{"__typename":"StatusContext","context":"legacy/ci","state":"FAILURE"},{"__typename":"StatusContext","context":"legacy/wait","state":"PENDING"},{"__typename":"CheckRun","conclusion":"FAILURE","name":"dup","status":"COMPLETED","startedAt":"2026-01-01T00:00:00Z"},{"__typename":"CheckRun","conclusion":"SUCCESS","name":"dup","status":"COMPLETED","startedAt":"2026-01-01T00:05:00Z"}]' ;;
        # [184] a superseded run stays in the rollup: only the LATEST entry per (name, workflowName) counts (startedAt; an entry
        # with none, or the zero date of a queued run, is the newest attempt); a StatusContext keeps its latest per context
        dup-cancel-then-ok) ROLL='[{"__typename":"CheckRun","conclusion":"CANCELLED","name":"guards","status":"COMPLETED","startedAt":"2026-01-01T00:00:00Z","workflowName":"ci"},{"__typename":"CheckRun","conclusion":"SUCCESS","name":"guards","status":"COMPLETED","startedAt":"2026-01-01T00:05:00Z","workflowName":"ci"}]' ;;
        dup-cancel-then-ok-rev) ROLL='[{"__typename":"CheckRun","conclusion":"SUCCESS","name":"guards","status":"COMPLETED","startedAt":"2026-01-01T00:05:00Z","workflowName":"ci"},{"__typename":"CheckRun","conclusion":"CANCELLED","name":"guards","status":"COMPLETED","startedAt":"2026-01-01T00:00:00Z","workflowName":"ci"}]' ;;
        dup-ok-then-fail) ROLL='[{"__typename":"CheckRun","conclusion":"SUCCESS","name":"guards","status":"COMPLETED","startedAt":"2026-01-01T00:00:00Z","workflowName":"ci"},{"__typename":"CheckRun","conclusion":"FAILURE","name":"guards","status":"COMPLETED","startedAt":"2026-01-01T00:05:00Z","workflowName":"ci"}]' ;;
        dup-two-workflows) ROLL='[{"__typename":"CheckRun","conclusion":"SUCCESS","name":"build","status":"COMPLETED","startedAt":"2026-01-01T00:05:00Z","workflowName":"a"},{"__typename":"CheckRun","conclusion":"FAILURE","name":"build","status":"COMPLETED","startedAt":"2026-01-01T00:00:00Z","workflowName":"b"}]' ;;
        dup-two-workflows-ok) ROLL='[{"__typename":"CheckRun","conclusion":"CANCELLED","name":"build","status":"COMPLETED","startedAt":"2026-01-01T00:00:00Z","workflowName":"a"},{"__typename":"CheckRun","conclusion":"SUCCESS","name":"build","status":"COMPLETED","startedAt":"2026-01-01T00:05:00Z","workflowName":"a"},{"__typename":"CheckRun","conclusion":"SUCCESS","name":"build","status":"COMPLETED","startedAt":"2026-01-01T00:01:00Z","workflowName":"b"}]' ;;
        dup-newer-no-start) ROLL='[{"__typename":"CheckRun","conclusion":"SUCCESS","name":"guards","status":"COMPLETED","startedAt":"2026-01-01T00:00:00Z","workflowName":"ci"},{"__typename":"CheckRun","conclusion":"","name":"guards","status":"QUEUED","workflowName":"ci"}]' ;;
        dup-newer-no-start-first) ROLL='[{"__typename":"CheckRun","conclusion":"","name":"guards","status":"QUEUED","workflowName":"ci"},{"__typename":"CheckRun","conclusion":"FAILURE","name":"guards","status":"COMPLETED","startedAt":"2026-01-01T00:00:00Z","workflowName":"ci"}]' ;;
        dup-newer-zero-start) ROLL='[{"__typename":"CheckRun","conclusion":"FAILURE","name":"guards","status":"COMPLETED","startedAt":"2026-01-01T00:00:00Z","workflowName":"ci"},{"__typename":"CheckRun","conclusion":"","name":"guards","status":"QUEUED","startedAt":"0001-01-01T00:00:00Z","workflowName":"ci"}]' ;;
        dup-context-cancel-ok) ROLL='[{"__typename":"StatusContext","context":"ci","state":"FAILURE","createdAt":"2026-01-01T00:00:00Z"},{"__typename":"StatusContext","context":"ci","state":"SUCCESS","createdAt":"2026-01-01T00:05:00Z"}]' ;;
        dup-context-ok-fail) ROLL='[{"__typename":"StatusContext","context":"ci","state":"SUCCESS","createdAt":"2026-01-01T00:00:00Z"},{"__typename":"StatusContext","context":"ci","state":"FAILURE","createdAt":"2026-01-01T00:05:00Z"}]' ;;
        dup-context-no-date) ROLL='[{"__typename":"StatusContext","context":"ci","state":"FAILURE"},{"__typename":"StatusContext","context":"ci","state":"SUCCESS"}]' ;;
        none) ROLL='[]' ;;
        *) ROLL='' ;;
      esac
      if [ -n "$ROLL" ]; then
        jq -nc --argjson r "$ROLL" '{headRefName:"feat/issue-84",headRefOid:"abc123",body:"hello body",commits:[],comments:[],statusCheckRollup:$r}'
      else
        jq -nc '{headRefName:"feat/issue-84",headRefOid:"abc123",body:"hello body",commits:[],comments:[]}'
      fi
      exit 0
    fi
    if [ -n "${GH_FILES:-}" ]; then
      # [229] 100 changed files, the length at which gh's cap makes a list indistinguishable from a truncated one
      jq -nc '{headRefName:"feat/issue-84",headRefOid:"abc123",body:"hello body",commits:[],comments:[],files:[range(0;100) | {path:("f\(.).md"),additions:1,deletions:0,changeType:"ADDED"}]}'
      exit 0
    fi
    cat <<'JSON'
{"headRefName":"feat/issue-84","headRefOid":"abc123","body":"hello body","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN",
 "files":[{"path":"a.md","additions":1,"deletions":1,"changeType":"MODIFIED"},{"path":"dir/b.md","additions":2,"deletions":0,"changeType":"ADDED"}],
 "statusCheckRollup":[{"__typename":"CheckRun","conclusion":"SUCCESS","name":"guards","status":"COMPLETED","workflowName":"guards"},{"__typename":"CheckRun","conclusion":"SKIPPED","name":"extra","status":"COMPLETED"}],
 "commits":[{"committedDate":"2026-01-01T00:10:00Z"},{"committedDate":"2026-01-01T00:20:00Z"}],
 "comments":[{"id":"IC_1","isMinimized":false,"body":"<!-- pipeline-review-round 1 -->\nverdict"},
             {"id":"IC_2","isMinimized":true,"body":"<!-- pipeline-review-round 0 -->\nold"},
             {"id":"IC_3","isMinimized":false,"body":"unrelated comment"}]}
JSON
    ;;
  *"issue list"*)
    if [ -n "${GH_MANY:-}" ]; then
      jq -nc '[range(0;1000) | {number:., createdAt:"2026-01-01T00:40:00Z", url:"u"}]'
    else
      echo '[{"number":90,"createdAt":"2026-01-01T00:40:00Z","url":"https://github.com/o/r/issues/90","title":"x"},{"number":91,"createdAt":"2026-01-01T00:50:00Z","url":"https://github.com/o/r/issues/91"}]'
    fi
    ;;
  *) exit 1 ;;
esac
GHEOF
  chmod +x "$PSD/bin/gh"

  OUT="$(PATH="$PSD/bin:$PATH" bash "$PS" --pr 7 --wt "$PSD/wt" --repo o/r)"; RC=$?
  ok=0
  [ "$RC" -eq 0 ] && [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = "1" ] && ok=1
  check "pr-state.sh: exit 0 and exactly one line" "$ok"
  ok=0
  [ "$(printf '%s' "$OUT" | jq -c '[.headRefName, .headRefOid, .mergeable, .mergeStateStatus, .lastCommitDate, .commitCount]')" = '["feat/issue-84","abc123","MERGEABLE","CLEAN","2026-01-01T00:20:00Z",2]' ] && ok=1
  check "pr-state.sh: head, mergeability, last commit date and commit count from one gh call" "$ok"
  ok=0
  [ "$(printf '%s' "$OUT" | jq -c '.reviewCommentIds')" = '["IC_1"]' ] && ok=1
  check "pr-state.sh: reviewCommentIds keeps only un-minimized pipeline-review-round comments" "$ok"
  ok=0
  printf '%s' "$OUT" | jq -e '(.bodyDigest | test("^[0-9a-f]{12}$")) and (.now | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))' >/dev/null 2>&1 && ok=1
  check "pr-state.sh: 12-hex bodyDigest and an ISO now" "$ok"
  ok=0
  [ "$(printf '%s' "$OUT" | jq -c '[.openIssues, .openIssuesTruncated]')" = '[null,false]' ] && ok=1
  check "pr-state.sh: openIssues is null without --since" "$ok"

  OUT2="$(PATH="$PSD/bin:$PATH" bash "$PS" --pr 7 --wt "$PSD/wt" --repo o/r --since 2026-01-01T00:00:00Z)"
  ok=0
  [ "$(printf '%s' "$OUT2" | jq -c '[(.openIssues | map(.number)), .openIssuesTruncated]')" = '[[90,91],false]' ] && ok=1
  check "pr-state.sh: --since lists the open issues created in the window (number, createdAt, url only)" "$ok"
  ok=0
  [ "$(printf '%s' "$OUT" | jq -r .bodyDigest)" = "$(printf '%s' "$OUT2" | jq -r .bodyDigest)" ] && ok=1
  check "pr-state.sh: bodyDigest is stable for an unchanged body" "$ok"

  OUT3="$(GH_MANY=1 PATH="$PSD/bin:$PATH" bash "$PS" --pr 7 --wt "$PSD/wt" --since 2026-01-01T00:00:00Z)"
  ok=0
  [ "$(printf '%s' "$OUT3" | jq -c '[.openIssues, .openIssuesTruncated]')" = '[null,true]' ] && ok=1
  check "pr-state.sh: exactly the scan limit (1000) issues -> openIssues null, openIssuesTruncated true" "$ok"

  OUT4="$(GH_FAIL=1 PATH="$PSD/bin:$PATH" bash "$PS" --pr 7 --wt "$PSD/wt" --since 2026-01-01T00:00:00Z)"; RC=$?
  ok=0
  [ "$RC" -eq 0 ] && [ "$(printf '%s\n' "$OUT4" | wc -l | tr -d ' ')" = "1" ] \
    && [ "$(printf '%s' "$OUT4" | jq -c '[.headRefOid, .bodyDigest, .commitCount, .reviewCommentIds, .openIssues]')" = '[null,null,null,null,null]' ] \
    && printf '%s' "$OUT4" | jq -e '.now | length > 0' >/dev/null 2>&1 && ok=1
  check "pr-state.sh: failing gh -> nulls but now still set, exit 0, one line" "$ok"

  # [229] files: the PR's changed paths from the same gh call; 100 or more (gh's cap) -> null; failing gh -> null
  ok=0
  [ "$(printf '%s' "$OUT" | jq -c '.files')" = '["a.md","dir/b.md"]' ] && ok=1
  check "pr-state.sh: files lists the changed paths (one gh call)" "$ok"
  OUT9="$(GH_FILES=many PATH="$PSD/bin:$PATH" bash "$PS" --pr 7 --wt "$PSD/wt" --repo o/r)"
  ok=0
  [ "$(printf '%s' "$OUT9" | jq -c '.files')" = 'null' ] && ok=1
  check "pr-state.sh: 100 files (the gh cap) -> files null" "$ok"
  ok=0
  [ "$(printf '%s' "$OUT4" | jq -c '.files')" = 'null' ] && ok=1
  check "pr-state.sh: failing gh -> files null" "$ok"
  ok=0
  out_files="$(node -e '
    const { PARSERS } = require(process.argv[1])
    const p = (o) => PARSERS["pr-state"](JSON.stringify(o), "", 0)
    const has = (v) => Object.prototype.hasOwnProperty.call(v, "files")
    const kept = p({ files: ["a.md", "b/c.md"] })
    const dropped = [p({ files: null }), p({ files: "a.md" }), p({ files: ["a.md", 3] }), p({})]
    process.stdout.write(JSON.stringify(kept.files) === "[\"a.md\",\"b/c.md\"]" && dropped.every((v) => !v.error && !has(v)) ? "OK" : "BAD")
  ' "$PR")"
  [ "$out_files" = "OK" ] && ok=1
  check "pr-state parser keeps files (a list of strings), drops it otherwise" "$ok"

  # [183] acceptanceChecked: the ids ticked in the body's acceptance block (the fence-aware reader of the tick), [] without a block
  ok=0
  [ "$(printf '%s' "$OUT" | jq -c '.acceptanceChecked')" = '[]' ] && ok=1
  check "[183] pr-state.sh: acceptanceChecked is [] for a body without an acceptance block" "$ok"
  ACC_BODY='x
<!-- acceptance:start -->
- [x] <!-- ac:3 --> c
- [ ] <!-- ac:2 --> b
- [x] <!-- ac:1 --> a
- [x] ticked line without an id
<!-- acceptance:end -->
```
<!-- acceptance:start -->
- [x] <!-- ac:9 --> an example
<!-- acceptance:end -->
```'
  OUT6="$(GH_ACC="$ACC_BODY" PATH="$PSD/bin:$PATH" bash "$PS" --pr 7 --wt "$PSD/wt" --repo o/r)"
  ok=0
  [ "$(printf '%s' "$OUT6" | jq -c '.acceptanceChecked')" = '[1,3]' ] && ok=1
  check "[183] pr-state.sh: acceptanceChecked lists the ticked ids of the real block, ascending, not the fenced example's" "$ok"
  ok=0
  [ "$(printf '%s' "$OUT4" | jq -c '.acceptanceChecked')" = 'null' ] && ok=1
  check "[183] pr-state.sh: failing gh -> acceptanceChecked null" "$ok"
  ok=0
  out6="$(printf '%s\n' "$OUT6" | node -e '
    const { PARSERS } = require(process.argv[1])
    const v = PARSERS["pr-state"](require("fs").readFileSync(0, "utf8"), "", 0)
    process.stdout.write(v.error ? "ERR" : JSON.stringify(v.acceptanceChecked))
  ' "$PR")"
  [ "$out6" = "[1,3]" ] && ok=1
  check "[183] pr-state parser keeps acceptanceChecked (a list of positive integers, else null)" "$ok"

  # [184] ciState: the state of every check on the head, derived from the statusCheckRollup of the same gh call
  ci_of() { PATH="$PSD/bin:$PATH" GH_CI="$1" bash "$PS" --pr 7 --wt "$PSD/wt" --repo o/r | jq -r '.ciState'; }
  ok=0
  [ "$(printf '%s' "$OUT" | jq -r '.ciState')" = 'green' ] \
    && [ "$(ci_of failing)" = 'failing' ] && [ "$(ci_of pending)" = 'pending' ] && [ "$(ci_of none)" = 'none' ] \
    && [ "$(ci_of context-failing)" = 'failing' ] && [ "$(ci_of context-pending)" = 'pending' ] \
    && [ "$(ci_of cancelled)" = 'failing' ] && [ "$(ci_of timed-out)" = 'failing' ] \
    && [ "$(ci_of absent)" = 'null' ] && [ "$(printf '%s' "$OUT4" | jq -r '.ciState')" = 'null' ] && ok=1
  check "[184] pr-state.sh: ciState is green|failing|pending|none for the rollups (CheckRun and StatusContext entries) and null when gh fails or the field is absent" "$ok"
  ok=0
  cip="$(for j in '{"ciState":"green"}' '{"ciState":"failing"}' '{"ciState":"pending"}' '{"ciState":"none"}' '{"ciState":"weird"}' '{"ciState":true}' '{}'; do
    printf '%s\n' "$j" | node -e '
      const { PARSERS } = require(process.argv[1])
      const v = PARSERS["pr-state"](require("fs").readFileSync(0, "utf8"), "", 0)
      process.stdout.write(v.error ? "ERR;" : JSON.stringify(v.ciState) + ";")
    ' "$PR"
  done)"
  [ "$cip" = '"green";"failing";"pending";"none";null;null;null;' ] && ok=1
  check "[184] pr-state parser keeps ciState from {green,failing,pending,none}, else null" "$ok"
  # [184] ciChecks: the per-check map {name: green|failing|pending} from the SAME per-entry classification (CheckRun .name,
  # StatusContext .context; SKIPPED/NEUTRAL green; two entries of one (name, workflowName): the LATEST by startedAt wins; two workflows: the worst of the two); null when the rollup is absent
  cc_of() { PATH="$PSD/bin:$PATH" GH_CI="$1" bash "$PS" --pr 7 --wt "$PSD/wt" --repo o/r | jq -cS '.ciChecks'; }
  ok=0
  [ "$(printf '%s' "$OUT" | jq -cS '.ciChecks')" = '{"extra":"green","guards":"green"}' ] \
    && [ "$(cc_of mixed)" = '{"CodeQL":"pending","dup":"green","guards":"green","legacy/ci":"failing","legacy/wait":"pending","neutral":"green"}' ] \
    && [ "$(cc_of failing)" = '{"a":"green","b":"failing"}' ] && [ "$(cc_of pending)" = '{"a":"green","b":"pending"}' ] \
    && [ "$(cc_of cancelled)" = '{"a":"failing"}' ] && [ "$(cc_of none)" = '{}' ] \
    && [ "$(cc_of absent)" = 'null' ] && [ "$(printf '%s' "$OUT4" | jq -c '.ciChecks')" = 'null' ] && ok=1
  check "[184] pr-state.sh: ciChecks maps each check name to green|failing|pending (CheckRun name, StatusContext context), {} for an empty rollup, null when gh fails or the field is absent" "$ok"
  # [184] a superseded run (a concurrency cancel) never outvotes the latest one, in ciState and in ciChecks alike
  ok=0
  [ "$(ci_of dup-cancel-then-ok)" = 'green' ] && [ "$(cc_of dup-cancel-then-ok)" = '{"guards":"green"}' ] \
    && [ "$(ci_of dup-cancel-then-ok-rev)" = 'green' ] && [ "$(cc_of dup-cancel-then-ok-rev)" = '{"guards":"green"}' ] \
    && [ "$(ci_of dup-ok-then-fail)" = 'failing' ] && [ "$(cc_of dup-ok-then-fail)" = '{"guards":"failing"}' ] \
    && [ "$(ci_of dup-two-workflows)" = 'failing' ] && [ "$(cc_of dup-two-workflows)" = '{"build":"failing"}' ] \
    && [ "$(ci_of dup-two-workflows-ok)" = 'green' ] && [ "$(cc_of dup-two-workflows-ok)" = '{"build":"green"}' ] \
    && [ "$(ci_of dup-newer-no-start)" = 'pending' ] && [ "$(cc_of dup-newer-no-start)" = '{"guards":"pending"}' ] \
    && [ "$(ci_of dup-newer-no-start-first)" = 'pending' ] && [ "$(cc_of dup-newer-no-start-first)" = '{"guards":"pending"}' ] \
    && [ "$(ci_of dup-newer-zero-start)" = 'pending' ] && [ "$(cc_of dup-newer-zero-start)" = '{"guards":"pending"}' ] \
    && [ "$(ci_of dup-context-cancel-ok)" = 'green' ] && [ "$(cc_of dup-context-cancel-ok)" = '{"ci":"green"}' ] \
    && [ "$(ci_of dup-context-ok-fail)" = 'failing' ] && [ "$(cc_of dup-context-ok-fail)" = '{"ci":"failing"}' ] \
    && [ "$(ci_of dup-context-no-date)" = 'green' ] && [ "$(cc_of dup-context-no-date)" = '{"ci":"green"}' ] && ok=1
  check "[184] pr-state.sh: of two entries with one check name only the LATEST counts (startedAt; none or the zero date = newest; StatusContext by createdAt, else the last occurrence), per workflowName, in ciState and ciChecks" "$ok"
  ok=0
  ccp="$(for j in '{"ciChecks":{"guards":"green","CodeQL":"pending","x":"failing"}}' '{"ciChecks":{}}' '{"ciChecks":{"a":"green","b":"weird"}}' '{"ciChecks":{"a":1}}' '{"ciChecks":{"a":null}}' '{"ciChecks":["a"]}' '{"ciChecks":"green"}' '{"ciChecks":null}' '{}' '{"ciChecks":{"__proto__":"green","constructor":"green","ok":"green"}}'; do
    printf '%s\n' "$j" | node -e '
      const { PARSERS } = require(process.argv[1])
      const v = PARSERS["pr-state"](require("fs").readFileSync(0, "utf8"), "", 0)
      const c = v.ciChecks
      const plain = c !== null && typeof c === "object" && Object.getPrototypeOf(c) === Object.prototype
      process.stdout.write(v.error ? "ERR;" : JSON.stringify(c === null ? null : Object.keys(c).sort().map((k) => [k, c[k]])) + (c === null || plain ? "" : "!") + ";")
    ' "$PR"
  done)"
  [ "$ccp" = '[["CodeQL","pending"],["guards","green"],["x","failing"]];[];[["a","green"]];[];[];null;null;null;null;[["ok","green"]];' ] && ok=1
  check "[184] pr-state parser keeps ciChecks only as a plain object of green|failing|pending entries, else null (a bogus value drops its entry; a non-object gives null; __proto__ and constructor keys are dropped)" "$ok"

  # [164] decisionLog: the round lines of the real decision-log block (trimmed, heading dropped), [] without a block, null when gh fails
  DL_BODY='Closes #164
<!-- decision-log:start -->
## Decision log
- round 0 — REQUIRED_CHANGES (1 blocker)
- round 1 — LGTM
<!-- decision-log:end -->'
  OUT7="$(GH_ACC="$DL_BODY" PATH="$PSD/bin:$PATH" bash "$PS" --pr 7 --wt "$PSD/wt" --repo o/r)"
  ok=0
  [ "$(printf '%s' "$OUT7" | jq -c '.decisionLog')" = '["- round 0 — REQUIRED_CHANGES (1 blocker)","- round 1 — LGTM"]' ] \
    && [ "$(printf '%s' "$OUT" | jq -c '.decisionLog')" = '[]' ] \
    && [ "$(printf '%s' "$OUT4" | jq -c '.decisionLog')" = 'null' ] && ok=1
  check "[164] pr-state.sh: decisionLog lists the round lines of the real block (trimmed, heading dropped), [] for a body without a block, null when gh fails" "$ok"
  ok=0
  dlp="$(for j in '{"decisionLog":["- round 0 — LGTM"]}' '{"decisionLog":"x"}' '{"decisionLog":["a",1]}' '{}'; do
    printf '%s\n' "$j" | node -e '
      const { PARSERS } = require(process.argv[1])
      const v = PARSERS["pr-state"](require("fs").readFileSync(0, "utf8"), "", 0)
      process.stdout.write(v.error ? "ERR;" : JSON.stringify(v.decisionLog) + ";")
    ' "$PR"
  done)"
  [ "$dlp" = '["- round 0 — LGTM"];null;null;null;' ] && ok=1
  check "[164] pr-state parser keeps decisionLog (a list of strings, else null)" "$ok"

  # [164] pr-body-splice.cjs: a block whose end marker is indented stays ONE block; the entries mode reads the real block
  SPL="$SCRIPT_DIR/pr-body-splice.cjs"
  printf 'Closes #146\n\n<!-- decision-log:start -->\n  ## Decision log\n  - round 0 — REQUIRED_CHANGES (1 blocker)\n  <!-- decision-log:end -->\n' > "$WORK/dl-pre.md"
  printf '<!-- decision-log:start -->\n## Decision log\n- round 0 — a\n- round 1 — b\n<!-- decision-log:end -->\n' > "$WORK/dl-text.md"
  ok=0
  node "$SPL" splice decision-log "$WORK/dl-pre.md" "$WORK/dl-text.md" "$WORK/dl-out.md" \
    && [ "$(grep -c 'decision-log:start' "$WORK/dl-out.md")" = "1" ] && [ "$(grep -c 'decision-log:end' "$WORK/dl-out.md")" = "1" ] \
    && grep -q -- '- round 1 — b' "$WORK/dl-out.md" && ! grep -q 'REQUIRED_CHANGES' "$WORK/dl-out.md" && ok=1
  check "[164] pr-body-splice.cjs splice decision-log replaces a block whose end marker is indented: one start marker" "$ok"
  ok=0
  [ "$(node "$SPL" entries "$WORK/dl-out.md")" = '["- round 0 — a","- round 1 — b"]' ] \
    && [ "$(printf 'no block here\n' | node "$SPL" entries -)" = '[]' ] && ok=1
  check "[164] pr-body-splice.cjs entries prints the round lines of the real block as a JSON array ([] with no block)" "$ok"

  # [164] a legacy body with 3 decision-log blocks (PR #146 shape: indented end markers): one pair after a splice, every round kept
  # in body order, the text outside the blocks untouched; pr-state.sh lists the rounds of all the blocks
  printf 'Closes #146\n\n<!-- decision-log:start -->\n  ## Decision log\n  - round 0 — a\n  <!-- decision-log:end -->\n\nmiddle\n\n<!-- decision-log:start -->\n  ## Decision log\n  - round 1 — b\n  <!-- decision-log:end -->\n\n<!-- acceptance:start -->\n- [ ] <!-- ac:1 --> x\n<!-- acceptance:end -->\n\n<!-- decision-log:start -->\n  ## Decision log\n  - round 2 — c\n  <!-- decision-log:end -->\n' > "$WORK/dl3-pre.md"
  printf '<!-- decision-log:start -->\n## Decision log\n- round 0 — a\n- round 1 — b\n- round 2 — c\n- round 3 — d\n<!-- decision-log:end -->\n' > "$WORK/dl3-text.md"
  printf 'Closes #146\n\n\nmiddle\n\n\n<!-- acceptance:start -->\n- [ ] <!-- ac:1 --> x\n<!-- acceptance:end -->\n\n<!-- decision-log:start -->\n## Decision log\n- round 0 — a\n- round 1 — b\n- round 2 — c\n- round 3 — d\n<!-- decision-log:end -->\n' > "$WORK/dl3-want.md"
  ok=0
  [ "$(node "$SPL" entries "$WORK/dl3-pre.md")" = '["- round 0 — a","- round 1 — b","- round 2 — c"]' ] \
    && node "$SPL" splice decision-log "$WORK/dl3-pre.md" "$WORK/dl3-text.md" "$WORK/dl3-out.md" \
    && [ "$(grep -c 'decision-log:start' "$WORK/dl3-out.md")" = "1" ] && [ "$(grep -c 'decision-log:end' "$WORK/dl3-out.md")" = "1" ] \
    && cmp -s "$WORK/dl3-out.md" "$WORK/dl3-want.md" && ok=1
  check "[164] pr-body-splice.cjs: 3 decision-log blocks (indented end markers) -> entries lists every round in order; splice leaves one pair, the text outside byte-identical" "$ok"
  OUT8="$(GH_ACC="$(cat "$WORK/dl3-pre.md")" PATH="$PSD/bin:$PATH" bash "$PS" --pr 7 --wt "$PSD/wt" --repo o/r)"
  ok=0
  [ "$(printf '%s' "$OUT8" | jq -c '.decisionLog')" = '["- round 0 — a","- round 1 — b","- round 2 — c"]' ] && ok=1
  check "[164] pr-state.sh: decisionLog lists the rounds of ALL the decision-log blocks of the body, in body order" "$ok"

  ok=0
  out5="$(PATH="$PSD/bin:$PATH" bash "$PS" --pr 7 --wt "$PSD/wt" --repo o/r | node -e '
    const { PARSERS } = require(process.argv[1])
    const v = PARSERS["pr-state"](require("fs").readFileSync(0, "utf8"), "", 0)
    process.stdout.write(v.error ? "ERR" : v.headRefOid + ":" + v.commitCount)
  ' "$PR")"
  [ "$out5" = "abc123:2" ] && ok=1
  check "pr-state.sh output round-trips through the pr-state parser" "$ok"
else
  echo "SKIP - pr-state.sh e2e needs jq"
fi

