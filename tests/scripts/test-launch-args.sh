#!/usr/bin/env bash
# Self-test of scripts/runtime/launch-args.cjs (#527): the args object of a workflow launch, built from a
# synthetic git tree made by scripts/gen-launch-fixtures.cjs in $TMPDIR (nothing is committed).
# Covers the shape of a plan, dev and review launch, the byte-for-byte determinism, the overrides, and the
# refusals (mode ref until #520, unknown stage or flag, a root that is not a git tree), all exit 2 with empty stdout.
# bash 3.2 compatible. Trailer: [test-launch-args] status=<ok|fail> passed=<n> failed=<n>
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
LA="$ROOT/scripts/runtime/launch-args.cjs"
GEN="$ROOT/scripts/gen-launch-fixtures.cjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/launch-args-selftest.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
TREE="$TMP/t"
node "$GEN" --tree "$TREE" --size 22k || { echo "cannot build the fixture tree"; exit 1; }

# js <expression over a = parsed stdout of the last run>: prints true or false
js() { node -e 'const a = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.stdout.write(String(Boolean(eval(process.argv[2]))))' "$TMP/out" "$1"; }
run() { node "$LA" "$@" >"$TMP/out" 2>"$TMP/err"; RC=$?; }
check() { # check <name> <js expression>
  if [ "$RC" -eq 0 ] && [ "$(js "$2")" = "true" ]; then ok "$1"; else bad "$1 (rc=$RC)"; fi
}
refused() { # refused <name> <args...>
  local name="$1"; shift
  run "$@"
  if [ "$RC" -eq 2 ] && [ ! -s "$TMP/out" ] && [ "$(wc -l < "$TMP/err" | tr -d ' ')" = "1" ]; then ok "$name"; else bad "$name (rc=$RC, stdout bytes $(wc -c < "$TMP/out" | tr -d ' '))"; fi
}

run --root "$TREE" --ref origin/main --stage plan --mode full
check "plan launch: one minified JSON line, ordered keys, no entryStage" 'Object.keys(a).slice(0, 7).join() === "issue,brief,worktreePath,mode,pmReview,config,configLocal" && !("entryStage" in a) && !("planText" in a)'
if [ "$(wc -l < "$TMP/out" | tr -d ' ')" = "1" ]; then ok "plan launch: stdout is a single line"; else bad "plan launch: stdout is not a single line"; fi
check "plan launch: the assembler's role text is carried (Sam bytes > 0)" 'a.projectSpecifics.roles.Sam.bytes > 0 && !("files" in a.projectSpecifics)'
check "plan launch: shared and every role digest are 64 hex" '/^[0-9a-f]{64}$/.test(a.projectSpecifics.shared.digest) && ["Sam","Nick","Morgan","Theo","Mia"].every((r) => /^[0-9a-f]{64}$/.test(a.projectSpecifics.roles[r].digest))'
check "plan launch: the brief is the short default and points to the issue" 'a.brief === "implement the issue" && a.issue === 1'

cp "$TMP/out" "$TMP/first"
run --root "$TREE" --ref origin/main --stage plan --mode full
if cmp -s "$TMP/first" "$TMP/out"; then ok "two runs are byte-identical"; else bad "two runs differ"; fi

run --root "$TREE" --stage plan --issue 7 --brief "short brief" --mode full
check "issue and brief flags are honoured" 'a.issue === 7 && a.brief === "short brief"'

run --root "$TREE" --stage review --pr 42
check "review launch: entryStage review and the PR number" 'a.entryStage === "review" && a.prNumber === 42'
run --root "$TREE" --stage dev
check "dev launch: entryStage dev, no prNumber" 'a.entryStage === "dev" && !("prNumber" in a)'

printf 'the plan\n' > "$TMP/plan.txt"
run --root "$TREE" --stage dev --plan-file "$TMP/plan.txt"
check "plan file: planText carried verbatim" 'a.planText === "the plan\n"'

node -e '
const { build } = require(process.argv[1])
const a = build({ root: process.argv[2], stage: "plan", worktreePath: "/wt", pluginRoot: "/pl", sessionRoot: "/ss" })
process.stdout.write(JSON.stringify(a) + "\n")' "$LA" "$TREE" >"$TMP/out" 2>"$TMP/err"; RC=$?
check "overrides: worktreePath, pluginRoot and sessionRoot are honoured" 'a.worktreePath === "/wt" && a.pluginRoot === "/pl" && a.sessionRoot === "/ss"'

refused "mode ref is refused until #520" --root "$TREE" --stage plan --mode ref
if grep -q 'until #520' "$TMP/err"; then ok "mode ref: the message names #520"; else bad "mode ref: message $(cat "$TMP/err")"; fi
refused "unknown stage is refused" --root "$TREE" --stage x
refused "unknown flag is refused" --root "$TREE" --stage plan --bogus
mkdir -p "$TMP/plain/.claude"
cp "$TREE/.claude/pipeline.config.json" "$TMP/plain/.claude/pipeline.config.json"
refused "a root that is not a git tree is refused" --root "$TMP/plain" --stage plan

STATUS=ok; [ "$FAIL" -eq 0 ] || STATUS=fail
echo "[test-launch-args] status=${STATUS} passed=${PASS} failed=${FAIL}"
[ "$FAIL" -eq 0 ]
