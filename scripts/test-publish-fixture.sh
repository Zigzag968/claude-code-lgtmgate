#!/usr/bin/env bash
# Self-test of scripts/publish-fixture.cjs (+ its .sh wrapper), fully hermetic: the raw capture is a
# SYNTHETIC one generated from the public smoke fixture into a temp directory (planted unique words in
# the scout plan, the diagnose evidence, the nick summary and the brief), and everything is published
# into temp output directories. The real Claude Code projects directory and fixtures/incidents are never touched.
#
# Cases: `ok: published ...` (what the published file holds and how it replays), `ok: protected ...`,
# `ok: coupled ...`, `ok: printed ...`, `ok: publishing twice ...`, `ok: no temp copy ...`,
# `ok: refuses ...` (each refusal names its cause and writes nothing), `ok: usage ...`.
# The stub engines (--fp) are test doubles for the engine body; the PEM header is assembled from fragments.
# bash 3.2 compatible. Trailer: [test-publish-fixture] status=<ok|fail> passed=<n> failed=<n>
set -u
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
export ROOT
# the repo must come out of the suite exactly as it went in: no stub engine or publisher writes into the working tree
TREE0="$(git status --short --untracked-files=all 2>&1)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
TMP="${TMPDIR:-/tmp}/publish-fixture-selftest.$$"
mkdir -p "$TMP"
TMP="$(cd "$TMP" && pwd -P)"
RAWD="$TMP/raw"
RAW="$RAWD/123-auto.json"
mkdir -p "$RAWD"

W_PLAN=zqplanx9; W_EVID=zqevidx9; W_SUMM=zqsummx9; W_BRIEF=zqbriefx9; W_LABEL=zqlabelx9
export W_PLAN W_EVID W_SUMM W_BRIEF W_LABEL

cat > "$TMP/gen.cjs" <<'JS'
// node gen.cjs <out file> <variant>   variants: base | pem | badstatus | note
const fs = require('fs')
const path = require('path')
const [out, variant] = process.argv.slice(2)
const f = JSON.parse(fs.readFileSync(path.join(process.env.ROOT, 'fixtures/smoke/auto-lgtm.json'), 'utf8'))
// the shape capture-incident.cjs writes: name, args, calls, expect.status only
delete f.note
f.name = '123-auto'
f.expect = { status: f.expect.status }
const scout = f.calls['scout-issue-123-1']
// long free text, like a real capture: this is what minimization must collapse
const para = (w, n) => Array.from({ length: n }, (_, i) => `line ${i}: ${w} private detail that no public fixture needs`).join('\n')
scout.plan = scout.plan.replace('1. src/slugify.js: transliterate before stripping', para(process.env.W_PLAN, 40))
f.calls['diagnose-issue-123'].evidence = para(process.env.W_EVID, 30)
f.calls['nick-issue-123'].summary = `opened PR #42, ${process.env.W_SUMM} inside`
f.args.brief = `fix slugify accents, ${process.env.W_BRIEF} customer`
f.args.proceedThrough = 'review'
// an entry the replay never consumes (its label names a private branch) and the unconsumed tail of an array
f.calls[`unused-${process.env.W_LABEL}-feat-branch`] = { someKey: 'someValue', n: 777777, b: true }
f.calls['plan-check-123-1'] = [f.calls['plan-check-123-1'], { verdict: 'CONFORMING', issues: [] }]
if (variant === 'pem') f.args.issueType = process.env.PEM_HEADER
if (variant === 'oneway') f.args.config = { oneWayDoorKinds: ['Status', 'seam'], oneWayDoorPaths: ['workflows/**', '!docs/'] }
if (variant === 'nogo') {
  // the run stops at the scout and Sam's free-text rationale becomes result.reason
  f.calls['scout-issue-123-1'].decision = 'NO-GO'
  f.calls['scout-issue-123-1'].rationale = 'adds ZQCUSTOMERSTATUS for Acme'
  f.expect.status = 'no-go'
}
if (variant === 'badstatus') f.expect.status = 'escalate'
if (variant === 'note') f.note = 'free text'
fs.writeFileSync(out, JSON.stringify(f, null, 2) + '\n')
JS

# rinfo <fixture> <js expression over r>: replays the fixture against the real engine and prints the expression
# as JSON (r = { result, logs, calls, sites }, as returned by replayFixture)
cat > "$TMP/rinfo.cjs" <<'JS'
const fs = require('fs')
const path = require('path')
const root = process.env.ROOT
const { stripExports, buildPipelineRunner, replayFixture } = require(path.join(root, 'scripts/run-offline.cjs'))
const run = buildPipelineRunner(stripExports(fs.readFileSync(path.join(root, 'workflows/deliver-pipeline.js'), 'utf8')))
const fx = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
replayFixture(fx, run, { sites: true }).then((r) => { process.stdout.write(JSON.stringify(eval(process.argv[3]))) })
JS
# counts <fixture>: prints "<key names> <non-string scalars>" over args and calls
cat > "$TMP/counts.cjs" <<'JS'
const f = JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8'))
let k = 0; let n = 0
const walk = (v) => {
  if (Array.isArray(v)) v.forEach(walk)
  else if (v !== null && typeof v === 'object') for (const key of Object.keys(v)) { k++; walk(v[key]) }
  else if (typeof v !== 'string') n++
}
walk(f.args); walk(f.calls)
process.stdout.write(`${k} ${n}`)
JS
rinfo() { node "$TMP/rinfo.cjs" "$1" "$2"; }

# pub [args...]: run the publisher; sets OUT (stdout), ERR (stderr) and RC
pub() {
  OUT=$(bash scripts/publish-fixture.sh "$@" 2>"$TMP/stderr.txt"); RC=$?
  ERR=$(cat "$TMP/stderr.txt")
}
last_line() { printf '%s\n' "$OUT" | tail -n 1; }
# planted_in <file>...: counts the planted words found in the given files
planted_in() { cat "$@" 2>/dev/null | grep -c -e "$W_PLAN" -e "$W_EVID" -e "$W_SUMM" -e "$W_BRIEF" -e "$W_LABEL" || true; }
# jsf <file> <js expression over f>: evaluates against the JSON file, prints the result as JSON
jsf() {
  node -e 'const f=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(JSON.stringify(eval(process.argv[2])))' "$1" "$2"
}
newdir() { rm -rf "$TMP/$1"; mkdir -p "$TMP/$1"; echo "$TMP/$1"; }

node "$TMP/gen.cjs" "$RAW" base

# ---- positive: a published fixture ------------------------------------------------------------------

OUTD="$(newdir out)"
PUB="$OUTD/123-auto.json"
pub "$RAW" --out-dir "$OUTD"
PUBLISHED=no
if [ "$RC" -eq 0 ] && [ -f "$PUB" ] && [ "$(last_line)" = "[publish-fixture] status=ok out=$PUB" ]; then
  PUBLISHED=yes
else
  bad "publish of the synthetic capture: rc=$RC out=$OUT err=$ERR"
fi

REPLAY_OK=no
if [ "$PUBLISHED" = yes ]; then
  n=$(planted_in "$PUB")
  if [ "$n" = "0" ]; then ok "published fixture holds no planted word"; else bad "planted word(s) survive in the published fixture ($n lines)"; fi

  rp=$(node scripts/run-offline.cjs "$PUB" --report-unused 2>&1)
  case "$rp" in
    *"status=ready"*"[offline] status=ok passed=1 failed=0"*) REPLAY_OK=yes; ok "published fixture replays to status=ok";;
    *) bad "published fixture replay: $rp";;
  esac

  rawsz=$(wc -c < "$RAW" | tr -d ' '); pubsz=$(wc -c < "$PUB" | tr -d ' ')
  if [ "$pubsz" -lt "$rawsz" ]; then ok "published fixture is smaller than the raw capture"; else bad "published fixture is not smaller: $pubsz >= $rawsz"; fi

  if grep -qF '"mode": "auto"' "$PUB" && grep -qF '"proceedThrough": "review"' "$PUB" && grep -qF 'features/issue-123' "$PUB"; then
    ok "protected and flow-selecting fields survive"
  else
    bad "protected or flow-selecting field lost (mode, proceedThrough or the preflight headRef)"
  fi

  # the oracle pins the SHAPE of the result too: a neutralization that moves worktreeBehind or opens a failure path is refused
  rb=$(rinfo "$RAW" 'r.result.worktreeBehind'); pb=$(rinfo "$PUB" 'r.result.worktreeBehind')
  rl=$(rinfo "$RAW" 'r.logs.length'); pl=$(rinfo "$PUB" 'r.logs.length')
  rk=$(rinfo "$RAW" 'Object.keys(r.result).sort()'); pk=$(rinfo "$PUB" 'Object.keys(r.result).sort()')
  if [ "$rb" = "0" ] && [ "$pb" = "0" ] && [ "$rl" = "$pl" ] && [ "$rk" = "$pk" ]; then
    ok "result shape is preserved (worktreeBehind, keys, log count)"
  else
    bad "result shape changed by minimization: worktreeBehind raw=$rb pub=$pb logs raw=$rl pub=$pl"
  fi

  rawcmd=$(jsf "$RAW" 'f.calls["probe-123-provision-provision-r0"].line.match(/cmd=([0-9a-f]{64})/)[1]')
  pubcmd=$(jsf "$PUB" 'f.calls["probe-123-provision-provision-r0"].line.match(/cmd=([0-9a-f]{64})/)[1]')
  wt=$(jsf "$PUB" 'f.args.wtPath')
  if [ "$rawcmd" != "$pubcmd" ] && [ "$wt" = '"_"' ] && [ "$REPLAY_OK" = yes ]; then
    ok "coupled PROBE hashes are recomputed"
  else
    bad "coupled hashes: raw=$rawcmd pub=$pubcmd wtPath=$wt replay=$REPLAY_OK"
  fi

  printf '%s\n' "$OUT" > "$TMP/stdout.txt"
  leaks=$(cat "$TMP/stdout.txt" "$TMP/stderr.txt" | grep -c -e "$W_PLAN" -e "$W_EVID" -e "$W_SUMM" -e "$W_BRIEF" -e "$W_LABEL" -e 'features/issue-123' || true)
  if grep -Eq '^remains: [0-9]+ strings, [0-9]+ characters \(was [0-9]+\)$' "$TMP/stdout.txt" \
     && grep -Eq '^  args\.mode [0-9]+ protected$' "$TMP/stdout.txt" && [ "$leaks" = "0" ]; then
    ok "printed remainder lists field names and counts, never values"
  else
    bad "printed remainder: leaks=$leaks stdout=$OUT"
  fi

  # F2: entries the final replay never consumed leave the published file, and what is NOT neutralized is counted
  if ! grep -q 'unused-' "$PUB" && [ "$(jsf "$PUB" 'Array.isArray(f.calls["plan-check-123-1"]) ? f.calls["plan-check-123-1"].length : -1')" = "1" ] \
     && ! node scripts/run-offline.cjs "$PUB" --report-unused 2>&1 | grep -q 'unused:'; then
    ok "unconsumed call entries are pruned from the published file"
  else
    bad "unconsumed entries survive in the published file"
  fi
  want=$(node "$TMP/counts.cjs" "$PUB")
  got=$(sed -n -E 's/^kept as is: ([0-9]+) key names, ([0-9]+) non-string scalars .*$/\1 \2/p' "$TMP/stdout.txt")
  if [ -n "$got" ] && [ "$got" = "$want" ] && grep -Eq '^pruned: [1-9][0-9]* unconsumed call entries$' "$TMP/stdout.txt"; then
    ok "printed counts of kept key names and non-string scalars match the published file"
  else
    bad "printed counts: got='$got' want='$want' stdout=$OUT"
  fi

  OUT2D="$(newdir out2)"
  pub "$RAW" --out-dir "$OUT2D"
  if [ "$RC" -eq 0 ] && cmp -s "$PUB" "$OUT2D/123-auto.json"; then ok "publishing twice gives byte-identical files"; else bad "second publish differs or failed: rc=$RC"; fi

  EMPTYT="$(newdir emptytmp)"
  OUT3D="$(newdir out3)"
  OUT=$(TMPDIR="$EMPTYT" bash scripts/publish-fixture.sh "$RAW" --out-dir "$OUT3D" 2>"$TMP/stderr.txt"); RC=$?
  left=$(ls -A "$EMPTYT" | wc -l | tr -d ' ')
  if [ "$RC" -eq 0 ] && [ "$left" = "0" ] && [ -f "$OUT3D/123-auto.json" ]; then ok "no temp copy is left behind"; else bad "temp copy left behind: rc=$RC left=$left"; fi

  # ---- fail-closed: every refusal names its cause and writes nothing ----------------------------------
  before=$(cksum < "$PUB"); listing=$(ls -A "$OUTD")
  pub "$RAW" --out-dir "$OUTD"
  after=$(cksum < "$PUB"); listing2=$(ls -A "$OUTD")
  if [ "$RC" -eq 1 ] && [ "$(last_line)" = "[publish-fixture] status=refused" ] && [ "$before" = "$after" ] && [ "$listing" = "$listing2" ] \
     && printf '%s\n' "$ERR" | grep -q '^refused: .*exists'; then
    ok "refuses when the output file exists"
  else
    bad "refusal on an existing output file: rc=$RC last='$(last_line)' err=$ERR"
  fi
fi

# refusal_case <name> <expected stderr substring> <out dir> <publisher args...>: exit 1, trailer refused, cause named, out dir empty
refusal_case() {
  name="$1"; want="$2"; dir="$3"; shift 3
  pub "$@"
  left=$(ls -A "$dir" | wc -l | tr -d ' ')
  case "$ERR" in
    *"$want"*)
      if [ "$RC" -eq 1 ] && [ "$(last_line)" = "[publish-fixture] status=refused" ] && [ "$left" = "0" ]; then ok "refuses $name"; else bad "refuses $name: rc=$RC last='$(last_line)' left=$left"; fi;;
    *) bad "refuses $name: stderr does not name '$want': rc=$RC err=$ERR";;
  esac
}

# F3: free text that the engine copies into result.reason is published as is, so it is reported by path and length
NGRAW="$RAWD/129-nogo.json"
node "$TMP/gen.cjs" "$NGRAW" nogo
D17="$(newdir out-nogo)"
pub "$NGRAW" 129-nogo --out-dir "$D17"
rlen=$(node -e 'process.stdout.write(String("adds ZQCUSTOMERSTATUS for Acme".length))')
nout=$(printf '%s\n' "$OUT")
if [ "$RC" -eq 0 ] && printf '%s\n' "$nout" | grep -Fxq "  expect.reason $rlen free-text" \
   && printf '%s\n' "$nout" | grep -Fxq "  calls.scout-issue-123-1.rationale $rlen kept free-text" \
   && printf '%s\n' "$nout" | grep -Eq '^free text: [1-9][0-9]* field\(s\), [0-9]+ characters ' \
   && ! printf '%s\n%s\n' "$nout" "$ERR" | grep -q 'ZQCUSTOMERSTATUS' \
   && grep -q 'ZQCUSTOMERSTATUS' "$D17/129-nogo.json" \
   && [ "$(node scripts/run-offline.cjs "$D17/129-nogo.json" 2>&1 | tail -n 1)" = "[offline] status=ok passed=1 failed=0" ]; then
  ok "free text copied into expect.reason and kept fields is reported by path and length"
else
  bad "free-text report: rc=$RC err=$ERR out=$OUT"
fi

# the R3 configuration (oneWayDoorKinds / oneWayDoorPaths) is a switch of the engine the oracle cannot always see: it survives
OWRAW="$RAWD/128-oneway.json"
node "$TMP/gen.cjs" "$OWRAW" oneway
D16="$(newdir out-oneway)"
pub "$OWRAW" 128-oneway --out-dir "$D16"
owc=$(jsf "$D16/128-oneway.json" 'f.args.config' 2>/dev/null)
if [ "$RC" -eq 0 ] && [ "$owc" = '{"oneWayDoorKinds":["Status","seam"],"oneWayDoorPaths":["workflows/**","!docs/"]}' ]; then
  ok "protected R3 config (oneWayDoorKinds, oneWayDoorPaths) survives"
else
  bad "R3 config lost or publication failed: rc=$RC config=$owc err=$ERR"
fi

# the redactor refuses on residue: a PEM header in a protected arg (minimization never touches it)
PEMRAW="$RAWD/123-pem.json"
PEM_HEADER="-----BEGIN RSA ""PRIVATE KEY-----"
export PEM_HEADER
node "$TMP/gen.cjs" "$PEMRAW" pem
D10="$(newdir out-pem)"; T10="$(newdir tmp-pem)"
OUT=$(TMPDIR="$T10" bash scripts/publish-fixture.sh "$PEMRAW" --out-dir "$D10" 2>"$TMP/stderr.txt"); RC=$?
ERR=$(cat "$TMP/stderr.txt")
left=$(ls -A "$D10" | wc -l | tr -d ' '); tleft=$(ls -A "$T10" | wc -l | tr -d ' ')
echoed=$(printf '%s\n%s\n' "$OUT" "$ERR" | grep -c 'BEGIN' || true)
case "$ERR" in
  *"redact-fixture exited 3"*"pem-private-key"*)
    if [ "$RC" -eq 1 ] && [ "$left" = "0" ] && [ "$tleft" = "0" ] && [ "$echoed" = "0" ] && [ "$(last_line)" = "[publish-fixture] status=refused" ]; then
      ok "refuses when the redactor exits 3"
    else
      bad "refuses when the redactor exits 3: rc=$RC out-left=$left tmp-left=$tleft echoed=$echoed"
    fi;;
  *) bad "refuses when the redactor exits 3: stderr: $ERR";;
esac

# stub engines (--fp): test doubles for the engine body, with no agent() call
printf '%s\n' "globalThis.__pf = (globalThis.__pf || 0) + 1" "return { status: globalThis.__pf % 2 ? 'a' : 'b' }" > "$TMP/stub-flaky.js"
printf '%s\n' "return { status: args.p === '/opt/zzz-secret' ? 'a' : 'b' }" > "$TMP/stub-path.js"
printf '{"name":"1-s","args":{},"calls":{},"expect":{"status":"a"}}\n' > "$RAWD/124-flaky.json"
printf '{"name":"1-s","args":{"p":"/opt/zzz-secret"},"calls":{},"expect":{"status":"a"}}\n' > "$RAWD/125-path.json"

D11="$(newdir out-flaky)"
refusal_case "when the baseline replay is not deterministic" "not deterministic" "$D11" "$RAWD/124-flaky.json" --fp "$TMP/stub-flaky.js" --out-dir "$D11"

printf '%s\n' "globalThis.__pf3 = (globalThis.__pf3 || 0) + 1" "return { status: globalThis.__pf3 % 3 === 0 ? 'b' : 'a' }" > "$TMP/stub-flaky3.js"
D11b="$(newdir out-flaky3)"
refusal_case "when the baseline is stable for two replays but not three" "not deterministic" "$D11b" "$RAWD/124-flaky.json" --fp "$TMP/stub-flaky3.js" --out-dir "$D11b"

D12="$(newdir out-path)"
refusal_case "when redaction changes the outcome" "outcome changed after redaction" "$D12" "$RAWD/125-path.json" --fp "$TMP/stub-path.js" --out-dir "$D12"

BADRAW="$RAWD/126-badstatus.json"
node "$TMP/gen.cjs" "$BADRAW" badstatus
D13="$(newdir out-badstatus)"
refusal_case "a capture whose recorded status the replay does not reproduce" "expect.status is not reproduced" "$D13" "$BADRAW" --out-dir "$D13"

NOTERAW="$RAWD/127-note.json"
node "$TMP/gen.cjs" "$NOTERAW" note
D15="$(newdir out-note)"
refusal_case "a capture with a free-text top-level key" "outside name, args, calls, expect" "$D15" "$NOTERAW" --out-dir "$D15"

# ---- the write: never a partial file at the final name -----------------------------------------------

# a preload that kills the publisher (SIGKILL) halfway through its first write into KILL_DIR
cat > "$TMP/killwrite.cjs" <<'JS'
const fs = require('fs')
const dir = process.env.KILL_DIR
const fds = new Map()
const open = fs.openSync
fs.openSync = function (p, ...rest) {
  const fd = open.call(this, p, ...rest)
  if (dir && typeof p === 'string' && p.startsWith(dir)) fds.set(fd, p)
  return fd
}
const write = fs.writeSync
fs.writeSync = function (fd, buf, off, len, ...rest) {
  if (fds.has(fd)) { write.call(this, fd, buf, off, Math.floor(len / 2)); process.kill(process.pid, 'SIGKILL') }
  return write.call(this, fd, buf, off, len, ...rest)
}
JS
DK="$(newdir out-kill)"
KRC=$(KILL_DIR="$DK" NODE_OPTIONS="--require $TMP/killwrite.cjs" bash -c 'bash scripts/publish-fixture.sh "$@" >/dev/null 2>&1; echo $?' _ "$RAW" --out-dir "$DK" 2>/dev/null)
kfinal=no; [ -e "$DK/123-auto.json" ] && kfinal=yes
pub "$RAW" --out-dir "$DK"
if [ "$KRC" -ne 0 ] && [ "$kfinal" = no ] && [ "$RC" -eq 0 ] && [ -f "$DK/123-auto.json" ] \
   && [ "$(node scripts/run-offline.cjs "$DK/123-auto.json" 2>&1 | tail -n 1)" = "[offline] status=ok passed=1 failed=0" ]; then
  ok "a kill during the write leaves no file at the final name, and a rerun publishes"
else
  bad "kill during the write: killed-rc=$KRC final-after-kill=$kfinal rerun-rc=$RC"
fi

if [ "$PUBLISHED" = yes ]; then
  only=$(ls -A "$OUTD")
  if [ "$only" = "123-auto.json" ]; then ok "the output directory holds the published file and no temporary file"; else bad "output directory holds: $only"; fi
fi

# a symbolic link at the final name (even a dangling one) is refused and its target never created
DL="$(newdir out-link)"
ln -s "$TMP/never-created.json" "$DL/123-auto.json"
pub "$RAW" --out-dir "$DL"
if [ "$RC" -eq 1 ] && [ "$(last_line)" = "[publish-fixture] status=refused" ] && [ ! -e "$TMP/never-created.json" ] && [ -L "$DL/123-auto.json" ] \
   && [ "$(ls -A "$DL")" = "123-auto.json" ] && printf '%s\n' "$ERR" | grep -q '^refused: .*exists'; then
  ok "refuses a symbolic link at the output name"
else
  bad "refuses a symbolic link: rc=$RC target=$([ -e "$TMP/never-created.json" ] && echo created || echo absent) err=$ERR"
fi

# a missing output directory is refused
pub "$RAW" --out-dir "$TMP/no-such-dir"
if [ "$RC" -eq 1 ] && [ "$(last_line)" = "[publish-fixture] status=refused" ] && [ ! -e "$TMP/no-such-dir" ] \
   && printf '%s\n' "$ERR" | grep -q '^refused: the output directory does not exist'; then
  ok "refuses a missing output directory"
else
  bad "refuses a missing output directory: rc=$RC err=$ERR"
fi

# a file that appears at the final name during the run is never overwritten (the engine stub plants it)
# the victim path is absolute and comes from the environment, never from an arg (minimization would turn an arg into `_`
# and the stub would then write into the working directory)
printf '%s\n' "const fs = process.mainModule.require('fs')" "try { fs.writeFileSync(process.env.RACE_VICTIM, 'precious\n', { flag: 'wx' }) } catch (e) {}" "return { status: 'a' }" > "$TMP/stub-race.js"
DR="$(newdir out-race)"
printf '{"name":"1-s","args":{},"calls":{},"expect":{"status":"a"}}\n' > "$RAWD/130-race.json"
RACE_VICTIM="$DR/130-race.json"; export RACE_VICTIM
pub "$RAWD/130-race.json" --fp "$TMP/stub-race.js" --out-dir "$DR"
if [ "$RC" -eq 1 ] && [ "$(last_line)" = "[publish-fixture] status=refused" ] && [ "$(cat "$DR/130-race.json")" = "precious" ] \
   && [ "$(ls -A "$DR")" = "130-race.json" ] && printf '%s\n' "$ERR" | grep -q '^refused: .*never overwritten'; then
  ok "refuses to overwrite a file that appeared during the run"
else
  bad "race on the output name: rc=$RC content=$(cat "$DR/130-race.json" 2>/dev/null) listing=$(ls -A "$DR") err=$ERR"
fi

# an unwritable output directory ends as status=error with nothing left behind
DW="$(newdir out-readonly)"
chmod 555 "$DW"
pub "$RAW" --out-dir "$DW"
wleft=$(ls -A "$DW" | wc -l | tr -d ' ')
chmod 755 "$DW"
if [ "$RC" -eq 1 ] && [ "$(last_line)" = "[publish-fixture] status=error" ] && [ "$wleft" = "0" ]; then
  ok "an unwritable output directory is an error and leaves nothing"
else
  bad "unwritable output directory: rc=$RC last='$(last_line)' left=$wleft"
fi

# ---- each step of the publisher is pinned by a case that fails when the step is disabled ---------------------------------

# mkcap <out> <args JSON> [<status>]: a minimal capture (no calls) for the stub engines
mkcap() { node -e 'const [o,a,st]=process.argv.slice(1);require("fs").writeFileSync(o,JSON.stringify({name:"1-s",args:JSON.parse(a),calls:{},expect:{status:st||"a"}}))' "$1" "$2" "${3:-a}"; }

# fault preload for the child processes and the publisher itself (PF_FAULT selects one fault)
cat > "$TMP/fault.cjs" <<'JS'
const base = require('path').basename(process.argv[1] || '')
const f = process.env.PF_FAULT
if (f === 'redact-check' && base === 'redact-fixture.cjs' && process.argv.includes('--check')) process.exit(1)
if (f === 'redact-crash' && base === 'redact-fixture.cjs' && !process.argv.includes('--check')) process.exit(2)
if (f === 'strict-exit' && base === 'run-offline.cjs') { console.log('[offline] status=ok passed=1 failed=0'); process.exit(1) }
if (f === 'strict-nopass' && base === 'run-offline.cjs') { console.log('[offline] status=ok passed=0 failed=0'); process.exit(0) }
if (f === 'stack-limit' && base === 'publish-fixture.cjs') Error.stackTraceLimit = 2
if (f === 'track-fsync') {
  const fs = require('fs')
  const fsync = fs.fsyncSync
  fs.fsyncSync = function (fd) { fs.appendFileSync(process.env.PF_MARK, 'fsync\n'); return fsync.call(this, fd) }
}
JS
# pubf <fault> [args...]: pub with a fault injected
pubf() { f="$1"; shift; OUT=$(PF_FAULT="$f" NODE_OPTIONS="--require $TMP/fault.cjs" bash scripts/publish-fixture.sh "$@" 2>"$TMP/stderr.txt"); RC=$?; ERR=$(cat "$TMP/stderr.txt"); }

# the oracle compares the engine call sites: a neutralization that only moves the path through the engine is refused
printf '%s\n' "if (String(args.p).length > 3) {" "  log('one')" "} else {" "  log('two')" "}" "return { status: 'a' }" > "$TMP/stub-sites.js"
mkcap "$RAWD/131-sites.json" '{"p":"zq-branch-token"}'
D20="$(newdir out-sites)"
pub "$RAWD/131-sites.json" --fp "$TMP/stub-sites.js" --out-dir "$D20"
if [ "$RC" -eq 0 ] && [ "$(jsf "$D20/131-sites.json" 'f.args.p')" = '"zq-branch-token"' ]; then
  ok "a neutralization that only changes the engine call sites is refused"
else
  bad "sites oracle: rc=$RC p=$(jsf "$D20/131-sites.json" 'f.args.p' 2>/dev/null) err=$ERR"
fi

# the oracle compares the form of the result: a string equal to a token of the engine's vocabulary is pinned, other free text is not
printf '%s\n' "const T = 'zqvocabtoken'" "return { status: 'a', tag: String(args.p).split(',')[0], free: args.q }" > "$TMP/stub-vocab.js"
mkcap "$RAWD/132-vocab.json" '{"p":"zqvocabtoken,zqfreetextx9","q":"zqfreetextx9"}'
D21="$(newdir out-vocab)"
pub "$RAWD/132-vocab.json" --fp "$TMP/stub-vocab.js" --out-dir "$D21"
if [ "$RC" -eq 0 ] && [ "$(jsf "$D21/132-vocab.json" 'f.args.p+"|"+f.args.q')" = '"zqvocabtoken,zqfreetextx9|_"' ]; then
  ok "a result string that is a token of the engine's vocabulary is pinned and other free text is neutralized"
else
  bad "vocabulary: rc=$RC args=$(jsf "$D21/132-vocab.json" 'JSON.stringify(f.args)' 2>/dev/null) err=$ERR"
fi
# an emptiness change is a shape change: an empty string stays empty, a non-empty one stays non-empty
printf '%s\n' "return { status: 'a', e: args.e, n: args.n }" > "$TMP/stub-empty.js"
mkcap "$RAWD/133-empty.json" '{"e":"","n":"zqfreetextx9"}'
D22="$(newdir out-empty)"
pub "$RAWD/133-empty.json" --fp "$TMP/stub-empty.js" --out-dir "$D22"
if [ "$RC" -eq 0 ] && [ "$(jsf "$D22/133-empty.json" 'f.args.e+"|"+f.args.n')" = '"|_"' ]; then ok "an empty string stays empty and a non-empty one stays non-empty"; else bad "emptiness: rc=$RC err=$ERR"; fi

# a multi-line string whose middle line cannot be neutralized is cut line by line
printf '%s\n' "return { status: String(args.p).split('\\n')[1] === 'KEEP' ? 'a' : 'b' }" > "$TMP/stub-lines.js"
mkcap "$RAWD/134-lines.json" '{"p":"first zqlineone\nKEEP\nlast zqlinetwo"}'
D23="$(newdir out-lines)"
pub "$RAWD/134-lines.json" --fp "$TMP/stub-lines.js" --out-dir "$D23"
if [ "$RC" -eq 0 ] && [ "$(jsf "$D23/134-lines.json" 'f.args.p')" = '"_\nKEEP\n_"' ]; then
  ok "a multi-line string is neutralized line by line around the line the engine needs"
else
  bad "line pass: rc=$RC p=$(jsf "$D23/134-lines.json" 'f.args.p' 2>/dev/null) err=$ERR"
fi

# the published expect pins the exact trace and the ordered call labels
if [ "$PUBLISHED" = yes ]; then
  lab=$(rinfo "$PUB" 'r.calls.map((c) => c.label)'); tr=$(rinfo "$PUB" 'r.result.trace')
  if [ "$(jsf "$PUB" 'f.expect.traceExact')" = "true" ] && [ "$(jsf "$PUB" 'f.expect.callLabels')" = "$lab" ] && [ "$(jsf "$PUB" 'f.expect.trace')" = "$tr" ]; then
    ok "published expect holds traceExact, the exact trace and the ordered call labels"
  else
    bad "published expect: traceExact/callLabels/trace do not match the replay"
  fi
fi

# the baseline must be a clean run with a result object
printf '%s\n' "return 5" > "$TMP/stub-noresult.js"
mkcap "$RAWD/135-noresult.json" '{}'
D24="$(newdir out-noresult)"
refusal_case "a baseline whose engine returns no result object" "returned no result object" "$D24" "$RAWD/135-noresult.json" --fp "$TMP/stub-noresult.js" --out-dir "$D24"
printf '%s\n' "throw new Error('boom')" > "$TMP/stub-throw.js"
D25="$(newdir out-throw)"
refusal_case "a baseline whose engine throws" "the engine threw" "$D25" "$RAWD/135-noresult.json" --fp "$TMP/stub-throw.js" --out-dir "$D25"
printf '%s\n' "return { status: 'a', reason: 5 }" > "$TMP/stub-reason.js"
D26="$(newdir out-reason)"
refusal_case "a baseline whose result.reason is not a string" "result.reason is not a string" "$D26" "$RAWD/135-noresult.json" --fp "$TMP/stub-reason.js" --out-dir "$D26"
printf '%s\n' "try { await agent('p', { label: 'missing-label' }) } catch (e) {}" "return { status: 'a' }" > "$TMP/stub-missing.js"
D27="$(newdir out-missing)"
refusal_case "a baseline with an unanswered call" "unanswered call" "$D27" "$RAWD/135-noresult.json" --fp "$TMP/stub-missing.js" --out-dir "$D27"

# the capture format
SIMRAW="$RAWD/136-sim.json"; node -e 'const f=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));f.args.simulate={};require("fs").writeFileSync(process.argv[2],JSON.stringify(f))' "$RAW" "$SIMRAW"
D28="$(newdir out-sim)"
refusal_case "a capture that sets args.simulate" "args.simulate" "$D28" "$SIMRAW" --out-dir "$D28"
THRRAW="$RAWD/137-throws.json"; node -e 'const f=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));f.expect.throws="x";require("fs").writeFileSync(process.argv[2],JSON.stringify(f))' "$RAW" "$THRRAW"
D29="$(newdir out-throws)"
refusal_case "a capture that expects a throw" "expect.throws" "$D29" "$THRRAW" --out-dir "$D29"

# the existing-file refusal comes before any replay: a capture that would be refused later still reports the file
D30="$(newdir out-early)"
printf 'precious\n' > "$D30/126-badstatus.json"
pub "$BADRAW" --out-dir "$D30"
if [ "$RC" -eq 1 ] && printf '%s\n' "$ERR" | grep -q '^refused: .*exists' && [ "$(cat "$D30/126-badstatus.json")" = "precious" ]; then
  ok "refuses an existing output file before replaying anything"
else
  bad "early existing-file refusal: rc=$RC err=$ERR"
fi

# a probe answer whose hash is not the engine's is not coupled (re-hashing it would turn a failed probe into a good one)
node -e '
const fs = require("fs")
const f = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))
const e = f.calls["probe-123-provision-freshness-provision-freshness-r0"]
const old = /cmd=([0-9a-f]{64})/.exec(e.line)[1]
e.line = e.line.split(old).join("1".repeat(64)); e.verify = e.verify.split(old).join("1".repeat(64))
fs.writeFileSync(process.argv[2], JSON.stringify(f))' "$RAW" "$RAWD/138-badhash.json"
D31="$(newdir out-badhash)"
pub "$RAWD/138-badhash.json" --out-dir "$D31"
if [ "$RC" -eq 0 ] && [ "$(planted_in "$D31/138-badhash.json")" = "0" ] \
   && [ "$(node scripts/run-offline.cjs "$D31/138-badhash.json" 2>&1 | tail -n 1)" = "[offline] status=ok passed=1 failed=0" ]; then
  ok "a probe answer whose hash is not the engine's is not coupled and the rest is minimized"
else
  bad "uncoupled hash: rc=$RC planted=$(planted_in "$D31/138-badhash.json" 2>/dev/null) err=$ERR"
fi

# faults injected into the children: the gates after the redaction each refuse
D32="$(newdir out-fault1)"
pubf redact-check "$RAW" --out-dir "$D32"
if [ "$RC" -eq 1 ] && [ "$(last_line)" = "[publish-fixture] status=refused" ] && printf '%s\n' "$ERR" | grep -q 'refused: redact-fixture --check exited 1' && [ "$(ls -A "$D32" | wc -l | tr -d ' ')" = "0" ]; then
  ok "refuses when redact-fixture --check reports a change"
else
  bad "--check refusal: rc=$RC err=$ERR"
fi
D33="$(newdir out-fault2)"
pubf redact-crash "$RAW" --out-dir "$D33"
if [ "$RC" -eq 1 ] && [ "$(last_line)" = "[publish-fixture] status=refused" ] && printf '%s\n' "$ERR" | grep -q 'refused: redact-fixture exited 2' && [ "$(ls -A "$D33" | wc -l | tr -d ' ')" = "0" ]; then
  ok "refuses when redact-fixture fails with a code other than 3"
else
  bad "redactor failure refusal: rc=$RC err=$ERR"
fi
D34="$(newdir out-fault3)"
pubf strict-exit "$RAW" --out-dir "$D34"
if [ "$RC" -eq 1 ] && [ "$(last_line)" = "[publish-fixture] status=refused" ] && printf '%s\n' "$ERR" | grep -q 'refused: strict replay of the redacted candidate failed' && [ "$(ls -A "$D34" | wc -l | tr -d ' ')" = "0" ]; then
  ok "refuses when the strict replay exits non-zero"
else
  bad "strict exit refusal: rc=$RC err=$ERR"
fi
D35="$(newdir out-fault4)"
pubf strict-nopass "$RAW" --out-dir "$D35"
if [ "$RC" -eq 1 ] && printf '%s\n' "$ERR" | grep -q 'refused: strict replay of the redacted candidate failed' && [ "$(ls -A "$D35" | wc -l | tr -d ' ')" = "0" ]; then
  ok "refuses when the strict replay does not report the fixture as passed"
else
  bad "strict passed refusal: rc=$RC err=$ERR"
fi
# a real behavioural gap: an engine that behaves differently inside run-offline.cjs is caught by the strict replay alone
printf '%s\n' "return { status: /run-offline/.test(process.argv[1] || '') ? 'b' : 'a' }" > "$TMP/stub-argv.js"
D36="$(newdir out-argv)"
refusal_case "an engine whose behaviour differs in the strict replay" "strict replay of the redacted candidate failed" "$D36" "$RAWD/124-flaky.json" --fp "$TMP/stub-argv.js" --out-dir "$D36"
# engine call sites that cannot be resolved (a stack too short to reach the engine frame) are refused
D37="$(newdir out-stack)"
printf '%s\n' "log('x')" "return { status: 'a' }" > "$TMP/stub-log.js"
pubf stack-limit "$RAWD/124-flaky.json" --fp "$TMP/stub-log.js" --out-dir "$D37"
if [ "$RC" -eq 1 ] && printf '%s\n' "$ERR" | grep -q 'refused: baseline replay: an engine call site could not be resolved' && [ "$(ls -A "$D37" | wc -l | tr -d ' ')" = "0" ]; then
  ok "refuses when an engine call site cannot be resolved"
else
  bad "unresolved site refusal: rc=$RC err=$ERR"
fi
# the written file is flushed before it is linked
D38="$(newdir out-fsync)"
: > "$TMP/fsync-mark"
PF_MARK="$TMP/fsync-mark" PF_FAULT=track-fsync NODE_OPTIONS="--require $TMP/fault.cjs" bash scripts/publish-fixture.sh "$RAW" --out-dir "$D38" >/dev/null 2>&1
if [ -f "$D38/123-auto.json" ] && [ "$(grep -c fsync "$TMP/fsync-mark")" -ge 1 ]; then ok "the candidate is fsynced before it is linked"; else bad "no fsync before the link"; fi

# ---- usage errors (exit 2, before any filesystem access) ----------------------------------------------

pub
case "$(last_line)" in "[publish-fixture] status=usage-error") [ "$RC" -eq 2 ] && U1=yes || U1=no;; *) U1=no;; esac
UD="$(newdir out-usage)"
pub "$RAW" '../x' --out-dir "$UD"
case "$(last_line)" in "[publish-fixture] status=usage-error") [ "$RC" -eq 2 ] && U2=yes || U2=no;; *) U2=no;; esac
uleft=$(ls -A "$UD" | wc -l | tr -d ' ')
if [ "$U1" = yes ] && [ "$U2" = yes ] && [ "$uleft" = "0" ]; then ok "usage errors exit 2"; else bad "usage errors: no-arg=$U1 bad-name=$U2 left=$uleft"; fi

TREE1="$(git status --short --untracked-files=all 2>&1)"
if [ "$TREE0" = "$TREE1" ]; then ok "the suite leaves the working tree untouched"; else bad "the suite changed the working tree: before='$TREE0' after='$TREE1'"; fi

rm -rf "$TMP"
STATUS=ok; [ "$FAIL" -gt 0 ] && STATUS=fail
echo "[test-publish-fixture] status=$STATUS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
