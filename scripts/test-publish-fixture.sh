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
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
TMP="${TMPDIR:-/tmp}/publish-fixture-selftest.$$"
mkdir -p "$TMP"
TMP="$(cd "$TMP" && pwd -P)"
RAWD="$TMP/raw"
RAW="$RAWD/123-auto.json"
mkdir -p "$RAWD"

W_PLAN=zqplanx9; W_EVID=zqevidx9; W_SUMM=zqsummx9; W_BRIEF=zqbriefx9
export W_PLAN W_EVID W_SUMM W_BRIEF

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
if (variant === 'pem') f.args.issueType = process.env.PEM_HEADER
if (variant === 'badstatus') f.expect.status = 'escalate'
if (variant === 'note') f.note = 'free text'
fs.writeFileSync(out, JSON.stringify(f, null, 2) + '\n')
JS

# pub [args...]: run the publisher; sets OUT (stdout), ERR (stderr) and RC
pub() {
  OUT=$(bash scripts/publish-fixture.sh "$@" 2>"$TMP/stderr.txt"); RC=$?
  ERR=$(cat "$TMP/stderr.txt")
}
last_line() { printf '%s\n' "$OUT" | tail -n 1; }
# planted_in <file>...: counts the planted words found in the given files
planted_in() { cat "$@" 2>/dev/null | grep -c -e "$W_PLAN" -e "$W_EVID" -e "$W_SUMM" -e "$W_BRIEF" || true; }
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

  rawcmd=$(jsf "$RAW" 'f.calls["probe-123-provision-provision-r0"].line.match(/cmd=([0-9a-f]{64})/)[1]')
  pubcmd=$(jsf "$PUB" 'f.calls["probe-123-provision-provision-r0"].line.match(/cmd=([0-9a-f]{64})/)[1]')
  wt=$(jsf "$PUB" 'f.args.wtPath')
  if [ "$rawcmd" != "$pubcmd" ] && [ "$wt" = '"_"' ] && [ "$REPLAY_OK" = yes ]; then
    ok "coupled PROBE hashes are recomputed"
  else
    bad "coupled hashes: raw=$rawcmd pub=$pubcmd wtPath=$wt replay=$REPLAY_OK"
  fi

  printf '%s\n' "$OUT" > "$TMP/stdout.txt"
  leaks=$(cat "$TMP/stdout.txt" "$TMP/stderr.txt" | grep -c -e "$W_PLAN" -e "$W_EVID" -e "$W_SUMM" -e "$W_BRIEF" -e 'features/issue-123' || true)
  if grep -Eq '^remains: [0-9]+ strings, [0-9]+ characters \(was [0-9]+\)$' "$TMP/stdout.txt" \
     && grep -Eq '^  args\.mode [0-9]+ protected$' "$TMP/stdout.txt" && [ "$leaks" = "0" ]; then
    ok "printed remainder lists field names and counts, never values"
  else
    bad "printed remainder: leaks=$leaks stdout=$OUT"
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

# ---- usage errors (exit 2, before any filesystem access) ----------------------------------------------

pub
case "$(last_line)" in "[publish-fixture] status=usage-error") [ "$RC" -eq 2 ] && U1=yes || U1=no;; *) U1=no;; esac
UD="$(newdir out-usage)"
pub "$RAW" '../x' --out-dir "$UD"
case "$(last_line)" in "[publish-fixture] status=usage-error") [ "$RC" -eq 2 ] && U2=yes || U2=no;; *) U2=no;; esac
uleft=$(ls -A "$UD" | wc -l | tr -d ' ')
if [ "$U1" = yes ] && [ "$U2" = yes ] && [ "$uleft" = "0" ]; then ok "usage errors exit 2"; else bad "usage errors: no-arg=$U1 bad-name=$U2 left=$uleft"; fi

rm -rf "$TMP"
STATUS=ok; [ "$FAIL" -gt 0 ] && STATUS=fail
echo "[test-publish-fixture] status=$STATUS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
