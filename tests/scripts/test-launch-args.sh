#!/usr/bin/env bash
# Self-test of scripts/runtime/launch-args.cjs (#527, mode ref #520, mode file #605): the args object of a workflow launch, built from a
# synthetic git tree made by scripts/gen-launch-fixtures.cjs in $TMPDIR (nothing is committed).
# Covers the shape of a plan, dev and review launch, the byte-for-byte determinism, the overrides, and the
# mode ref (references instead of the objects, the fingerprint of the specifics) and the refusals (unknown mode, stage or flag,
# a root that is not a git tree), all exit 2 with empty stdout. Mode file: the launch file of a run (one absolute path of the
# generated shape, the label from the REST title, then the brief, then the issue number), its refusals (bad issue, not ignored,
# git failure, relative session root, unknown flag, an engine source without the shape).
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

# ---- mode file (#605) -----------------------------------------------------------------------------
GHBIN="$TMP/ghbin"; mkdir -p "$GHBIN"
cat > "$GHBIN/gh" <<'STUB'
#!/usr/bin/env bash
[ "${GH_STUB_FAIL:-}" = "1" ] && exit 1
case "$2" in
  repos/acme/widgets/issues/520) printf '{"number":520,"state":"open","title":"%s","body":"x"}\n' "${GH_STUB_TITLE:-Derive the run title}" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$GHBIN/gh"
git -C "$TREE" remote add origin https://github.com/acme/widgets.git
SESS="$TMP/sess"; mkdir -p "$SESS"; git init -q "$SESS"; printf '.pipeline/\n' > "$SESS/.gitignore"
written() { find "$1" -type f 2>/dev/null | wc -l | tr -d ' '; }
pathrun() { PATH="$GHBIN:$PATH" run --mode file --root "$TREE" --session-root "$SESS" "$@"; }

pathrun --issue 520
P1="$(cat "$TMP/out")"
if [ "$RC" -eq 0 ] && [ "$(wc -l < "$TMP/out" | tr -d ' ')" = "1" ] && [ -f "$P1" ] && printf '%s' "$P1" | grep -Eq '^/.*/\.pipeline/launch/[0-9a-f]{12}/#520 - Derive the run title\.js$'; then ok "mode file: one absolute path of the generated shape, the file exists"; else bad "mode file: shape ($RC $P1)"; fi
DIGEST="$(node -e 'process.stdout.write(require("crypto").createHash("sha256").update(require("fs").readFileSync(process.argv[1])).digest("hex").slice(0, 12))' "$P1")"
if [ "$(basename "$(dirname "$P1")")" = "$DIGEST" ] && grep -qx 'const LAUNCH_FILE_GENERATED = true' "$P1" && grep -qx "  name: '#520 - Derive the run title'," "$P1"; then ok "mode file: the directory is the digest of the bytes, the flag is on, the meta name is the label"; else bad "mode file: digest or flag"; fi
pathrun --issue 520
if [ "$RC" -eq 0 ] && [ "$(cat "$TMP/out")" = "$P1" ] && [ "$(written "$SESS/.pipeline")" = 1 ]; then ok "mode file: a second run prints the same path and writes no second file"; else bad "mode file: not idempotent"; fi
GH_STUB_FAIL=1 pathrun --issue 520 --brief "Issue 520: a brief line
second line"
if [ "$RC" -eq 0 ] && grep -qF '/#520 - a brief line.js' "$TMP/out"; then ok "mode file: without a REST title the label is the first line of --brief"; else bad "mode file: brief label ($(cat "$TMP/out"))"; fi
GH_STUB_FAIL=1 pathrun --issue 520
if [ "$RC" -eq 0 ] && grep -qF '/#520.js' "$TMP/out"; then ok "mode file: without a title and a brief the label is #<N>"; else bad "mode file: bare label ($(cat "$TMP/out"))"; fi
pathrun --issue 520 --brief "ignored brief"
if [ "$RC" -eq 0 ] && [ "$(cat "$TMP/out")" = "$P1" ]; then ok "mode file: the REST title wins over --brief"; else bad "mode file: title chain"; fi

# the same helper gives the hook its title: args.title equals the title part of the file name
printf '%s' "{\"cwd\":\"$TREE\",\"tool_name\":\"Workflow\",\"tool_input\":{\"scriptPath\":\"$P1\",\"args\":{\"issue\":520,\"worktreePath\":\"$TREE\",\"title\":\"typed\"}}}" > "$TMP/hook-in.json"
PATH="$GHBIN:$PATH" CLAUDE_PROJECT_DIR="$SESS" bash "$ROOT/hooks/workflow-args-expand.sh" < "$TMP/hook-in.json" > "$TMP/hook-out.json" 2>/dev/null
HOOK_TITLE="$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).hookSpecificOutput.updatedInput.args.title)' "$TMP/hook-out.json" 2>/dev/null)"
FILE_TITLE="$(basename "$P1" .js | sed 's/^#520 - //')"
if [ -n "$HOOK_TITLE" ] && [ "$HOOK_TITLE" = "$FILE_TITLE" ]; then ok "mode file: the hook derives the same title as the file name (one helper)"; else bad "mode file: hook title '$HOOK_TITLE' vs file '$FILE_TITLE'"; fi

BEFORE="$(written "$SESS/.pipeline")"
refused "mode file: a 20-digit --issue is refused" --mode file --root "$TREE" --session-root "$SESS" --issue 99999999999999999999
refused "mode file: --issue 0 is refused" --mode file --root "$TREE" --session-root "$SESS" --issue 0
refused "mode file: a missing --issue is refused" --mode file --root "$TREE" --session-root "$SESS"
refused "mode file: a relative --session-root is refused" --mode file --root "$TREE" --session-root rel/dir --issue 520
refused "mode file: --title is an unknown argument" --mode file --root "$TREE" --session-root "$SESS" --issue 520 --title x
if grep -q 'unknown argument: --title' "$TMP/err"; then ok "mode file: --title is refused as an unknown argument"; else bad "mode file: --title message"; fi
if [ "$(written "$SESS/.pipeline")" = "$BEFORE" ]; then ok "mode file: the refusals write nothing"; else bad "mode file: a refusal wrote a file"; fi

NOIGN="$TMP/noignore"; mkdir -p "$NOIGN"; git init -q "$NOIGN"
refused "mode file: a session root that does not ignore .pipeline/ is refused" --mode file --root "$TREE" --session-root "$NOIGN" --issue 520 --brief x
if grep -qF '.gitignore' "$TMP/err" && grep -qF '.pipeline/' "$TMP/err" && [ ! -e "$NOIGN/.pipeline" ]; then ok "mode file: the not-ignored message names .pipeline/ and .gitignore, nothing is written"; else bad "mode file: not-ignored message ($(cat "$TMP/err"))"; fi
cp "$TMP/err" "$TMP/err-not-ignored"
NOREPO="$TMP/norepo"; mkdir -p "$NOREPO"
GIT_CEILING_DIRECTORIES="$TMP" refused "mode file: a session root outside any repository is refused" --mode file --root "$TREE" --session-root "$NOREPO" --issue 520 --brief x
if grep -qF 'git check-ignore' "$TMP/err" && ! grep -qF '.gitignore' "$TMP/err" && ! cmp -s "$TMP/err" "$TMP/err-not-ignored" && [ ! -e "$NOREPO/.pipeline" ]; then ok "mode file: the git-failure message names git check-ignore and differs from the not-ignored one"; else bad "mode file: git-failure message ($(cat "$TMP/err"))"; fi

cp "$ROOT/workflows/deliver-pipeline.js" "$TMP/patched-engine.js"; printf '// patched-copy-marker\n' >> "$TMP/patched-engine.js"
pathrun --issue 520 --engine "$TMP/patched-engine.js"
if [ "$RC" -eq 0 ] && grep -qF 'patched-copy-marker' "$(cat "$TMP/out")" && [ "$(cat "$TMP/out")" != "$P1" ]; then ok "mode file: --engine launches a patched copy of the engine"; else bad "mode file: --engine ($RC)"; fi
printf 'console.log(1)\n' > "$TMP/not-an-engine.js"
refused "mode file: an engine source without the launch-copy shape is refused" --mode file --root "$TREE" --session-root "$SESS" --issue 520 --engine "$TMP/not-an-engine.js"
refused "mode file: a relative --engine is refused" --mode file --root "$TREE" --session-root "$SESS" --issue 520 --engine workflows/deliver-pipeline.js

STATUS=ok; [ "$FAIL" -eq 0 ] || STATUS=fail
echo "[test-launch-args] status=${STATUS} passed=${PASS} failed=${FAIL}"
[ "$FAIL" -eq 0 ]
