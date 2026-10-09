#!/usr/bin/env bash
# Parity test of the acceptance start marker: the engine, the splice template, the acceptance-check lib and the
# lead-merge script each spell it on their own. Every literal spelling must equal one canonical string and every
# regex spelling must match it. Sites are located by their quoted text, never by line number.
# PARITY_ROOT points the test at another copy of the four files (negative runs); the harness always comes from the repo.
# bash 3.2 compatible. Trailer: [test-marker-parity] passed=<n> failed=<n>
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export ROOT="$REPO_ROOT"
# shellcheck source=lib/harness.sh
. "$REPO_ROOT/tests/scripts/lib/harness.sh"
SRC="${PARITY_ROOT:-$REPO_ROOT}"
CANON='<!-- acceptance:start -->'

# site <kind: literal|regex> <file> <label> <expected count> <sed -E expression matching a whole line, one capture group>
site() {
  local kind="$1" file="$2" label="$3" want="$4" expr="$5" found n=0 line
  if [ ! -f "$SRC/$file" ]; then bad "$file $label: file missing"; return; fi
  found="$(sed -nE "s/$expr/\\1/p" "$SRC/$file")"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=$((n+1))
    if [ "$kind" = literal ]; then
      if [ "$line" = "$CANON" ]; then ok "$file $label: literal equals the canonical marker"
      else bad "$file $label: literal is '$line', expected '$CANON'"; fi
    elif python3 -c 'import re,sys; sys.exit(0 if re.search(sys.argv[1], sys.argv[2]) else 1)' "$line" "$CANON"; then
      ok "$file $label: regex '$line' matches the canonical marker"
    else
      bad "$file $label: regex '$line' does not match '$CANON'"
    fi
  done <<EOF
$found
EOF
  [ "$n" -eq "$want" ] || bad "$file $label: expected $want spelling(s), found $n"
}

command -v python3 >/dev/null 2>&1 || bad "python3 is missing"

J=workflows/deliver-pipeline.js
site literal "$J" ACCEPTANCE_START 1 "^const ACCEPTANCE_START = '([^']*)'\$"
site literal "$J" includes 1 ".*b\\.includes\\('([^']*acceptance:start[^']*)'\\).*"
site literal "$J" AC_BLOCK_START 1 "^const AC_BLOCK_START = '([^']*)'\$"
C=templates/pr-body-splice.cjs
site literal "$C" ACCEPTANCE_START 1 "^const ACCEPTANCE_START = '([^']*)'\$"
site literal "$C" includes 1 ".*b\\.includes\\('([^']*acceptance:start[^']*)'\\).*"
site literal scripts/lib/acceptance-check.sh MSTART 1 ".*MSTART = \"([^\"]*)\".*"
site regex scripts/lead-merge.sh re.search 1 ".*re\\.search\\(r\"([^\"]*acceptance:start[^\"]*)\".*"
site regex scripts/lib/merge-gates.sh re.search 1 ".*re\\.search\\(r\"([^\"]*acceptance:start[^\"]*)\".*"

echo "[test-marker-parity] passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
