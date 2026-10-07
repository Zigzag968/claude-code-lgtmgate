#!/usr/bin/env bash
# Regression test for templates/probe-run.cjs (E2.2, #80), templates/preflight.sh (#83) and templates/pr-state.sh (#84) and templates/pr-write.sh (#85): pure parsers replayed against
# fixtures/probes/*.raw, plus end-to-end runs of the CLI in a temp dir. No network. bash 3.2 safe.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PR="$SCRIPT_DIR/probe-run.cjs"
TMP_BASE="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
WORK="$(mktemp -d "$TMP_BASE/probe-run-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

HI_SHA=98ea6e4f216f2fb4b69fff9b3a44842c38686ca685f3f55dc48c5d3fb1107be4

pass_count=0
fail_count=0

check() {
  local name="$1" ok="$2"
  if [ "$ok" -eq 1 ]; then echo "PASS - $name"; pass_count=$((pass_count + 1))
  else echo "FAIL - $name"; fail_count=$((fail_count + 1)); fi
}

# (a) every fixtures/probes/<parser>--<case>.raw through PARSERS deep-equals its .expected
n_raw=0
for raw in "$ROOT"/fixtures/probes/*.raw; do
  [ -f "$raw" ] || continue
  n_raw=$((n_raw + 1))
  base="$(basename "$raw" .raw)"
  parser="${base%%--*}"
  exp="$ROOT/fixtures/probes/$base.expected"
  ok=0
  if [ -f "$exp" ] && node -e '
    const fs = require("fs"), assert = require("assert")
    const { PARSERS } = require(process.argv[1])
    const got = PARSERS[process.argv[2]](fs.readFileSync(process.argv[3], "utf8"), "", 0)
    assert.deepStrictEqual(got, JSON.parse(fs.readFileSync(process.argv[4], "utf8")))
  ' "$PR" "$parser" "$raw" "$exp" 2>/dev/null; then ok=1; fi
  check "parser fixture $base" "$ok"
done
[ "$n_raw" -ge 12 ] && ok=1 || ok=0
check "at least 2 fixtures per parser (found $n_raw .raw files)" "$ok"

# (b) e2e: one PROBE line, exit=0, known sha, record with 8 keys
OUT1="$WORK/b"
LINE="$(node "$PR" --label t --round 0 --out "$OUT1" --parser lines --cmd "printf 'hi\n'")"
CMD_SHA="$(node -e 'process.stdout.write(require("crypto").createHash("sha256").update(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).cmd).digest("hex"))' "$OUT1/t-r0.json")"
RC=$?
ok=0
[ "$RC" -eq 0 ] && [ "$(printf '%s\n' "$LINE" | wc -l | tr -d ' ')" = "1" ] &&
  [ "$LINE" = "PROBE name=lines exit=0 sha=$HI_SHA cmd=$CMD_SHA json={\"lines\":[\"hi\"]}" ] && ok=1
check "e2e printf hi: single PROBE line with expected sha" "$ok"
ok=0
[ "$CMD_SHA" = "$(node -e 'process.stdout.write(require("crypto").createHash("sha256").update("printf '"'"'hi\\n'"'"'").digest("hex"))')" ] && case "$LINE" in *" cmd=$CMD_SHA json="*) ok=1 ;; esac
check "[151] PROBE line carries cmd= equal to the sha256 of the executed command" "$ok"
ok=0
[ "$(node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(Object.keys(r).length)' "$OUT1/t-r0.json")" = "8" ] && ok=1
check "record has 8 keys" "$ok"

# (c) failing command: exit=3 reported, script exits 0
LINE="$(node "$PR" --label f --round 1 --out "$WORK/c" --parser lines --cmd 'exit 3')"
RC=$?
ok=0
[ "$RC" -eq 0 ] && case "$LINE" in "PROBE name=lines exit=3 "*) ok=1 ;; esac
check "failing cmd: exit=3 in line, script exit 0" "$ok"

# (d) idempotence: identical cmd + successful record -> reused, file unchanged, command NOT re-run
BEFORE="$(cat "$OUT1/t-r0.json")"
LINE2="$(node "$PR" --label t --round 0 --out "$OUT1" --parser lines --cmd "printf 'hi\n'")"
AFTER="$(cat "$OUT1/t-r0.json")"
ok=0
case "$LINE2" in *"sha=$HI_SHA "*) [ "$BEFORE" = "$AFTER" ] && ok=1 ;; esac
check "idempotent: identical successful record reused, bytes unchanged" "$ok"

# (d2) same label/round, DIFFERENT cmd -> rebuilt (record bound to its command, #82)
LINE3="$(node "$PR" --label t --round 0 --out "$OUT1" --parser lines --cmd "printf 'other\n'")"
ok=0
case "$LINE3" in *"sha=$HI_SHA "*) ok=0 ;; *'json={"lines":["other"]}') ok=1 ;; esac
[ "$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).cmd)' "$OUT1/t-r0.json")" = "printf 'other\n'" ] || ok=0
check "different cmd on same label/round re-executes and rewrites the record" "$ok"

# (d3) failed record -> re-executed on the next run (relaunch after a fix), then reused once it succeeds
RD="$WORK/relaunch"
MARK="$WORK/fixed-marker"
RCMD="test -f '$MARK' && echo ok"
L1="$(node "$PR" --label prov --round 0 --out "$RD" --parser lines --cmd "$RCMD")"
ok=0; case "$L1" in "PROBE name=lines exit=1 "*) ok=1 ;; esac
check "relaunch: first run fails (exit=1, record stored)" "$ok"
: > "$MARK"
L2="$(node "$PR" --label prov --round 0 --out "$RD" --parser lines --cmd "$RCMD")"
ok=0; case "$L2" in "PROBE name=lines exit=0 "*'json={"lines":["ok"]}') ok=1 ;; esac
check "relaunch: failed record re-executed after the cause is fixed (exit=0)" "$ok"
rm -f "$MARK"
L3="$(node "$PR" --label prov --round 0 --out "$RD" --parser lines --cmd "$RCMD")"
[ "$L3" = "$L2" ] && ok=1 || ok=0
check "relaunch: successful record is then reused without re-running" "$ok"

# (e) 70000 bytes -> truncated, stored length 65536
node "$PR" --label big --round 0 --out "$WORK/e" --parser lines --cmd "head -c 70000 /dev/zero | tr '\\0' x" >/dev/null
ok=0
[ "$(node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(r.truncated+":"+Buffer.byteLength(r.stdout))' "$WORK/e/big-r0.json")" = "true:65536" ] && ok=1
check "70000-byte output: truncated true, stored 65536" "$ok"

# (f) invalid invocations exit 2
node "$PR" --label t --round 0 --out relative/dir --parser lines --cmd 'true' >/dev/null 2>&1
RC=$?
[ "$RC" -eq 2 ] && ok=1 || ok=0
check "relative --out exits 2" "$ok"
node "$PR" --label 'a b' --round 0 --out "$WORK/g" --parser lines --cmd 'true' >/dev/null 2>&1
RC=$?
[ "$RC" -eq 2 ] && ok=1 || ok=0
check "unsafe label exits 2" "$ok"

# unknown parser still prints a line
LINE="$(node "$PR" --label u --round 0 --out "$WORK/h" --parser nope --cmd 'true')"
case "$LINE" in *'json={"error":"unknown-parser"}') ok=1 ;; *) ok=0 ;; esac
check "unknown parser -> error json" "$ok"

# provision parser: unknown version is an error, not a silent v1 (#82)
ok=0
[ "$(node -e 'const {PARSERS}=require(process.argv[1]);console.log(JSON.stringify(PARSERS.provision("PROVISION-VERSION:9\nLINKED a -> /x\n")))' "$PR")" = '{"error":"unknown-version"}' ] && ok=1
check "provision parser: unknown version -> error" "$ok"

# (h) verify mode (#82): never re-runs the command, compares the recomputed line with the attestation
VD="$WORK/v"
VLINE="$(node "$PR" --label vt --round 0 --out "$VD" --parser lines --cmd "printf 'hi\n'")"
ATT="$WORK/v-attest.jsonl"
VOUT="$(node "$PR" --verify --label vt --round 0 --out "$VD" --parser lines --attest "$ATT")"
ok=0; [ "$VOUT" = "VERIFY fail reason=no-attestation" ] && ok=1
check "verify no-attestation: no attest file" "$ok"

node -e 'console.log(JSON.stringify({agent_id:"a",tool_use_id:"t",kind:"probe",label:"vt",round:0,line:process.argv[1],ts:new Date().toISOString()}))' "$VLINE" > "$ATT"
VOUT="$(node "$PR" --verify --label vt --round 0 --out "$VD" --parser lines --attest "$ATT")"
ok=0; [ "$VOUT" = "VERIFY ok line=$VLINE" ] && ok=1
check "verify ok: attested line equals the recomputed one (entry bound to label and round)" "$ok"

# the attestation is bound to the call (#83): the same line attested for another label or round does not verify
cp "$VD/vt-r0.json" "$VD/vt-r1.json"; cp "$VD/vt-r0.json" "$VD/other-r0.json"
VOUT="$(node "$PR" --verify --label vt --round 1 --out "$VD" --parser lines --attest "$ATT")"
ok=0; [ "$VOUT" = "VERIFY fail reason=no-attestation" ] && ok=1
check "verify no-attestation: entry attested for another round" "$ok"
VOUT="$(node "$PR" --verify --label other --round 0 --out "$VD" --parser lines --attest "$ATT")"
ok=0; [ "$VOUT" = "VERIFY fail reason=no-attestation" ] && ok=1
check "verify no-attestation: entry attested for another label" "$ok"

VOUT="$(node "$PR" --verify --label nope --round 0 --out "$VD" --parser lines --attest "$ATT")"
ok=0; [ "$VOUT" = "VERIFY fail reason=no-record" ] && ok=1
check "verify no-record: missing record" "$ok"

node -e 'const fs=require("fs");const f=process.argv[1];const r=JSON.parse(fs.readFileSync(f,"utf8"));r.stdout="tampered\n";fs.writeFileSync(f,JSON.stringify(r))' "$VD/vt-r0.json"
VOUT="$(node "$PR" --verify --label vt --round 0 --out "$VD" --parser lines --attest "$ATT")"
ok=0; [ "$VOUT" = "VERIFY fail reason=sha-mismatch" ] && ok=1
check "verify sha-mismatch: tampered record" "$ok"

VOUT="$(node "$PR" --verify --label vt --round 0 --out "$VD" --parser git-rev-list-count --attest "$ATT")"
ok=0; [ "$VOUT" = "VERIFY fail reason=no-attestation" ] && ok=1
check "verify no-attestation: entries exist only for another parser name" "$ok"

node "$PR" --verify --label vt --round 0 --out "$VD" --parser lines --attest relative.jsonl >/dev/null 2>&1
RC=$?
[ "$RC" -eq 2 ] && ok=1 || ok=0
check "verify relative --attest exits 2" "$ok"

# --no-reuse (#83): a live-state probe re-executes even with an identical cmd and a stored exit-0 record
NR="$WORK/nr"
NRC="printf '%s\\n' \"\$(cat $WORK/nr-prefix)\""
printf 'a/' > "$WORK/nr-prefix"
node "$PR" --label nr --round 0 --out "$NR" --parser lines --cmd "$NRC" >/dev/null
printf 'b/' > "$WORK/nr-prefix"
O1="$(node "$PR" --label nr --round 0 --out "$NR" --parser lines --cmd "$NRC")"
case "$O1" in *'"a/"'*) ok=1 ;; *) ok=0 ;; esac
check "default: identical cmd + exit 0 is reused (still a/)" "$ok"
O2="$(node "$PR" --label nr --round 0 --out "$NR" --parser lines --no-reuse --cmd "$NRC")"
case "$O2" in *'"b/"'*) ok=1 ;; *) ok=0 ;; esac
check "--no-reuse: same cmd re-executes (b/)" "$ok"
node "$PR" --verify --label nr --round 0 --out "$NR" --parser lines --no-reuse --attest "$WORK/nr-a.jsonl" >/dev/null 2>&1
[ "$?" -eq 2 ] && ok=1 || ok=0
check "--no-reuse with --verify exits 2" "$ok"

# VERIFY needs an attestation newer than the record, and the latest one for the call (#83)
SD="$WORK/sv"; SA="$WORK/sv-attest.jsonl"
SL="$(node "$PR" --label sv --round 0 --out "$SD" --parser lines --cmd "printf 'x\\n'")"
node -e 'const l=process.argv[1];const e=(ts,line)=>JSON.stringify({agent_id:"a",tool_use_id:"t",kind:"probe",label:"sv",round:0,line,ts});console.log(e("2000-01-01T00:00:00Z",l))' "$SL" > "$SA"
SOUT="$(node "$PR" --verify --label sv --round 0 --out "$SD" --parser lines --attest "$SA")"
ok=0; [ "$SOUT" = "VERIFY fail reason=stale-attestation" ] && ok=1
check "verify: an attestation older than the record does not satisfy VERIFY" "$ok"
node -e 'const l=process.argv[1];const e=(ts,line)=>JSON.stringify({agent_id:"a",tool_use_id:"t",kind:"probe",label:"sv",round:0,line,ts});console.log(e("2000-01-01T00:00:00Z",l));console.log(e(new Date().toISOString(),l))' "$SL" > "$SA"
SOUT="$(node "$PR" --verify --label sv --round 0 --out "$SD" --parser lines --attest "$SA")"
ok=0; [ "$SOUT" = "VERIFY ok line=$SL" ] && ok=1
check "verify: a fresh latest attestation after an old one passes" "$ok"
node -e 'const l=process.argv[1];const e=(ts,line)=>JSON.stringify({agent_id:"a",tool_use_id:"t",kind:"probe",label:"sv",round:0,line,ts});console.log(e(new Date().toISOString(),l));console.log(e(new Date().toISOString(),"PROBE name=lines exit=0 sha=0 json={}"))' "$SL" > "$SA"
SOUT="$(node "$PR" --verify --label sv --round 0 --out "$SD" --parser lines --attest "$SA")"
ok=0; [ "$SOUT" = "VERIFY fail reason=sha-mismatch" ] && ok=1
check "verify: the latest entry for the call must match (older matching entry is not enough)" "$ok"

# (i) preflight.sh end to end (#83): stub gh first on PATH, temp git repo with a local bare origin. No network.
PF="$SCRIPT_DIR/preflight.sh"
if command -v jq >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
  PFD="$WORK/pf"; mkdir -p "$PFD/bin" "$PFD/wt/.claude"
  cat > "$PFD/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"pr view"*) [ -n "${GH_FAIL:-}" ] && { [ -n "${GH_ERR:-}" ] && printf '%s\n' "$GH_ERR" >&2; exit 1; }; echo "feat/issue-83" ;;
  *"issue view"*) [ -n "${GH_FAIL:-}" ] && exit 1; echo "${GH_TOTAL:-0}" ;;
  *"sub_issues"*) printf '12\n15\n' ;;
  *) exit 1 ;;
esac
GHEOF
  chmod +x "$PFD/bin/gh"
  echo '{"branchPrefix":"feat/"}' > "$PFD/wt/.claude/pipeline.config.json"

  OUT="$(PATH="$PFD/bin:$PATH" bash "$PF" branch --wt "$PFD/wt" --pr 7 --repo o/r --stamp 1)"
  ok=0; [ "$OUT" = '{"mode":"branch","headRef":"feat/issue-83","branchPrefix":"feat/"}' ] && ok=1
  check "preflight.sh branch: head ref and branch prefix in one JSON line" "$ok"

  OUT="$(GH_FAIL=1 PATH="$PFD/bin:$PATH" bash "$PF" branch --wt "$PFD/nowt" --pr 7)"; RC=$?
  ok=0; [ "$RC" -eq 0 ] && [ "$OUT" = '{"mode":"branch","headRef":null,"branchPrefix":null}' ] && ok=1
  check "preflight.sh branch: failing gh and missing config -> nulls, exit 0, one line" "$ok"

  # [239] a failing head-ref read names its cause (closed set), the config read is kept, no raw stderr text leaves the script
  OUT="$(GH_FAIL=1 GH_ERR='Post "https://api.github.com/graphql": tls: failed to verify certificate: x509: certificate signed by unknown authority' PATH="$PFD/bin:$PATH" bash "$PF" branch --wt "$PFD/wt" --pr 7 --repo o/r)"; RC=$?
  ok=0; [ "$RC" -eq 0 ] && [ "$OUT" = '{"mode":"branch","headRef":null,"branchPrefix":"feat/","readFailed":"tls"}' ] && ok=1
  check "[239] preflight.sh branch: a failing PR read names its cause as readFailed (tls), branchPrefix kept, no stderr text" "$ok"

  echo '{}' > "$PFD/wt/.claude/pipeline.config.json"
  OUT="$(PATH="$PFD/bin:$PATH" bash "$PF" branch --wt "$PFD/wt" --pr '')"
  ok=0; [ "$OUT" = '{"mode":"branch","headRef":null,"branchPrefix":""}' ] && ok=1
  check "preflight.sh branch: no PR number, key absent -> headRef null, branchPrefix empty string" "$ok"

  # dev: temp repo, local bare origin with one target changed upstream
  git init -q --bare "$PFD/origin.git" 2>/dev/null
  git init -q -b main "$PFD/repo" 2>/dev/null
  git -C "$PFD/repo" config user.email t@t; git -C "$PFD/repo" config user.name t
  echo a > "$PFD/repo/a.txt"; echo b > "$PFD/repo/b.txt"
  git -C "$PFD/repo" add . >/dev/null; git -C "$PFD/repo" commit -q -m base
  git -C "$PFD/repo" remote add origin "$PFD/origin.git"; git -C "$PFD/repo" push -q origin main 2>/dev/null
  echo a2 > "$PFD/repo/a.txt"; git -C "$PFD/repo" commit -q -am upstream; git -C "$PFD/repo" push -q origin main 2>/dev/null
  git -C "$PFD/repo" reset -q --hard HEAD~1 2>/dev/null

  OUT="$(PATH="$PFD/bin:$PATH" GH_TOTAL=0 bash "$PF" dev --wt "$PFD/repo" --issue 83 --base main --repo o/r --targets 'a.txt b.txt')"
  ok=0
  [ "$(printf '%s' "$OUT" | jq -c '[.mode, .planStale, .openSubIssues, .writable]')" = '["dev",["a.txt"],[],true]' ] && ok=1
  check "preflight.sh dev: changed plan target listed, sub-issues total 0 -> [], git dir writable" "$ok"
  ok=0
  [ "$(printf '%s' "$OUT" | jq -r '.gitDir')" = "$(git -C "$PFD/repo" rev-parse --absolute-git-dir)" ] && ok=1
  check "preflight.sh dev: gitDir is the absolute git dir of the worktree" "$ok"

  OUT="$(PATH="$PFD/bin:$PATH" GH_TOTAL=2 bash "$PF" dev --wt "$PFD/repo" --issue 83 --base main --repo o/r --targets '')"
  ok=0
  [ "$(printf '%s' "$OUT" | jq -c '[.planStale, .openSubIssues]')" = '[null,["12","15"]]' ] && ok=1
  check "preflight.sh dev: empty targets -> planStale null, open sub-issues listed" "$ok"

  OUT="$(GH_FAIL=1 PATH="$PFD/bin:$PATH" bash "$PF" dev --wt "$PFD/repo" --issue 83 --base main --repo o/r --targets 'a.txt')"
  ok=0
  [ "$(printf '%s' "$OUT" | jq -c '.openSubIssues')" = "null" ] && [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = "1" ] && ok=1
  check "preflight.sh dev: failing gh -> openSubIssues null, still exactly one line" "$ok"

  OUT="$(bash "$PF" bogus)"; ok=0; [ "$(printf '%s' "$OUT" | jq -c '.mode')" = "null" ] && ok=1
  check "preflight.sh unknown mode -> mode null (parser reports bad-mode)" "$ok"
else
  echo "SKIP - preflight.sh e2e needs jq and git"
fi

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
    cat <<'JSON'
{"headRefName":"feat/issue-84","headRefOid":"abc123","body":"hello body","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN",
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

# (k) pr-write.sh end to end (#85): a stub gh first on PATH logs every call and serves per-op state. Every op must
# READ before it writes, skip an already-applied write, and write nothing after a failed read. No network.
PW="$SCRIPT_DIR/pr-write.sh"
if command -v jq >/dev/null 2>&1; then
  PWD_="$WORK/pw"; mkdir -p "$PWD_/bin" "$PWD_/wt"
  GHLOG="$PWD_/gh.log"
  cat > "$PWD_/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
echo "$*" >> "$GHLOG"
case "$*" in
  *"pr edit"*)
    f=""; prev=""
    for a in "$@"; do [ "$prev" = "--body-file" ] && f="$a"; prev="$a"; done
    if [ -n "${GH_EDIT_TRUNCATE:-}" ] && [ ! -f "$GH_BODY_FILE.trunc" ]; then
      : > "$GH_BODY_FILE.trunc"; printf 'x\n' > "$GH_BODY_FILE"
    else
      cp "$f" "$GH_BODY_FILE"
    fi
    exit 0 ;;
  *"pr comment"*|*"issue comment"*|*"project item-edit"*|*minimizeComment*) exit 0 ;;
esac
[ -n "${GH_READ_FAIL:-}" ] && exit 1
[ -n "${GH_READ_ERR:-}" ] && { printf '%s\n' "$GH_READ_ERR" >&2; exit 1; }
case "$*" in
  *"pr view"*"--json body"*)
    cat "$GH_BODY_FILE"
    if [ -n "${GH_MUTATE_AFTER_READ:-}" ] && [ ! -f "$GH_BODY_FILE.mut" ]; then : > "$GH_BODY_FILE.mut"; printf 'edited by someone else\n' >> "$GH_BODY_FILE"; fi ;;
  *"api "*"/comments"*) printf '%s\n' "${GH_PAGINATED:-}" ;;
  *"--json comments"*) d='{"comments":[]}'; printf '%s\n' "${GH_COMMENTS:-$d}" ;;
  *"node(id"*) printf '%s\n' "${GH_MINIMIZED:-false}" ;;
  *projectItems*) printf '%s\n' "${GH_STATUS:-}" ;;
  *) exit 1 ;;
esac
GHEOF
  chmod +x "$PWD_/bin/gh"

  # run_pw <op> args... : runs pr-write.sh against the stub, fresh log; prints the single stdout line
  run_pw() {
    : > "$GHLOG"
    PATH="$PWD_/bin:$PATH" GHLOG="$GHLOG" GH_BODY_FILE="$PWD_/body.md" bash "$PW" "$@" --wt "$PWD_/wt" --repo o/r
  }
  first_line() { awk -v p="$1" 'index($0, p) { print NR; exit }' "$GHLOG"; }
  # read_first <read pattern> <write pattern>: both calls logged, the read strictly before the write
  read_first() {
    local r w
    r="$(first_line "$1")"; w="$(first_line "$2")"
    [ -n "$r" ] && [ -n "$w" ] && [ "$r" -lt "$w" ] && echo 1 || echo 0
  }
  no_call() { [ -z "$(first_line "$1")" ] && echo 1 || echo 0; }
  res() { printf '%s' "$1" | jq -r '[.result, (.reason // "-")] | join("/")'; }
  one_line() { [ "$(printf '%s\n' "$1" | wc -l | tr -d ' ')" = "1" ] && echo 1 || echo 0; }

  # issue-comment and pr-comment
  for kind in issue pr; do
    if [ "$kind" = "issue" ]; then FLAG="--number"; else FLAG="--pr"; fi
    MK='<!-- pipeline-reviewer-window pr=7 -->'
    OUT="$(GH_COMMENTS='{"comments":[{"body":"hello"}]}' run_pw "$kind-comment" "$FLAG" 501 --marker "$MK" --body "$MK
text")"
    ok=0; [ "$(res "$OUT")" = "written/-" ] && [ "$(one_line "$OUT")" = 1 ] && [ "$(read_first "$kind view" "$kind comment")" = 1 ] && ok=1
    check "pr-write.sh $kind-comment: read-before-write (view, then comment)" "$ok"
    OUT="$(GH_COMMENTS="{\"comments\":[{\"body\":\"$MK\\ntext\"}]}" run_pw "$kind-comment" "$FLAG" 501 --marker "$MK" --body "$MK
text")"
    ok=0; [ "$(res "$OUT")" = "skipped/marker-present" ] && [ "$(no_call "$kind comment")" = 1 ] && ok=1
    check "pr-write.sh $kind-comment: skips when already applied (marker present, no comment call)" "$ok"
    OUT="$(GH_READ_FAIL=1 run_pw "$kind-comment" "$FLAG" 501 --marker "$MK" --body "$MK
text")"
    ok=0; [ "$(res "$OUT")" = "failed/read-failed" ] && [ "$(no_call "$kind comment")" = 1 ] && ok=1
    check "pr-write.sh $kind-comment: read failure writes nothing" "$ok"
  done

  # [151] marker lookup past the 100-comment cap: the view serves 100 marker-less comments, REST serves 101
  C100="$(node -e 'console.log(JSON.stringify({comments:Array.from({length:100},(_, i)=>({body:"c"+i}))}))')"
  PAG="$(node -e 'const a=Array.from({length:100},(_, i)=>({body:"c"+i}));a.push({body:process.argv[1]+"\ntext"});a.forEach(o=>console.log(JSON.stringify(o)))' "$MK")"
  OUT="$(GH_COMMENTS="$C100" GH_PAGINATED="$PAG" run_pw issue-comment --number 501 --marker "$MK" --body "$MK
text")"
  ok=0; [ "$(res "$OUT")" = "skipped/marker-present" ] && [ "$(no_call 'issue comment')" = 1 ] && [ -n "$(first_line 'api repos/o/r/issues/501/comments')" ] && ok=1
  check "[151] pr-write.sh issue-comment: marker only in the 101st comment is found (paginated), no comment call" "$ok"
  OUT="$(GH_COMMENTS="$C100" GH_PAGINATED="$PAG" run_pw pr-comment --pr 501 --marker "$MK" --body "$MK
text")"
  ok=0; [ "$(res "$OUT")" = "skipped/marker-present" ] && [ "$(no_call 'pr comment')" = 1 ] && [ -n "$(first_line 'api repos/o/r/issues/501/comments')" ] && ok=1
  check "[151] pr-write.sh pr-comment: marker only in the 101st comment is found (paginated), no comment call" "$ok"

  # minimize
  OUT="$(GH_MINIMIZED=false run_pw minimize --id IC_1)"
  ok=0; [ "$(res "$OUT")" = "written/-" ] && [ "$(read_first 'node(id' 'minimizeComment')" = 1 ] && ok=1
  check "pr-write.sh minimize: read-before-write (isMinimized read, then the mutation)" "$ok"
  OUT="$(GH_MINIMIZED=true run_pw minimize --id IC_1)"
  ok=0; [ "$(res "$OUT")" = "skipped/already-minimized" ] && [ "$(no_call minimizeComment)" = 1 ] && ok=1
  check "pr-write.sh minimize: skips when already applied (already minimized)" "$ok"
  OUT="$(GH_READ_FAIL=1 run_pw minimize --id IC_1)"
  ok=0; [ "$(res "$OUT")" = "failed/read-failed" ] && [ "$(no_call minimizeComment)" = 1 ] && ok=1
  check "pr-write.sh minimize: read failure writes nothing" "$ok"

  # status
  ST_OLD='{"data":{"repository":{"issue":{"projectItems":{"nodes":[{"id":"PVTI_1","project":{"number":5},"fieldValues":{"nodes":[{},{"optionId":"opt-old","field":{"id":"F1"}}]}}]}}}}}'
  ST_SET='{"data":{"repository":{"issue":{"projectItems":{"nodes":[{"id":"PVTI_1","project":{"number":5},"fieldValues":{"nodes":[{"optionId":"opt-new","field":{"id":"F1"}}]}}]}}}}}'
  ST_NONE='{"data":{"repository":{"issue":{"projectItems":{"nodes":[]}}}}}'
  SARGS="--issue 85 --project-number 5 --project-id P1 --field-id F1 --option-id opt-new"
  OUT="$(GH_STATUS="$ST_OLD" run_pw status $SARGS)"
  ok=0; [ "$(res "$OUT")" = "written/-" ] && [ "$(read_first projectItems 'project item-edit')" = 1 ] && grep -q -- '--id PVTI_1 --field-id F1 --project-id P1 --single-select-option-id opt-new' "$GHLOG" && ok=1
  check "pr-write.sh status: read-before-write (item read, then item-edit with the read id)" "$ok"
  OUT="$(GH_STATUS="$ST_SET" run_pw status $SARGS)"
  ok=0; [ "$(res "$OUT")" = "skipped/already-set" ] && [ "$(no_call 'project item-edit')" = 1 ] && ok=1
  check "pr-write.sh status: skips when already applied (option already set)" "$ok"
  OUT="$(GH_STATUS="$ST_NONE" run_pw status $SARGS)"
  ok=0; [ "$(res "$OUT")" = "skipped/not-on-project" ] && [ "$(no_call 'project item-edit')" = 1 ] && ok=1
  check "pr-write.sh status: issue not on the project -> no edit with an empty id" "$ok"
  OUT="$(GH_READ_FAIL=1 run_pw status $SARGS)"
  ok=0; [ "$(res "$OUT")" = "failed/read-failed" ] && [ "$(no_call 'project item-edit')" = 1 ] && ok=1
  check "pr-write.sh status: read failure writes nothing" "$ok"

  # body-splice
  PRE_BODY='Closes #1

## Acceptance checklist
<!-- acceptance:start -->
- [ ] old
<!-- acceptance:end -->
<!-- decision-log:start -->
<!-- decision-log:end -->'
  DL='<!-- decision-log:start -->
## Decision log
- round 0 — LGTM
<!-- decision-log:end -->'
  printf '%s\n' "$PRE_BODY" > "$PWD_/body.md"
  OUT="$(run_pw body-splice --pr 9 --mode decision-log --text "$DL")"
  ok=0; [ "$(res "$OUT")" = "written/-" ] && [ "$(read_first 'pr view' 'pr edit')" = 1 ] && grep -q -- '- round 0 — LGTM' "$PWD_/body.md" && ok=1
  check "pr-write.sh body-splice: read-before-write (body read, spliced, then edit)" "$ok"
  OUT="$(run_pw body-splice --pr 9 --mode decision-log --text "$DL")"
  ok=0; [ "$(res "$OUT")" = "skipped/unchanged" ] && [ "$(no_call 'pr edit')" = 1 ] && ok=1
  check "pr-write.sh body-splice: skips when already applied (spliced body unchanged)" "$ok"
  OUT="$(run_pw body-splice --pr 9 --mode acceptance --text '- [ ] new one
- [ ] new two')"
  ok=0; [ "$(res "$OUT")" = "written/-" ] && grep -q -- '- \[ \] new two' "$PWD_/body.md" && ! grep -q -- '- \[ \] old' "$PWD_/body.md" && ok=1
  check "pr-write.sh body-splice: acceptance mode replaces the block contents" "$ok"
  printf 'no markers here, long enough body text to matter\n' > "$PWD_/body.md"
  OUT="$(run_pw body-splice --pr 9 --mode acceptance --text '- [ ] x')"
  ok=0; [ "$(res "$OUT")" = "failed/no-markers" ] && [ "$(no_call 'pr edit')" = 1 ] && ok=1
  check "pr-write.sh body-splice: acceptance markers absent -> failed, never appends, no edit" "$ok"
  OUT="$(GH_READ_FAIL=1 run_pw body-splice --pr 9 --mode decision-log --text "$DL")"
  ok=0; [ "$(res "$OUT")" = "failed/read-failed" ] && [ "$(no_call 'pr edit')" = 1 ] && ok=1
  check "pr-write.sh body-splice: read failure writes nothing" "$ok"
  printf '%s\n' "$PRE_BODY" > "$PWD_/body.md"
  OUT="$(GH_EDIT_TRUNCATE=1 run_pw body-splice --pr 9 --mode decision-log --text "$DL")"
  ok=0; [ "$(res "$OUT")" = "failed/guard-failed-restored" ] && [ "$(cat "$PWD_/body.md")" = "$PRE_BODY" ] && ok=1
  check "pr-write.sh body-splice: a lossy write trips the guard and the pre body is restored" "$ok"
  printf '%s\n' "$PRE_BODY" > "$PWD_/body.md"
  OUT="$(run_pw body-splice --pr 9 --mode decision-log --text "$DL" --expect-digest 000000000000)"
  ok=0; [ "$(res "$OUT")" = "failed/stale-read" ] && [ "$(no_call 'pr edit')" = 1 ] && [ "$(cat "$PWD_/body.md")" = "$PRE_BODY" ] && ok=1
  check "[151] pr-write.sh body-splice: a stale --expect-digest fails stale-read, no edit" "$ok"
  printf '%s\n' "$PRE_BODY" > "$PWD_/body.md"
  OUT="$(GH_MUTATE_AFTER_READ=1 run_pw body-splice --pr 9 --mode decision-log --text "$DL")"
  ok=0; [ "$(res "$OUT")" = "failed/stale-read" ] && [ "$(no_call 'pr edit')" = 1 ] && grep -q 'edited by someone else' "$PWD_/body.md" && ok=1
  check "[151] pr-write.sh body-splice: body changed between the first read and the edit fails stale-read, no edit" "$ok"

  # body-splice --mode tick (#183): the block re-spliced from the rendered checklist, boxes set by id
  TK_TXT='- [ ] <!-- ac:1 --> first
- [ ] <!-- ac:2 --> [human-gate] second
- [ ] <!-- ac:3 --> third'
  tk_body() { printf 'Closes #1\n\n## What this ships\n- a summary line long enough that rewording two boxes stays far under the ten percent guard\n- another summary line of the same kind, so the body is not only the checklist\n\n## Acceptance checklist\n<!-- acceptance:start -->\n%s\n<!-- acceptance:end -->\n<!-- decision-log:start -->\n<!-- decision-log:end -->\n' "$1" > "$PWD_/body.md"; }
  tk_body '- [ ] <!-- ac:1 --> first, stale wording
- [ ] <!-- ac:2 --> [human-gate] second
- [ ] <!-- ac:3 --> third, stale wording'
  OUT="$(run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1,3 --keep 2)"
  ok=0; [ "$(res "$OUT")" = "written/-" ] && [ "$(read_first 'pr view' 'pr edit')" = 1 ] \
    && grep -qxF -- '- [x] <!-- ac:1 --> first' "$PWD_/body.md" && grep -qxF -- '- [ ] <!-- ac:2 --> [human-gate] second' "$PWD_/body.md" \
    && grep -qxF -- '- [x] <!-- ac:3 --> third' "$PWD_/body.md" && ! grep -q 'stale wording' "$PWD_/body.md" && ok=1
  check "pr-write.sh body-splice: tick ticks the ids 1,3, leaves 2 open, restores the canonical text" "$ok"
  tk_body '- [ ] <!-- ac:1 --> first
- [x] <!-- ac:2 --> [human-gate] second
- [ ] <!-- ac:3 --> third'
  OUT="$(run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1,3 --keep 2,3)"
  ok=0; [ "$(res "$OUT")" = "written/-" ] \
    && grep -qxF -- '- [x] <!-- ac:1 --> first' "$PWD_/body.md" && grep -qxF -- '- [x] <!-- ac:2 --> [human-gate] second' "$PWD_/body.md" \
    && grep -qxF -- '- [ ] <!-- ac:3 --> third' "$PWD_/body.md" && ok=1
  check "pr-write.sh body-splice: tick keeps the state of a --keep id from the body ([x] stays, [ ] stays even when listed in --ids)" "$ok"
  tk_body '- [x] <!-- ac:1 --> first
- [ ] <!-- ac:2 --> [human-gate] second
- [ ] <!-- ac:3 --> third'
  OUT="$(run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 3 --keep '')"
  ok=0; [ "$(res "$OUT")" = "written/-" ] \
    && grep -qxF -- '- [ ] <!-- ac:1 --> first' "$PWD_/body.md" && grep -qxF -- '- [x] <!-- ac:3 --> third' "$PWD_/body.md" && ok=1
  check "pr-write.sh body-splice: tick reopens a stale [x] of an id in neither list" "$ok"
  OUT="$(run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 3 --keep '')"
  ok=0; [ "$(res "$OUT")" = "skipped/unchanged" ] && [ "$(no_call 'pr edit')" = 1 ] && ok=1
  check "[183] pr-write.sh tick that changes nothing: skipped/unchanged, no edit" "$ok"
  printf 'no markers here, long enough body text to matter\n' > "$PWD_/body.md"
  OUT="$(run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1 --keep 2)"
  ok=0; [ "$(res "$OUT")" = "failed/no-markers" ] && [ "$(no_call 'pr edit')" = 1 ] && ok=1
  check "pr-write.sh body-splice: tick with the markers absent -> failed/no-markers, never appends, no edit" "$ok"
  OUT="$(run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1,x --keep 2)"
  ok=0; [ "$(res "$OUT")" = "failed/bad-args" ] && [ "$(no_call 'pr view')" = 1 ] && ok=1
  check "[183] pr-write.sh tick with a non-digit id: failed/bad-args, nothing read" "$ok"
  # [183] review round: a line Nick added to the block survives, a fenced example is never the block, CRLF is kept
  R2L='- [ ] fixture `fixtures/incidents/9-*.json` present, replayed red on the base and green on the branch'
  tk_body "- [ ] <!-- ac:1 --> first
- [ ] <!-- ac:2 --> [human-gate] second
- [ ] <!-- ac:3 --> third
$R2L"
  OUT="$(run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1,3 --keep 2)"
  ok=0; [ "$(res "$OUT")" = "written/-" ] && grep -qxF -- '- [x] <!-- ac:3 --> third' "$PWD_/body.md" && grep -qxF -- "$R2L" "$PWD_/body.md" \
    && [ "$(awk -v l="$R2L" '$0 == l { n++ } END { print n + 0 }' "$PWD_/body.md")" = 1 ] \
    && [ "$(grep -n -F -- "$R2L" "$PWD_/body.md" | cut -d: -f1)" -gt "$(grep -n -F -- '- [x] <!-- ac:3 --> third' "$PWD_/body.md" | cut -d: -f1)" ] && ok=1
  check "[183] pr-write.sh tick keeps a box line without an id: once, open, after the rendered lines" "$ok"
  OUT="$(run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1,3 --keep 2)"
  ok=0; [ "$(res "$OUT")" = "skipped/unchanged" ] && [ "$(no_call 'pr edit')" = 1 ] && ok=1
  check "[183] pr-write.sh tick again over the kept line: skipped/unchanged, no edit" "$ok"
  # [tick-ids] (#257): --mode tick-ids ticks the listed ids of a 14-box body, no text on the command line
  ti_box() { # <id> <mark> : the line of box <id>, [human-gate] on box 5
    local g=""; [ "$1" = 5 ] && g="[human-gate] "
    printf -- '- [%s] <!-- ac:%s --> %sbox number %s `cmd %s` prints `%s`' "$2" "$1" "$g" "$1" "$1" "$1"
  }
  ti_block() { # <space-separated ids ticked> : the 14 box lines
    local i m out=""
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
      m=" "; case " $1 " in *" $i "*) m="x" ;; esac
      out="$out$(ti_box "$i" "$m")"$'\n'
    done
    printf '%s' "${out%$'\n'}"
  }
  tk_body "$(ti_block '1 3 14')"; cp "$PWD_/body.md" "$PWD_/ti-expected.md"
  tk_body "$(ti_block '')"
  OUT="$(run_pw body-splice --pr 9 --mode tick-ids --ids 1,3,14)"
  ok=0; [ "$(res "$OUT")" = "written/-" ] && [ "$(grep -c -- '^- \[x\]' "$PWD_/body.md")" = 3 ] && [ "$(grep -c -- '^- \[ \]' "$PWD_/body.md")" = 11 ] \
    && grep -qF -- '- [x] <!-- ac:1 --> ' "$PWD_/body.md" && grep -qF -- '- [x] <!-- ac:3 --> ' "$PWD_/body.md" && grep -qF -- '- [x] <!-- ac:14 --> ' "$PWD_/body.md" && ok=1
  check "[tick-ids] ids 1,3,14 of a 14-box body become [x], the other 11 stay open" "$ok"
  ok=0; cmp -s "$PWD_/body.md" "$PWD_/ti-expected.md" && ok=1
  check "[tick-ids] every other byte of the body is unchanged (the body equals the hand-built expected one)" "$ok"
  ok=0; [ "$(res "$OUT")" = "written/-" ] && [ "$(one_line "$OUT")" = 1 ] && ok=1
  check "[tick-ids] the output is the single line written/- as in text mode" "$ok"
  tk_body "$(ti_block '')"; cp "$PWD_/body.md" "$PWD_/ti-before.md"
  OUT="$(run_pw body-splice --pr 9 --mode tick-ids --ids 2,15)"
  ok=0; [ "$(res "$OUT")" = "failed/unknown-id" ] && cmp -s "$PWD_/body.md" "$PWD_/ti-before.md" && [ "$(no_call 'pr edit')" = 1 ] && ok=1
  check "[tick-ids] an unknown id (15) is refused: failed/unknown-id, body untouched, no edit (the valid id 2 is not ticked either)" "$ok"
  OUT="$(run_pw body-splice --pr 9 --mode tick-ids --ids 4,5)"
  ok=0; [ "$(res "$OUT")" = "failed/human-gate-id" ] && cmp -s "$PWD_/body.md" "$PWD_/ti-before.md" && [ "$(no_call 'pr edit')" = 1 ] && ok=1
  check "[tick-ids] a human-gate id (5) is refused: failed/human-gate-id, body untouched, no edit" "$ok"
  tk_body "$(ti_block '1 3 14')"
  OUT="$(run_pw body-splice --pr 9 --mode tick-ids --ids 1,3,14)"
  ok=0; [ "$(res "$OUT")" = "skipped/unchanged" ] && [ "$(no_call 'pr edit')" = 1 ] && ok=1
  check "[tick-ids] a second tick of the same ids is skipped/unchanged, no edit" "$ok"
  # [183] second review round (G1): the tick replaces only the id boxes; every other line of the block survives, once, in order
  while IFS= read -r FOREIGN <&3; do
    tk_body "- [ ] <!-- ac:1 --> first
$FOREIGN
- [ ] <!-- ac:2 --> [human-gate] second
- [ ] <!-- ac:3 --> third"
    OUT="$(run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1,3 --keep 2)"
    ok=0; [ "$(res "$OUT")" = "written/-" ] && grep -qxF -- '- [x] <!-- ac:3 --> third' "$PWD_/body.md" \
      && [ "$(awk -v l="$FOREIGN" '$0 == l { n++ } END { print n + 0 }' "$PWD_/body.md")" = 1 ] \
      && [ "$(grep -n -x -F -- "$FOREIGN" "$PWD_/body.md" | cut -d: -f1)" -gt "$(grep -n -F -- '- [x] <!-- ac:3 --> third' "$PWD_/body.md" | cut -d: -f1)" ] && ok=1
    OUT="$(run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1,3 --keep 2)"
    [ "$(res "$OUT")" = "skipped/unchanged" ] && [ "$(no_call 'pr edit')" = 1 ] || ok=0
    check "[183] pr-write.sh tick keeps the foreign block line '$FOREIGN' once, after the rendered lines, and again changes nothing" "$ok"
  done 3<<'EOF'
exception: skip lint -- migration pending -- #9
- exception: skip lint -- migration pending -- #9
Note: the migration plan is in the issue
* [ ] x
1. [ ] x
-[ ] x
- [ ] a box without an id
EOF
  tk_body "- [ ] <!-- ac:1 --> first

- [ ] <!-- ac:2 --> [human-gate] second
- [ ] <!-- ac:3 --> third"
  OUT="$(run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1,3 --keep 2)"
  ok=0; [ "$(res "$OUT")" = "written/-" ] && [ "$(sed -n '/ac:3 -->/{n;p;}' "$PWD_/body.md")" = "" ] && [ "$(sed -n '/ac:3 -->/{n;n;p;}' "$PWD_/body.md")" = "<!-- acceptance:end -->" ] && ok=1
  check "[183] pr-write.sh tick keeps a blank line of the block after the rendered lines" "$ok"
  FENCE='```
<!-- acceptance:start -->
- [ ] an example box
<!-- acceptance:end -->
```'
  tk_body '- [ ] <!-- ac:1 --> first
- [ ] <!-- ac:2 --> [human-gate] second
- [ ] <!-- ac:3 --> third'
  { printf '%s\n' "$FENCE"; cat "$PWD_/body.md"; printf '\n%s\n' "$FENCE"; } > "$PWD_/body2.md" && cp "$PWD_/body2.md" "$PWD_/body.md"
  OUT="$(run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1,3 --keep 2)"
  ok=0; [ "$(res "$OUT")" = "written/-" ] && grep -qxF -- '- [x] <!-- ac:1 --> first' "$PWD_/body.md" && grep -qxF -- '- [ ] an example box' "$PWD_/body.md" \
    && [ "$(grep -c -F -- '- [ ] an example box' "$PWD_/body.md")" = 2 ] && ok=1
  check "[183] pr-write.sh tick ignores marker pairs inside fenced code blocks (before and after the block)" "$ok"
  # [183] second review round (G4): the fence kinds the scanner knows, each holding an example pair AFTER the real block
  # (read unfenced, that example would be "the last pair" and the tick would hit it instead of the real block)
  EX='<!-- acceptance:start -->
- [ ] an example box
<!-- acceptance:end -->'
  while IFS='|' read -r FNAME FOPEN FINNER FCLOSE <&3; do
    tk_body '- [ ] <!-- ac:1 --> first
- [ ] <!-- ac:2 --> [human-gate] second
- [ ] <!-- ac:3 --> third'
    { cat "$PWD_/body.md"; printf '\n%s\n' "$FOPEN"; [ -z "$FINNER" ] || printf '%s\n' "$FINNER"; printf '%s\n%s\n' "$EX" "$FCLOSE"; } > "$PWD_/body2.md" && cp "$PWD_/body2.md" "$PWD_/body.md"
    OUT="$(run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1,3 --keep 2)"
    ok=0; [ "$(res "$OUT")" = "written/-" ] && grep -qxF -- '- [x] <!-- ac:1 --> first' "$PWD_/body.md" && grep -qxF -- '- [x] <!-- ac:3 --> third' "$PWD_/body.md" \
      && [ "$(grep -c -F -- 'ac:1' "$PWD_/body.md")" = 1 ] && [ "$(tail -n 4 "$PWD_/body.md" | head -n 3)" = "$EX" ] && ok=1
    check "[183] pr-write.sh tick: a $FNAME fence after the block keeps its example pair out of the tick" "$ok"
  done 3<<'EOF'
tilde|~~~||~~~
5-tilde|~~~~~||~~~~~
4-backtick holding a 3-backtick fence|````|```|````
backtick holding a tilde line|```|~~~|```
tilde holding a backtick line|~~~|```|~~~
EOF
  # a fence inside the block holds a marker pair and an id-looking line: neither cuts the block nor is a box
  tk_body '- [ ] <!-- ac:1 --> first
```
<!-- acceptance:start -->
- [ ] <!-- ac:2 --> fenced example
<!-- acceptance:end -->
```
- [ ] <!-- ac:2 --> [human-gate] second
- [ ] <!-- ac:3 --> third'
  OUT="$(run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1,3 --keep 2)"
  ok=0; [ "$(res "$OUT")" = "written/-" ] && grep -qxF -- '- [x] <!-- ac:3 --> third' "$PWD_/body.md" && grep -qxF -- '- [ ] <!-- ac:2 --> fenced example' "$PWD_/body.md" \
    && [ "$(grep -c -F -- 'ac:2' "$PWD_/body.md")" = 2 ] && ok=1
  check "[183] pr-write.sh tick: a fence inside the block keeps its marker pair and its id-looking line as they are" "$ok"
  # a fence never closed before the block swallows it: failed/no-markers, never appends, no edit
  { printf 'Closes #1\n\n```\nan example, never closed\n\n'; printf '<!-- acceptance:start -->\n%s\n<!-- acceptance:end -->\n' "$TK_TXT"; } > "$PWD_/body.md"
  OUT="$(run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1,3 --keep 2)"
  ok=0; [ "$(res "$OUT")" = "failed/no-markers" ] && [ "$(no_call 'pr edit')" = 1 ] && ok=1
  check "[183] pr-write.sh tick: a fence never closed before the block -> failed/no-markers, no edit" "$ok"
  tk_body '- [x] <!-- ac:1 --> first
- [ ] <!-- ac:2 --> [human-gate] second
- [x] <!-- ac:3 --> third'
  sed 's/$/\r/' "$PWD_/body.md" > "$PWD_/body2.md" && cp "$PWD_/body2.md" "$PWD_/body.md"
  OUT="$(run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1,3 --keep 2)"
  ok=0; [ "$(res "$OUT")" = "skipped/unchanged" ] && [ "$(no_call 'pr edit')" = 1 ] && ok=1
  check "[183] pr-write.sh tick over a CRLF body that is already right: skipped/unchanged, no edit" "$ok"
  sed 's/$/\r/' <<< "$(printf 'Closes #1\n\n## What this ships\n- a summary line long enough that rewording two boxes stays far under the ten percent guard\n- another summary line of the same kind, so the body is not only the checklist\n\n<!-- acceptance:start -->\n- [ ] <!-- ac:1 --> first\n- [ ] <!-- ac:2 --> [human-gate] second\n- [ ] <!-- ac:3 --> third\n<!-- acceptance:end -->')" > "$PWD_/body.md"
  OUT="$(run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1,3 --keep 2)"
  ok=0; [ "$(res "$OUT")" = "written/-" ] && grep -qxF -- "$(printf -- '- [x] <!-- ac:1 --> first\r')" "$PWD_/body.md" \
    && [ "$(tr -d '\r' < "$PWD_/body.md" | wc -c | tr -d ' ')" -lt "$(wc -c < "$PWD_/body.md" | tr -d ' ')" ] \
    && [ "$(grep -c "$(printf '\r$')" "$PWD_/body.md")" = "$(wc -l < "$PWD_/body.md" | tr -d ' ')" ] && ok=1
  check "[183] pr-write.sh tick over a CRLF body writes CRLF line breaks only" "$ok"

  # [212] the tick command is gated by its digest BEFORE it runs (--expect-cmd), and the block travels as ONE token (--text-b64)
  td_sha() { node -e 'process.stdout.write(require("crypto").createHash("sha256").update(process.argv[1]).digest("hex"))' "$1"; }
  td_field() { printf '%s\n' "$1" | awk -v k="$2" '{ for (i = 1; i <= NF; i++) if (index($i, k "=") == 1) { print substr($i, length(k) + 2); exit } }'; }
  td_pr() { PATH="$PWD_/bin:$PATH" GHLOG="$GHLOG" GH_BODY_FILE="$PWD_/body.md" node "$PR" "$@"; }
  TD_OUT="$WORK/td"
  TD_M1="$WORK/td-marker-wrong"; TD_M2="$WORK/td-marker-right"
  TD_CMD1="touch '$TD_M1'"; TD_CMD2="touch '$TD_M2'"
  TD_LINE="$(node "$PR" --label tdw --round 0 --out "$TD_OUT" --parser lines --no-reuse --expect-cmd "$(td_sha 'some other command')" --cmd "$TD_CMD1")"
  ok=0
  [ ! -e "$TD_M1" ] && [ "$(td_field "$TD_LINE" exit)" = "-1" ] && [ "$(td_field "$TD_LINE" cmd)" = "$(td_sha "refused:$TD_CMD1")" ] \
    && [ "$(printf '%s\n' "$TD_LINE" | wc -l | tr -d ' ')" = 1 ] && ok=1
  check "[tick-digest] a wrong --expect-cmd runs nothing: exit=-1 and cmd= is the digest of the refused: marker plus the typed command" "$ok"
  TD_LINE="$(node "$PR" --label tdr --round 0 --out "$TD_OUT" --parser lines --no-reuse --expect-cmd "$(td_sha "$TD_CMD2")" --cmd "$TD_CMD2")"
  ok=0
  [ -e "$TD_M2" ] && [ "$(td_field "$TD_LINE" exit)" = "0" ] && [ "$(td_field "$TD_LINE" cmd)" = "$(td_sha "$TD_CMD2")" ] && ok=1
  check "[tick-digest] the right --expect-cmd runs the command: exit=0 and cmd= equals the expected digest" "$ok"
  # the refusal never lets a stored failure answer a later call (exit != 0 is never reused)
  TD_LINE="$(node "$PR" --label tdw --round 0 --out "$TD_OUT" --parser lines --expect-cmd "$(td_sha "$TD_CMD1")" --cmd "$TD_CMD1")"
  ok=0
  [ -e "$TD_M1" ] && [ "$(td_field "$TD_LINE" exit)" = "0" ] && ok=1
  check "[tick-digest] a refused record is never reused: the same call with the right digest then runs" "$ok"
  # A refusal must always read as a digest mismatch to the engine: the PROBE line's cmd= never equals the digest it wanted,
  # whatever the token (wrong, truncated, empty, non-hex) and even when the copied --cmd is intact; the typed text stays visible.
  TD_CMD3="touch '$WORK/td-marker-3'"
  TD_WANT3="$(td_sha "$TD_CMD3")"
  td_refuse_case() { # <label> <token> <name>
    rm -f "$WORK/td-marker-3"
    TD_LINE="$(node "$PR" --label "$1" --round 0 --out "$TD_OUT" --parser pr-write --no-reuse --expect-cmd "$2" --cmd "$TD_CMD3")"
    TD_RC=$?
    ok=0
    [ "$TD_RC" -eq 0 ] && [ ! -e "$WORK/td-marker-3" ] && [ "$(printf '%s\n' "$TD_LINE" | wc -l | tr -d ' ')" = 1 ] \
      && [ "$(td_field "$TD_LINE" exit)" = "-1" ] && [ -n "$(td_field "$TD_LINE" cmd)" ] && [ "$(td_field "$TD_LINE" cmd)" != "$TD_WANT3" ] \
      && [ "$(node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(r.stderr+"|"+r.cmd.includes(process.argv[2])+"|"+r.cmd.startsWith("refused:"))' "$TD_OUT/$1-r0.json" "$TD_CMD3")" = "expect-cmd-mismatch|true|true" ] && ok=1
    check "[tick-digest] $3: nothing runs, exit 0 with a PROBE line of exit=-1 whose cmd= is not the wanted digest (record keeps the typed text)" "$ok"
  }
  td_refuse_case tdx1 "$(td_sha 'some other command')" "a wrong digest with an INTACT --cmd"
  td_refuse_case tdx2 "$(printf '%s' "$TD_WANT3" | cut -c1-40)" "a truncated digest with an intact --cmd"
  td_refuse_case tdx3 "" "an empty digest with an intact --cmd"
  td_refuse_case tdx4 "not-a-digest" "a non-hex digest with an intact --cmd"
  td_refuse_case tdx5 "$(printf '%s' "$TD_WANT3" | cut -c1-63)g" "a 64-character digest with a non-hex character with an intact --cmd"
  rm -f "$WORK/td-marker-3"
  TD_LINE="$(node "$PR" --label tdu --round 0 --out "$TD_OUT" --parser pr-write --no-reuse --expect-cmd "$(printf '%s' "$TD_WANT3" | tr 'a-f' 'A-F')" --cmd "$TD_CMD3")"
  ok=0
  [ -e "$WORK/td-marker-3" ] && [ "$(td_field "$TD_LINE" exit)" = "0" ] && [ "$(td_field "$TD_LINE" cmd)" = "$TD_WANT3" ] && ok=1
  check "[tick-digest] an UPPERCASE digest that matches the intact --cmd is normalised: the command runs and cmd= equals the digest" "$ok"
  # a write parser without --expect-cmd is refused too (a model that drops the flag must not get an unchecked write)
  rm -f "$WORK/td-marker-3"
  TD_LINE="$(node "$PR" --label tdn --round 0 --out "$TD_OUT" --parser pr-write --no-reuse --cmd "$TD_CMD3")"
  ok=0
  [ ! -e "$WORK/td-marker-3" ] && [ "$(td_field "$TD_LINE" exit)" = "-1" ] && [ "$(td_field "$TD_LINE" cmd)" != "$TD_WANT3" ] && ok=1
  check "[tick-digest] the pr-write parser without --expect-cmd is refused: nothing runs, cmd= is not the digest of the command" "$ok"
  TD_LINE="$(node "$PR" --label tdn2 --round 0 --out "$TD_OUT" --parser lines --no-reuse --cmd "$TD_CMD3")"
  ok=0
  [ -e "$WORK/td-marker-3" ] && [ "$(td_field "$TD_LINE" exit)" = "0" ] && [ "$(td_field "$TD_LINE" cmd)" = "$TD_WANT3" ] && ok=1
  check "[tick-digest] a read parser (lines) without --expect-cmd still runs the command" "$ok"
  # end to end: the composed command carries the whole block; a copy that re-flows it (boxes 2..N indented under box 1) is refused
  TD_TXT="$TK_TXT"
  TD_FLOW="$(printf '%s\n' "$TD_TXT" | awk 'NR == 1 { print; next } { print "  " $0 }')"
  tk_body '- [ ] <!-- ac:1 --> first
- [ ] <!-- ac:2 --> [human-gate] second
- [ ] <!-- ac:3 --> third, stale wording'
  cp "$PWD_/body.md" "$PWD_/body.before"
  TD_COMPOSED="bash '$PW' body-splice --pr 9 --mode tick --text '$TD_TXT' --ids 1,3 --keep 2 --wt '$PWD_/wt' --repo o/r"
  TD_TYPED="bash '$PW' body-splice --pr 9 --mode tick --text '$TD_FLOW' --ids 1,3 --keep 2 --wt '$PWD_/wt' --repo o/r"
  : > "$GHLOG"
  TD_LINE="$(td_pr --label tdf --round 0 --out "$TD_OUT" --parser pr-write --no-reuse --expect-cmd "$(td_sha "$TD_COMPOSED")" --cmd "$TD_TYPED")"
  ok=0
  [ "$TD_TYPED" != "$TD_COMPOSED" ] && cmp -s "$PWD_/body.md" "$PWD_/body.before" && [ "$(no_call 'pr edit')" = 1 ] && [ "$(no_call 'pr view')" = 1 ] \
    && [ "$(td_field "$TD_LINE" exit)" = "-1" ] && [ "$(td_field "$TD_LINE" cmd)" = "$(td_sha "refused:$TD_TYPED")" ] \
    && [ "$(td_field "$TD_LINE" cmd)" != "$(td_sha "$TD_COMPOSED")" ] && ok=1
  check "[tick-digest] a re-flowed copy of the tick command leaves the body byte-identical, no gh call, and its cmd= differs from the composed one" "$ok"
  # --text-b64: a long multi-line block (backticks, both quote kinds, id comments, non-ASCII) lands exactly as --text does
  TD_BLK="$(cat <<'BLKEOF'
- [ ] <!-- ac:1 --> run `node a.cjs | grep -c "x"` and expect '0'
- [ ] <!-- ac:2 --> [human-gate] café ok: $HOME and \n stay literal
- [ ] <!-- ac:3 --> third, with a "double" and a 'single' quote, then 100% done
- [ ] <!-- ac:4 --> fourth
BLKEOF
)"
  TD_B64="$(printf '%s' "$TD_BLK" | node -e 'process.stdout.write(require("fs").readFileSync(0).toString("base64"))')"
  tk_body '- [ ] <!-- ac:1 --> stale one
- [ ] <!-- ac:2 --> [human-gate] stale two
- [ ] <!-- ac:3 --> stale three
- [ ] <!-- ac:4 --> stale four'
  cp "$PWD_/body.md" "$PWD_/body.before"
  OUT_T="$(run_pw body-splice --pr 9 --mode tick --text "$TD_BLK" --ids 1,3 --keep 2)"
  cp "$PWD_/body.md" "$PWD_/body.via-text"
  cp "$PWD_/body.before" "$PWD_/body.md"
  OUT_B="$(run_pw body-splice --pr 9 --mode tick --text-b64 "$TD_B64" --ids 1,3 --keep 2)"
  ok=0
  [ "$(res "$OUT_T")" = "written/-" ] && [ "$(res "$OUT_B")" = "written/-" ] && cmp -s "$PWD_/body.via-text" "$PWD_/body.md" \
    && grep -qF -- 'café ok: $HOME and \n stay literal' "$PWD_/body.md" && grep -qxF -- "- [x] <!-- ac:3 --> third, with a \"double\" and a 'single' quote, then 100% done" "$PWD_/body.md" \
    && [ "$(printf '%s' "$TD_B64" | wc -l | tr -d ' ')" = 0 ] && ok=1
  check "[tick-digest] --text-b64 of a long multi-line block (backticks, quotes, id comments, non-ASCII) gives the same body as --text, in one token" "$ok"
  # end to end through probe-run with the RIGHT digest and --text-b64
  tk_body '- [ ] <!-- ac:1 --> stale one
- [ ] <!-- ac:2 --> [human-gate] stale two
- [ ] <!-- ac:3 --> stale three
- [ ] <!-- ac:4 --> stale four'
  TD_REAL="bash '$PW' body-splice --pr 9 --mode tick --text-b64 '$TD_B64' --ids 1,3 --keep 2 --wt '$PWD_/wt' --repo o/r"
  TD_LINE="$(td_pr --label tdb --round 0 --out "$TD_OUT" --parser pr-write --no-reuse --expect-cmd "$(td_sha "$TD_REAL")" --cmd "$TD_REAL")"
  TD_PARSED="$(printf '%s\n' "$TD_LINE" | node -e '
    const { PARSERS } = require(process.argv[1])
    const json = require("fs").readFileSync(0, "utf8").split(" json=")[1]
    const v = PARSERS["pr-write"](json, "", 0)
    process.stdout.write(v.error ? "ERR" : v.op + ":" + v.result)
  ' "$PR")"
  ok=0
  [ "$TD_PARSED" = "body-splice:written" ] && [ "$(td_field "$TD_LINE" cmd)" = "$(td_sha "$TD_REAL")" ] \
    && grep -qxF -- "- [x] <!-- ac:1 --> run \`node a.cjs | grep -c \"x\"\` and expect '0'" "$PWD_/body.md" && grep -qxF -- "- [x] <!-- ac:3 --> third, with a \"double\" and a 'single' quote, then 100% done" "$PWD_/body.md" && ok=1
  check "[tick-digest] the right digest with --text-b64 through probe-run: written, ids ticked, the PROBE line parses as written" "$ok"

  # [239] a failed READ names its cause: reason stays read-failed, `detail` is one of tls|auth|rate-limit|not-found|other,
  # never the stderr text; a silent failure and every non-failure keep today's exact line
  detail_of() { printf '%s' "$1" | jq -r '.detail // "-"'; }
  E_TLS='Post "https://api.github.com/graphql": tls: failed to verify certificate: x509: certificate signed by unknown authority'
  printf '%s\n' "$PRE_BODY" > "$PWD_/body.md"
  OUT="$(GH_READ_ERR="$E_TLS" run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1 --keep 2)"
  ok=0; [ "$(res "$OUT")" = "failed/read-failed" ] && [ "$(detail_of "$OUT")" = "tls" ] && [ "$(no_call 'pr edit')" = 1 ] && [ "$(one_line "$OUT")" = 1 ] && ok=1
  check "[239] pr-write.sh body-splice (tick): a TLS certificate failure on the body read -> failed/read-failed, detail tls, no edit" "$ok"
  OUT="$(GH_READ_ERR='HTTP 401: Bad credentials (https://api.github.com/graphql)
Try authenticating with:  gh auth login -h github.com' run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1 --keep 2)"
  ok=0; [ "$(res "$OUT")" = "failed/read-failed" ] && [ "$(detail_of "$OUT")" = "auth" ] && [ "$(no_call 'pr edit')" = 1 ] && ok=1
  check "[239] pr-write.sh body-splice: a 401 on the body read -> detail auth" "$ok"
  OUT="$(GH_READ_ERR='GraphQL: API rate limit already exceeded for user ID 1234' run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1 --keep 2)"
  ok=0; [ "$(res "$OUT")" = "failed/read-failed" ] && [ "$(detail_of "$OUT")" = "rate-limit" ] && ok=1
  check "[239] pr-write.sh body-splice: a rate limit on the body read -> detail rate-limit" "$ok"
  OUT="$(GH_READ_ERR='GraphQL: Could not resolve to a PullRequest with the number of 99999. (repository.pullRequest)' run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1 --keep 2)"
  ok=0; [ "$(res "$OUT")" = "failed/read-failed" ] && [ "$(detail_of "$OUT")" = "not-found" ] && ok=1
  check "[239] pr-write.sh body-splice: an unknown PR on the body read -> detail not-found" "$ok"
  OUT="$(GH_READ_ERR='dial tcp: lookup api.github.com: no such host' run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1 --keep 2)"
  ok=0; [ "$(res "$OUT")" = "failed/read-failed" ] && [ "$(detail_of "$OUT")" = "other" ] && ok=1
  check "[239] pr-write.sh body-splice: an unrecognised read error -> detail other" "$ok"
  OUT="$(GH_READ_FAIL=1 run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1 --keep 2)"
  OUT_OK="$(run_pw body-splice --pr 9 --mode decision-log --text "$DL")"
  ok=0
  [ "$OUT" = '{"op":"body-splice","result":"failed","reason":"read-failed","bytes":null}' ] && [ "$(printf '%s' "$OUT_OK" | jq -r 'has("detail")')" = "false" ] && ok=1
  check "[239] pr-write.sh: a failure with no stderr and a successful op print today's exact line (no detail key)" "$ok"
  OUT="$(GH_READ_ERR='tls: failed to verify certificate, token ghp_abcdefghijklmnopqrstuvwxyzabcdefghij sent to https://api.github.com/graphql' run_pw body-splice --pr 9 --mode tick --text "$TK_TXT" --ids 1 --keep 2)"
  ok=0; [ "$(detail_of "$OUT")" = "tls" ] && [ "$(printf '%s' "$OUT" | grep -c 'ghp_\|https://')" = 0 ] && ok=1
  check "[239] pr-write.sh: a token-shaped string and a URL in stderr never reach the output line (only the class does)" "$ok"
  OUT="$(GH_READ_ERR="$E_TLS" run_pw pr-comment --pr 501 --marker "$MK" --body "$MK
text")"
  ok=0; [ "$(res "$OUT")" = "failed/read-failed" ] && [ "$(detail_of "$OUT")" = "tls" ] && [ "$(no_call 'pr comment')" = 1 ] && ok=1
  check "[239] pr-write.sh pr-comment: a TLS failure on the comment read -> detail tls, no comment call" "$ok"
  OUT="$(GH_READ_ERR='HTTP 401: Bad credentials (https://api.github.com/graphql)' run_pw status $SARGS)"
  ok=0; [ "$(res "$OUT")" = "failed/read-failed" ] && [ "$(detail_of "$OUT")" = "auth" ] && [ "$(no_call 'project item-edit')" = 1 ] && ok=1
  check "[239] pr-write.sh status: a 401 on the project item read -> detail auth, no item-edit" "$ok"

  # parser round trip and the engine/helper block parity
  OUT="$(GH_MINIMIZED=true run_pw minimize --id IC_1)"
  out_rt="$(printf '%s\n' "$OUT" | node -e '
    const { PARSERS } = require(process.argv[1])
    const v = PARSERS["pr-write"](require("fs").readFileSync(0, "utf8"), "", 0)
    process.stdout.write(v.error ? "ERR" : v.op + ":" + v.result + ":" + v.reason)
  ' "$PR")"
  [ "$out_rt" = "minimize:skipped:already-minimized" ] && ok=1 || ok=0
  check "pr-write.sh output round-trips through the pr-write parser" "$ok"
else
  echo "SKIP - pr-write.sh e2e needs jq"
fi

# [239] the parsers keep the named cause only from the closed set (never an out-of-set string), and add no key when it is absent
ok=0
node -e '
  const assert = require("assert")
  const { PARSERS } = require(process.argv[1])
  const pw = (o) => PARSERS["pr-write"](JSON.stringify(o), "", 0)
  const base = { op: "body-splice", result: "failed", reason: "read-failed", bytes: null }
  for (const c of ["tls", "auth", "rate-limit", "not-found", "other"]) assert.deepStrictEqual(pw({ ...base, detail: c }), { ...base, detail: c })
  for (const bad of ["x509: certificate signed by unknown authority", "TLS", "", null, 7, ["tls"]]) assert.deepStrictEqual(pw({ ...base, detail: bad }), base)
  assert.deepStrictEqual(pw(base), base)
  assert.ok(!("detail" in pw({ op: "status", result: "written", reason: null, bytes: null })))
' "$PR" 2>"$WORK/239p.err" && ok=1
[ "$ok" -eq 1 ] || head -n 3 "$WORK/239p.err"
check "[239] PARSERS pr-write keeps detail only from the closed set and adds no key when absent" "$ok"
ok=0
node -e '
  const assert = require("assert")
  const { PARSERS } = require(process.argv[1])
  const pf = (o) => PARSERS.preflight(JSON.stringify(o), "", 0)
  const base = { mode: "branch", headRef: null, branchPrefix: "feat/" }
  for (const c of ["tls", "auth", "rate-limit", "not-found", "other"]) assert.deepStrictEqual(pf({ ...base, readFailed: c }), { ...base, readFailed: c })
  for (const bad of ["x509: unknown authority", "TLS", "", null, 7]) assert.deepStrictEqual(pf({ ...base, readFailed: bad }), base)
  assert.deepStrictEqual(pf(base), base)
  assert.ok(!("readFailed" in pf({ mode: "dev", planStale: null, openSubIssues: null, gitDir: null, writable: null, readFailed: "tls" })))
' "$PR" 2>"$WORK/239f.err" && ok=1
[ "$ok" -eq 1 ] || head -n 3 "$WORK/239f.err"
check "[239] PARSERS preflight keeps readFailed only from the closed set (branch mode) and adds no key when absent" "$ok"

BLK='/^\/\/ --- prBodySplice:start ---/,/^\/\/ --- prBodySplice:end ---/p'
[ -n "$(sed -n "$BLK" "$ROOT/workflows/deliver-pipeline.js")" ] && [ "$(sed -n "$BLK" "$ROOT/workflows/deliver-pipeline.js")" = "$(sed -n "$BLK" "$SCRIPT_DIR/pr-body-splice.cjs")" ] && ok=1 || ok=0
check "pr-body-splice.cjs: source identical to the engine block" "$ok"

# [237] acceptanceBoxes: a first line of only carriage returns is blank whatever their number (the engine file and the template)
for f237 in "$ROOT/workflows/deliver-pipeline.js" "$SCRIPT_DIR/pr-body-splice.cjs"; do
  ok=0
  node -e '
    const fs = require("fs"), assert = require("assert")
    const s = fs.readFileSync(process.argv[1], "utf8")
    const a = s.indexOf("// --- prBodySplice:start ---"), b = s.indexOf("// --- prBodySplice:end ---")
    assert.ok(a >= 0 && b > a, "prBodySplice markers not found")
    const boxes = new Function(s.slice(a, b) + "\nreturn acceptanceBoxes")()
    const rows = [["\r\n", []], ["\r\r\n", []], ["\r\r\r\n", []], ["\n", []], ["note\r\n", ["note"]], [" \r\n", [" "]]]
    for (const [head, foreign] of rows) {
      const got = boxes(head + "- [ ] <!-- ac:1 --> a\r\n")
      assert.deepStrictEqual(got.foreign, foreign, "first line " + JSON.stringify(head) + ": foreign=" + JSON.stringify(got.foreign))
      assert.deepStrictEqual([...got.checkedById], [[1, false]])
    }
  ' "$f237" 2>"$WORK/237.err" && ok=1
  [ "$ok" -eq 1 ] || head -n 3 "$WORK/237.err"
  check "[237] acceptanceBoxes treats a first line of only carriage returns as blank ($(basename "$f237"))" "$ok"
done

SHA_BLK="$(sed -n '/^\/\/ --- sha256Hex:start ---/,/^\/\/ --- sha256Hex:end ---/p' "$ROOT/workflows/deliver-pipeline.js")"
ok=0
[ -n "$SHA_BLK" ] && node -e '
  const assert = require("assert"), crypto = require("crypto")
  const sha = new Function(process.argv[1] + "\nreturn sha256Hex")()
  for (const s of ["", "printf '"'"'hi\\n'"'"'", "abc", "x".repeat(200), "caf\u00e9 \u20ac \ud83d\ude00 \u65e5\u672c"]) {
    assert.strictEqual(sha(s), crypto.createHash("sha256").update(s, "utf8").digest("hex"))
  }
' "$SHA_BLK" 2>/dev/null && ok=1
check "[151] engine sha256Hex equals crypto sha256 (empty, ASCII, 200 bytes, non-ASCII)" "$ok"
B64_BLK="$(sed -n '/^\/\/ --- base64Utf8:start ---/,/^\/\/ --- base64Utf8:end ---/p' "$ROOT/workflows/deliver-pipeline.js")"
ok=0
[ -n "$B64_BLK" ] && node -e '
  const assert = require("assert")
  const b64 = new Function(process.argv[1] + "\nreturn base64Utf8")()
  const cases = ["", "a", "ab", "abc", "abcd", "abcde", "line one\nline two\n", "`tick` \"d\" \x27s\x27 $HOME", "café € 😀 日本", "x".repeat(1000), "- [ ] <!-- ac:1 --> a\n- [ ] <!-- ac:2 --> b"]
  for (const s of cases) {
    const got = b64(s)
    assert.strictEqual(got, Buffer.from(s, "utf8").toString("base64"))
    assert.ok(!got.includes("\n"))
  }
' "$B64_BLK" 2>/dev/null && ok=1
check "[tick-digest] engine base64Utf8 equals Buffer base64 of the UTF-8 bytes (lengths mod 3 = 0/1/2, newline, backtick, quotes, non-ASCII), one line" "$ok"
# parity of both hand-written encoders with Node over lone surrogates (U+D800..U+DFFF encode as U+FFFD, EF BF BD), astral characters, CRLF, empty
cat > "$WORK/parity.cjs" <<'JS'
const assert = require("assert"), crypto = require("crypto")
const [shaBlk, b64Blk] = process.argv.slice(2)
const sha = new Function(shaBlk + "\nreturn sha256Hex")()
const b64 = new Function(b64Blk + "\nreturn base64Utf8")()
const corpus = ["", "\ud800", "\udfff", "a\ud800b", "\udc00\ud800", "x\ud83dy", "\ud83d\ude00", "\ud83d\ude00\ud83d", "\ud83d", "\u{10ffff}\u{10000}",
  "caf\u00e9 \u20ac \u65e5\u672c", "line one\r\nline two\r\n", "\r\n", "a\r\nb\nc\rd", "- [ ] <!-- ac:1 --> a\r\n- [ ] <!-- ac:2 --> b\ud800\r\n", "x".repeat(1000) + "\udc00"]
for (const s of corpus) {
  assert.strictEqual(b64(s), Buffer.from(s).toString("base64"), "base64 " + JSON.stringify(s))
  assert.strictEqual(sha(s), crypto.createHash("sha256").update(Buffer.from(s)).digest("hex"), "sha256 " + JSON.stringify(s))
}
JS
ok=0
[ -n "$SHA_BLK" ] && [ -n "$B64_BLK" ] && node "$WORK/parity.cjs" "$SHA_BLK" "$B64_BLK" 2>"$WORK/parity.err" && ok=1
check "[tick-digest] engine sha256Hex and base64Utf8 equal Node over lone surrogates, astral characters, CRLF and the empty string" "$ok"
node "$PR" --verify --label x --round 0 --out "$WORK/tdv" --parser lines --attest "$WORK/tdv.jsonl" --expect-cmd "$(printf '%064d' 0)" >/dev/null 2>&1
[ "$?" -eq 2 ] && ok=1 || ok=0
check "[tick-digest] --expect-cmd together with --verify exits 2 (usage)" "$ok"
node "$PR" --label x --round 0 --out "$WORK/tdv" --parser lines --expect-cmd not-a-digest --cmd 'true' >/dev/null 2>&1
[ "$?" -eq 0 ] && ok=1 || ok=0
check "[tick-digest] an --expect-cmd that is not 64 hex characters is a refusal (exit 0 and a PROBE line), not a usage error" "$ok"
SAN_LINE="$(grep -m1 '^const sanitizeProbeToken' "$ROOT/workflows/deliver-pipeline.js")"
ok=0
[ -n "$SAN_LINE" ] && [ "$(node -e 'const f = new Function(process.argv[1] + "; return sanitizeProbeToken")(); process.stdout.write(f("PR Ready/Merged:x"))' "$SAN_LINE" 2>/dev/null)" = "PR-Ready-Merged-x" ] && ok=1
check "[151] sanitizeProbeToken maps 'PR Ready/Merged:x' to 'PR-Ready-Merged-x'" "$ok"

# (f2) #195: the plugin-version check. The REAL pluginVersionCmd runs through the REAL probe-run.cjs (parser `lines`)
# against real manifests, and the PROBE line it prints feeds the REAL pluginVersionVerdict. The roots carry a space and a
# single quote on purpose (quoting). The engine version is read from the `const BUILD` line, never hardcoded.
PV_BLK="$(sed -n '/^\/\/ --- pluginVersion:start ---/,/^\/\/ --- pluginVersion:end ---/p' "$ROOT/workflows/deliver-pipeline.js")"
PV_ENGINE="$(sed -n "s/.*const BUILD = {[^}]*version: '\([^']*\)'.*/\1/p" "$ROOT/workflows/deliver-pipeline.js" | head -n 1)"
PV_ROOTS="$WORK/pv roots o'x"
mkdir -p "$PV_ROOTS/same/.claude-plugin" "$PV_ROOTS/old/.claude-plugin" "$PV_ROOTS/bad/.claude-plugin" "$PV_ROOTS/nov/.claude-plugin"
printf '{"name":"lgtmgate","version":"%s"}\n' "$PV_ENGINE" > "$PV_ROOTS/same/.claude-plugin/plugin.json"
printf '{"name":"lgtmgate","version":"0.0.1-old"}\n' > "$PV_ROOTS/old/.claude-plugin/plugin.json"
printf '{not json\n' > "$PV_ROOTS/bad/.claude-plugin/plugin.json"
printf '{"name":"lgtmgate"}\n' > "$PV_ROOTS/nov/.claude-plugin/plugin.json"
pv_verdict() {
  node -e '
    const { spawnSync } = require("child_process")
    const [blk, pr, root, engine, out] = process.argv.slice(1)
    const { pluginVersionCmd, pluginVersionVerdict } = new Function(blk + "\nreturn { pluginVersionCmd, pluginVersionVerdict }")()
    const r = spawnSync("node", [pr, "--label", "pv", "--round", "0", "--out", out, "--parser", "lines", "--no-reuse", "--cmd", pluginVersionCmd(root)], { encoding: "utf8" })
    const m = /^PROBE name=lines exit=(\d+) .* json=(.*)$/m.exec(r.stdout || "")
    if (!m) { process.stdout.write("no-probe-line|" + r.stdout + r.stderr); process.exit(0) }
    const v = pluginVersionVerdict({ engineVersion: engine, pluginRoot: root, exit: Number(m[1]), lines: JSON.parse(m[2]).lines })
    process.stdout.write(v ? v.code + "|" + v.reason : "ok|")
  ' "$PV_BLK" "$PR" "$1" "$PV_ENGINE" "$WORK/pv-out" 2>/dev/null
}
ok=0
[ -n "$PV_BLK" ] && [ -n "$PV_ENGINE" ] && [ "$(pv_verdict "$PV_ROOTS/same")" = "ok|" ] && ok=1
check "[195] a root holding the engine's version ($PV_ENGINE) passes (real command, real probe-run.cjs, real manifest)" "$ok"
PV_OUT="$(pv_verdict "$PV_ROOTS/old")"
ok=0
case "$PV_OUT" in
  *"pv roots"*) ok=0 ;;
  "plugin-version-skew|"*"0.0.1-old"*"$PV_ENGINE"*"pass the current plugin root and relaunch") ok=1 ;;
esac
check "[195] a root holding another version is a plugin-version-skew naming both versions and the remedy, never the root path" "$ok"
PV_OUT="$(pv_verdict "$PV_ROOTS/none")"
ok=0
case "$PV_OUT" in
  *"pv roots"*) ok=0 ;;
  "plugin-version-unreadable|"*".claude-plugin/plugin.json (missing)"*"pass the current plugin root and relaunch") ok=1 ;;
esac
check "[195] a root without a manifest fails closed as plugin-version-unreadable (missing), never naming the root path" "$ok"
PV_OUT="$(pv_verdict "$PV_ROOTS/bad")"
ok=0
case "$PV_OUT" in
  "plugin-version-unreadable|"*"(unreadable)"*"pass the current plugin root and relaunch") ok=1 ;;
esac
check "[195] a manifest that is not JSON fails closed as plugin-version-unreadable (unreadable)" "$ok"
PV_OUT="$(pv_verdict "$PV_ROOTS/nov")"
ok=0
case "$PV_OUT" in
  "plugin-version-unreadable|"*"(no-version)"*"pass the current plugin root and relaunch") ok=1 ;;
esac
check "[195] a manifest without a version fails closed as plugin-version-unreadable (no-version)" "$ok"

# (g) agents/probe.md tools: lists exactly Bash
TOOLS="$(awk '/^---$/{f++; next} f==1 && /^tools:/{t=1; next} f==1 && t && /^  - /{sub(/^  - /,""); print; next} f==1 && t{t=0}' "$ROOT/agents/probe.md" | tr '\n' ',')"
[ "$TOOLS" = "Bash," ] && ok=1 || ok=0
check "agents/probe.md tools is exactly Bash (got '$TOOLS')" "$ok"

if [ "$fail_count" -eq 0 ]; then st=ok; else st=fail; fi
echo "[probe-run] status=$st passed=$pass_count failed=$fail_count"
[ "$fail_count" -eq 0 ]
