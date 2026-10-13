#!/usr/bin/env bash
# Self-test of hooks/workflow-args-expand.sh + scripts/runtime/workflow-args-expand.cjs (#520): the PreToolUse(Workflow) hook that
# expands `projectSpecificsRef` / `configRef` to the full objects and gives a launch of the engine a copy titled with the issue
# number under .pipeline/launch/. Throw-away git trees come from scripts/gen-launch-fixtures.cjs in $TMPDIR (nothing is committed).
# The tool_input skeletons are the three shapes observed in real Workflow calls (launch by name, launch by scriptPath, resume).
# bash 3.2 compatible. Prints `PASS: <name>` per case and a last line `[hook-test] passed=<n> failed=<m>`.
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
HOOK="$ROOT/hooks/workflow-args-expand.sh"
GEN="$ROOT/scripts/gen-launch-fixtures.cjs"
LA="$ROOT/scripts/runtime/launch-args.cjs"
AC="$ROOT/scripts/runtime/agent-context.cjs"
CLEAN="$ROOT/scripts/runtime/clean-launch-files.cjs"
ENGINE="$ROOT/workflows/deliver-pipeline.js"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/workflow-args-expand.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
OUT="$TMP/out"; ERR="$TMP/err"; RC=0

# new_tree <name> [ignore]: a fixture project in $TMP/<name>; with `ignore`, .pipeline/ is gitignored there
new_tree() {
  node "$GEN" --tree "$TMP/$1" --size 4k >/dev/null || { echo "cannot build the fixture tree"; exit 1; }
  if [ "${2:-}" = "ignore" ]; then printf '.pipeline/\n' > "$TMP/$1/.gitignore"; fi
}
# mk_input <tree> <kind: name|path|resume> <mode: ref|full> [extra-js]: writes $TMP/in.json for the tree
mk_input() {
  node "$LA" --root "$1" --ref origin/main --stage plan --mode "$3" --issue 520 --brief "implement the issue" > "$TMP/args.json" || exit 1
  node -e '
const fs = require("fs")
const [tree, kind, engine, file] = process.argv.slice(1, 5)
const args = JSON.parse(fs.readFileSync(process.argv[5], "utf8"))
const extra = process.argv[6] ? new Function("a", "ti", process.argv[6]) : null
const shapes = {
  name: { name: "lgtmgate:deliver-pipeline", args },
  path: { scriptPath: engine, args },
  resume: { scriptPath: engine, resumeFromRunId: "wf_76786d84-860", args },
}
const ti = shapes[kind]
if (extra) extra(args, ti)
fs.writeFileSync(file, JSON.stringify({ cwd: tree, tool_name: "Workflow", tool_input: ti }))' "$1" "$2" "$ENGINE" "$TMP/in.json" "$TMP/args.json" "${4:-}"
}
# hook <tree> [input-file]: runs the hook on the input; stdout in $OUT, stderr in $ERR, exit code in $RC
hook() {
  CLAUDE_PROJECT_DIR="$1" bash "$HOOK" < "${2:-$TMP/in.json}" > "$OUT" 2> "$ERR"; RC=$?
}
# jx <expr>: true/false for a JS expression over j (the parsed stdout) and i (the input file)
jx() {
  node -e '
const fs = require("fs")
const j = fs.readFileSync(process.argv[1], "utf8").trim() ? JSON.parse(fs.readFileSync(process.argv[1], "utf8")) : null
const i = JSON.parse(fs.readFileSync(process.argv[3], "utf8"))
process.stdout.write(String(Boolean(new Function("j", "i", "require", "return (" + process.argv[2] + ")")(j, i, require))))' "$OUT" "$1" "${2:-$TMP/in.json}"
}
expect() { # expect <name> <rc> <js>
  if [ "$RC" = "$2" ] && [ "$(jx "$3")" = "true" ]; then pass "$1"; else fail "$1 (rc=$RC out=$(head -c 300 "$OUT") err=$(head -c 300 "$ERR"))"; fi
}
expect_deny() { # expect_deny <name> [needle]
  if [ "$RC" = 2 ] && [ "$(jx 'j.hookSpecificOutput.permissionDecision === "deny" && j.hookSpecificOutput.permissionDecisionReason.startsWith("specifics-ref-mismatch:")')" = "true" ] && [ -s "$ERR" ] && { [ -z "${2:-}" ] || grep -qF -- "$2" "$OUT"; }; then pass "$1"; else fail "$1 (rc=$RC out=$(head -c 300 "$OUT"))"; fi
}
launch_files() { local n=0 f; for f in "$1"/.pipeline/launch/issue-520-*.js; do [ -e "$f" ] && n=$((n+1)); done; echo "$n"; }

# ---- expansion ---------------------------------------------------------------------------------
new_tree t1 ignore; T1="$TMP/t1"
mk_input "$T1" path ref; hook "$T1"
REFSHA="$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).tool_input.args.projectSpecificsRef.refSha)' "$TMP/in.json")"
node "$AC" --root "$T1" --sha "$REFSHA" --local "$T1/.claude/pipeline.config.local.json" > "$TMP/assembled.json"
cp "$TMP/in.json" "$TMP/in-ref.json"
node -e '
const fs = require("fs")
const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))
const u = j.hookSpecificOutput.updatedInput.args
const assembled = fs.readFileSync(process.argv[2], "utf8").trim()
const config = JSON.parse(fs.readFileSync(process.argv[3] + "/.claude/pipeline.config.json", "utf8"))
const keys = Object.keys(u)
const ok = JSON.stringify(u.projectSpecifics) === assembled && JSON.stringify(u.config) === JSON.stringify(config)
  && !("projectSpecificsRef" in u) && !("configRef" in u) && !("permissionDecision" in j.hookSpecificOutput)
  && keys.indexOf("config") < keys.indexOf("configLocal") && keys.indexOf("projectSpecifics") < keys.indexOf("pluginRoot")
process.exit(ok ? 0 : 1)' "$OUT" "$TMP/assembled.json" "$T1"
NR=$?
if [ "$NR" -eq 0 ] && [ "$RC" = 0 ]; then PASS=$((PASS+1)); echo "PASS: expand-match (deep-equal to the assembler stdout and the config file, key order kept)"; else fail "expand-match (rc=$RC)"; fi

# a tampered fingerprint, a stale sha, a digest mismatch
mk_input "$T1" path ref 'a.projectSpecificsRef.fp12 = a.projectSpecificsRef.fp12.replace(/^./, (c) => (c === "0" ? "1" : "0"))'; hook "$T1"
expect_deny "deny-fingerprint"
mk_input "$T1" path ref 'a.projectSpecificsRef.refSha = "0000000000000000000000000000000000000001"'; hook "$T1"
expect_deny "deny-stale-sha"
mk_input "$T1" path ref 'a.configRef.digest64 = a.configRef.digest64.replace(/^./, (c) => (c === "0" ? "1" : "0"))'; hook "$T1"
expect_deny "deny-config-digest"
mk_input "$T1" path ref 'a.configRef.path = "../outside.json"'; hook "$T1"
expect_deny "deny-config-path-outside"
mk_input "$T1" path ref 'a.config = {}'; hook "$T1"
expect_deny "deny-both-config-and-ref"
mkdir -p "$TMP/other" && git init -q "$TMP/other"
mk_input "$T1" path ref "a.worktreePath = \"$TMP/other\""; hook "$T1"
expect_deny "deny-foreign-worktree"
if ! grep -Eq 'Sam|Nick|Morgan|Theo|Mia' "$OUT"; then pass "deny-names-no-role"; else fail "deny-names-no-role"; fi

# ---- planRef (#533): the plan artifact read back, the digest the engine pinned -----------------------------
expect_plan_deny() { # expect_plan_deny <name> [needle]
  if [ "$RC" = 2 ] && [ "$(jx 'j.hookSpecificOutput.permissionDecision === "deny" && j.hookSpecificOutput.permissionDecisionReason.startsWith("plan-ref-mismatch:") && j.hookSpecificOutput.permissionDecisionReason.includes("docs/consumer-reference.md (plan-ref-mismatch)")')" = "true" ] && [ -s "$ERR" ] && { [ -z "${2:-}" ] || grep -qF -- "$2" "$OUT"; }; then pass "$1"; else fail "$1 (rc=$RC out=$(head -c 300 "$OUT"))"; fi
}
mkdir -p "$T1/.pipeline/plans"; PLAN_FILE="$T1/.pipeline/plans/issue-520-sam.md"
printf '# Plan\n\n- [ ] <!-- ac:1 --> **ac:1** proof with an accent: caf\xc3\xa9\n- [ ] <!-- ac:2 --> second\n' > "$PLAN_FILE"
PLAN_DIGEST="$(node -e 'process.stdout.write(require("crypto").createHash("sha256").update(require("fs").readFileSync(process.argv[1])).digest("hex"))' "$PLAN_FILE")"
mk_input "$T1" path ref "a.entryStage = 'dev'; a.planRef = { issue: 520, digest: '$PLAN_DIGEST', targets: ['a/b.js'], designStep: true, lanes: ['x'] }"; hook "$T1"
expect "expand-plan-equals-artifact" 0 'j.hookSpecificOutput.updatedInput.args.planText === require("fs").readFileSync("'"$PLAN_FILE"'", "utf8")'
expect "expand-plan-keeps-planref-and-adds-no-script-line" 0 'JSON.stringify(j.hookSpecificOutput.updatedInput.args.planRef) === JSON.stringify(i.tool_input.args.planRef) && Object.keys(j.hookSpecificOutput.updatedInput.args).indexOf("planText") === Object.keys(j.hookSpecificOutput.updatedInput.args).indexOf("planRef") + 1 && !/^(targetFiles|design-step|lanes):/mi.test(j.hookSpecificOutput.updatedInput.args.planText)'
printf 'x' >> "$PLAN_FILE"
hook "$T1"
expect_plan_deny "deny-plan-ref-mismatch-byte" "plan-ref-mismatch"
if ! grep -q 'caf' "$OUT"; then pass "deny-plan-names-no-plan-text"; else fail "deny-plan-names-no-plan-text"; fi
new_tree t6 ignore; T6="$TMP/t6"
mk_input "$T6" path ref "a.entryStage = 'dev'; a.planRef = { issue: 520, digest: '$PLAN_DIGEST' }"; hook "$T6"
expect_plan_deny "deny-plan-ref-missing-artifact" "plan-ref-mismatch"
mk_input "$T1" path ref "a.entryStage = 'dev'; a.planRef = { issue: 521, digest: '$PLAN_DIGEST' }"; hook "$T1"
expect_plan_deny "deny-plan-ref-issue-mismatch" "plan-ref-mismatch"
mk_input "$T1" path ref "a.entryStage = 'dev'; a.planText = 'typed'; a.planRef = { issue: 520, digest: '$PLAN_DIGEST' }"; hook "$T1"
expect_plan_deny "deny-both-plantext-and-planref" "plan-ref-mismatch"

# ---- calls that are not ours ----------------------------------------------------------------------
mk_input "$T1" path full; hook "$T1"
if [ "$RC" = 0 ] && [ ! -s "$OUT" ]; then pass "pass-no-reference"; else fail "pass-no-reference (rc=$RC)"; fi
printf '{"cwd":"%s","tool_name":"Workflow","tool_input":{"name":"other:workflow","args":{"issue":1}}}' "$T1" > "$TMP/foreign.json"
START=$(node -e 'process.stdout.write(String(Date.now()))')
hook "$T1" "$TMP/foreign.json"
END=$(node -e 'process.stdout.write(String(Date.now()))')
ELAPSED=$((END - START))
# the two node starts above cost about 40 ms each; the hook itself is a plain bash string match
if [ "$RC" = 0 ] && [ ! -s "$OUT" ] && [ "$ELAPSED" -lt 250 ]; then pass "foreign-call (empty stdout, exit 0, ${ELAPSED} ms including two probe starts)"; else fail "foreign-call (rc=$RC ${ELAPSED} ms)"; fi
START=$(node -e 'process.stdout.write(String(Date.now()))')
START2=$(node -e 'process.stdout.write(String(Date.now()))')
BASELINE=$((START2 - START))
START=$(node -e 'process.stdout.write(String(Date.now()))')
CLAUDE_PROJECT_DIR="$T1" bash "$HOOK" < "$TMP/foreign.json" > "$OUT" 2>&1
HOOK_MS=$(( $(node -e 'process.stdout.write(String(Date.now()))') - START - BASELINE ))
if [ "$HOOK_MS" -lt 100 ]; then pass "foreign-call-under-100ms (${HOOK_MS} ms net of one node start)"; else fail "foreign-call-under-100ms (${HOOK_MS} ms)"; fi
printf '{"cwd":"%s","tool_name":"Workflow","tool_input":{"name":"other:workflow","args":{"configRef":{"path":"x.json"}}}}' "$T1" > "$TMP/foreign2.json"
hook "$T1" "$TMP/foreign2.json"
if [ "$RC" = 0 ] && [ ! -s "$OUT" ]; then pass "foreign-call-with-reference-words (another workflow is never touched)"; else fail "foreign-call-with-reference-words (rc=$RC)"; fi

# ---- args as a JSON string, preserved fields ----------------------------------------------------------
mk_input "$T1" path ref 'ti.args = JSON.stringify(ti.args)'; hook "$T1"
expect "args-string" 0 'typeof j.hookSpecificOutput.updatedInput.args === "string" && JSON.parse(j.hookSpecificOutput.updatedInput.args).config.baseBranch !== undefined && "projectSpecifics" in JSON.parse(j.hookSpecificOutput.updatedInput.args)'
new_tree t2; T2="$TMP/t2" # not ignored: the engine named by the call is kept
mk_input "$T2" name ref 'ti.extra = { keep: 1 }'; hook "$T2"
expect "preserve-fields-name" 0 'j.hookSpecificOutput.updatedInput.name === "lgtmgate:deliver-pipeline" && !("scriptPath" in j.hookSpecificOutput.updatedInput) && j.hookSpecificOutput.updatedInput.extra.keep === 1'
mk_input "$T2" path ref; hook "$T2"
expect "preserve-fields-scriptpath" 0 'j.hookSpecificOutput.updatedInput.scriptPath === i.tool_input.scriptPath && !("name" in j.hookSpecificOutput.updatedInput)'
mk_input "$T2" resume ref; hook "$T2"
expect "preserve-fields-resume" 0 'j.hookSpecificOutput.updatedInput.resumeFromRunId === "wf_76786d84-860" && j.hookSpecificOutput.updatedInput.scriptPath === i.tool_input.scriptPath'
if [ "$(launch_files "$T2")" = 0 ] && [ ! -d "$T2/.pipeline/launch" ]; then pass "launch-not-ignored (keeps the engine, expands the arguments, writes no file)"; else fail "launch-not-ignored (a file was written)"; fi
expect "launch-not-ignored-args-expanded" 0 '"config" in j.hookSpecificOutput.updatedInput.args && "projectSpecifics" in j.hookSpecificOutput.updatedInput.args'

# ---- the launch file ---------------------------------------------------------------------------------
new_tree t3 ignore; T3="$TMP/t3"
mk_input "$T3" name ref; hook "$T3"
GEN1="$(node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(j.hookSpecificOutput.updatedInput.scriptPath||"")' "$OUT")"
if [ -n "$GEN1" ] && [ -f "$GEN1" ] && [ "$(jx '!("name" in j.hookSpecificOutput.updatedInput) && /\/\.pipeline\/launch\/issue-520-[0-9a-f]{12}\.js$/.test(j.hookSpecificOutput.updatedInput.scriptPath)')" = "true" ]; then pass "launch-named (replaced by a scriptPath under .pipeline/launch/, no name)"; else fail "launch-named ($GEN1)"; fi
node -e '
const fs = require("fs")
const a = fs.readFileSync(process.argv[1], "utf8").split("\n")
const b = fs.readFileSync(process.argv[2], "utf8").split("\n")
if (a.length !== b.length) process.exit(1)
const changed = []
for (let k = 0; k < a.length; k++) if (a[k] !== b[k]) changed.push(k)
const inMeta = (k) => k < 12
const constant = (k) => a[k].startsWith("const PHASE_TITLES = ")
const ok = changed.length === 8 && changed.every((k) => inMeta(k) || constant(k)) && changed.filter(constant).length === 1
process.exit(ok ? 0 : 1)' "$ENGINE" "$GEN1"
NR=$?
if [ "$NR" -eq 0 ]; then pass "launch-diff-only-titles (8 lines: name, description, 5 titles, PHASE_TITLES)"; else fail "launch-diff-only-titles"; fi
hook "$T3"
SECOND="$(node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(j.hookSpecificOutput.updatedInput.scriptPath||"")' "$OUT")"
if [ "$SECOND" = "$GEN1" ] && [ "$(launch_files "$T3")" = 1 ]; then pass "launch-reuse (second call, same path, one file)"; else fail "launch-reuse ($SECOND vs $GEN1)"; fi
# a resume that re-passes the generated path
mk_input "$T3" resume ref "ti.scriptPath = \"$GEN1\""; hook "$T3"
if [ "$RC" = 0 ] && [ "$(jx "j.hookSpecificOutput.updatedInput.scriptPath === \"$GEN1\" && j.hookSpecificOutput.updatedInput.resumeFromRunId === \"wf_76786d84-860\"")" = "true" ] && [ "$(launch_files "$T3")" = 1 ]; then pass "resume-generated-path-idempotent"; else fail "resume-generated-path-idempotent (rc=$RC $(head -c 300 "$OUT"))"; fi
# one extra byte
printf '\n' >> "$GEN1"
mk_input "$T3" name ref; hook "$T3"
expect_deny "launch-tamper-denied" "$(basename "$GEN1")"
mk_input "$T3" resume ref "ti.scriptPath = \"$GEN1\""; hook "$T3"
expect_deny "resume-tamper-denied" "$(basename "$GEN1")"

# a scriptPath given by the call is the source, not the plugin cache
new_tree t4 ignore; T4="$TMP/t4"
mkdir -p "$TMP/custom"; cp "$ENGINE" "$TMP/custom/deliver-pipeline.js"; printf '// custom-source-marker\n' >> "$TMP/custom/deliver-pipeline.js"
mk_input "$T4" path ref "ti.scriptPath = \"$TMP/custom/deliver-pipeline.js\""; hook "$T4"
GEN4="$(node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(j.hookSpecificOutput.updatedInput.scriptPath||"")' "$OUT")"
if [ -n "$GEN4" ] && [ -f "$GEN4" ] && grep -q 'custom-source-marker' "$GEN4" && [ "$GEN4" != "$GEN1" ]; then pass "launch-from-scriptpath (copied from the given path)"; else fail "launch-from-scriptpath ($GEN4)"; fi

# ---- title cap and prefix rule (same rule as scripts/guards.cjs checkPhaseTitles) --------------------------
node -e '
const fs = require("fs")
const { retitle } = require(process.argv[1] + "/scripts/lib/launch-file.cjs")
const source = fs.readFileSync(process.argv[1] + "/workflows/deliver-pipeline.js", "utf8")
let ok = true
for (const n of [1, 520, 99999]) {
  const out = retitle(source, n)
  if (out === null) { ok = false; continue }
  const titles = [...out.slice(0, out.indexOf("\n}\n")).matchAll(/\{ title: \x27([^\x27]*)\x27/g)].map((m) => m[1])
  const dynamic = [titles[2] + " 2", titles[4] + " 99"]
  if (titles.length !== 5 || [...titles, ...dynamic].some((t) => [...t].length > 16)) ok = false
  for (let a = 0; a < titles.length; a++) for (let b = a + 1; b < titles.length; b++) {
    const [s, l] = titles[a].length <= titles[b].length ? [titles[a], titles[b]] : [titles[b], titles[a]]
    if (l.toLowerCase().startsWith(s.toLowerCase())) ok = false
  }
  if (retitle(out, n) !== out) ok = false
}
if (retitle(source, 123456) !== null) ok = false
if (retitle(source.replace("title: \x27Dev\x27", "title: \x27Develop\x27"), 1) !== null) ok = false
process.exit(ok ? 0 : 1)' "$ROOT"
NR=$?
if [ "$NR" -eq 0 ]; then pass "title-cap-and-prefix (idempotent, <= 16 characters, none a prefix; a six-digit issue keeps the plain names)"; else fail "title-cap-and-prefix"; fi
new_tree t5 ignore; T5="$TMP/t5"
node "$LA" --root "$T5" --ref origin/main --stage plan --mode ref --issue 1234567 --brief x > "$TMP/args.json"
node -e 'const fs=require("fs");fs.writeFileSync(process.argv[2],JSON.stringify({cwd:process.argv[1],tool_name:"Workflow",tool_input:{name:"lgtmgate:deliver-pipeline",args:JSON.parse(fs.readFileSync(process.argv[3],"utf8"))}}))' "$T5" "$TMP/in.json" "$TMP/args.json"
hook "$T5"
expect "title-too-long-keeps-name" 0 'j.hookSpecificOutput.updatedInput.name === "lgtmgate:deliver-pipeline" && !("scriptPath" in j.hookSpecificOutput.updatedInput) && "config" in j.hookSpecificOutput.updatedInput.args'

# ---- advisory ------------------------------------------------------------------------------------------
mk_input "$T1" path ref 'a.brief = "x".repeat(701)'; hook "$T1"
expect "advisory-over" 0 'typeof j.hookSpecificOutput.additionalContext === "string" && j.hookSpecificOutput.additionalContext.includes("701") && !("permissionDecision" in j.hookSpecificOutput)'
mk_input "$T1" path ref 'a.brief = "x".repeat(700)'; hook "$T1"
expect "advisory-under" 0 '!("additionalContext" in j.hookSpecificOutput)'

# ---- run state (#545): title, derived merged/epic, parallel advisory -----------------------------------
expect_deny_code() { # expect_deny_code <name> <code> [needle]
  if [ "$RC" = 2 ] && [ "$(jx "j.hookSpecificOutput.permissionDecision === 'deny' && j.hookSpecificOutput.permissionDecisionReason.startsWith('$2:') && j.hookSpecificOutput.permissionDecisionReason.includes('docs/consumer-reference.md ($2)')")" = "true" ] && [ -s "$ERR" ] && { [ -z "${3:-}" ] || grep -qF -- "$3" "$OUT"; }; then pass "$1"; else fail "$1 (rc=$RC out=$(head -c 300 "$OUT"))"; fi
}
script_of() { node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).hookSpecificOutput.updatedInput.scriptPath || "")' "$OUT"; }
new_tree rs1 ignore; RS1="$TMP/rs1"
mk_input "$RS1" name ref 'a.title = "Fast launches"'; hook "$RS1"
expect "run-state-title-named-launch" 0 'j.hookSpecificOutput.updatedInput.scriptPath.includes("/.pipeline/launch/issue-520-") && !("name" in j.hookSpecificOutput.updatedInput) && j.hookSpecificOutput.updatedInput.args.title === "Fast launches"'
RS1_FILE="$(script_of)"
if grep -qF "  name: 'deliver-pipeline #520 Fast launches'," "$RS1_FILE" && grep -qF "  description: '#520 Fast launches: Sam (plan)" "$RS1_FILE"; then pass "run-state-title-in-name-and-description"; else fail "run-state-title-in-name-and-description"; fi
if [ "$(grep -F '{ title:' "$RS1_FILE" | grep -c 'Fast launches')" = 0 ] && grep -qF "{ title: '#520 Setup'" "$RS1_FILE" && grep -qF "const PHASE_TITLES = { setup: '#520 Setup', diagnose: '#520 Diagnose', plan: '#520 Plan', dev: '#520 Dev', review: '#520 Review' }" "$RS1_FILE"; then pass "run-state-title-phases-number-only"; else fail "run-state-title-phases-number-only"; fi
mk_input "$RS1" name ref 'a.title = "it'"'"'s a \\ title"'; hook "$RS1"
RS1_Q="$(script_of)"; cp "$RS1_Q" "$TMP/quote.js"
if [ -n "$RS1_Q" ] && node --check "$TMP/quote.js" 2>/dev/null; then pass "run-state-title-escapes-quote (valid JS with a quote and a backslash)"; else fail "run-state-title-escapes-quote"; fi
mk_input "$RS1" name ref 'a.title = "Fast launches"'; hook "$RS1"; FIRST="$(script_of)"
mk_input "$RS1" path ref 'a.title = "Fast launches"; ti.scriptPath = "'"$FIRST"'"'; hook "$RS1"; SECOND="$(script_of)"
mk_input "$RS1" path ref 'a.title = "Other words"; ti.scriptPath = "'"$FIRST"'"'; hook "$RS1"; THIRD="$(script_of)"
mk_input "$RS1" name ref 'a.title = "Other words"'; hook "$RS1"; DIRECT="$(script_of)"
if [ -n "$FIRST" ] && [ "$FIRST" = "$SECOND" ] && [ -n "$THIRD" ] && [ "$THIRD" != "$FIRST" ] && [ "$THIRD" = "$DIRECT" ] && [ "$RC" = 0 ]; then pass "run-state-title-idempotent (same title keeps the file, another title from a generated file equals a fresh launch)"; else fail "run-state-title-idempotent ($FIRST $SECOND $THIRD $DIRECT)"; fi
mk_input "$RS1" name ref 'a.title = "x".repeat(81)'; hook "$RS1"
expect_deny_code "run-state-title-deny-length" "launch-argument-invalid" "81 bytes"
mk_input "$RS1" name ref 'a.title = "two\nlines"'; hook "$RS1"
expect_deny_code "run-state-title-deny-newline" "launch-argument-invalid" "newline"

GHBIN="$TMP/ghbin"; mkdir -p "$GHBIN"
cat > "$GHBIN/gh" <<'STUB'
#!/usr/bin/env bash
case "$2" in
  repos/acme/widgets/issues/520) echo '{"number":520,"state":"open","body":"x\ndepends-on: #530, #531, #532\n"}' ;;
  repos/acme/widgets/issues/530|repos/acme/widgets/issues/531|repos/acme/widgets/issues/532) echo '{"state":"closed","state_reason":"completed"}' ;;
  repos/acme/widgets/issues/520/parent) echo '{"number":528}' ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$GHBIN/gh"
new_tree rs2 ignore; RS2="$TMP/rs2"; git -C "$RS2" remote add origin https://github.com/acme/widgets.git
mk_input "$RS2" name ref; PATH="$GHBIN:$PATH" hook "$RS2"
expect "run-state-merged-derived" 0 'JSON.stringify(j.hookSpecificOutput.updatedInput.args.merged) === "[530,531,532]" && j.hookSpecificOutput.updatedInput.args.epic === 528'
mk_input "$RS2" name ref 'a.merged = [1, 2]; a.epic = 9'; PATH="$GHBIN:$PATH" hook "$RS2"
expect "run-state-merged-overwrites-typed" 0 'JSON.stringify(j.hookSpecificOutput.updatedInput.args.merged) === "[530,531,532]" && j.hookSpecificOutput.updatedInput.args.epic === 528'
mk_input "$RS1" name ref 'a.merged = [1, 2]; a.epic = 9'; PATH="$GHBIN:$PATH" hook "$RS1"
expect "run-state-merged-typed-dropped-without-repo (no origin, no config.repo: no derived key, the typed ones are gone)" 0 '!("merged" in j.hookSpecificOutput.updatedInput.args) && !("epic" in j.hookSpecificOutput.updatedInput.args)'

mkdir -p "$RS1/.pipeline"; printf '{"status":"dev"}\n' > "$RS1/.pipeline/issue-777.json"
mk_input "$RS1" name ref 'a.parallel = [888]'; hook "$RS1"
expect "run-state-parallel-advisory (an active run missing from parallel and a listed number with no active run)" 0 '/#777/.test(j.hookSpecificOutput.additionalContext) && /#888/.test(j.hookSpecificOutput.additionalContext) && !("permissionDecision" in j.hookSpecificOutput)'
mk_input "$RS1" name ref 'a.parallel = [777]'; hook "$RS1"
expect "run-state-parallel-consistent-no-advisory" 0 '!("additionalContext" in j.hookSpecificOutput)'

# ---- cleanup -----------------------------------------------------------------------------------------
C="$TMP/clean"; mkdir -p "$C/.pipeline/launch"
printf 'a' > "$C/.pipeline/launch/issue-5-aaaaaaaaaaaa.js"; printf 'b' > "$C/.pipeline/launch/issue-6-bbbbbbbbbbbb.js"
printf 'k' > "$C/.pipeline/launch/keep.txt"; printf 'o' > "$C/.pipeline/other.txt"
OUTC="$(node "$CLEAN" --root "$C" --issue 5)"
if [ "$OUTC" = "removed 1" ] && [ ! -e "$C/.pipeline/launch/issue-5-aaaaaaaaaaaa.js" ] && [ -e "$C/.pipeline/launch/issue-6-bbbbbbbbbbbb.js" ]; then pass "cleanup-removes (one issue)"; else fail "cleanup-removes ($OUTC)"; fi
OUTC="$(node "$CLEAN" --root "$C")"
if [ "$OUTC" = "removed 1" ] && [ -e "$C/.pipeline/launch/keep.txt" ] && [ -e "$C/.pipeline/other.txt" ]; then pass "cleanup-keeps-other (other files and other .pipeline content stay)"; else fail "cleanup-keeps-other ($OUTC)"; fi
rm "$C/.pipeline/launch/keep.txt"
node "$CLEAN" --root "$C" >/dev/null
if [ ! -d "$C/.pipeline/launch" ] && [ -e "$C/.pipeline/other.txt" ]; then pass "cleanup-removes-empty-directory"; else fail "cleanup-removes-empty-directory"; fi
node "$CLEAN" --bogus >/dev/null 2>&1; if [ $? -eq 2 ]; then pass "cleanup-usage-exit-2"; else fail "cleanup-usage-exit-2"; fi

echo "[hook-test] passed=${PASS} failed=${FAIL}"
[ "$FAIL" -eq 0 ]
