#!/usr/bin/env bash
# temp dir, generators, helpers, and the publish and refusal cases (sourced by tests/scripts/test-publish-fixture.sh, never executed).
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
if (variant === 'oneword') {
  // single-word private values, each one also a literal of the engine file (agent names, branch names, a decision)
  f.args.brief = 'Sam'
  f.args.config = { customer: 'Nick', pw: 'security', codeword: 'hook', owner: 'Mia' }
  f.args.repo = 'release'
  f.args.branchName = 'develop'
}
// #195: a capture of a REAL run holds the literal engine version in the plugin version probe answer (the public smoke
// fixture quotes the token). liveversion: the run's engine is the repo's engine. skew: a captured plugin-version-skew
// incident (the stale root's answer stays literal; the cmd hash is recomputed for that root).
if (variant === 'liveversion' || variant === 'skew') {
  const src = fs.readFileSync(path.join(process.env.ROOT, 'workflows/deliver-pipeline.js'), 'utf8')
  const ENGINE = /const BUILD = \{[^}]*\bversion: '([^']+)'/.exec(src)[1]
  const e = f.calls['probe-123-lines-plugin-version-r0']
  const ver = variant === 'skew' ? '1.0.0-beta.3' : ENGINE
  for (const k of ['line', 'verify']) e[k] = e[k].split('@@ENGINE_VERSION@@').join(ver)
  if (variant === 'skew') {
    const root = '/cache/lgtmgate/1.0.0-beta.3'
    const blk = src.slice(src.indexOf('// --- pluginVersion:start ---'), src.indexOf('// --- pluginVersion:end ---'))
    const cmd = new Function(blk + '\nreturn pluginVersionCmd')()(root)
    const h = require('crypto').createHash('sha256').update(cmd).digest('hex')
    for (const k of ['line', 'verify']) e[k] = e[k].replace(/cmd=[0-9a-f]{64}/, 'cmd=' + h)
    f.args.pluginRoot = root
    f.calls = { 'probe-123-lines-plugin-version-r0': e }
    f.expect = { status: 'escalate' }
  }
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
# pubf <fault> [args...]: pub with a fault injected
pubf() { f="$1"; shift; OUT=$(PF_FAULT="$f" NODE_OPTIONS="--require $TMP/fault.cjs" bash scripts/publish-fixture.sh "$@" 2>"$TMP/stderr.txt"); RC=$?; ERR=$(cat "$TMP/stderr.txt"); }
# planted_in <file>...: counts the planted words found in the given files
planted_in() { cat "$@" 2>/dev/null | grep -c -e "$W_PLAN" -e "$W_EVID" -e "$W_SUMM" -e "$W_BRIEF" -e "$W_LABEL" || true; }
# jsf <file> <js expression over f>: evaluates against the JSON file, prints the result as JSON
jsf() {
  node -e 'const f=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(JSON.stringify(eval(process.argv[2])))' "$1" "$2"
}
newdir() { rm -rf "${TMP:?}/$1"; mkdir -p "$TMP/$1"; echo "$TMP/$1"; }

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

# F3b: the free-text report also counts what the old report let through: PROBE / VERIFY lines kept whole that carry a repository
# path, a folder name after /Users/<name> or a title, and protected fields that hold a path. Planted words are fictitious.
cat > "$TMP/genft.cjs" <<'JS'
const hex = (c) => c.repeat(64)
const probe = (name, json) => `PROBE name=${name} exit=0 sha=${hex('a')} cmd=${hex('b')} json=${JSON.stringify(json)}`
const entry = (name, json) => ({ line: probe(name, json), verify: `VERIFY ok line=${probe(name, json)}` })
const cap = {
  name: '1-s',
  args: { config: { oneWayDoorPaths: ['src/zqprotx9/**'] } },
  calls: {
    'probe-1-a': entry('stale', { planStale: '/zqrepox9/work' }),
    'probe-1-b': entry('where', { gitDir: '/Users/you/zqprojx9/.git/worktrees/w1' }),
    'probe-1-c': entry('pr', { title: 'zqtitlex9 fix the thing' }),
    'probe-1-d': entry('plain', { ok: true, behind: 0 }),
  },
  expect: { status: 'a' },
}
require('fs').writeFileSync(process.argv[2], JSON.stringify(cap))
JS
printf '%s\n' "const rs = []" "for (const k of ['a', 'b', 'c', 'd']) rs.push(await agent('p', { label: 'probe-1-' + k }))" \
  "return { status: rs.every((r) => /^PROBE name=/.test(r.line) && /^VERIFY ok line=PROBE /.test(r.verify)) ? 'a' : 'b' }" > "$TMP/stub-probes.js"
node "$TMP/genft.cjs" "$RAWD/140-ft.json"
D41="$(newdir out-ft)"
pub "$RAWD/140-ft.json" --fp "$TMP/stub-probes.js" --out-dir "$D41"
FTP="$D41/140-ft.json"
ftn=$(jsf "$FTP" '["probe-1-a","probe-1-b","probe-1-c"].reduce((n,k)=>n+f.calls[k].line.length+f.calls[k].verify.length,0)+f.args.config.oneWayDoorPaths[0].length' 2>/dev/null)
ftl=$(jsf "$FTP" 'f.calls["probe-1-a"].line.length' 2>/dev/null)
ftd=$(jsf "$FTP" 'f.calls["probe-1-d"].line.length' 2>/dev/null)
ftp=$(jsf "$FTP" 'f.args.config.oneWayDoorPaths[0].length' 2>/dev/null)
nout=$(printf '%s\n' "$OUT")
if [ "$RC" -eq 0 ] && [ -n "$ftn" ] \
   && printf '%s\n' "$nout" | grep -Fxq "free text: 7 field(s), $ftn characters (published as is, read them before publishing)" \
   && printf '%s\n' "$nout" | grep -Fxq "  calls.probe-1-a.line $ftl kept free-text" \
   && printf '%s\n' "$nout" | grep -Fxq "  calls.probe-1-d.line $ftd kept" \
   && printf '%s\n' "$nout" | grep -Fxq "  args.config.oneWayDoorPaths[0] $ftp protected free-text" \
   && [ "$(printf '%s\n%s\n' "$nout" "$ERR" | grep -c -e zqrepox9 -e zqprojx9 -e zqtitlex9 -e zqprotx9 || true)" = "0" ] \
   && grep -q zqprojx9 "$FTP" && grep -q zqrepox9 "$FTP" && grep -q zqtitlex9 "$FTP"; then
  ok "kept probe lines with a path or a title and protected paths are counted as free text, by path and length, never printed"
else
  bad "free text of probe lines and protected paths: rc=$RC want-chars=$ftn err=$ERR out=$OUT"
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

