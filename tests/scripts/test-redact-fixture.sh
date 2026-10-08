#!/usr/bin/env bash
# Self-test of scripts/redact-fixture.cjs (#188): every listed class is rewritten, the anchored
# secret-key rule leaves look-alike keys alone, a PEM private-key header refuses (exit 3, nothing
# written, the value never printed) and the placeholders stay outside the no-private-refs patterns.
# Planted values are assembled below from fragments: no token-shaped or private-path literal in this source.
# bash 3.2 compatible. Trailer: [test-redact-fixture] status=<ok|fail> passed=<n> failed=<n>
set -u
cd "$(dirname "$0")/../.." || exit 1
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
# nth_line <label> <file> <n> <text>   ok when line n of the file is exactly <text>
nth_line() {
  local got; got=$(sed -n "${3}p" "$2")
  if [ "$got" = "$4" ]; then ok "$1"; else bad "$1: line $3 is [$got]"; fi
}
# line_count <label> <file> <n>   ok when the file has n lines
line_count() {
  local got; got=$(wc -l < "$2" | tr -d ' ')
  if [ "$got" = "$3" ]; then ok "$1"; else bad "$1: $got lines"; fi
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
# the machine-path rows of NO_PRIVATE_REFS_PATTERNS (tests/templates/test-canonical-guards.sh), once its two allow-listed placeholders are removed
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

# ---- secret-named pairs outside parsed JSON keys (a string holding JSON, a text capture) -------------
# n1.json: the pair sits inside a string value (PROBE line, agent answer); n2.jsonl / n3.raw: text captures;
# n4.json: truncated, falls back to text mode (one escaped pair, one plain pair).
cat > "$TMP/n1.json" <<'EOF'
{"calls":{"p":{"line":"PROBE name=x exit=0 json={\"token\":\"MKS12\"}"},"a":"{\"apiKey\":\"MKS1\"}","c":"{\"Password\": \"MKS15\", \"n\": 2}"},"top":{"password":"MKS9"}}
EOF
printf '%s\n%s\n' '{"password":"MKS10"}' '{"event":"x","detail":"{\"client_secret\":\"MKS16\"}"}' > "$TMP/n2.jsonl"
printf 'out: %s\nnext line\n' '{"token":"MKS11"}' > "$TMP/n3.raw"
printf '%s' '{"calls":{"a":"{\"refresh_token\":\"MKS13\"}","b":{"authorization":"MKS14"' > "$TMP/n4.json"
N_ALL="$TMP/n1.json $TMP/n2.jsonl $TMP/n3.raw $TMP/n4.json"
for f in n1.json n2.jsonl n3.raw n4.json; do
  node "$RF" --check "$TMP/$f" >"$TMP/o.out" 2>&1; rc=$?
  if [ "$rc" = 1 ] && grep -qxF "would redact: $TMP/$f" "$TMP/o.out"; then ok "--check: $f holds a secret-named pair outside a parsed key (exit 1)"; else bad "--check $f: exit $rc, $(cat "$TMP/o.out")"; fi
done
cp "$TMP/n1.json" "$TMP/n1.orig"
node "$RF" $N_ALL >"$TMP/o.out" 2>"$TMP/o.err"; rc=$?
if [ "$rc" = 0 ]; then ok "the four inputs are rewritten (exit 0)"; else bad "n-inputs: exit $rc, $(cat "$TMP/o.err")"; fi
absent  "string holding JSON: the pairs in a PROBE line and an answer are rewritten, the parsed key too" "$TMP/n1.json" MKS12 MKS1 MKS15 MKS9
present "string holding JSON: the rest of the PROBE line is kept" "$TMP/n1.json" 'PROBE name=x exit=0 json={\"token\":\"REDACTED\"}' '\"n\": 2'
absent  ".jsonl: plain and escaped pairs are rewritten" "$TMP/n2.jsonl" MKS10 MKS16
present ".jsonl: the clean part of the journal is kept" "$TMP/n2.jsonl" '"event":"x"'
absent  ".raw: the pair in a command output is rewritten" "$TMP/n3.raw" MKS11
present ".raw: the text around the pair is kept" "$TMP/n3.raw" 'out: {"token":"REDACTED"}' 'next line'
absent  "truncated .json (text fallback): escaped and plain pairs are rewritten" "$TMP/n4.json" MKS13 MKS14
for f in n1.json n2.jsonl n3.raw n4.json; do
  cp "$TMP/$f" "$TMP/$f.once"
  node "$RF" "$TMP/$f" >"$TMP/o.out" 2>"$TMP/o.err"; rc=$?
  if [ "$rc" = 0 ] && [ ! -s "$TMP/o.out" ] && cmp -s "$TMP/$f" "$TMP/$f.once"; then ok "idempotent: a second run on $f changes nothing"; else bad "second run $f: exit $rc, output [$(cat "$TMP/o.out")]"; fi
  node "$RF" --check "$TMP/$f" >"$TMP/o.out" 2>&1; rc=$?
  if [ "$rc" = 0 ] && [ ! -s "$TMP/o.out" ]; then ok "--check: $f is clean after redaction (exit 0)"; else bad "--check clean $f: exit $rc, $(cat "$TMP/o.out")"; fi
done

# ---- an escaped pair whose value holds a quote (embedded-quote tail, review round 3) ---------------------
# In a string that holds JSON, a quote inside the value is serialised `\\\"` (3 backslashes) and a backslash
# `\\\\`; the closing delimiter is a lone `\"`. Values are assembled from fragments; nesting deeper than
# one string-in-JSON level is out of scope.
BS='\'
Q1="$BS\""
Q3="$BS$BS$BS\""
B4="$BS$BS$BS$BS"
V_REPRO="ab${Q3}ZQsec""ret1"
V_TWO="Aq${Q3}Bq${B4}Cq${Q3}Dq""ZQsec""ret2"
PAIR_REPRO="{${Q1}password${Q1}:${Q1}${V_REPRO}${Q1}}"
PAIR_TWO="{${Q1}token${Q1}:${Q1}${V_TWO}${Q1},${Q1}n${Q1}:2}"
printf '%s\n%s\n' "{\"out\":\"${PAIR_REPRO}\"}" '{"event":"clean"}' > "$TMP/e1.jsonl"
printf 'out: %s\nnext line\n' "${PAIR_REPRO}" > "$TMP/e2.raw"
printf '%s' "{\"calls\":{\"a\":\"${PAIR_REPRO}\",\"b\":{\"x\":\"${PAIR_TWO}\"" > "$TMP/e3.json"
printf '%s\n' "{\"out\":\"${PAIR_TWO}\"}" > "$TMP/e4.jsonl"
printf '%s\n' "{\"out\":\"${PAIR_REPRO}\",\"two\":\"${PAIR_TWO}\"}" > "$TMP/e5.json"
for f in e1.jsonl e2.raw e3.json e4.jsonl e5.json; do
  node "$RF" --check "$TMP/$f" >"$TMP/o.out" 2>&1; rc=$?
  if [ "$rc" = 1 ]; then ok "embedded quote: --check $f is not clean before redaction (exit 1)"; else bad "embedded quote --check before $f: exit $rc"; fi
done
node "$RF" $TMP/e1.jsonl $TMP/e2.raw $TMP/e3.json $TMP/e4.jsonl $TMP/e5.json >"$TMP/o.out" 2>"$TMP/o.err"; rc=$?
if [ "$rc" = 0 ]; then ok "embedded quote: the five inputs are rewritten (exit 0)"; else bad "embedded quote rewrite: exit $rc, $(cat "$TMP/o.err")"; fi
absent  "embedded quote .jsonl: nothing of the value remains" "$TMP/e1.jsonl" ab ZQsec""ret1
present "embedded quote .jsonl: the pair and the rest of the journal are kept" "$TMP/e1.jsonl" "{\"out\":\"{${Q1}password${Q1}:${Q1}REDACTED${Q1}}\"}" '{"event":"clean"}'
absent  "embedded quote .raw: nothing of the value remains" "$TMP/e2.raw" ab ZQsec""ret1
present "embedded quote .raw: the text around the pair is kept" "$TMP/e2.raw" "out: {${Q1}password${Q1}:${Q1}REDACTED${Q1}}" 'next line'
absent  "embedded quote truncated .json (text fallback): both values are gone" "$TMP/e3.json" ab ZQsec""ret1 Aq Bq Cq Dq ZQsec""ret2
present "embedded quote truncated .json (text fallback): the surrounding text is kept" "$TMP/e3.json" "${Q1}password${Q1}:${Q1}REDACTED${Q1}}" "${Q1}token${Q1}:${Q1}REDACTED${Q1},${Q1}n${Q1}:2}"
absent  "embedded quote, two quotes and a backslash (.jsonl): nothing of the value remains" "$TMP/e4.jsonl" Aq Bq Cq Dq ZQsec""ret2
present "embedded quote, two quotes and a backslash (.jsonl): the pair after the value is kept" "$TMP/e4.jsonl" "{\"out\":\"{${Q1}token${Q1}:${Q1}REDACTED${Q1},${Q1}n${Q1}:2}\"}"
absent  "embedded quote, parsed .json value: nothing of either value remains" "$TMP/e5.json" ab Aq Bq Cq Dq ZQsec""ret1 ZQsec""ret2
out=$(node -e '
const f = JSON.parse(require("fs").readFileSync(process.argv[1], "utf-8"))
const a = JSON.parse(f.out), b = JSON.parse(f.two)
process.stdout.write([a.password, b.token, b.n].join("|"))' "$TMP/e5.json" 2>&1)
if [ "$out" = "REDACTED|REDACTED|2" ]; then ok "embedded quote, parsed .json value: the output parses and the inner JSON is intact"; else bad "embedded quote parsed .json: $out"; fi
for f in e1.jsonl e2.raw e3.json e4.jsonl e5.json; do
  cp "$TMP/$f" "$TMP/$f.once"
  node "$RF" "$TMP/$f" >"$TMP/o.out" 2>"$TMP/o.err"; rc=$?
  if [ "$rc" = 0 ] && [ ! -s "$TMP/o.out" ] && cmp -s "$TMP/$f" "$TMP/$f.once"; then ok "embedded quote: a second run on $f changes nothing"; else bad "embedded quote second run $f: exit $rc, output [$(cat "$TMP/o.out")]"; fi
  node "$RF" --check "$TMP/$f" >"$TMP/o.out" 2>&1; rc=$?
  if [ "$rc" = 0 ] && [ ! -s "$TMP/o.out" ]; then ok "embedded quote: --check $f is clean after redaction (exit 0)"; else bad "embedded quote --check after $f: exit $rc, $(cat "$TMP/o.out")"; fi
done

# ---- an escaped pair whose value ends in backslashes (review round 4) ---------------------------------------
# A value ending in m backslashes is serialised as 4m of them, then the lone `\"` closing delimiter: a run of
# 4m+1 backslashes before the quote. It is the real end of the value, not an embedded quote.
B8="$B4$B4"
printf '%s\n%s\n' "{\"m\":\"{${Q1}token${Q1}:${Q1}ZRsec""ret1${B4}${Q1}}\"}" '{"event":"clean"}' > "$TMP/b1.jsonl"
printf '%s\n%s\n' "{\"m\":\"{${Q1}token${Q1}:${Q1}ZRsec""ret2${B4}${Q1},${Q1}note${Q1}:${Q1}KEEPb2${Q1}}\"}" '{"event":"clean"}' > "$TMP/b2.jsonl"
printf '%s\n%s\n' "{\"m\":\"{${Q1}token${Q1}:${Q1}ZRsec""ret3${B8}${Q1}}\"}" '{"event":"clean"}' > "$TMP/b3.jsonl"
printf '%s\n' "{\"m\":\"{${Q1}token${Q1}:${Q1}ZRsec""ret4${B8}${Q1},${Q1}note${Q1}:${Q1}KEEPb4${Q1}}\"}" > "$TMP/b4.jsonl"
printf '%s' "{\"calls\":{\"a\":\"{${Q1}token${Q1}:${Q1}ZRsec""ret5${B4}${Q1},${Q1}note${Q1}:${Q1}KEEPb5${Q1}}\",\"b\":{\"x\":\"{${Q1}token${Q1}:${Q1}ZRsec""ret6${B8}${Q1},${Q1}note${Q1}:${Q1}KEEPb6${Q1}}\",\"tail\":\"cut" > "$TMP/b5.json"
for f in b1.jsonl b2.jsonl b3.jsonl b4.jsonl b5.json; do
  node "$RF" --check "$TMP/$f" >"$TMP/o.out" 2>&1; rc=$?
  if [ "$rc" = 1 ]; then ok "trailing backslashes: --check $f is not clean before redaction (exit 1)"; else bad "trailing backslashes --check before $f: exit $rc"; fi
done
node "$RF" $TMP/b1.jsonl $TMP/b2.jsonl $TMP/b3.jsonl $TMP/b4.jsonl $TMP/b5.json >"$TMP/o.out" 2>"$TMP/o.err"; rc=$?
if [ "$rc" = 0 ]; then ok "trailing backslashes: the five inputs are rewritten (exit 0)"; else bad "trailing backslashes rewrite: exit $rc, $(cat "$TMP/o.err")"; fi
absent  "trailing backslashes: no secret value remains" "$TMP/b1.jsonl" ZRsec""ret1
absent  "trailing backslashes with a following key: no secret value remains" "$TMP/b2.jsonl" ZRsec""ret2
absent  "trailing backslashes, two of them: no secret value remains" "$TMP/b3.jsonl" ZRsec""ret3
absent  "trailing backslashes, two of them, with a following key: no secret value remains" "$TMP/b4.jsonl" ZRsec""ret4
absent  "trailing backslashes in a truncated .json (text fallback): both values are gone" "$TMP/b5.json" ZRsec""ret5 ZRsec""ret6
present "trailing backslashes: the closing delimiter and the rest of the string are kept (.jsonl)" "$TMP/b1.jsonl" "{\"m\":\"{${Q1}token${Q1}:${Q1}REDACTED${Q1}}\"}" '{"event":"clean"}'
present "trailing backslashes: the following key is kept (.jsonl)" "$TMP/b2.jsonl" "{\"m\":\"{${Q1}token${Q1}:${Q1}REDACTED${Q1},${Q1}note${Q1}:${Q1}KEEPb2${Q1}}\"}"
present "trailing backslashes, two of them: the closing delimiter is kept (.jsonl)" "$TMP/b3.jsonl" "{\"m\":\"{${Q1}token${Q1}:${Q1}REDACTED${Q1}}\"}" '{"event":"clean"}'
present "trailing backslashes, two of them: the following key is kept (.jsonl)" "$TMP/b4.jsonl" "{\"m\":\"{${Q1}token${Q1}:${Q1}REDACTED${Q1},${Q1}note${Q1}:${Q1}KEEPb4${Q1}}\"}"
present "trailing backslashes in a truncated .json: the surrounding text is kept" "$TMP/b5.json" "${Q1}token${Q1}:${Q1}REDACTED${Q1},${Q1}note${Q1}:${Q1}KEEPb5${Q1}}" "${Q1}token${Q1}:${Q1}REDACTED${Q1},${Q1}note${Q1}:${Q1}KEEPb6${Q1}}" ',"tail":"cut'
out=$(node -e '
const fs = require("fs")
const bad = []
for (const [f, note] of [["b1.jsonl", undefined], ["b2.jsonl", "KEEPb2"], ["b3.jsonl", undefined], ["b4.jsonl", "KEEPb4"]]) {
  const lines = fs.readFileSync(process.argv[1] + "/" + f, "utf-8").split("\n").filter(Boolean)
  try { const inner = JSON.parse(JSON.parse(lines[0]).m); if (inner.token !== "REDACTED" || inner.note !== note) bad.push(f + ":value") } catch (e) { bad.push(f + ":parse") }
}
try {
  const t = JSON.parse(fs.readFileSync(process.argv[1] + "/b5.json", "utf-8") + "\"}}}")
  const a = JSON.parse(t.calls.a), b = JSON.parse(t.calls.b.x)
  if (a.token !== "REDACTED" || a.note !== "KEEPb5" || b.token !== "REDACTED" || b.note !== "KEEPb6") bad.push("b5.json:value")
} catch (e) { bad.push("b5.json:parse") }
process.stdout.write(bad.join(" "))' "$TMP" 2>&1)
if [ -z "$out" ]; then ok "trailing backslashes: every inner string still parses as JSON with the secret replaced and the next key intact"; else bad "trailing backslashes, inner JSON: $out"; fi
for f in b1.jsonl b2.jsonl b3.jsonl b4.jsonl b5.json; do
  cp "$TMP/$f" "$TMP/$f.once"
  node "$RF" "$TMP/$f" >"$TMP/o.out" 2>"$TMP/o.err"; rc=$?
  if [ "$rc" = 0 ] && [ ! -s "$TMP/o.out" ] && cmp -s "$TMP/$f" "$TMP/$f.once"; then ok "trailing backslashes: a second run on $f changes nothing"; else bad "trailing backslashes second run $f: exit $rc, output [$(cat "$TMP/o.out")]"; fi
  node "$RF" --check "$TMP/$f" >"$TMP/o.out" 2>&1; rc=$?
  if [ "$rc" = 0 ] && [ ! -s "$TMP/o.out" ]; then ok "trailing backslashes: --check $f is clean after redaction (exit 0)"; else bad "trailing backslashes --check after $f: exit $rc, $(cat "$TMP/o.out")"; fi
done

# ---- a truncated line (unterminated value) followed by other lines (review round 4) -----------------------------
# A value stops at the end of its line: the next line is never swallowed, merged or broken.
# t1: plain form; t2: escaped form in a string holding JSON; both as .jsonl and .raw.
L_CLEAN='{"a":"KEEPt1"}'
L_NEXT='{"password":"ZTsec''ret3"}'
printf '%s\n%s\n%s\n' '{"token":"ZTsec''ret1' "$L_CLEAN" "$L_NEXT" > "$TMP/t1.jsonl"
printf '%s\n%s\n%s\n' "{\"m\":\"{${Q1}token${Q1}:${Q1}ZTsec""ret2" '{"a":"KEEPt2"}' "$L_NEXT" > "$TMP/t2.jsonl"
cp "$TMP/t1.jsonl" "$TMP/t3.raw"
cp "$TMP/t2.jsonl" "$TMP/t4.raw"
for f in t1.jsonl t2.jsonl t3.raw t4.raw; do
  node "$RF" --check "$TMP/$f" >"$TMP/o.out" 2>&1; rc=$?
  if [ "$rc" = 1 ]; then ok "truncated line: --check $f is not clean before redaction (exit 1)"; else bad "truncated line --check before $f: exit $rc"; fi
done
node "$RF" $TMP/t1.jsonl $TMP/t2.jsonl $TMP/t3.raw $TMP/t4.raw >"$TMP/o.out" 2>"$TMP/o.err"; rc=$?
if [ "$rc" = 0 ]; then ok "truncated line: the four inputs are rewritten (exit 0)"; else bad "truncated line rewrite: exit $rc, $(cat "$TMP/o.err")"; fi
for f in t1.jsonl t3.raw; do
  absent  "truncated line, plain form ($f): the secret value of the cut line is gone" "$TMP/$f" ZTsec""ret1 ZTsec""ret3
  nth_line "truncated line, plain form ($f): the cut line keeps its key" "$TMP/$f" 1 '{"token":"REDACTED'
  nth_line "truncated line, plain form ($f): the next line is byte-identical" "$TMP/$f" 2 '{"a":"KEEPt1"}'
  nth_line "truncated line, plain form ($f): a secret on the line after is still rewritten" "$TMP/$f" 3 '{"password":"REDACTED"}'
  line_count "truncated line, plain form ($f): the line count is unchanged" "$TMP/$f" 3
done
for f in t2.jsonl t4.raw; do
  absent  "truncated line, escaped form ($f): the secret value of the cut line is gone" "$TMP/$f" ZTsec""ret2 ZTsec""ret3
  nth_line "truncated line, escaped form ($f): the cut line keeps its key" "$TMP/$f" 1 "{\"m\":\"{${Q1}token${Q1}:${Q1}REDACTED"
  nth_line "truncated line, escaped form ($f): the next line is byte-identical" "$TMP/$f" 2 '{"a":"KEEPt2"}'
  nth_line "truncated line, escaped form ($f): a secret on the line after is still rewritten" "$TMP/$f" 3 '{"password":"REDACTED"}'
  line_count "truncated line, escaped form ($f): the line count is unchanged" "$TMP/$f" 3
done
for f in t1.jsonl t2.jsonl t3.raw t4.raw; do
  cp "$TMP/$f" "$TMP/$f.once"
  node "$RF" "$TMP/$f" >"$TMP/o.out" 2>"$TMP/o.err"; rc=$?
  if [ "$rc" = 0 ] && [ ! -s "$TMP/o.out" ] && cmp -s "$TMP/$f" "$TMP/$f.once"; then ok "truncated line: a second run on $f changes nothing"; else bad "truncated line second run $f: exit $rc, output [$(cat "$TMP/o.out")]"; fi
  node "$RF" --check "$TMP/$f" >"$TMP/o.out" 2>&1; rc=$?
  if [ "$rc" = 0 ] && [ ! -s "$TMP/o.out" ]; then ok "truncated line: --check $f is clean after redaction (exit 0)"; else bad "truncated line --check after $f: exit $rc, $(cat "$TMP/o.out")"; fi
done

# false-positive guards: look-alike keys, prose, hex values and empty or non-string values stay byte-identical
HEX="0123456789abcdef0123456789abcdef01234567"
node -e '
const hex = process.argv[1]
const line = "PROBE name=x exit=0 sha=" + hex + " cmd=" + hex + " json={\"authSecurityBoundarySignal\":\"keep-a\",\"tokenCount\":\"keep-b\",\"secretary\":\"keep-c\",\"mytoken\":\"keep-d\",\"token\":\"\",\"password\":null}"
const prose = "the token is rotated daily; a secret ingredient; set the password later; \"token\" alone, and \"password: soon\""
process.stdout.write(JSON.stringify({ calls: { p: { line }, q: prose } }, null, 2) + "\n")
' "$HEX" > "$TMP/g.json"
node -e '
const hex = process.argv[1]
process.stdout.write("{\"authSecurityBoundarySignal\":\"keep-e\",\"tokenCount\":\"keep-f\",\"secretary\":\"keep-g\"}\n" + "{\"line\":\"PROBE sha=" + hex + " cmd=" + hex + "\"}\n" + "a sentence about the token and the password, \"token\" in quotes.\n")
' "$HEX" > "$TMP/g.jsonl"
cp "$TMP/g.jsonl" "$TMP/g.raw"
for f in g.json g.jsonl g.raw; do
  cp "$TMP/$f" "$TMP/$f.orig"
  node "$RF" "$TMP/$f" >"$TMP/o.out" 2>"$TMP/o.err"; rc=$?
  if [ "$rc" = 0 ] && [ ! -s "$TMP/o.out" ] && cmp -s "$TMP/$f" "$TMP/$f.orig"; then ok "false positives: $f is byte-identical (look-alike keys, prose, sha=/cmd= hex, empty values)"; else bad "false positives $f: exit $rc, output [$(cat "$TMP/o.out")]"; fi
  node "$RF" --check "$TMP/$f" >"$TMP/o.out" 2>&1; rc=$?
  if [ "$rc" = 0 ]; then ok "false positives: --check $f exits 0"; else bad "--check $f: exit $rc"; fi
done

rm -rf "$TMP"
STATUS=ok; [ "$FAIL" -gt 0 ] && STATUS=fail
echo "[test-redact-fixture] status=$STATUS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
