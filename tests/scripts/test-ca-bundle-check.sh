#!/usr/bin/env bash
# Regression test for scripts/ca-bundle-check.sh (#251). Offline: the script only tests files named by SSL_CERT_FILE and
# GIT_SSL_CAINFO, so each case runs it with those two variables set explicitly (or removed) to files made under $TMPDIR.
# Cases: both unset, present non-empty, missing, empty, each variable alone, an empty value, no path in the output.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/ca-bundle-check.sh"
BASE="$(mktemp -d "${TMPDIR:-/tmp}/ca-bundle-check-test.XXXXXX")"
PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

GOOD="$BASE/good.crt"; printf 'CERT\n' > "$GOOD"
EMPTY="$BASE/empty.crt"; : > "$EMPTY"
GONE="$BASE/gone.crt"

OUT=""; RC=0
# run <ssl_cert_file|-> <git_ssl_cainfo|->: "-" removes the variable
run() {
  local args=(-u SSL_CERT_FILE -u GIT_SSL_CAINFO)
  [ "$1" = "-" ] || args+=("SSL_CERT_FILE=$1")
  [ "$2" = "-" ] || args+=("GIT_SSL_CAINFO=$2")
  OUT="$(env "${args[@]}" bash "$SCRIPT" </dev/null 2>&1)"; RC=$?
}
has() { case "$OUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

run - -
[ "$RC" -eq 0 ] && has "nothing to check" && ok "both unset: exit 0, nothing checked" || bad "both unset (rc=$RC): $OUT"

run "$GOOD" "$GOOD"
[ "$RC" -eq 0 ] && has "ok (2 variable(s) checked)" && ! has sandbox-ca-stale && ok "present non-empty files: exit 0, two checked" || bad "present (rc=$RC): $OUT"

run "$GONE" "$GOOD"
[ "$RC" -eq 1 ] && has sandbox-ca-stale && has SSL_CERT_FILE && has "missing" && has "restart the session" \
  && ok "missing SSL_CERT_FILE: exit 1, names token, variable, cause and fix" || bad "missing (rc=$RC): $OUT"

run "$EMPTY" "$GOOD"
[ "$RC" -eq 1 ] && has sandbox-ca-stale && has SSL_CERT_FILE && has "empty" && has "restart the session" \
  && ok "empty SSL_CERT_FILE: exit 1, cause empty" || bad "empty (rc=$RC): $OUT"

run "$GOOD" "$GONE"
[ "$RC" -eq 1 ] && has sandbox-ca-stale && has GIT_SSL_CAINFO && ! has "SSL_CERT_FILE names" \
  && ok "stale GIT_SSL_CAINFO alone: exit 1 naming it" || bad "git var (rc=$RC): $OUT"

run - "$EMPTY"
[ "$RC" -eq 1 ] && has GIT_SSL_CAINFO && has "empty" && ok "only GIT_SSL_CAINFO set, empty file: exit 1" || bad "git only (rc=$RC): $OUT"

run "" "$GOOD"
[ "$RC" -eq 0 ] && has "ok (1 variable(s) checked)" && ok "an empty value is skipped" || bad "empty value (rc=$RC): $OUT"

run "$GONE" "$EMPTY"
[ "$RC" -eq 1 ] && has SSL_CERT_FILE && [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" -eq 1 ] \
  && ok "both stale: one line, the first variable" || bad "both stale (rc=$RC): $OUT"

run "$GONE" "$GOOD"
if ! has "$BASE"; then ok "the output never contains the file path"; else bad "path leaked: $OUT"; fi

echo "[ca-bundle-check test] passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
