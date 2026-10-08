#!/usr/bin/env bash
# Tick-equivalence test: the acceptance-box tick exists three times, in the python of scripts/lead-merge.sh (the
# --tick-from-review step), as tickAcceptanceBlock in workflows/deliver-pipeline.js and as the `tick` mode of
# templates/pr-body-splice.cjs. The same body and the same boxes to tick go through the three; the outputs must be byte-equal
# (after dropping the suffix lead-merge appends to a ticked line). The three files are read, never edited.
# The inputs are those where the three agree; the known gaps (a fenced box with the text of a proven box, an end marker look-alike
# inside the real block, CRLF read in text mode, non-box lines moved after the boxes) are DEBT(#360) and are not exercised.
# PARITY_ROOT points the test at another copy of the three files (negative runs); the harness always comes from the repo.
# bash 3.2 compatible. Trailer: [test-tick-equivalence] passed=<n> failed=<n>
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export ROOT="$REPO_ROOT"
# shellcheck source=lib/harness.sh
. "$REPO_ROOT/tests/scripts/lib/harness.sh"
SRC="${PARITY_ROOT:-$REPO_ROOT}"
T="$(mktemp -d "${TMPDIR:-/tmp}/tick-equivalence.XXXXXX")"
trap 'rm -rf "$T"' EXIT
SUFFIX=" — ticked by lead-merge from Morgan's review"
SM='<!-- acceptance:start -->'; EM='<!-- acceptance:end -->'
BOXES=( '- [ ] <!-- ac:1 --> alpha' '- [ ] <!-- ac:2 --> beta' '- [ ] <!-- ac:3 --> [human-gate] gamma' )

# setup: the python of the tick step and the engine function, extracted from the files under test
setup() {
  awk '/python3 - .*tick_tmp\/body.txt.*tick_tmp\/review.txt/ {grab=1; next} grab && /^PY$/ {exit} grab {print}' \
    "$SRC/scripts/lead-merge.sh" > "$T/tick.py"
  [ -s "$T/tick.py" ] || { bad "setup: the tick python was not found in scripts/lead-merge.sh"; return 1; }
  awk '/^\/\/ --- prBodySplice:start/ {grab=1} grab {print} /^\/\/ --- prBodySplice:end/ {exit}' \
    "$SRC/workflows/deliver-pipeline.js" > "$T/engine.js"
  [ -s "$T/engine.js" ] || { bad "setup: the prBodySplice block was not found in workflows/deliver-pipeline.js"; return 1; }
  echo 'module.exports = { tickAcceptanceBlock }' >> "$T/engine.js"
  cat > "$T/run-engine.js" <<'JS'
const fs = require('fs')
const { tickAcceptanceBlock } = require(process.argv[2])
const ids = (csv) => (csv ? csv.split(',').map(Number) : [])
let rendered = fs.readFileSync(process.argv[4], 'utf8')
if (rendered.endsWith('\n')) rendered = rendered.slice(0, -1)
const out = tickAcceptanceBlock(fs.readFileSync(process.argv[3], 'utf8'), rendered, ids(process.argv[5]), ids(process.argv[6]))
if (out === null) process.exit(3)
fs.writeFileSync(process.argv[7], out)
JS
  printf '%s\n' "${BOXES[@]}" > "$T/rendered.txt"
}

# review <tick csv> <out>: one proof line per box to tick, in the shape lead-merge reads
review() {
  local id; : > "$2"
  for id in $(echo "$1" | tr ',' ' '); do
    printf -- '- %s — verified, tick pending (permissions): `cmd`\n' "$(echo "${BOXES[$((id-1))]}" | cut -c7-)" >> "$2"
  done
}

# run_case <name> <tick csv> <keep csv> <crlf: 0|1>   (the body is in $T/body.txt)
run_case() {
  local name="$1" tick="$2" keep="$3" crlf="$4" d
  review "$tick" "$T/review.txt"
  python3 "$T/tick.py" "$T/body.txt" "$T/review.txt" 2>/dev/null | sed "s/$SUFFIX\$//" > "$T/py.out"
  node "$T/run-engine.js" "$T/engine.js" "$T/body.txt" "$T/rendered.txt" "$tick" "$keep" "$T/eng.out" || { bad "tick-equivalence $name: the engine tick failed"; return; }
  node "$SRC/templates/pr-body-splice.cjs" tick "$T/body.txt" "$T/rendered.txt" "$T/cli.out" "$tick" "$keep" || { bad "tick-equivalence $name: the template CLI tick failed"; return; }
  if [ "$crlf" = 1 ]; then
    # DEBT(#360): the python reads the body in text mode, so it drops the CR; engine and CLI keep it
    tr -d '\r' < "$T/eng.out" > "$T/eng.lf"
    [ "$(grep -c $'\r' "$T/eng.out")" -gt 0 ] || { bad "tick-equivalence $name: the engine lost the CR"; return; }
    d=$(diff "$T/py.out" "$T/eng.lf") || { bad "tick-equivalence $name: python vs engine differ: $d"; return; }
  else
    d=$(diff "$T/py.out" "$T/eng.out") || { bad "tick-equivalence $name: python vs engine differ: $d"; return; }
  fi
  d=$(diff "$T/eng.out" "$T/cli.out") || { bad "tick-equivalence $name: engine vs template CLI differ: $d"; return; }
  ok "tick-equivalence $name: python, engine and template CLI agree"
}

block() { # <eol> <box1> <box2> <box3>: the acceptance block
  printf '%s%s' "$SM" "$1"; shift 1
  local b; for b in "$@"; do printf '%s%s' "$b" "$EOL"; done
  printf '%s%s' "$EM" "$EOL"
}
fenced() { # a fenced example holding a marker pair and a box
  printf '%s%s%s%s%s%s%s%s%s%s%s' '```' "$EOL" "$SM" "$EOL" '- [ ] <!-- ac:1 --> example one' "$EOL" "$EM" "$EOL" '```' "$EOL" ""
}

if setup; then
  EOL=$'\n'
  { printf 'intro%s' "$EOL"; block "$EOL" "${BOXES[@]}"; printf 'tail%s' "$EOL"; } > "$T/body.txt"
  run_case plain 1,2 3 0
  run_case ids 1 3 0
  { printf 'intro%s' "$EOL"; fenced; block "$EOL" "${BOXES[@]}"; printf 'tail%s' "$EOL"; } > "$T/body.txt"
  run_case fence-before 1,2 3 0
  { printf 'intro%s' "$EOL"; block "$EOL" "${BOXES[@]}"; fenced; printf 'tail%s' "$EOL"; } > "$T/body.txt"
  run_case fence-after 1,2 3 0
  { printf 'intro%s' "$EOL"; printf '```%s%s%s- [ ] <!-- ac:9 --> example nine%s```%s' "$EOL" "$EM" "$EOL" "$EOL" "$EOL"
    block "$EOL" "${BOXES[@]}"; printf 'tail%s' "$EOL"; } > "$T/body.txt"
  run_case lookalike-marker 1,2 3 0
  { printf 'intro%s' "$EOL"; block "$EOL" "${BOXES[0]}" "${BOXES[1]}" '- [x] <!-- ac:3 --> [human-gate] gamma'; printf 'tail%s' "$EOL"; } > "$T/body.txt"
  run_case human-gate 1 3 0
  { printf 'intro%s' "$EOL"; block "$EOL" "${BOXES[@]}"; printf 'tail%s' "$EOL"; } > "$T/body.txt"
  run_case nothing-to-tick "" 3 0
  EOL=$'\r\n'
  { printf 'intro%s' "$EOL"; block "$EOL" "${BOXES[@]}"; printf 'tail%s' "$EOL"; } > "$T/body.txt"
  run_case crlf 1,2 3 1
fi

echo "[test-tick-equivalence] passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
