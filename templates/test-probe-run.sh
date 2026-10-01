#!/usr/bin/env bash
# Regression test for templates/probe-run.cjs (E2.2, #80) and templates/preflight.sh (#83): pure parsers replayed against
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
RC=$?
ok=0
[ "$RC" -eq 0 ] && [ "$(printf '%s\n' "$LINE" | wc -l | tr -d ' ')" = "1" ] &&
  [ "$LINE" = "PROBE name=lines exit=0 sha=$HI_SHA json={\"lines\":[\"hi\"]}" ] && ok=1
check "e2e printf hi: single PROBE line with expected sha" "$ok"
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

node -e 'console.log(JSON.stringify({agent_id:"a",tool_use_id:"t",kind:"probe",label:"vt",round:0,line:process.argv[1],ts:"x"}))' "$VLINE" > "$ATT"
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

# (i) preflight.sh end to end (#83): stub gh first on PATH, temp git repo with a local bare origin. No network.
PF="$SCRIPT_DIR/preflight.sh"
if command -v jq >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
  PFD="$WORK/pf"; mkdir -p "$PFD/bin" "$PFD/wt/.claude"
  cat > "$PFD/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"pr view"*) [ -n "${GH_FAIL:-}" ] && exit 1; echo "feat/issue-83" ;;
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

# (g) agents/probe.md tools: lists exactly Bash
TOOLS="$(awk '/^---$/{f++; next} f==1 && /^tools:/{t=1; next} f==1 && t && /^  - /{sub(/^  - /,""); print; next} f==1 && t{t=0}' "$ROOT/agents/probe.md" | tr '\n' ',')"
[ "$TOOLS" = "Bash," ] && ok=1 || ok=0
check "agents/probe.md tools is exactly Bash (got '$TOOLS')" "$ok"

if [ "$fail_count" -eq 0 ]; then st=ok; else st=fail; fi
echo "[probe-run] status=$st passed=$pass_count failed=$fail_count"
[ "$fail_count" -eq 0 ]
