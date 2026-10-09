#!/usr/bin/env bash
# the write (never a partial file) and the step-pinning cases (sourced by tests/scripts/test-publish-fixture.sh, never executed).
# ---- the write: never a partial file at the final name -----------------------------------------------

# a preload that signals the publisher (KILL_SIG, default SIGKILL) halfway through its first write into KILL_DIR
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
const sig = process.env.KILL_SIG || 'SIGKILL'
const write = fs.writeSync
fs.writeSync = function (fd, buf, off, len, ...rest) {
  if (fds.has(fd)) {
    write.call(this, fd, buf, off, Math.floor(len / 2))
    if (sig !== 'SIGKILL') fds.delete(fd) // a catchable signal is handled later; the write goes on
    process.kill(process.pid, sig)
  }
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

# SIGTERM halfway through the write: the temporary file is removed and the run ends as an error, nothing at the final name
DS="$(newdir out-sigterm)"; TS="$(newdir tmp-sigterm)"
SOUT=$(KILL_DIR="$DS" KILL_SIG=SIGTERM TMPDIR="$TS" NODE_OPTIONS="--require $TMP/killwrite.cjs" bash scripts/publish-fixture.sh "$RAW" --out-dir "$DS" 2>"$TMP/stderr.txt"); SRC=$?
SERR=$(cat "$TMP/stderr.txt")
if [ "$SRC" -eq 1 ] && [ "$(printf '%s\n' "$SOUT" | tail -n 1)" = "[publish-fixture] status=error" ] && [ -z "$(ls -A "$DS")" ] && [ -z "$(ls -A "$TS")" ] \
   && printf '%s\n' "$SERR" | grep -q '^error: interrupted by SIGTERM'; then
  ok "a SIGTERM during the write removes the temporary file and ends as an error"
else
  bad "SIGTERM during the write: rc=$SRC last='$(printf '%s\n' "$SOUT" | tail -n 1)' out-dir=$(ls -A "$DS" | tr '\n' ' ') tmp=$(ls -A "$TS" | tr '\n' ' ') err=$SERR"
fi

# SIGINT / SIGTERM after the redactor ran: the private candidate directory is removed and nothing is written
cat > "$TMP/sigphase.cjs" <<'JS'
const cp = require('child_process')
const spawnSync = cp.spawnSync
let sent = false
cp.spawnSync = function (cmd, args, ...rest) {
  const r = spawnSync.call(this, cmd, args, ...rest)
  if (!sent && process.env.PF_SIG && Array.isArray(args) && /redact-fixture\.cjs$/.test(String(args[0])) && !args.includes('--check')) {
    sent = true
    process.kill(process.pid, process.env.PF_SIG)
  }
  return r
}
JS
for sg in SIGINT SIGTERM; do
  DP="$(newdir out-$sg)"; TP="$(newdir tmp-$sg)"
  POUT=$(PF_SIG=$sg TMPDIR="$TP" NODE_OPTIONS="--require $TMP/sigphase.cjs" bash scripts/publish-fixture.sh "$RAW" --out-dir "$DP" 2>"$TMP/stderr.txt"); PRC=$?
  PERR=$(cat "$TMP/stderr.txt")
  if [ "$PRC" -eq 1 ] && [ "$(printf '%s\n' "$POUT" | tail -n 1)" = "[publish-fixture] status=error" ] && [ -z "$(ls -A "$DP")" ] && [ -z "$(ls -A "$TP")" ] \
     && printf '%s\n' "$PERR" | grep -q "^error: interrupted by $sg"; then
    ok "a $sg during the redaction removes the private copy and writes nothing"
  else
    bad "$sg during the redaction: rc=$PRC last='$(printf '%s\n' "$POUT" | tail -n 1)' out-dir=$(ls -A "$DP" | tr '\n' ' ') tmp=$(ls -A "$TP" | tr '\n' ' ') err=$PERR"
  fi
done

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

# a single-word value is not public because the engine file happens to contain the same word as a literal: it is neutralized like
# any other string (the engine file holds `zqvocabtoken` here, and the result carries it)
printf '%s\n' "const T = 'zqvocabtoken'" "return { status: 'a', tag: String(args.p).split(',')[0], free: args.q }" > "$TMP/stub-vocab.js"
mkcap "$RAWD/132-vocab.json" '{"p":"zqvocabtoken,zqfreetextx9","q":"zqfreetextx9","w":"zqvocabtoken"}'
D21="$(newdir out-vocab)"
pub "$RAWD/132-vocab.json" --fp "$TMP/stub-vocab.js" --out-dir "$D21"
if [ "$RC" -eq 0 ] && [ "$(jsf "$D21/132-vocab.json" 'f.args.p+"|"+f.args.q+"|"+f.args.w')" = '"_|_|_"' ] && ! grep -q 'zqvocabtoken' "$D21/132-vocab.json"; then
  ok "a single-word value equal to a literal of the engine file is neutralized like any other string"
else
  bad "vocabulary: rc=$RC args=$(jsf "$D21/132-vocab.json" 'JSON.stringify(f.args)' 2>/dev/null) err=$ERR"
fi
# the real engine: single-word private values that are literals of the engine file (agent names, branch names, a decision) go too
ONERAW="$RAWD/139-oneword.json"
node "$TMP/gen.cjs" "$ONERAW" oneword
D40="$(newdir out-oneword)"
pub "$ONERAW" 139-oneword --out-dir "$D40"
owv=$(jsf "$D40/139-oneword.json" '[f.args.brief, f.args.config, f.args.repo, f.args.branchName, f.calls["scout-issue-123-1"].decision]' 2>/dev/null)
if [ "$RC" -eq 0 ] && [ "$owv" = '["_",{"customer":"_","pw":"_","codeword":"_","owner":"_"},"_","_","_"]' ] \
   && [ "$(node scripts/run-offline.cjs "$D40/139-oneword.json" 2>&1 | tail -n 1)" = "[offline] status=ok passed=1 failed=0" ]; then
  ok "single-word private values and the scout decision are neutralized and the fixture still replays"
else
  bad "single-word values: rc=$RC values=$owv err=$ERR"
fi
# an emptiness change is a shape change: an empty string stays empty, a non-empty one stays non-empty
printf '%s\n' "return { status: 'a', e: args.e, n: args.n }" > "$TMP/stub-empty.js"
mkcap "$RAWD/133-empty.json" '{"e":"","n":"zqfreetextx9"}'
D22="$(newdir out-empty)"
pub "$RAWD/133-empty.json" --fp "$TMP/stub-empty.js" --out-dir "$D22"
if [ "$RC" -eq 0 ] && [ "$(jsf "$D22/133-empty.json" 'f.args.e+"|"+f.args.n')" = '"|_"' ]; then ok "an empty string stays empty and a non-empty one stays non-empty"; else bad "emptiness: rc=$RC err=$ERR"; fi

# the oracle pins the FORM of the result: a number, a boolean, the length of an array and the emptiness of a string
printf '%s\n' "return { status: 'a', n: String(args.p1).length, b: String(args.p2).length > 3, arr: String(args.p3).split(','), e: String(args.p4) === '_' ? '' : 'yy' }" > "$TMP/stub-shape.js"
mkcap "$RAWD/141-shape.json" '{"p1":"zqlongwordx9","p2":"zqlongwordx9","p3":"aaaa,bbbb","p4":"zqfreetextx9"}'
D42="$(newdir out-shape)"
pub "$RAWD/141-shape.json" --fp "$TMP/stub-shape.js" --out-dir "$D42"
shp="$D42/141-shape.json"
[ "$RC" -eq 0 ] || bad "shape stub publication: rc=$RC err=$ERR"
if [ "$(jsf "$shp" 'f.args.p1' 2>/dev/null)" = '"zqlongwordx9"' ]; then ok "a number of the result is pinned exactly by the oracle"; else bad "number of the result not pinned: p1=$(jsf "$shp" 'f.args.p1' 2>/dev/null)"; fi
if [ "$(jsf "$shp" 'f.args.p2' 2>/dev/null)" = '"zqlongwordx9"' ]; then ok "a boolean of the result is pinned exactly by the oracle"; else bad "boolean of the result not pinned: p2=$(jsf "$shp" 'f.args.p2' 2>/dev/null)"; fi
if [ "$(jsf "$shp" 'f.args.p3' 2>/dev/null)" = '"aaaa,bbbb"' ]; then ok "the length of an array of the result is pinned by the oracle"; else bad "array length of the result not pinned: p3=$(jsf "$shp" 'f.args.p3' 2>/dev/null)"; fi
if [ "$(jsf "$shp" 'f.args.p4' 2>/dev/null)" = '"zqfreetextx9"' ]; then ok "a non-empty string of the result stays non-empty"; else bad "emptiness of the result not pinned: p4=$(jsf "$shp" 'f.args.p4' 2>/dev/null)"; fi

# typed neutral tokens: zeros of the same length for a hash of 32 characters or more, `1` for an integer, `_` otherwise
printf '%s\n' "return { status: 'a' }" > "$TMP/stub-any.js"
H31=0123456789abcdef0123456789abcde; H32=0123456789abcdef0123456789abcdef; H64="$H32$H32"
mkcap "$RAWD/142-tokens.json" "{\"h31\":\"$H31\",\"h32\":\"$H32\",\"h64\":\"$H64\",\"num\":\"12345\",\"neg\":\"-7\",\"word\":\"zqwordx9\"}"
D43="$(newdir out-tokens)"
pub "$RAWD/142-tokens.json" --fp "$TMP/stub-any.js" --out-dir "$D43"
tk=$(jsf "$D43/142-tokens.json" '[f.args.h31, f.args.h32, f.args.h64, f.args.num, f.args.neg, f.args.word].join("|")' 2>/dev/null)
z32=00000000000000000000000000000000
if [ "$RC" -eq 0 ] && [ "$tk" = "\"_|$z32|$z32$z32|1|1|_\"" ]; then ok "neutral tokens: zeros for a hash of 32 characters or more, 1 for an integer, _ otherwise"; else bad "neutral tokens: rc=$RC got=$tk"; fi

# the passes repeat to a fixpoint, three at most: x1 can only go after x2, x2 after x3, x3 after x4 (the chain needs four passes for x1)
printf '%s\n' "const a = args" "return { status: (a.x1 === 'zq1' || a.x2 === '_') && (a.x2 === 'zq2' || a.x3 === '_') && (a.x3 === 'zq3' || a.x4 === '_') ? 'a' : 'b' }" > "$TMP/stub-chain.js"
mkcap "$RAWD/143-chain.json" '{"x1":"zq1","x2":"zq2","x3":"zq3","x4":"zq4"}'
D44="$(newdir out-chain)"
pub "$RAWD/143-chain.json" --fp "$TMP/stub-chain.js" --out-dir "$D44"
if [ "$RC" -eq 0 ] && [ "$(jsf "$D44/143-chain.json" '[f.args.x1, f.args.x2, f.args.x3, f.args.x4].join("|")' 2>/dev/null)" = '"zq1|_|_|_"' ]; then
  ok "minimization repeats to a fixpoint in three passes, no fewer and no more"
else
  bad "pass count: rc=$RC args=$(jsf "$D44/143-chain.json" 'JSON.stringify(f.args)' 2>/dev/null) err=$ERR"
fi

# the published file is readable (0644) whatever the umask: the temporary file is created 0600
DM="$(newdir out-mode)"
( umask 077; bash scripts/publish-fixture.sh "$RAW" --out-dir "$DM" >/dev/null 2>&1 )
pmode=$(node -e 'process.stdout.write((require("fs").statSync(process.argv[1]).mode & 0o777).toString(8))' "$DM/123-auto.json" 2>/dev/null)
if [ "$pmode" = "644" ]; then ok "the published file is world-readable (mode 644) under a restrictive umask"; else bad "published file mode: $pmode"; fi

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

# SIGTERM while the minimization runs: it stops before the next replay (a long run can be interrupted), nothing is written
printf '%s\n' "const fs = process.mainModule.require('fs')" "const first = !fs.existsSync(process.env.COUNT_FILE)" \
  "fs.appendFileSync(process.env.COUNT_FILE, 'x')" "if (first) process.kill(process.pid, 'SIGTERM')" "return { status: 'a' }" > "$TMP/stub-sigmin.js"
mkcap "$RAWD/144-sigmin.json" "$(node -e 'const a={};for(let i=0;i<20;i++)a["k"+i]="zqword"+i;process.stdout.write(JSON.stringify(a))')"
DN="$(newdir out-sigmin)"; TN="$(newdir tmp-sigmin)"
COUNT_FILE="$TN/count"; export COUNT_FILE
NOUT=$(TMPDIR="$TN" bash scripts/publish-fixture.sh "$RAWD/144-sigmin.json" --fp "$TMP/stub-sigmin.js" --out-dir "$DN" 2>"$TMP/stderr.txt"); NRC=$?
ncount=$(wc -c < "$COUNT_FILE" 2>/dev/null | tr -d ' ')
if [ "$NRC" -eq 1 ] && [ "$(printf '%s\n' "$NOUT" | tail -n 1)" = "[publish-fixture] status=error" ] && [ -z "$(ls -A "$DN")" ] && [ "${ncount:-99}" -le 2 ]; then
  ok "a SIGTERM during the minimization stops it before the next replay and writes nothing"
else
  bad "SIGTERM during the minimization: rc=$NRC replays=$ncount last='$(printf '%s\n' "$NOUT" | tail -n 1)' out-dir=$(ls -A "$DN" | tr '\n' ' ')"
fi

