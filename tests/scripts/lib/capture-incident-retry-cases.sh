#!/usr/bin/env bash
# #209 retried-call cases and the usage errors (sourced by tests/scripts/test-capture-incident.sh, never executed).
# ---- #209: a call the engine retried is captured once, under its engine label ----------------------------
# The engine's real shape (see the generator): ONE record entry '<label> (retry N)' with the agentId of the last attempt; the
# journal holds N+1 `started` rows '<label>' under one key, the N earlier ones without a result. The capture holds one entry per
# engine label with the answer of the record's agentId, retries=<sum of N>, and refuses everything it cannot attribute.
SMOKE_SC=$(node -e 'process.stdout.write(JSON.stringify(require(process.env.ROOT+"/fixtures/smoke/auto-lgtm.json").calls["scout-issue-123-1"]))')
SMOKE_DG=$(node -e 'process.stdout.write(JSON.stringify(require(process.env.ROOT+"/fixtures/smoke/auto-lgtm.json").calls["diagnose-issue-123"]))')
SMOKE_N=$(node -e 'process.stdout.write(String(Object.keys(require(process.env.ROOT+"/fixtures/smoke/auto-lgtm.json").calls).length))')
retry_fold() { # name mutation expected-retries expected-note-substring
  newrun "$2"
  cap "$RUN" 181 t --out "$OUTD"
  if expect_ok "retried call $1"; then
    got=$(jsq 'f.calls["scout-issue-123-1"]')
    n=$(jsq 'Object.keys(f.calls).filter((k) => k.indexOf("scout-issue-123") === 0).length')
    nwant=$(node -e 'process.stdout.write(String(Object.keys(require(process.env.ROOT+"/fixtures/smoke/auto-lgtm.json").calls).filter((k) => k.indexOf("scout-issue-123") === 0).length))')
    last=$(printf '%s\n' "$OUT" | /usr/bin/grep 'status=ok out=')
    if [ "$got" = "$SMOKE_SC" ] && [ "$n" = "$nwant" ] && ! /usr/bin/grep -q '(retry' "$CAP" \
       && case "$last" in *" retries=$3") true;; *) false;; esac \
       && case "$OUT" in *"$4"*"[offline] status=ok"*) true;; *) false;; esac; then
      ok "retried call $1: captured once under its engine label, retries=$3, replays"
    else
      bad "retried call $1: got=$got entries=$n/$nwant last='$last' out=$OUT"
    fi
  fi
}
retry_fold "one retry (two journal starts under one key, one result)" retry 1 "folded retried call scout-issue-123-1: 2 attempts, answer of agentId ag-"
# the answering attempt is the record's agentId, the died one is named in the note
newrun retry
cap "$RUN" 181 t --out "$OUTD"
SCA=$(node -e 'const l=Object.keys(require(process.env.ROOT+"/fixtures/smoke/auto-lgtm.json").calls);process.stdout.write("ag-"+l.indexOf("scout-issue-123-1"))')
case "$OUT" in
  *"answer of agentId $SCA used, died attempt ag-dead-$SCA-0 [line "*) ok "retried call: the note names the answering agentId (the record's) and the died attempt";;
  *) bad "retried call note attribution: want answer $SCA died ag-dead-$SCA-0: $OUT";;
esac
RDEAD=3 retry_fold "three retries (retry 3: three died starts)" retry 3 "4 attempts"
RDEAD=12 retry_fold "two-digit N (retry 12)" retry 12 "folded retried call"
RDEAD=999 retry_fold "N at the upper bound (retry 999)" retry 999 "folded retried call"
retry_fold "an earlier pass answered the same key with a decoy, the record's agentId decides" retryrelaunch 1 "answer of agentId ag-"
case "$OUT" in
  *"stale-r [line"*) bad "retried call: the note names an earlier pass's ANSWERED attempt as died: $OUT";;
  *"died attempt ag-dead-$SCA-0 [line "*) ok "retried call: an earlier pass's answered attempt on the same key is not named as died";;
  *) bad "retried call: died attempt not named in the relaunch case: $OUT";;
esac
retry_fold "the result row names no agentId (joined by key)" retrynoid 1 "folded retried call"
# two retried calls in one run: retries sums N (1 + 2), one entry per call
newrun retrymulti
cap "$RUN" 181 t --out "$OUTD"
if expect_ok "retried call two calls"; then
  last=$(printf '%s\n' "$OUT" | /usr/bin/grep 'status=ok out=')
  if [ "$(jsq 'f.calls["scout-issue-123-1"]')" = "$SMOKE_SC" ] && [ "$(jsq 'f.calls["diagnose-issue-123"]')" = "$SMOKE_DG" ] \
     && [ "$(jsq 'Object.keys(f.calls).length')" = "$SMOKE_N" ] && case "$last" in *" calls=$SMOKE_N "*" retries=3") true;; *) false;; esac; then
    ok "retried call two retried calls in one run: retries=3 (N summed, not one per call), one entry each"
  else
    bad "retried call two calls: last='$last'"
  fi
fi
# a legitimate engine label ending with (retry 1), in journal and record alike, is captured as is (the journal is the authority)
newrun retrylegit
cap "$RUN" 181 t --out "$OUTD"
if expect_ok "retried call legit label"; then
  last=$(printf '%s\n' "$OUT" | /usr/bin/grep 'status=ok out=')
  if [ "$(jsq 'f.calls["decoy-retry (retry 1)"]')" = '"legit"' ] && [ "$(jsq '"decoy-retry" in f.calls')" = "false" ] \
     && case "$last" in *" retries=0") true;; *) false;; esac; then
    ok "retried call: a label that ends with (retry 1) in journal and record is kept as is, retries=0"
  else
    bad "retried call legit label: last='$last' keys=$(jsq 'Object.keys(f.calls).filter((k) => k.indexOf("decoy") === 0)')"
  fi
fi
# ... and when that same call was retried, only the engine suffix is folded
newrun retrylegitfold
cap "$RUN" 181 t --out "$OUTD"
if expect_ok "retried call legit label retried"; then
  last=$(printf '%s\n' "$OUT" | /usr/bin/grep 'status=ok out=')
  if [ "$(jsq 'f.calls["decoy-retry (retry 1)"]')" = '"legit"' ] && case "$last" in *" retries=1") true;; *) false;; esac; then
    ok "retried call: a retried call whose label ends with (retry 1) folds the last suffix only (retries=1)"
  else
    bad "retried call legit label retried: last='$last'"
  fi
fi
# two calls of one engine label: attributed by agentId and key, in record order, never guessed
twin_case() { # name mutation
  newrun "$2"
  cap "$RUN" 181 t --out "$OUTD"
  if expect_ok "retried call $1"; then
    last=$(printf '%s\n' "$OUT" | /usr/bin/grep 'status=ok out=')
    if [ "$(jsq 'f.calls["decoy-twin"]')" = '["first","second"]' ] && case "$last" in *" retries=1") true;; *) false;; esac; then
      ok "retried call $1: both answers kept in record order, the retry attributed by agentId and key"
    else
      bad "retried call $1: twin=$(jsq 'f.calls["decoy-twin"]') last='$last'"
    fi
  fi
}
twin_case "two calls of one label, the second retried" retrytwin
twin_case "two calls of one label, the first retried" retrytwinfirst
export KIND="retried call"
refusal "two calls of one label sharing a key, one retried (ambiguous)" retrytwinshared "ambiguous retried call"
refusal "journal label of the answer is another call's" retrydiff 'journal "scout-issue-123-2", record "scout-issue-123-1 (retry 1)"'
refusal "a died attempt of the key has another label" retrydeadlabel "label mismatch on key $SCOUT_KEY"
refusal "no attempt answers" retryalldied "died call scout-issue-123-1 key $SCOUT_KEY"
refusal "the key's last event is failed" retryfailedlast "failed call scout-issue-123-1 key $SCOUT_KEY"
refusal "result rows name other attempts only" retryotherid "no result row of agentId"
# N is checked against the died attempts of the key, never guessed
RDEAD=1 RSFX=' (retry 2)' refusal "N above the died attempts (retry 2, one died)" retry "retry count mismatch"
RDEAD=2 RSFX=' (retry 1)' refusal "N below the died attempts (retry 1, two died)" retry "retry count mismatch"
RDEAD=0 RSFX=' (retry 1)' refusal "retry suffix on a call with no died attempt" retry "retry count mismatch"
# the suffix is exactly ' (retry N)': N 1-999 without leading zero, one space before, nothing after, case-sensitive
sfx_refusal() { # suffix
  RDEAD=1 RSFX="$1" refusal "suffix <$(printf '%q' "$1")>" retry "label mismatch for agentId"
}
sfx_refusal ' (retry)'
sfx_refusal ' (retry )'
sfx_refusal ' (retry 0)'
sfx_refusal ' (retry 01)'
sfx_refusal ' (retry -1)'
sfx_refusal ' (retry +1)'
sfx_refusal ' (retry 1.0)'
sfx_refusal ' (retry 1e0)'
sfx_refusal ' (retry  1)'
sfx_refusal ' (Retry 1)'
sfx_refusal ' (RETRY 1)'
sfx_refusal ' (retried 1)'
sfx_refusal ' (retry 1) '
sfx_refusal $' (retry 1)\t'
sfx_refusal $' (retry 1)\n'
sfx_refusal '  (retry 1)'
sfx_refusal '(retry 1)'
sfx_refusal ' (retry 1) (retry 1)'
sfx_refusal ' (retry 1000)'
sfx_refusal ' (retry 99999999999999999999)'
# the other retry suffixes of the engine are not folded (out of #209): they refuse as a label mismatch
sfx_refusal ' (throttle-retry)'
sfx_refusal ' (after usage limit)'
export KIND=

# unexpected file-system errors end as a status line, never a stack trace
# capsep [args...]: like cap, but stdout and stderr kept apart (OUT = stdout, ERR = stderr)
capsep() {
  OUT=$(cd "$REPO" && CLAUDE_PROJECTS_DIR="$PROJ" bash "$ROOT/scripts/capture-incident.sh" "$@" 2>"$TMP/stderr.txt"); RC=$?
  ERR=$(cat "$TMP/stderr.txt")
}
error_case() { # name; asserts the result of the last capsep
  name="$1"
  last=$(printf '%s\n' "$OUT" | tail -n 1)
  stack=$(printf '%s\n' "$ERR" | grep -cE '^[[:space:]]+at |node:internal' || true)
  left=$(ls -A "$OUTD" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$RC" -eq 1 ] && [ "$last" = "[capture-incident] status=error" ] && [ "$stack" = "0" ] && [ "$left" = "0" ] \
     && printf '%s\n' "$ERR" | grep -q '^error: [A-Z]'; then
    ok "error $name: status=error, one stderr line, no stack, nothing written"
  else
    bad "error $name: rc=$RC last='$last' stack=$stack left=$left err=$ERR"
  fi
}
newrun base
mkdir -p "$OUTD"; chmod 500 "$OUTD"
capsep "$RUN" 181 t --out "$OUTD"
chmod 700 "$OUTD"
error_case "read-only output directory"
LONG=$(printf 'a%.0s' $(seq 1 300))
newrun base
mkdir -p "$OUTD"
capsep "$RUN" 181 "$LONG" --out "$OUTD"
error_case "300-character label"

# ---- usage errors (exit 2, before any filesystem access) ---------------------------------------

usage_case() { # name expected-substring args...
  name="$1"; want="$2"; shift 2
  cap "$@"
  case "$OUT" in
    *"$want"*"status=usage-error"*) [ "$RC" -eq 2 ] && ok "usage $name" || bad "usage $name: exit $RC";;
    *) bad "usage $name: $OUT";;
  esac
}
usage_case "bad runId" "runId" '../x' 181 t --out "$OUTD"
usage_case "bad issue" "issue" "$RUN" 12a t --out "$OUTD"
usage_case "bad label" "label" "$RUN" 181 Up --out "$OUTD"
usage_case "unknown flag" "--force" "$RUN" 181 t --force
usage_case "flag without value" "--out" "$RUN" 181 t --out

