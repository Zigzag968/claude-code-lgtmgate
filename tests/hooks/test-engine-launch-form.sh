#!/usr/bin/env bash
# Self-test of the one-launch-form rule of hooks/workflow-args-expand.sh + scripts/runtime/workflow-args-expand.cjs (#605): the
# lgtmgate engine is launched from its generated launch file only; a call by name, an inline script that carries the engine and the
# engine source are refused with `engine-launch-form`; a launch of the generated file is accepted (digest checked, arguments
# expanded); every foreign workflow is left alone; an unexpected error on a call that is the engine's is a deny (fail closed).
# The tool_input skeletons name the Workflow tool's own input schema (script, scriptPath, name, args, resumeFromRunId; title and
# description are ignored by the tool). No payload was recorded: the Card-label replay of MAINTAINING.md re-checks them live.
# Throw-away git trees from scripts/gen-launch-fixtures.cjs in $TMPDIR (nothing is committed). bash 3.2 compatible.
# Prints `PASS: <name>` per case and a last line `[engine-form-test] passed=<n> failed=<m>`.
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
HOOK="$ROOT/hooks/workflow-args-expand.sh"
GEN="$ROOT/scripts/gen-launch-fixtures.cjs"
LA="$ROOT/scripts/runtime/launch-args.cjs"
ENGINE="$ROOT/workflows/deliver-pipeline.js"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/engine-launch-form.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
OUT="$TMP/out"; ERR="$TMP/err"; RC=0
export ERRFILE="$ERR"

# new_tree <name>: a fixture project in $TMP/<name>, .pipeline/ gitignored
new_tree() {
  node "$GEN" --tree "$TMP/$1" --size 4k >/dev/null || { echo "cannot build the fixture tree"; exit 1; }
  printf '.pipeline/\n' > "$TMP/$1/.gitignore"
}
# generated <tree> [issue]: prints the path of the launch file made by launch-args.cjs --mode file
generated() { node "$LA" --mode file --root "$1" --session-root "$1" --issue "${2:-520}" --brief "implement the issue"; }
# mk <tree> <ref|full> <js expression for tool_input over a (args) g (generated file) e (engine path)> [cwd]: writes $TMP/in.json
mk() {
  node "$LA" --root "$1" --session-root "$1" --ref origin/main --stage plan --mode "$2" --issue 520 --brief "implement the issue" > "$TMP/args.json" || exit 1
  local g; g="$(generated "$1")" || exit 1
  node -e '
const fs = require("fs")
const [tree, expr, cwd, engine, gen, file] = process.argv.slice(1, 7)
const a = JSON.parse(fs.readFileSync(process.argv[7], "utf8"))
const ti = new Function("a", "g", "e", "return (" + expr + ")")(a, gen, engine)
fs.writeFileSync(file, JSON.stringify({ cwd: cwd || tree, tool_name: "Workflow", tool_input: ti }))' "$1" "$3" "${4:-}" "$ENGINE" "$g" "$TMP/in.json" "$TMP/args.json"
}
hook() { CLAUDE_PROJECT_DIR="$1" bash "$HOOK" < "${2:-$TMP/in.json}" > "$OUT" 2> "$ERR"; RC=$?; }
jx() {
  node -e '
const fs = require("fs")
const raw = fs.readFileSync(process.argv[1], "utf8").trim()
const j = raw ? JSON.parse(raw) : null
const i = JSON.parse(fs.readFileSync(process.argv[3], "utf8"))
process.stdout.write(String(Boolean(new Function("j", "i", "require", "return (" + process.argv[2] + ")")(j, i, require))))' "$OUT" "$1" "${2:-$TMP/in.json}"
}
expect() { # expect <name> <rc> <js>
  if [ "$RC" = "$2" ] && [ "$(jx "$3")" = "true" ]; then pass "$1"; else fail "$1 (rc=$RC out=$(head -c 300 "$OUT") err=$(head -c 300 "$ERR"))"; fi
}
FORM='j.hookSpecificOutput.permissionDecision === "deny" && j.hookSpecificOutput.permissionDecisionReason.startsWith("engine-launch-form:") && j.hookSpecificOutput.permissionDecisionReason.includes("launch-args.cjs --mode file") && j.hookSpecificOutput.permissionDecisionReason.endsWith("(engine-launch-form).") && require("fs").readFileSync(process.env.ERRFILE, "utf8") === j.hookSpecificOutput.permissionDecisionReason + "\n"'
expect_form() { expect "$1" 2 "$FORM"; }
expect_silent() { if [ "$RC" = 0 ] && [ ! -s "$OUT" ]; then pass "$1"; else fail "$1 (rc=$RC out=$(head -c 300 "$OUT") err=$(head -c 300 "$ERR"))"; fi; }
launch_count() { find "$1/.pipeline/launch" -type f 2>/dev/null | wc -l | tr -d ' '; }

new_tree t1; T1="$TMP/t1"
G1="$(generated "$T1")"

# ---- the refused forms ---------------------------------------------------------------------------------------
mk "$T1" ref '{ name: "lgtmgate:deliver-pipeline", args: a }'; hook "$T1"
expect_form "engine-name-refused"
mk "$T1" ref '{ name: "lgtmgate:deliver-pipeline" }'; hook "$T1"
expect_form "engine-name-refused-no-args"
mk "$T1" full '{ name: "lgtmgate:deliver-pipeline", args: a }'; hook "$T1"
expect_form "engine-name-refused-full-form-args"
mk "$T1" ref '{ script: require("fs").readFileSync(e, "utf8"), args: a }'; hook "$T1"
expect_form "engine-inline-refused"
mk "$T1" ref '{ script: require("fs").readFileSync(g, "utf8"), args: a }'; hook "$T1"
expect_form "engine-inline-generated-copy-refused"
mk "$T1" ref '{ scriptPath: e, args: a }'; hook "$T1"
expect_form "engine-source-refused"
mkdir -p "$TMP/custom"; cp "$ENGINE" "$TMP/custom/deliver-pipeline.js"
mk "$T1" ref '{ scriptPath: "'"$TMP/custom/deliver-pipeline.js"'", args: a }'; hook "$T1"
expect_form "engine-source-copy-refused"
mkdir -p "$TMP/custom/other"; printf 'console.log("not the engine")\n' > "$TMP/custom/other/deliver-pipeline.js"
mk "$T1" ref '{ scriptPath: "'"$TMP/custom/other/deliver-pipeline.js"'", args: a }'; hook "$T1"
expect_silent "engine-named-file-without-marker-untouched"
mk "$T1" ref '{ title: "x", description: require("fs").readFileSync(e, "utf8"), args: a }'; hook "$T1"
expect_form "engine-marker-in-any-string-field-refused"

# ---- the generated file ------------------------------------------------------------------------------------
BEFORE="$(launch_count "$T1")"
mk "$T1" ref '{ scriptPath: g, args: a }'; hook "$T1"
expect "engine-generated-accepted" 0 '"config" in j.hookSpecificOutput.updatedInput.args && "projectSpecifics" in j.hookSpecificOutput.updatedInput.args && !("configRef" in j.hookSpecificOutput.updatedInput.args) && j.hookSpecificOutput.updatedInput.scriptPath === i.tool_input.scriptPath && !("name" in j.hookSpecificOutput.updatedInput) && !("permissionDecision" in j.hookSpecificOutput)'
mk "$T1" ref '{ scriptPath: g, resumeFromRunId: "wf_76786d84-860", args: a }'; hook "$T1"
expect "engine-generated-resume-accepted" 0 'j.hookSpecificOutput.updatedInput.resumeFromRunId === "wf_76786d84-860" && j.hookSpecificOutput.updatedInput.scriptPath === i.tool_input.scriptPath && "config" in j.hookSpecificOutput.updatedInput.args'
if [ "$(launch_count "$T1")" = "$BEFORE" ]; then pass "engine-generated-hook-writes-no-file"; else fail "engine-generated-hook-writes-no-file"; fi
mk "$T1" ref '{ scriptPath: g, name: "lgtmgate:deliver-pipeline", args: a }'; hook "$T1"
expect "engine-scriptpath-precedence" 0 '"config" in j.hookSpecificOutput.updatedInput.args && j.hookSpecificOutput.updatedInput.scriptPath === i.tool_input.scriptPath'
mk "$T1" full '{ scriptPath: g, args: a }'; hook "$T1"
expect_silent "engine-generated-no-reference-untouched"
mk "$T1" ref '{ scriptPath: g, args: JSON.stringify(a) }'; hook "$T1"
expect "engine-generated-args-string" 0 'typeof j.hookSpecificOutput.updatedInput.args === "string" && "projectSpecifics" in JSON.parse(j.hookSpecificOutput.updatedInput.args)'

# a file edited after it was written, and a file under the wrong digest directory
cp "$G1" "$TMP/g1.keep"; printf '\n' >> "$G1"
node -e '
const fs = require("fs")
const a = JSON.parse(fs.readFileSync(process.argv[3], "utf8"))
fs.writeFileSync(process.argv[2], JSON.stringify({ cwd: process.argv[1], tool_name: "Workflow", tool_input: { scriptPath: process.argv[4], args: a } }))' "$T1" "$TMP/tamper.json" "$TMP/args.json" "$G1"
hook "$T1" "$TMP/tamper.json"
expect "engine-generated-tamper-refused" 2 'j.hookSpecificOutput.permissionDecision === "deny" && j.hookSpecificOutput.permissionDecisionReason.startsWith("specifics-ref-mismatch:") && j.hookSpecificOutput.permissionDecisionReason.includes("'"$(basename "$G1")"'")'
cp "$TMP/g1.keep" "$G1"
mkdir -p "$T1/.pipeline/launch/0123456789ab"; cp "$G1" "$T1/.pipeline/launch/0123456789ab/$(basename "$G1")"
node -e '
const fs = require("fs")
const a = JSON.parse(fs.readFileSync(process.argv[3], "utf8"))
fs.writeFileSync(process.argv[2], JSON.stringify({ cwd: process.argv[1], tool_name: "Workflow", tool_input: { scriptPath: process.argv[4], args: a } }))' "$T1" "$TMP/wrongdir.json" "$TMP/args.json" "$T1/.pipeline/launch/0123456789ab/$(basename "$G1")"
hook "$T1" "$TMP/wrongdir.json"
expect "engine-generated-wrong-directory-digest-refused" 2 'j.hookSpecificOutput.permissionDecision === "deny" && j.hookSpecificOutput.permissionDecisionReason.startsWith("specifics-ref-mismatch:") && j.hookSpecificOutput.permissionDecisionReason.includes("'"$(basename "$G1")"'")'
mk "$T1" ref '{ scriptPath: g, args: Object.assign({}, a, { issue: 999 }) }'; hook "$T1"
expect_form "engine-generated-issue-mismatch-refused"

# ---- paths that are not the generated shape, foreign calls -----------------------------------------------------
mk "$T1" ref '{ scriptPath: "'"$TMP/custom/#999 - poc c basename.js"'", args: a }'; hook "$T1"
expect_silent "non-generated-path-untouched"
mk "$T1" ref '{ scriptPath: "'"$T1/.pipeline/launch/issue-520-0123456789ab.js"'", args: a }'; hook "$T1"
expect_silent "non-generated-legacy-name-untouched"
mk "$T1" ref '{ name: "other-plugin:workflow", args: a }'; hook "$T1"
expect_silent "foreign-untouched-other-plugin"
mk "$T1" ref '{ name: "my-saved-workflow", args: a }'; hook "$T1"
expect_silent "foreign-untouched-saved-workflow"
mk "$T1" ref '{ script: "log(1)", args: a }'; hook "$T1"
expect_silent "foreign-untouched-inline-script"
mk "$T1" ref '{ script: "log(1)", name: "lgtmgate:deliver-pipeline", args: a }'; hook "$T1"
expect_silent "foreign-inline-script-wins-over-name (the tool runs the script)"
node -e '
const body = "// filler line with words PHASE_TITLES and deliver-pipeline.js and projectSpecificsRef\n".repeat(5500)
process.stdout.write(JSON.stringify({ cwd: process.argv[1], tool_name: "Workflow", tool_input: { script: body + "log(1)\n", args: { issue: 1 } } }))' "$T1" > "$TMP/big.json"
SIZE=$(wc -c < "$TMP/big.json" | tr -d ' ')
hook "$T1" "$TMP/big.json"
if [ "$SIZE" -gt 400000 ]; then expect_silent "foreign-untouched-400kb-inline-script (${SIZE} bytes)"; else fail "foreign-untouched-400kb-inline-script (only ${SIZE} bytes)"; fi
mk "$T1" ref '{ resumeFromRunId: "wf_76786d84-860", args: a }'; hook "$T1"
expect_silent "resume-with-refs-and-no-script-identity"

# ---- foreign call that mentions the engine name, with a poisoned environment ------------------------------------
POISON='const { run } = require(process.argv[1] + "/scripts/runtime/workflow-args-expand.cjs"); const env = new Proxy({}, { get() { throw new Error("poisoned environment") } })'
node -e "$POISON"'
const raw = JSON.stringify({ cwd: "/", tool_name: "Workflow", tool_input: { name: "other:workflow", args: { brief: "see lgtmgate:deliver-pipeline and configRef", configRef: { path: "x.json" } } } })
const r = run(raw, env)
process.stdout.write(JSON.stringify(r))' "$ROOT" > "$OUT"
if [ "$(jx 'j.code === 0 && j.stdout === "" && j.stderr === ""')" = "true" ]; then pass "foreign-mentions-engine-name-untouched"; else fail "foreign-mentions-engine-name-untouched ($(head -c 300 "$OUT"))"; fi
node -e "$POISON"'
const raw = JSON.stringify({ cwd: "/", tool_name: "Workflow", tool_input: { name: "lgtmgate:deliver-pipeline", args: { issue: 1 } } })
const r = run(raw, env)
process.stdout.write(JSON.stringify(r))' "$ROOT" > "$OUT"
if [ "$(jx 'j.code === 2 && j.stdout !== "" && JSON.parse(j.stdout).hookSpecificOutput.permissionDecisionReason + "\n" === j.stderr && j.stderr.startsWith("engine-launch-form:") && j.stderr.includes("launch-args.cjs --mode file") && j.stderr.trimEnd().endsWith("(engine-launch-form).")')" = "true" ]; then pass "engine-fail-closed (a by-name call under a poisoned environment: exit 2, deny JSON, stderr text identical to the reason)"; else fail "engine-fail-closed ($(head -c 300 "$OUT"))"; fi
mk "$T1" ref '{ scriptPath: g, args: a }'
node -e "$POISON"'
const raw = require("fs").readFileSync(process.argv[2], "utf8")
const r = run(raw, env)
process.stdout.write(JSON.stringify(r))' "$ROOT" "$TMP/in.json" > "$OUT"
if [ "$(jx 'j.code === 2 && JSON.parse(j.stdout).hookSpecificOutput.permissionDecisionReason + "\n" === j.stderr && j.stderr.startsWith("specifics-ref-mismatch:")')" = "true" ]; then pass "engine-fail-closed-generated-with-references (the expansion failed unexpectedly: exit 2, identical text)"; else fail "engine-fail-closed-generated-with-references ($(head -c 300 "$OUT"))"; fi
printf '{"cwd":"/","tool_name":"Workflow","tool_input":{"name":"lgtmgate:deliver-pipeline"' > "$TMP/broken.json"
hook "$T1" "$TMP/broken.json"
expect_form "engine-unparseable-input-with-registered-name-denied"

# ---- the refusal text never echoes a value taken from the call ----------------------------------------------------
INJ="$TMP/inj"; mkdir -p "$INJ"
node -e '
const fs = require("fs")
const args = { issue: "5; touch pwned2", brief: "a\"b`touch pwned3`$(touch pwned4)", worktreePath: "/x$(touch pwned)", sessionRoot: "/y\"; touch pwned5", configRef: { path: "x.json" } }
fs.writeFileSync(process.argv[2], JSON.stringify({ cwd: process.argv[1], tool_name: "Workflow", tool_input: { name: "lgtmgate:deliver-pipeline", args } }))' "$INJ" "$TMP/inj.json"
( cd "$INJ" && CLAUDE_PROJECT_DIR='/z$(touch pwned6)' bash "$HOOK" < "$TMP/inj.json" > "$OUT" 2> "$ERR"; echo $? > "$TMP/inj.rc" )
RC="$(cat "$TMP/inj.rc")"
REASON="$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).hookSpecificOutput.permissionDecisionReason)' "$OUT")"
if [ "$RC" = 2 ] && [ -z "$(find "$INJ" -name 'pwned*')" ] && printf '%s' "$REASON" | grep -qF -- '--issue <N> --root <worktree> --session-root <project>' && ! printf '%s' "$REASON" | grep -qE 'touch|pwned' && [ "$(printf '%s' "$REASON" | tr -cd '`$' | wc -c | tr -d ' ')" = 0 ] && [ "$(printf '%s' "$REASON" | tr -cd '"' | wc -c | tr -d ' ')" = 2 ]; then pass "deny-message-no-injection (placeholders for an unsafe issue and paths, no brief, no \$ or backtick, no file created)"; else fail "deny-message-no-injection (rc=$RC reason=$REASON)"; fi
node -e '
const fs = require("fs")
const args = { issue: 520, worktreePath: "/Users/dev/wt/issue-520", sessionRoot: "/Users/dev/project", configRef: { path: "x.json" } }
fs.writeFileSync(process.argv[2], JSON.stringify({ cwd: "/", tool_name: "Workflow", tool_input: { name: "lgtmgate:deliver-pipeline", args } }))' "$INJ" "$TMP/safe.json"
hook "$INJ" "$TMP/safe.json"
expect "deny-message-safe-values-are-printed" 2 'j.hookSpecificOutput.permissionDecisionReason.includes("--issue 520 --root /Users/dev/wt/issue-520 --session-root /Users/dev/project --brief")'

# ---- a relative scriptPath is resolved against the hook cwd ----------------------------------------------------------
REL=".pipeline/launch/$(basename "$(dirname "$G1")")/$(basename "$G1")"
printf '\n' >> "$G1"
node -e '
const fs = require("fs")
const a = JSON.parse(fs.readFileSync(process.argv[4], "utf8"))
fs.writeFileSync(process.argv[2], JSON.stringify({ cwd: process.argv[1], tool_name: "Workflow", tool_input: { scriptPath: process.argv[3], args: a } }))' "$T1" "$TMP/rel-match.json" "$REL" "$TMP/args.json"
hook "$T1" "$TMP/rel-match.json"
expect "relative-path-resolved-against-cwd (a tampered file is denied when cwd matches)" 2 'j.hookSpecificOutput.permissionDecisionReason.startsWith("specifics-ref-mismatch:")'
cp "$TMP/g1.keep" "$G1"
mkdir -p "$TMP/elsewhere"
node -e '
const fs = require("fs")
const a = JSON.parse(fs.readFileSync(process.argv[4], "utf8"))
fs.writeFileSync(process.argv[2], JSON.stringify({ cwd: process.argv[1], tool_name: "Workflow", tool_input: { scriptPath: process.argv[3], args: a } }))' "$TMP/elsewhere" "$TMP/rel-miss.json" "$REL" "$TMP/args.json"
hook "$T1" "$TMP/rel-miss.json"
expect "relative-path-cwd-mismatch-fails-open (arguments expanded, no refusal)" 0 '"config" in j.hookSpecificOutput.updatedInput.args && !("permissionDecision" in j.hookSpecificOutput)'
hook "$T1" "$TMP/rel-match.json"
expect "relative-path-resolved-against-cwd-accepted-when-intact" 0 '"config" in j.hookSpecificOutput.updatedInput.args && j.hookSpecificOutput.updatedInput.scriptPath === "'"$REL"'"'

# ---- title drift advisory (only a title derived from the issue) ---------------------------------------------------------
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
new_tree d1; D1="$TMP/d1"; git -C "$D1" remote add origin https://github.com/acme/widgets.git
DG="$(PATH="$GHBIN:$PATH" generated "$D1")"
mkd() { # mkd <js args edit>: a launch of $DG carrying a title (so the hook derives), worktree D1
  node -e '
const fs = require("fs")
const a = { issue: 520, worktreePath: process.argv[1], sessionRoot: process.argv[1], title: "typed title", brief: "x" }
fs.writeFileSync(process.argv[3], JSON.stringify({ cwd: process.argv[1], tool_name: "Workflow", tool_input: { scriptPath: process.argv[2], args: a } }))' "$D1" "$DG" "$TMP/drift.json"
}
mkd
PATH="$GHBIN:$PATH" hook "$D1" "$TMP/drift.json"
if [ "$RC" = 0 ] && [ "$(jx '!("additionalContext" in j.hookSpecificOutput) && j.hookSpecificOutput.updatedInput.args.title === "Derive the run title"' "$TMP/drift.json")" = "true" ]; then pass "drift-advisory-derived-title-equal-no-advisory"; else fail "drift-advisory-derived-title-equal-no-advisory (rc=$RC $(head -c 300 "$OUT"))"; fi
GH_STUB_TITLE="A newer issue title" PATH="$GHBIN:$PATH" hook "$D1" "$TMP/drift.json"
if [ "$RC" = 0 ] && [ "$(jx 'j.hookSpecificOutput.additionalContext.includes("Advisory: the launch file label reads \"#520 - Derive the run title\" but the issue title reads \"A newer issue title\" now") && j.hookSpecificOutput.additionalContext.includes("--mode file") && !("permissionDecision" in j.hookSpecificOutput)' "$TMP/drift.json")" = "true" ]; then pass "drift-advisory-derived-title-differs"; else fail "drift-advisory-derived-title-differs (rc=$RC $(head -c 300 "$OUT"))"; fi
GH_STUB_FAIL=1 PATH="$GHBIN:$PATH" hook "$D1" "$TMP/drift.json"
if [ "$RC" = 0 ] && [ "$(jx '!("additionalContext" in j.hookSpecificOutput) && j.hookSpecificOutput.updatedInput.args.title === "typed title"' "$TMP/drift.json")" = "true" ]; then pass "drift-advisory-derived-title-only (a typed title is never compared, no advisory without a derived title)"; else fail "drift-advisory-derived-title-only (rc=$RC $(head -c 300 "$OUT"))"; fi

# ---- end to end: the file printed by launch-args.cjs --mode file, through the real hook ---------------------------------
new_tree e1; E1="$TMP/e1"
E2E_FILE="$(generated "$E1")"
node "$LA" --root "$E1" --session-root "$E1" --ref origin/main --stage plan --mode ref --issue 520 --brief "implement the issue" > "$TMP/e2e-args.json"
node -e '
const fs = require("fs")
const a = JSON.parse(fs.readFileSync(process.argv[3], "utf8"))
fs.writeFileSync(process.argv[4], JSON.stringify({ cwd: process.argv[1], tool_name: "Workflow", tool_input: { scriptPath: process.argv[2], args: a } }))
fs.writeFileSync(process.argv[5], JSON.stringify({ cwd: process.argv[1], tool_name: "Workflow", tool_input: { name: "lgtmgate:deliver-pipeline", args: a } }))' "$E1" "$E2E_FILE" "$TMP/e2e-args.json" "$TMP/e2e-path.json" "$TMP/e2e-name.json"
hook "$E1" "$TMP/e2e-path.json"
echo "  end-to-end scriptPath payload -> exit $RC: $(head -c 200 "$OUT")"
expect "engine-end-to-end-generated-accepted" 0 '"config" in j.hookSpecificOutput.updatedInput.args && "projectSpecifics" in j.hookSpecificOutput.updatedInput.args && j.hookSpecificOutput.updatedInput.scriptPath === "'"$E2E_FILE"'"' 
hook "$E1" "$TMP/e2e-name.json"
echo "  end-to-end name payload -> exit $RC: $(head -c 300 "$OUT")"
expect "engine-end-to-end-name-refused" 2 'j.hookSpecificOutput.permissionDecisionReason.startsWith("engine-launch-form:")'

echo "[engine-form-test] passed=${PASS} failed=${FAIL}"
[ "$FAIL" -eq 0 ]
