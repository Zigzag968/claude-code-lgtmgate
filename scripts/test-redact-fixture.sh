#!/usr/bin/env bash
# Self-test of scripts/redact-fixture.cjs (#188): every listed class is rewritten, the anchored
# secret-key rule leaves look-alike keys alone, a PEM private-key header refuses (exit 3, nothing
# written, the value never printed) and the placeholders stay outside the no-private-refs patterns.
# Planted values are assembled below from fragments: no token-shaped or private-path literal in this source.
# bash 3.2 compatible. Trailer: [test-redact-fixture] status=<ok|fail> passed=<n> failed=<n>
set -u
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
TMP="${TMPDIR:-/tmp}/redact-fixture-selftest.$$"; mkdir -p "$TMP"
RF=scripts/redact-fixture.cjs

# absent <label> <file> <marker>...   ok when none of the markers is left in the file
absent() {
  local label=$1 f=$2 m; shift 2
  for m in "$@"; do
    if grep -qF -- "$m" "$f"; then bad "$label: $m survives"; return; fi
  done
  ok "$label"
}
# present <label> <file> <text>...    ok when every text is in the file
present() {
  local label=$1 f=$2 t; shift 2
  for t in "$@"; do
    if ! grep -qF -- "$t" "$f"; then bad "$label: $t is missing"; return; fi
  done
  ok "$label"
}
# refused <label> <expected stderr line> <file>...   exit 3, that exact line on stderr, no PEM text in any output, every file untouched
refused() {
  local label=$1 want=$2 f; shift 2
  for f in "$@"; do cp "$f" "$f.orig"; done
  node "$RF" "$@" >"$TMP/o.out" 2>"$TMP/o.err"; local rc=$?
  local why=""
  [ "$rc" = 3 ] || why="$why exit $rc;"
  grep -qxF -- "$want" "$TMP/o.err" || why="$why stderr lacks the line [$want];"
  if grep -qE 'BEGIN|planted-pem-body-marker' "$TMP/o.out" "$TMP/o.err"; then why="$why the value is echoed;"; fi
  for f in "$@"; do cmp -s "$f" "$f.orig" || why="$why $f changed;"; done
  if [ -z "$why" ]; then ok "$label"; else bad "$label:$why"; fi
}

# ---- planted values, assembled from fragments (SL = path separator) ---------------------------
SL=/
P_TMP1="${SL}pri""vate${SL}tmp${SL}claude-1${SL}mk-tmp-a${SL}out.txt"
P_TMP2="see ${SL}var${SL}fol""ders${SL}zz${SL}mk-var-b${SL}T${SL}x.txt, then done"
P_TMP3="${SL}pri""vate${SL}var${SL}fol""ders${SL}zz${SL}mk-var-c${SL}T"
P_TMP4="file://${SL}pri""vate${SL}tmp${SL}mk-tmp-d${SL}f.txt"
P_OPT1="${SL}op""t${SL}mk-opt-d${SL}bin${SL}run"
P_OPT2="${SL}op""t${SL}mk-opt-e,${SL}op""t${SL}mk-opt-f${SL}x"
D_HOME="-Us""ers-mk-home-g-Dev-proj"
D_VOL="${SL}Us""ers${SL}zz${SL}.claude${SL}projects${SL}-Vol""umes-mk-vol-h-Dev-x${SL}memory"
D_LNX="-ho""me-mk-linux-i-x"
S_USR="${SL}Us""ers${SL}mk-usr-j${SL}Dev"
S_LNX="${SL}ho""me${SL}mk-lnx-k${SL}y"
S_VOL="${SL}Vol""umes${SL}mk-vol-l${SL}Dev"
S_VOL2="${SL}Vol""umes${SL}mk-vol-m${SL}op""t${SL}mk-opt-n${SL}x"
S_KEYPATH="${SL}Us""ers${SL}mk-key-path${SL}x"
PEM_OPEN="-----BEGIN ""PRIVATE KEY-----"
PEM_BODY="planted-pem-body-marker"
PEM_CLOSE="-----END ""PRIVATE KEY-----"

cat > "$TMP/plant.json" <<EOF
{
  "temp": ["$P_TMP1", "$P_TMP2", "$P_TMP3", "$P_TMP4"],
  "opt": ["$P_OPT1", "$P_OPT2"],
  "dash": ["$D_HOME", "$D_VOL", "$D_LNX"],
  "slash": ["$S_USR", "$S_LNX", "$S_VOL", "$S_VOL2"],
  "keys": { "apiKey": "mk-k1", "api_key": "mk-k2", "secret": "mk-k3", "password": "mk-k4", "passwd": "mk-k5", "token": "mk-k6", "access_token": "mk-k7", "refresh_token": "mk-k8", "client_secret": "mk-k9", "private_key": "mk-k10", "authorization": "mk-k11" },
  "nested": { "list": [ { "Token": "mk-k12", "keepme": "keep-3" } ] },
  "authSecurityBoundarySignal": "keep-1",
  "tokenizer": "keep-2",
  "empty": { "token": "", "password": null, "secret": 7, "apiKey": false },
  "controls": ["smart-home-hub", "my-Users-guide", "--home-dir", "feat/fix-home-page"],
  "$S_KEYPATH": "value-under-a-path-key"
}
EOF
cp "$TMP/plant.json" "$TMP/plant.raw"
printf 'note: %s end\n' "$P_TMP1" > "$TMP/plain.txt"

# ---- rewrites ------------------------------------------------------------------------------------
node "$RF" "$TMP/plant.json" >"$TMP/o.out" 2>"$TMP/o.err"; rc=$?
if [ "$rc" = 0 ] && grep -qxF "redacted: $TMP/plant.json" "$TMP/o.out"; then ok "plant.json is rewritten (exit 0, redacted: line)"; else bad "plant.json: exit $rc, $(cat "$TMP/o.err")"; fi
absent  "temp-dir paths are rewritten" "$TMP/plant.json" mk-tmp-a mk-var-b mk-var-c mk-tmp-d
absent  "/opt paths are rewritten" "$TMP/plant.json" mk-opt-d mk-opt-e mk-opt-f
absent  "dash-encoded home, volume and linux-home paths are rewritten" "$TMP/plant.json" mk-home-g mk-vol-h mk-linux-i
absent  "slash home, volume and linux-home paths are rewritten" "$TMP/plant.json" mk-usr-j mk-lnx-k mk-vol-l mk-vol-m mk-opt-n
absent  "values of the 11 listed secret-named keys are rewritten" "$TMP/plant.json" mk-k1 mk-k2 mk-k3 mk-k4 mk-k5 mk-k6 mk-k7 mk-k8 mk-k9 mk-k10 mk-k11 mk-k12
absent  "a JSON key holding a private path is rewritten" "$TMP/plant.json" mk-key-path
present "anchored: authSecurityBoundarySignal and look-alike keys keep their values" "$TMP/plant.json" '"authSecurityBoundarySignal": "keep-1"' '"tokenizer": "keep-2"' '"keepme": "keep-3"'
out=$(node -e 'const f=require(process.argv[1]);process.stdout.write(JSON.stringify(f.empty)+"|"+f.keys.password)' "$TMP/plant.json")
if [ "$out" = '{"token":"","password":null,"secret":7,"apiKey":false}|REDACTED' ]; then ok "non-string and empty values of secret-named keys are unchanged"; else bad "empty/non-string values: $out"; fi
present "look-alike text is unchanged" "$TMP/plant.json" smart-home-hub my-Users-guide --home-dir feat/fix-home-page
present "placeholders are the documented ones" "$TMP/plant.json" "${SL}tmp${SL}redacted" "${SL}op""t${SL}app" "-Us""ers-you" "-ho""me-user" "-Vol""umes-disk" "${SL}Vol""umes${SL}<disk>" '"REDACTED"'
# the machine-path rows of NO_PRIVATE_REFS_PATTERNS (templates/test-canonical-guards.sh), once its two allow-listed placeholders are removed
left=$(sed -e "s#${SL}Us""ers${SL}you##g" -e "s#${SL}ho""me${SL}user##g" "$TMP/plant.json" | grep -Eic "${SL}Vol""umes${SL}[A-Za-z0-9_-]|${SL}Us""ers${SL}[A-Za-z0-9._-]|${SL}ho""me${SL}[A-Za-z0-9._-]")
if [ "$left" = 0 ]; then ok "placeholders stay outside the no-private-refs patterns"; else bad "placeholders: $left line(s) still match a machine-path pattern"; fi

cp "$TMP/plant.json" "$TMP/plant.once"
node "$RF" "$TMP/plant.json" >"$TMP/o.out" 2>"$TMP/o.err"; rc=$?
if [ "$rc" = 0 ] && [ ! -s "$TMP/o.out" ] && cmp -s "$TMP/plant.json" "$TMP/plant.once"; then ok "a second run changes nothing"; else bad "second run: exit $rc, output [$(cat "$TMP/o.out")]"; fi
node "$RF" --check "$TMP/plant.raw" >"$TMP/o.out" 2>&1; rc=$?
if [ "$rc" = 1 ] && grep -qxF "would redact: $TMP/plant.raw" "$TMP/o.out"; then ok "--check: raw input would change (exit 1) and is left untouched"; else bad "--check raw: exit $rc, $(cat "$TMP/o.out")"; fi
node "$RF" --check "$TMP/plant.json" >"$TMP/o.out" 2>&1; rc=$?
if [ "$rc" = 0 ] && [ ! -s "$TMP/o.out" ]; then ok "--check: redacted output is clean (exit 0)"; else bad "--check redacted: exit $rc, $(cat "$TMP/o.out")"; fi
node "$RF" "$TMP/plain.txt" >/dev/null 2>&1
absent  "plain text: the temp-dir path is rewritten" "$TMP/plain.txt" mk-tmp-a

# ---- refusals -------------------------------------------------------------------------------------
printf '{"calls":{"a":"line one\\n%s\\n%s\\n%s"}}\n' "$PEM_OPEN" "$PEM_BODY" "$PEM_CLOSE" > "$TMP/pem.json"
printf 'before\n%s\n%s\n%s\n' "$PEM_OPEN" "$PEM_BODY" "$PEM_CLOSE" > "$TMP/pem.txt"
printf '{"%s": 1}\n' "$PEM_OPEN" > "$TMP/pemkey.json"
refused "refuse: PEM header in a JSON value (exit 3, rule and JSON path named, value not echoed, file untouched)" "refused: $TMP/pem.json: pem-private-key at "'$.calls.a' "$TMP/pem.json"
refused "refuse: PEM header in a text file (line named)" "refused: $TMP/pem.txt: pem-private-key at line 2" "$TMP/pem.txt"
refused "refuse: PEM header as a JSON key (located at <key>, never printed)" "refused: $TMP/pemkey.json: pem-private-key at "'$.<key>' "$TMP/pemkey.json"
v_bad=""
for kind in "" "RSA " "EC " "OPENSSH " "ENCRYPTED "; do
  printf '%s\n' "-----BEGIN ${kind}""PRIVATE KEY-----" > "$TMP/pemv.txt"
  node "$RF" "$TMP/pemv.txt" >/dev/null 2>&1; [ $? = 3 ] || v_bad="$v_bad [${kind:-plain}]"
done
for pub in "PUBLIC KEY" "CERTIFICATE"; do
  printf '%s\n' "-----BEGIN ${pub}-----" > "$TMP/pemv.txt"
  node "$RF" "$TMP/pemv.txt" >/dev/null 2>&1; [ $? = 0 ] || v_bad="$v_bad [$pub refused]"
done
if [ -z "$v_bad" ]; then ok "refuse: plain, RSA, EC, OPENSSH and ENCRYPTED private-key headers; public key and certificate pass"; else bad "PEM variants:$v_bad"; fi
# a doubled prefix: the rewrite leaves a path that matches its own rule again, so the re-run of the table hits
printf '{"v": "%s"}\n' "${SL}pri""vate${SL}pri""vate${SL}tmp${SL}x" > "$TMP/refire.json"
refused "refuse: a rewrite that re-forms a match refuses (fail closed, nothing written)" "refused: $TMP/refire.json: temp-private-tmp at "'$.v' "$TMP/refire.json"
node "$RF" --check "$TMP/pem.json" >"$TMP/o.out" 2>"$TMP/o.err"; rc=$?
if [ "$rc" = 3 ] && grep -qxF "refused: $TMP/pem.json: pem-private-key at "'$.calls.a' "$TMP/o.err"; then ok "refuse: --check refuses too (exit 3)"; else bad "--check refusal: exit $rc, $(cat "$TMP/o.err")"; fi
cp "$TMP/plant.raw" "$TMP/mix-a.json"
cp "$TMP/pem.json" "$TMP/mix-b.json"
refused "all-or-nothing: a rewritable file and a PEM file given together are both left untouched" "refused: $TMP/mix-b.json: pem-private-key at "'$.calls.a' "$TMP/mix-a.json" "$TMP/mix-b.json"
cp "$TMP/plant.raw" "$TMP/mix-c.json"
node "$RF" "$TMP/mix-c.json" >/dev/null 2>&1
if ! cmp -s "$TMP/mix-c.json" "$TMP/plant.raw"; then ok "all-or-nothing control: the rewritable file alone is rewritten"; else bad "control: the rewritable file was not rewritten"; fi

rm -rf "$TMP"
STATUS=ok; [ "$FAIL" -gt 0 ] && STATUS=fail
echo "[test-redact-fixture] status=$STATUS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
