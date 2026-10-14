#!/usr/bin/env bash
# Self-test of scripts/runtime/launch-args.cjs (#527, mode ref #520): the args object of a workflow launch, built from a
# synthetic git tree made by scripts/gen-launch-fixtures.cjs in $TMPDIR (nothing is committed).
# Covers the shape of a plan, dev and review launch, the byte-for-byte determinism, the overrides, and the
# mode ref (references instead of the objects, the fingerprint of the specifics) and the refusals (unknown mode, stage or flag,
# a root that is not a git tree), all exit 2 with empty stdout.
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

SESSION="$TMP/session"; export SESSION
run --root "$TREE" --stage plan --mode ref --session-root "$SESSION"
check "mode ref: --session-root is printed verbatim, not derived from --root" 'a.sessionRoot === process.env.SESSION && a.sessionRoot !== a.worktreePath'
check "mode ref: ordered keys, references in place of config and projectSpecifics" 'Object.keys(a).slice(0, 8).join() === "issue,brief,worktreePath,mode,pmReview,configRef,configLocal,projectSpecificsRef" && !("config" in a) && !("projectSpecifics" in a)'
CFG_SHA="$(node -e 'process.stdout.write(require("crypto").createHash("sha256").update(require("fs").readFileSync(process.argv[1])).digest("hex"))' "$TREE/.claude/pipeline.config.json")"
export CFG_SHA
check "mode ref: configRef names the file and carries its sha256" 'a.configRef.path === ".claude/pipeline.config.json" && a.configRef.digest64 === process.env.CFG_SHA'
check "mode ref: projectSpecificsRef is the sha and the 12-hex fingerprint" '/^[0-9a-f]{40}$/.test(a.projectSpecificsRef.refSha) && /^[0-9a-f]{12}$/.test(a.projectSpecificsRef.fp12)'
cp "$TMP/out" "$TMP/ref"
run --root "$TREE" --stage plan --mode full
node -e '
const full = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))
const ref = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"))
const { fingerprint12 } = require(process.argv[3] + "/scripts/lib/agent-context-text.cjs")
process.stdout.write(String(fingerprint12(full.projectSpecifics) === ref.projectSpecificsRef.fp12 && full.projectSpecifics.refSha === ref.projectSpecificsRef.refSha))' "$TMP/out" "$TMP/ref" "$ROOT" >"$TMP/same"
if [ "$(cat "$TMP/same")" = "true" ]; then ok "mode ref: the fingerprint is the one of the full specifics"; else bad "mode ref: fingerprint differs from the full payload"; fi
run --root "$TREE" --stage plan --mode ref --session-root "$SESSION" --worktree /somewhere/wt --issue 9
check "mode ref: --worktree sets worktreePath" 'a.worktreePath === "/somewhere/wt" && a.issue === 9'
run --root "$TREE" --stage dev --mode ref --session-root "$SESSION" --plan-file "$TMP/plan.txt"
check "mode ref: planText stays in full, never behind a reference" 'a.planText === "the plan\n" && a.entryStage === "dev"'
run --root "$TREE" --stage plan --mode full
check "mode full: sessionRoot still defaults to --root without the flag" 'a.sessionRoot === a.worktreePath'
refused "mode ref without --session-root is refused" --root "$TREE" --stage plan --mode ref
if grep -q 'entry --session-root)$' "$TMP/err"; then ok "mode ref without --session-root: the message ends with the pointer"; else bad "mode ref without --session-root: no pointer at the end of the message"; fi
refused "mode ref with a relative --session-root is refused" --root "$TREE" --stage plan --mode ref --session-root rel/dir
refused "unknown mode is refused" --root "$TREE" --stage plan --mode bogus
refused "unknown stage is refused" --root "$TREE" --stage x
refused "unknown flag is refused" --root "$TREE" --stage plan --bogus
mkdir -p "$TMP/plain/.claude"
cp "$TREE/.claude/pipeline.config.json" "$TMP/plain/.claude/pipeline.config.json"
refused "a root that is not a git tree is refused" --root "$TMP/plain" --stage plan

STATUS=ok; [ "$FAIL" -eq 0 ] || STATUS=fail
echo "[test-launch-args] status=${STATUS} passed=${PASS} failed=${FAIL}"
[ "$FAIL" -eq 0 ]
