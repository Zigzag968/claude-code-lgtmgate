#!/usr/bin/env bash
# Self-test of hooks/workflow-args-expand.sh + scripts/runtime/workflow-args-expand.cjs (#520, #605): the PreToolUse(Workflow) hook that
# expands `projectSpecificsRef` / `configRef` to the full objects for a launch of the generated launch file (the file
# `launch-args.cjs --mode file` writes under .pipeline/launch/<sha12>/). The one-launch-form refusals are in test-engine-launch-form.sh.
# Throw-away git trees come from scripts/gen-launch-fixtures.cjs in $TMPDIR (nothing is committed).
# The tool_input skeletons follow the Workflow tool's input schema (scriptPath, resumeFromRunId, args): a launch and a resume of the
# generated file; the engine is never launched by name any more.
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
FAILBIN="$TMP/failbin"; mkdir -p "$FAILBIN"; printf '#!/usr/bin/env bash\nexit 1\n' > "$FAILBIN/gh"; chmod +x "$FAILBIN/gh"

# new_tree <name> [ignore]: a fixture project in $TMP/<name>; with `ignore`, .pipeline/ is gitignored there
new_tree() {
  node "$GEN" --tree "$TMP/$1" --size 4k >/dev/null || { echo "cannot build the fixture tree"; exit 1; }
  if [ "${2:-}" = "ignore" ]; then printf '.pipeline/\n' > "$TMP/$1/.gitignore"; fi
}
# mk_input <tree> <kind: path|resume> <mode: ref|full> [extra-js]: writes $TMP/in.json for the tree. The launch file is the one
# `launch-args.cjs --mode file` writes in the tree (a gh that always fails keeps the label to the brief, no network).
mk_input() {
  node "$LA" --root "$1" --session-root "$1" --ref origin/main --stage plan --mode "$3" --issue 520 --brief "implement the issue" > "$TMP/args.json" || exit 1
  local gen; gen="$(PATH="$FAILBIN:$PATH" node "$LA" --mode file --root "$1" --session-root "$1" --issue 520 --brief "implement the issue")" || exit 1
  node -e '
const fs = require("fs")
const [tree, kind, gen, file] = process.argv.slice(1, 5)
const args = JSON.parse(fs.readFileSync(process.argv[5], "utf8"))
const extra = process.argv[6] ? new Function("a", "ti", "gen", process.argv[6]) : null
const shapes = {
  path: { scriptPath: gen, args },
  resume: { scriptPath: gen, resumeFromRunId: "wf_76786d84-860", args },
}
const ti = shapes[kind]
if (extra) extra(args, ti, gen)
fs.writeFileSync(file, JSON.stringify({ cwd: tree, tool_name: "Workflow", tool_input: ti }))' "$1" "$2" "$gen" "$TMP/in.json" "$TMP/args.json" "${4:-}"
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
launch_files() { find "$1/.pipeline/launch" -type f -name '#520*' 2>/dev/null | wc -l | tr -d ' '; }

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
mk_input "$T1" path ref 'ti.args = "{not json, with projectSpecificsRef"'; hook "$T1"
expect "args-string-unparseable-denied" 2 'j.hookSpecificOutput.permissionDecisionReason.startsWith("specifics-ref-mismatch:") && j.hookSpecificOutput.permissionDecisionReason.includes("not valid JSON")'
new_tree t2 ignore; T2="$TMP/t2"
mk_input "$T2" path ref 'ti.extra = { keep: 1 }'; hook "$T2"
expect "preserve-fields-extra (a field the hook does not know is kept as it was)" 0 'j.hookSpecificOutput.updatedInput.extra.keep === 1 && !("name" in j.hookSpecificOutput.updatedInput)'
mk_input "$T2" path ref; hook "$T2"
expect "preserve-fields-scriptpath" 0 'j.hookSpecificOutput.updatedInput.scriptPath === i.tool_input.scriptPath && !("name" in j.hookSpecificOutput.updatedInput)'
mk_input "$T2" resume ref; hook "$T2"
expect "preserve-fields-resume" 0 'j.hookSpecificOutput.updatedInput.resumeFromRunId === "wf_76786d84-860" && j.hookSpecificOutput.updatedInput.scriptPath === i.tool_input.scriptPath'
BEFORE_FILES="$(find "$T2/.pipeline/launch" -type f | wc -l | tr -d ' ')"
hook "$T2"
if [ "$(find "$T2/.pipeline/launch" -type f | wc -l | tr -d ' ')" = "$BEFORE_FILES" ]; then pass "launch-hook-writes-no-file (the hook never creates or rewrites a launch file)"; else fail "launch-hook-writes-no-file"; fi
mk_input "$T2" path ref 'ti.scriptPath = a.worktreePath + "/.pipeline/launch/0123456789ab/#520 - never written.js"'; hook "$T2"
expect "launch-file-unreadable-fails-open (a generated-shape path that does not exist: arguments expanded, no refusal)" 0 '"config" in j.hookSpecificOutput.updatedInput.args && !("permissionDecision" in j.hookSpecificOutput)'

# ---- the launch file ---------------------------------------------------------------------------------
new_tree t3 ignore; T3="$TMP/t3"
mk_input "$T3" path ref; hook "$T3"
GEN1="$(node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(j.hookSpecificOutput.updatedInput.scriptPath||"")' "$OUT")"
if [ -n "$GEN1" ] && [ -f "$GEN1" ] && [ "$(jx '!("name" in j.hookSpecificOutput.updatedInput) && /\/\.pipeline\/launch\/[0-9a-f]{12}\/#520 - implement the issue\.js$/.test(j.hookSpecificOutput.updatedInput.scriptPath)')" = "true" ]; then pass "launch-generated-shape (the scriptPath the hook returns is the generated file the call named, no name added)"; else fail "launch-generated-shape ($GEN1)"; fi
node -e '
const fs = require("fs")
const a = fs.readFileSync(process.argv[1], "utf8").split("\n")
const b = fs.readFileSync(process.argv[2], "utf8").split("\n")
if (b.length !== a.length + 1) process.exit(1)
const titleAt = b.findIndex((l) => /^  title: \x27[^\x27]*\x27,$/.test(l))
if (titleAt < 1 || titleAt > 12 || !b[titleAt - 1].startsWith("  name: ")) process.exit(1)
b.splice(titleAt, 1)
const changed = []
for (let k = 0; k < a.length; k++) if (a[k] !== b[k]) changed.push(k)
const flagLine = a.findIndex((l) => /^const LAUNCH_FILE_GENERATED = false$/.test(l))
const ok = changed.length === 3 && changed.filter((k) => k < 12).length === 2 && changed.includes(flagLine) && b[flagLine] === "const LAUNCH_FILE_GENERATED = true"
process.exit(ok ? 0 : 1)' "$ENGINE" "$GEN1"
NR=$?
if [ "$NR" -eq 0 ]; then pass "launch-diff-only-titles (three changed lines: meta name, meta description and the flag, plus the inserted meta title line; phase titles untouched)"; else fail "launch-diff-only-titles"; fi
mk_input "$T3" path ref; hook "$T3"
SECOND="$(node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(j.hookSpecificOutput.updatedInput.scriptPath||"")' "$OUT")"
if [ "$SECOND" = "$GEN1" ] && [ "$(launch_files "$T3")" = 1 ]; then pass "launch-reuse (the same call twice: same path, one file)"; else fail "launch-reuse ($SECOND vs $GEN1)"; fi
# a resume that re-passes the generated path
mk_input "$T3" resume ref; hook "$T3"
if [ "$RC" = 0 ] && [ "$(jx "j.hookSpecificOutput.updatedInput.scriptPath === \"$GEN1\" && j.hookSpecificOutput.updatedInput.resumeFromRunId === \"wf_76786d84-860\"")" = "true" ] && [ "$(launch_files "$T3")" = 1 ]; then pass "resume-generated-path-idempotent"; else fail "resume-generated-path-idempotent (rc=$RC $(head -c 300 "$OUT"))"; fi
if [ "$(grep -c '^const LAUNCH_FILE_GENERATED = true$' "$GEN1")" = 1 ] && [ "$(grep -c '^const LAUNCH_FILE_GENERATED = false$' "$ENGINE")" = 1 ]; then pass "launch-flag-on-in-the-generated-file-off-in-the-engine"; else fail "launch-flag-on-in-the-generated-file-off-in-the-engine"; fi
# one extra byte: the same call, the file edited after it was written
cp "$GEN1" "$TMP/gen1.keep"; printf '\n' >> "$GEN1"
node -e '
const fs = require("fs")
const a = JSON.parse(fs.readFileSync(process.argv[3], "utf8"))
const resume = process.argv[5] === "resume"
fs.writeFileSync(process.argv[2], JSON.stringify({ cwd: process.argv[1], tool_name: "Workflow", tool_input: Object.assign({ scriptPath: process.argv[4], args: a }, resume ? { resumeFromRunId: "wf_76786d84-860" } : {}) }))' "$T3" "$TMP/tamper-path.json" "$TMP/args.json" "$GEN1" path
hook "$T3" "$TMP/tamper-path.json"
expect_deny "launch-tamper-denied" "$(basename "$GEN1")"
node -e '
const fs = require("fs")
const a = JSON.parse(fs.readFileSync(process.argv[3], "utf8"))
fs.writeFileSync(process.argv[2], JSON.stringify({ cwd: process.argv[1], tool_name: "Workflow", tool_input: { scriptPath: process.argv[4], resumeFromRunId: "wf_76786d84-860", args: a } }))' "$T3" "$TMP/tamper-resume.json" "$TMP/args.json" "$GEN1"
hook "$T3" "$TMP/tamper-resume.json"
expect_deny "resume-tamper-denied" "$(basename "$GEN1")"
cp "$TMP/gen1.keep" "$GEN1"

# a source given to --mode file is the source of the file, not the plugin cache
new_tree t4 ignore; T4="$TMP/t4"
mkdir -p "$TMP/custom"; cp "$ENGINE" "$TMP/custom/engine-copy.js"; printf '// custom-source-marker\n' >> "$TMP/custom/engine-copy.js"
GEN4="$(PATH="$FAILBIN:$PATH" node "$LA" --mode file --root "$T4" --session-root "$T4" --issue 520 --brief "implement the issue" --engine "$TMP/custom/engine-copy.js")"
mk_input "$T4" path ref 'ti.scriptPath = "'"$GEN4"'"'; hook "$T4"
if [ -n "$GEN4" ] && [ -f "$GEN4" ] && grep -q 'custom-source-marker' "$GEN4" && [ "$GEN4" != "$GEN1" ] && [ "$RC" = 0 ] && [ "$(jx 'j.hookSpecificOutput.updatedInput.scriptPath === "'"$GEN4"'"')" = "true" ]; then pass "launch-from-custom-engine (a patched copy given to --mode file is launched as printed)"; else fail "launch-from-custom-engine ($GEN4)"; fi

# ---- plain phase titles (#553; same rule as scripts/guards.cjs checkPhaseTitles) -----------------------------
node -e '
const fs = require("fs")
const { retitle } = require(process.argv[1] + "/scripts/lib/launch-file.cjs")
const source = fs.readFileSync(process.argv[1] + "/workflows/deliver-pipeline.js", "utf8")
let ok = true
const titlesOf = (out) => [...out.slice(0, out.indexOf("\n}\n")).matchAll(/\{ title: \x27([^\x27]*)\x27/g)].map((m) => m[1])
for (const n of [1, 520, 99999, 123456]) {
  const out = retitle(source, n)
  if (out === null) { ok = false; continue }
  if (titlesOf(out).join(",") !== "Setup,Diagnose,Plan,Dev,Review") ok = false
  if (/#\d+ (Setup|Diagnose|Plan|Dev|Review)/.test(out)) ok = false
  if (retitle(out, n) !== out) ok = false
}
// a launch file of the previous shape normalizes to the same bytes as a fresh launch
let legacy = retitle(source, 9)
for (const t of ["Setup", "Diagnose", "Plan", "Dev", "Review"]) legacy = legacy.replace("{ title: \x27" + t + "\x27", "{ title: \x27#9 " + t + "\x27").replace(t.toLowerCase() + ": \x27" + t + "\x27", t.toLowerCase() + ": \x27#9 " + t + "\x27")
legacy = legacy.replace(/^  name: .*$/m, "  name: \x27deliver-pipeline #9 Old title\x27,").replace(/^  title: .*\n/m, "")
if (legacy === retitle(source, 9) || retitle(legacy, 9) !== retitle(source, 9)) ok = false
if (retitle(source.replace("title: \x27Dev\x27", "title: \x27Develop\x27"), 1) !== null) ok = false
// a string third argument is the title (same as { title })
if (retitle(source, 553, "Short title") !== retitle(source, 553, { title: "Short title" }) || !retitle(source, 553, "Short title").includes("\n  name: \x27#553 - Short title\x27,\n")) ok = false
process.exit(ok ? 0 : 1)' "$ROOT"
NR=$?
if [ "$NR" -eq 0 ]; then pass "launch-phases-plain (plain titles for any issue number, idempotent, a launch file of the previous shape is normalized)"; else fail "launch-phases-plain"; fi
node -e '
const fs = require("fs")
const { retitle } = require(process.argv[1] + "/scripts/lib/launch-file.cjs")
const source = fs.readFileSync(process.argv[1] + "/workflows/deliver-pipeline.js", "utf8")
let ok = true
const descOf = (out) => { const m = out.match(/^  description: \x27(.*)\x27,$/m); return m ? m[1] : "" }
const brief = "Issue 455: lead-merge must refuse or switch to the branch copy when the PR changes scripts/lead-merge.sh; issue body is the source of truth."
const out = retitle(source, 455, { brief })
const d = descOf(out)
const rest = d
if (!d.startsWith("lead-merge must refuse") || d.includes("Issue 455") || d.includes("#455") || !d.endsWith("…")) ok = false
if ([...rest].length > 120) ok = false
const body = rest.slice(0, -1)
const words = brief.replace(/^Issue 455: /, "")
if (!words.startsWith(body) || !/\s/.test(words.charAt(body.length)) ) ok = false
for (const b of ["#455: short brief", "Issue 455 - short brief"]) if (descOf(retitle(source, 455, { brief: b })) !== "short brief") ok = false
if (descOf(retitle(source, 520, { brief: "implement the issue" })) !== "implement the issue") ok = false
const longToken = descOf(retitle(source, 455, { brief: "x".repeat(200) }))
if (!longToken.endsWith("…") || [...longToken].length > 120) ok = false
if (retitle(out, 455, { brief }) !== out) ok = false
process.exit(ok ? 0 : 1)' "$ROOT"
NR=$?
if [ "$NR" -eq 0 ]; then pass "launch-description-clean (issue prefix dropped, long line cut at a word boundary with an ellipsis, short brief unchanged)"; else fail "launch-description-clean"; fi
node -e '
const fs = require("fs")
const { retitle } = require(process.argv[1] + "/scripts/lib/launch-file.cjs")
const source = fs.readFileSync(process.argv[1] + "/workflows/deliver-pipeline.js", "utf8")
let ok = true
const line = (out, key) => { const m = out.match(new RegExp("^  " + key + ": \\x27(.*)\\x27,$", "m")); return m ? m[1] : null }
const out = retitle(source, 12, { title: "Fix the thing" })
if (line(out, "name") !== "#12 - Fix the thing" || line(out, "title") !== "#12 - lgtmgate" || line(out, "description") !== "Fix the thing") ok = false
if (out.indexOf("\n  name: ") + 1 >= out.indexOf("\n  title: ") || out.indexOf("\n  title: ") >= out.indexOf("\n  description: ")) ok = false
if (retitle(out, 12, { title: "Fix the thing" }) !== out) ok = false
if (retitle(out, 12, { title: "Other words" }) !== retitle(source, 12, { title: "Other words" })) ok = false
const quoted = retitle(source, 12, { title: "it\x27s a \\ title" })
fs.writeFileSync(process.argv[2], quoted)
if (line(quoted, "title") !== "#12 - lgtmgate") ok = false
process.exit(ok ? 0 : 1)' "$ROOT" "$TMP/launch-labels.js"
NR=$?
if [ "$NR" -eq 0 ] && node --check "$TMP/launch-labels.js" 2>/dev/null; then pass "launch-labels (name #N - title, title #N - lgtmgate, description title; idempotent; a quote and a backslash stay valid JS)"; else fail "launch-labels"; fi
node -e '
const fs = require("fs")
const { retitle } = require(process.argv[1] + "/scripts/lib/launch-file.cjs")
const source = fs.readFileSync(process.argv[1] + "/workflows/deliver-pipeline.js", "utf8")
let ok = true
const line = (out, key) => { const m = out.match(new RegExp("^  " + key + ": \\x27(.*)\\x27,$", "m")); return m ? m[1] : null }
const bare = retitle(source, 520)
if (line(bare, "name") !== "#520" || line(bare, "description") !== "#520" || line(bare, "title") !== "#520 - lgtmgate") ok = false
process.exit(ok ? 0 : 1)' "$ROOT"
NR=$?
if [ "$NR" -eq 0 ]; then pass "launch-fallback-bare (no title and no brief: name #N, description #N)"; else fail "launch-fallback-bare"; fi
node -e '
const fs = require("fs")
const { retitle } = require(process.argv[1] + "/scripts/lib/launch-file.cjs")
const source = fs.readFileSync(process.argv[1] + "/workflows/deliver-pipeline.js", "utf8")
let ok = true
const line = (out, key) => { const m = out.match(new RegExp("^  " + key + ": \\x27(.*)\\x27,$", "m")); return m ? m[1] : null }
const long = retitle(source, 520, { brief: ("long brief words ").repeat(20) })
const name = line(long, "name")
if (!name.startsWith("#520 - long brief words") || Buffer.byteLength(name.slice("#520 - ".length), "utf8") > 80) ok = false
const wide = line(retitle(source, 520, { brief: "é".repeat(100) }), "name")
if (Buffer.byteLength(wide.slice("#520 - ".length), "utf8") > 80) ok = false
process.exit(ok ? 0 : 1)' "$ROOT"
NR=$?
if [ "$NR" -eq 0 ]; then pass "launch-fallback-bound (a long brief gives an issue name of at most 80 bytes)"; else fail "launch-fallback-bound"; fi
node -e '
const fs = require("fs")
const { retitle } = require(process.argv[1] + "/scripts/lib/launch-file.cjs")
const source = fs.readFileSync(process.argv[1] + "/workflows/deliver-pipeline.js", "utf8")
const shaped = source.replace("\n  name: \x27deliver-pipeline\x27,\n", "\n  name: \x27deliver-pipeline\x27,\n  title: \"x\",\n")
process.exit(shaped !== source && retitle(shaped, 12, { title: "T" }) === null ? 0 : 1)' "$ROOT"
NR=$?
if [ "$NR" -eq 0 ]; then pass "launch-meta-title-shape (a meta title line of another shape gives no launch file)"; else fail "launch-meta-title-shape"; fi
new_tree t5 ignore; T5="$TMP/t5"
GEN5="$(PATH="$FAILBIN:$PATH" node "$LA" --mode file --root "$T5" --session-root "$T5" --issue 1234567 --brief x)"
node "$LA" --root "$T5" --session-root "$T5" --ref origin/main --stage plan --mode ref --issue 1234567 --brief x > "$TMP/args.json"
node -e 'const fs=require("fs");fs.writeFileSync(process.argv[2],JSON.stringify({cwd:process.argv[1],tool_name:"Workflow",tool_input:{scriptPath:process.argv[4],args:JSON.parse(fs.readFileSync(process.argv[3],"utf8"))}}))' "$T5" "$TMP/in.json" "$TMP/args.json" "$GEN5"
hook "$T5"
expect "seven-digit-issue-launches" 0 '/\/\.pipeline\/launch\/[0-9a-f]{12}\/#1234567 - x\.js$/.test(j.hookSpecificOutput.updatedInput.scriptPath) && !("name" in j.hookSpecificOutput.updatedInput) && "config" in j.hookSpecificOutput.updatedInput.args'

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
mk_input "$RS1" path ref 'a.title = "Fast launches"'; hook "$RS1"
expect "run-state-title-kept-with-generated-file (no origin: the typed title stays, the file is the one the call named)" 0 'j.hookSpecificOutput.updatedInput.scriptPath === i.tool_input.scriptPath && !("name" in j.hookSpecificOutput.updatedInput) && j.hookSpecificOutput.updatedInput.args.title === "Fast launches"'
RS1_FILE="$(script_of)"; cp "$RS1_FILE" "$TMP/rs1.before"
if cmp -s "$RS1_FILE" "$TMP/rs1.before" && grep -qF "  name: '#520 - implement the issue'," "$RS1_FILE" && grep -qF "  title: '#520 - lgtmgate'," "$RS1_FILE" && grep -qF "  description: 'implement the issue'," "$RS1_FILE"; then pass "run-state-title-never-rewrites-the-file (the typed title does not reach the labels)"; else fail "run-state-title-never-rewrites-the-file"; fi
if [ "$(grep -F '{ title:' "$RS1_FILE" | grep -c 'Fast launches')" = 0 ] && grep -qF "{ title: 'Setup'" "$RS1_FILE" && ! grep -qE "#520 (Setup|Diagnose|Plan|Dev|Review)" "$RS1_FILE" && grep -qF "const PHASE_TITLES = { setup: 'Setup', diagnose: 'Diagnose', plan: 'Plan', dev: 'Dev', review: 'Review' }" "$RS1_FILE"; then pass "run-state-title-phases-plain"; else fail "run-state-title-phases-plain"; fi
new_tree rs2 ignore; RS2="$TMP/rs2"
mk_input "$RS2" path ref; hook "$RS2"; RS2_FILE="$(script_of)"
if grep -qF "  name: '#520 - implement the issue'," "$RS2_FILE" && grep -qF "  description: 'implement the issue'," "$RS2_FILE"; then pass "launch-fallback-name-brief"; else fail "launch-fallback-name-brief ($(grep -m1 '^  name:' "$RS2_FILE"))"; fi
mk_input "$RS2" path ref 'a.prNumber = 560'; hook "$RS2"; RS2_FILE="$(script_of)"
if grep -qF "  name: '#520 - implement the issue'," "$RS2_FILE" && grep -qF "  title: '#520 - lgtmgate'," "$RS2_FILE" && grep -qF "  description: 'implement the issue'," "$RS2_FILE" && ! grep -E "^  (name|title|description):" "$RS2_FILE" | grep -qF "PR #"; then pass "launch-description-no-pr"; else fail "launch-description-no-pr ($(grep -m1 '^  description:' "$RS2_FILE"))"; fi
QUOTED="$(PATH="$FAILBIN:$PATH" node "$LA" --mode file --root "$RS1" --session-root "$RS1" --issue 521 --brief "it's a \\ title")"
cp "$QUOTED" "$TMP/quote.js"
if [ -n "$QUOTED" ] && node --check "$TMP/quote.js" 2>/dev/null; then pass "run-state-title-escapes-quote (valid JS with a quote and a backslash)"; else fail "run-state-title-escapes-quote"; fi
FIRST="$(PATH="$FAILBIN:$PATH" node "$LA" --mode file --root "$RS1" --session-root "$RS1" --issue 522 --brief "Fast launches")"
SECOND="$(PATH="$FAILBIN:$PATH" node "$LA" --mode file --root "$RS1" --session-root "$RS1" --issue 522 --brief "Fast launches")"
THIRD="$(PATH="$FAILBIN:$PATH" node "$LA" --mode file --root "$RS1" --session-root "$RS1" --issue 522 --brief "Other words")"
if [ -n "$FIRST" ] && [ "$FIRST" = "$SECOND" ] && [ -n "$THIRD" ] && [ "$THIRD" != "$FIRST" ] && [ "$(dirname "$THIRD")" != "$(dirname "$FIRST")" ]; then pass "run-state-title-idempotent (same title keeps the file, another title is another file in another digest directory)"; else fail "run-state-title-idempotent ($FIRST $SECOND $THIRD)"; fi
mk_input "$RS1" path ref 'a.title = "x".repeat(81)'; hook "$RS1"
expect_deny_code "run-state-title-deny-length" "launch-argument-invalid" "81 bytes"
mk_input "$RS1" path ref 'a.title = "two\nlines"'; hook "$RS1"
expect_deny_code "run-state-title-deny-newline" "launch-argument-invalid" "newline"

GHBIN="$TMP/ghbin"; mkdir -p "$GHBIN"
cat > "$GHBIN/gh" <<'STUB'
#!/usr/bin/env bash
[ "${GH_STUB_FAIL:-}" = "1" ] && exit 1
case "$2" in
  repos/acme/widgets/issues/520) printf '{"number":520,"state":"open","title":"%s","body":"x\\ndepends-on: #530, #531, #532\\n"}\n' "${GH_STUB_TITLE:-Derive the run title}" ;;
  repos/acme/widgets/issues/530|repos/acme/widgets/issues/531|repos/acme/widgets/issues/532) echo '{"state":"closed","state_reason":"completed"}' ;;
  repos/acme/widgets/issues/520/parent) echo '{"number":528}' ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$GHBIN/gh"
new_tree rs2 ignore; RS2="$TMP/rs2"; git -C "$RS2" remote add origin https://github.com/acme/widgets.git
mk_input "$RS2" path ref; PATH="$GHBIN:$PATH" hook "$RS2"
expect "run-state-merged-derived" 0 'JSON.stringify(j.hookSpecificOutput.updatedInput.args.merged) === "[530,531,532]" && j.hookSpecificOutput.updatedInput.args.epic === 528'
mk_input "$RS2" path ref 'a.merged = [1, 2]; a.epic = 9'; PATH="$GHBIN:$PATH" hook "$RS2"
expect "run-state-merged-overwrites-typed" 0 'JSON.stringify(j.hookSpecificOutput.updatedInput.args.merged) === "[530,531,532]" && j.hookSpecificOutput.updatedInput.args.epic === 528'
mk_input "$RS2" path ref 'a.title = "Review PR 9 words"'; PATH="$GHBIN:$PATH" hook "$RS2"
expect "run-state-title-from-issue (a typed title that differs is replaced by the issue title)" 0 'j.hookSpecificOutput.updatedInput.args.title === "Derive the run title"'
if [ "$(jx 'j.hookSpecificOutput.additionalContext.includes("label reads \"#520 - implement the issue\"") && j.hookSpecificOutput.additionalContext.includes("issue title reads \"Derive the run title\"")')" = "true" ]; then pass "run-state-title-from-issue-drift-advisory (the file keeps its label, the advisory names both)"; else fail "run-state-title-from-issue-drift-advisory"; fi
LONG_TITLE="Hook sets the run title from the issue title and cuts it when it is far too long for one line"
mk_input "$RS2" path ref 'a.title = "typed"'; GH_STUB_TITLE="$LONG_TITLE" PATH="$GHBIN:$PATH" hook "$RS2"
expect "run-state-title-cut-word-boundary" 0 '(() => { const t = j.hookSpecificOutput.updatedInput.args.title; const src = "'"$LONG_TITLE"'"; const body = t.slice(0, -1); return Buffer.byteLength(t) <= 80 && t.endsWith("…") && src.startsWith(body) && src[body.length] === " " })()'
mk_input "$RS2" path ref 'a.title = "Typed title kept"'; GH_STUB_FAIL=1 PATH="$GHBIN:$PATH" hook "$RS2"
expect "run-state-title-fail-open (the issue cannot be read: the typed title is kept, no refusal)" 0 'j.hookSpecificOutput.updatedInput.args.title === "Typed title kept" && !("permissionDecision" in j.hookSpecificOutput)'
mk_input "$RS2" path ref 'a.title = "x".repeat(81)'; GH_STUB_FAIL=1 PATH="$GHBIN:$PATH" hook "$RS2"
expect_deny_code "run-state-title-fallback-still-validated (unreadable issue, over-long typed title: refused as before)" "launch-argument-invalid" "81 bytes"
mk_input "$RS1" path ref 'a.merged = [1, 2]; a.epic = 9'; PATH="$GHBIN:$PATH" hook "$RS1"
expect "run-state-merged-typed-dropped-without-repo (no origin, no config.repo: no derived key, the typed ones are gone)" 0 '!("merged" in j.hookSpecificOutput.updatedInput.args) && !("epic" in j.hookSpecificOutput.updatedInput.args)'

# ---- launch facts (#581): the hook computes the plugin-version, session-root and config baseBranch answers ----
LFP="$TMP/lfplugin"; mkdir -p "$LFP/templates" "$LFP/.claude-plugin"
cp "$ROOT/templates/plugin-version.cjs" "$LFP/templates/plugin-version.cjs"; printf '{"version":"9.8.7"}\n' > "$LFP/.claude-plugin/plugin.json"
new_tree lf ignore; LF="$TMP/lf"; mkdir -p "$LF/.claude"; printf '{"baseBranch":"develop"}\n' > "$LF/.claude/pipeline.config.json"
SHAJS='const h = (s) => require("crypto").createHash("sha256").update(s).digest("hex"); const f = j.hookSpecificOutput.updatedInput.args.launchFacts || {};'
mk_input "$LF" path ref 'a.pluginRoot = "'"$LFP"'"; a.launchFacts = { pluginVersion: { for: "0".repeat(64), exit: 0, lines: ["typed"] } }'; hook "$LF"
expect "launch-facts-written (version and session root computed, bound by digest; the typed value is replaced)" 0 '(() => {'"$SHAJS"' return f.pluginVersion.for === h("plugin-version\n'"$LFP"'") && f.pluginVersion.exit === 0 && JSON.stringify(f.pluginVersion.lines) === "[\"PLUGIN-VERSION:9.8.7\"]" && f.sessionRoot.for === h("session-root\n'"$LF"'\n'"$LF"'") && f.sessionRoot.exit === 0 && JSON.stringify(f.sessionRoot.lines) === "[\"SESSION-ROOT:same\"]" && !("configBaseBranch" in f) })()'
mk_input "$LF" path ref 'a.launchFacts = { sessionRoot: { for: "0".repeat(64), exit: 0, lines: ["typed"] } }; delete a.pluginRoot; delete a.sessionRoot'; hook "$LF"
expect "launch-facts-typed-deleted (no pluginRoot and no sessionRoot: nothing to compute, the typed object is gone)" 0 '!("launchFacts" in j.hookSpecificOutput.updatedInput.args)'
mk_input "$LF" path ref 'a.pluginRoot = "relative/plugin"; delete a.sessionRoot'; hook "$LF"
expect "launch-facts-absent-without-absolute-plugin-root (fail open to the probes)" 0 '!("launchFacts" in j.hookSpecificOutput.updatedInput.args)'
mkdir -p "$TMP/lfbad/templates"; printf 'process.exit(3)\n' > "$TMP/lfbad/templates/plugin-version.cjs"
mk_input "$LF" path ref 'a.pluginRoot = "'"$TMP/lfbad"'"; delete a.sessionRoot'; hook "$LF"
expect "launch-facts-failing-script-keeps-exit (a non-zero exit is recorded with no line, the verdict stays the engine's)" 0 'j.hookSpecificOutput.updatedInput.args.launchFacts.pluginVersion.exit === 3 && j.hookSpecificOutput.updatedInput.args.launchFacts.pluginVersion.lines.length === 0'
mk_input "$LF" path ref 'a.pluginRoot = "'"$LFP"'"; delete a.sessionRoot; a.entryStage = "dev"'; hook "$LF"
expect "launch-facts-config-only-on-dev-entry (read from the worktree config, absent on a plan entry)" 0 '(() => {'"$SHAJS"' return JSON.stringify(f.configBaseBranch.lines) === "[\"{\\\"baseBranch\\\":\\\"develop\\\"}\"]" && f.configBaseBranch.for === h("config-base-branch\n'"$LF"'") })()'
mk_input "$LF" path ref 'a.pluginRoot = "'"$LFP"'"; delete a.sessionRoot; a.entryStage = "plan"'; hook "$LF"
expect "launch-facts-no-config-fact-on-plan-entry" 0 '!("configBaseBranch" in j.hookSpecificOutput.updatedInput.args.launchFacts)'

mkdir -p "$RS1/.pipeline"; printf '{"status":"dev"}\n' > "$RS1/.pipeline/issue-777.json"
mk_input "$RS1" path ref 'a.parallel = [888]'; hook "$RS1"
expect "run-state-parallel-advisory (an active run missing from parallel and a listed number with no active run)" 0 '/#777/.test(j.hookSpecificOutput.additionalContext) && /#888/.test(j.hookSpecificOutput.additionalContext) && !("permissionDecision" in j.hookSpecificOutput)'
mk_input "$RS1" path ref 'a.parallel = [777]'; hook "$RS1"
expect "run-state-parallel-consistent-no-advisory" 0 '!("additionalContext" in j.hookSpecificOutput)'

# ---- cleanup (the launch files of the new layout; the full matrix is in test-launch-file.sh) --------------------
C="$TMP/clean"; mkdir -p "$C/.pipeline/launch/aaaaaaaaaaaa" "$C/.pipeline/launch/bbbbbbbbbbbb"
printf 'a' > "$C/.pipeline/launch/aaaaaaaaaaaa/#5 - five.js"; printf 'b' > "$C/.pipeline/launch/bbbbbbbbbbbb/#6 - six.js"
printf 'k' > "$C/.pipeline/launch/keep.txt"; printf 'o' > "$C/.pipeline/other.txt"
OUTC="$(node "$CLEAN" --root "$C" --issue 5)"
if [ "$OUTC" = "removed 1" ] && [ ! -e "$C/.pipeline/launch/aaaaaaaaaaaa" ] && [ -e "$C/.pipeline/launch/bbbbbbbbbbbb/#6 - six.js" ]; then pass "cleanup-removes (one issue, its emptied digest directory goes too)"; else fail "cleanup-removes ($OUTC)"; fi
OUTC="$(node "$CLEAN" --root "$C")"
if [ "$OUTC" = "removed 1" ] && [ -e "$C/.pipeline/launch/keep.txt" ] && [ -e "$C/.pipeline/other.txt" ]; then pass "cleanup-keeps-other (other files and other .pipeline content stay)"; else fail "cleanup-keeps-other ($OUTC)"; fi
rm "$C/.pipeline/launch/keep.txt"
node "$CLEAN" --root "$C" >/dev/null
if [ ! -d "$C/.pipeline/launch" ] && [ -e "$C/.pipeline/other.txt" ]; then pass "cleanup-removes-empty-directory"; else fail "cleanup-removes-empty-directory"; fi
node "$CLEAN" --bogus >/dev/null 2>&1; if [ $? -eq 2 ]; then pass "cleanup-usage-exit-2"; else fail "cleanup-usage-exit-2"; fi

echo "[hook-test] passed=${PASS} failed=${FAIL}"
[ "$FAIL" -eq 0 ]
