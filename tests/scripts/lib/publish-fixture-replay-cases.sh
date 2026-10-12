#!/usr/bin/env bash
# cases #195, #213, #209 and the usage errors (sourced by tests/scripts/test-publish-fixture.sh, never executed).
# ---- #195: the plugin version probe answer follows the engine version, never the version of the day --------
# A real run journals the LITERAL engine version in that answer and lead-merge bumps it at every merge: a fixture published
# with the literal goes red at the next bump. The publication writes the token when the answer is the engine's version.
BUMPED="$TMP/engine-bumped.js"
bumped_engine "$BUMPED"
ENGV=$(node -e 'process.stdout.write(/const BUILD = \{[^}]*\bversion: \x27([^\x27]+)/.exec(require("fs").readFileSync(process.env.ROOT+"/workflows/deliver-pipeline.js","utf8"))[1])')
LIVE_RAW="$RAWD/123-live.json"
node "$TMP/gen.cjs" "$LIVE_RAW" liveversion
DLV="$(newdir out-live)"
pub "$LIVE_RAW" --out-dir "$DLV"
if [ "$RC" -eq 0 ] && [ -f "$DLV/123-live.json" ]; then
  LV="$DLV/123-live.json"
  [ "$(jsf "$LV" 'f.calls["probe-123-lines-plugin-version-r0"].line.includes("PLUGIN-VERSION:@@ENGINE_VERSION@@") && f.calls["probe-123-lines-plugin-version-r0"].verify.includes("PLUGIN-VERSION:@@ENGINE_VERSION@@")')" = "true" ] \
    && ok "version probe: the published answer (line and verify) is the token" || bad "version probe: token missing in the published file"
  case "$(cat "$LV")" in *"$ENGV"*) bad "version probe: the literal engine version $ENGV is still in the published file";; *) ok "version probe: no literal engine version left in the published file";; esac
  out=$(node scripts/run-offline.cjs "$LV" --fp "$BUMPED" 2>&1 | tail -n 1)
  case "$out" in *"status=ok passed=1"*) ok "version probe: the published fixture replays green against an engine whose version was bumped";; *) bad "version probe: bumped replay: $out";; esac
  out=$(OFFLINE_STRICT=1 node scripts/run-offline.cjs "$LV" 2>&1 | tail -n 1)
  case "$out" in *"status=ok passed=1"*) ok "version probe: and against the engine of the repo";; *) bad "version probe: replay: $out";; esac
else
  bad "version probe: publication of a live capture: rc=$RC out=$OUT err=$ERR"
fi

SKEW_RAW="$RAWD/123-skew.json"
node "$TMP/gen.cjs" "$SKEW_RAW" skew
DSK="$(newdir out-skew)"
pub "$SKEW_RAW" --out-dir "$DSK"
if [ "$RC" -eq 0 ] && [ -f "$DSK/123-skew.json" ]; then
  SK="$DSK/123-skew.json"
  [ "$(jsf "$SK" 'f.calls["probe-123-lines-plugin-version-r0"].line.includes("PLUGIN-VERSION:1.0.0-beta.3") && f.expect.status')" = '"escalate"' ] \
    && ok "version probe: a skew incident keeps the stale root's version literal" || bad "version probe: the stale root's version was rewritten: $(jsf "$SK" 'f.calls')"
  [ "$(jsf "$SK" 'f.expect.reason.startsWith("plugin-version-skew") && f.expect.reason.includes("@@ENGINE_VERSION@@") && !f.expect.reason.split("1.0.0-beta.3").join("").includes("'"$ENGV"'")')" = "true" ] \
    && ok "version probe: the published expect.reason of a skew quotes the engine version as the token" || bad "version probe: expect.reason of the skew: $(jsf "$SK" 'f.expect.reason')"
  out=$(node scripts/run-offline.cjs "$SK" --fp "$BUMPED" 2>&1 | tail -n 1)
  case "$out" in *"status=ok passed=1"*) ok "version probe: the skew fixture replays green against an engine whose version was bumped";; *) bad "version probe: skew bumped replay: $out";; esac
else
  bad "version probe: publication of a skew capture: rc=$RC out=$OUT err=$ERR"
fi

# ---- #213: a run whose buildStamp is older than the replaying engine publishes and replays to its recorded status ----
# A SYNTHETIC run (never the real projects directory) of an older engine: the record's result carries the engine's own
# buildStamp (1.0.0-beta.3), the pluginRoot names no version, the version probe answer is that literal version. The capture
# tokenizes the answer from the stamp, the publication keeps the token, and the fixture replays green on the current and on a
# bumped engine.
SPROJ="$TMP/stamp-projects"
SREPO="$TMP/stamp-repo"
rm -rf "$SPROJ" "$SREPO"
git init -q "$SREPO"
printf 'captures/\n' > "$SREPO/.gitignore"
node -e '
const fs = require("fs"), path = require("path"), crypto = require("crypto")
const [proj, runId] = process.argv.slice(1)
const smoke = JSON.parse(fs.readFileSync(path.join(process.env.ROOT, "fixtures/smoke/auto-lgtm.json"), "utf8"))
const src = fs.readFileSync(path.join(process.env.ROOT, "workflows/deliver-pipeline.js"), "utf8")
const blk = src.slice(src.indexOf("// --- pluginVersion:start ---"), src.indexOf("// --- pluginVersion:end ---"))
const root = "/main/checkout"
const h = crypto.createHash("sha256").update(new Function(blk + "\nreturn pluginVersionCommand")()(root)).digest("hex")
const VP = "probe-123-lines-plugin-version-r0"
for (const k of ["line", "verify"]) smoke.calls[VP][k] = smoke.calls[VP][k].split("@@ENGINE_VERSION@@").join("1.0.0-beta.3").replace(/cmd=[0-9a-f]{64}/, "cmd=" + h)
smoke.args.pluginRoot = root
// #429: with a plugin root the provisioning probe runs the plugin script, so its command (and cmd= digest) names that root
const PROV = "probe-123-provision-provision-r0"
const provCmd = `(SCRIPT="${root}/templates/provision-worktree.sh"; if [ -f "$SCRIPT" ]; then PROVISION_ENV_SYMLINK="required" bash "$SCRIPT" "${smoke.args.worktreePath}"; else echo "PROVISION-SKIPPED-NO-SCRIPT $SCRIPT (no provision.extraLinks configured - nothing to link)"; exit 0; fi) 2>&1`
for (const k of ["line", "verify"]) smoke.calls[PROV][k] = smoke.calls[PROV][k].replace(/cmd=[0-9a-f]{64}/, "cmd=" + crypto.createHash("sha256").update(provCmd).digest("hex"))
const runDir = path.join(proj, "-proj", "sess1", "subagents", "workflows", runId)
const recFile = path.join(proj, "-proj", "sess1", "workflows", runId + ".json")
fs.mkdirSync(runDir, { recursive: true }); fs.mkdirSync(path.dirname(recFile), { recursive: true })
const calls = Object.keys(smoke.calls).map((label, i) => ({ label, agentId: "ag-" + i, key: "v2:" + (1000 + i).toString(16), value: smoke.calls[label] }))
const rows = [{ type: "launched" }]
for (const c of calls) {
  rows.push({ type: "started", agentId: c.agentId, key: c.key, label: c.label, phase: "p" })
  rows.push({ type: "result", agentId: c.agentId, key: c.key, result: c.value })
}
fs.writeFileSync(path.join(runDir, "journal.jsonl"), rows.map((r) => JSON.stringify(r)).join("\n") + "\n")
fs.writeFileSync(recFile, JSON.stringify({
  runId, status: "completed", args: smoke.args,
  result: { status: smoke.expect.status, buildStamp: "[pipeline] lgtmgate@1.0.0-beta.3 cutFrom=abc1234 workflow=deliver-pipeline" },
  agentCount: calls.length,
  workflowProgress: calls.map((c, i) => ({ type: "workflow_agent", index: i, label: c.label, agentId: c.agentId, state: "done" })),
}))
' "$SPROJ" wf_s213
SOUT=$(cd "$SREPO" && CLAUDE_PROJECTS_DIR="$SPROJ" bash "$ROOT/scripts/capture-incident.sh" wf_s213 213 stamp --out "$SREPO/captures" 2>&1); SRC=$?
SCAP="$SREPO/captures/213-stamp.json"
if [ "$SRC" -eq 0 ] && [ -f "$SCAP" ]; then
  DST="$(newdir out-stamp)"
  pub "$SCAP" --out-dir "$DST"
  SPUB="$DST/213-stamp.json"
  SMOKE_ST=$(node -e 'process.stdout.write(JSON.stringify(require(process.env.ROOT+"/fixtures/smoke/auto-lgtm.json").expect.status))')
  if [ "$RC" -eq 0 ] && [ -f "$SPUB" ]; then
    sout=$(OFFLINE_STRICT=1 node scripts/run-offline.cjs "$SPUB" 2>&1 | tail -n 1)
    bout=$(OFFLINE_STRICT=1 node scripts/run-offline.cjs "$SPUB" --fp "$BUMPED" 2>&1 | tail -n 1)
    if [ "$(jsf "$SPUB" 'f.expect.status')" = "$SMOKE_ST" ] && ! grep -q '1\.0\.0-beta\.3' "$SPUB" \
       && [ "$sout" = "[offline] status=ok passed=1 failed=0" ] && [ "$bout" = "[offline] status=ok passed=1 failed=0" ]; then
      ok "buildStamp older run published: replays to its recorded status (current and bumped engine)"
    else
      bad "buildStamp older run publication: status=$(jsf "$SPUB" 'f.expect.status') replay='$sout' bumped='$bout'"
    fi
  else
    bad "buildStamp older run publication: rc=$RC out=$OUT err=$ERR"
  fi
else
  bad "buildStamp older run capture: rc=$SRC out=$SOUT"
fi

# ---- #209: a capture of a run that retried a call holds one entry per engine label ----------------------
# A SYNTHETIC run (never the real projects directory) in the engine's real shape: the scout call was retried once and the
# diagnose call twice; the record holds ONE entry per call ('<label> (retry N)', the agentId of the last attempt), the journal
# N+1 `started` rows '<label>' under one key with a `result` row for the last only. The capture folds them (retries=3), the
# publication carries one entry per engine label on, and the replay reproduces the recorded status.
RPROJ="$TMP/retry-projects"
RREPO="$TMP/retry-repo"
rm -rf "$RPROJ" "$RREPO"
git init -q "$RREPO"
printf 'captures/\n' > "$RREPO/.gitignore"
node -e '
const fs = require("fs"), path = require("path")
const [proj, runId] = process.argv.slice(1)
const smoke = JSON.parse(fs.readFileSync(path.join(process.env.ROOT, "fixtures/smoke/auto-lgtm.json"), "utf8"))
const runDir = path.join(proj, "-proj", "sess1", "subagents", "workflows", runId)
const recFile = path.join(proj, "-proj", "sess1", "workflows", runId + ".json")
fs.mkdirSync(runDir, { recursive: true }); fs.mkdirSync(path.dirname(recFile), { recursive: true })
const RETRIED = { "scout-issue-123-1": 1, "diagnose-issue-123": 2 } // label -> N
const calls = Object.keys(smoke.calls).map((label, i) => ({ label, n: RETRIED[label] || 0, agentId: "ag-" + i, key: "v2:" + (1000 + i).toString(16), value: smoke.calls[label] }))
const rows = [{ type: "launched" }]
for (const c of calls) {
  for (let d = 0; d < c.n; d++) rows.push({ type: "started", agentId: "ag-dead-" + c.agentId + "-" + d, key: c.key, label: c.label, phase: "p" })
  rows.push({ type: "started", agentId: c.agentId, key: c.key, label: c.label, phase: "p" })
  rows.push({ type: "result", agentId: c.agentId, key: c.key, result: c.value })
}
fs.writeFileSync(path.join(runDir, "journal.jsonl"), rows.map((r) => JSON.stringify(r)).join("\n") + "\n")
fs.writeFileSync(recFile, JSON.stringify({
  runId, status: "completed", args: smoke.args, result: { status: smoke.expect.status }, agentCount: calls.length,
  workflowProgress: calls.map((c, i) => ({ type: "workflow_agent", index: i, label: c.n ? c.label + " (retry " + c.n + ")" : c.label, agentId: c.agentId, state: "done" })),
}))
' "$RPROJ" wf_r209
ROUT=$(cd "$RREPO" && CLAUDE_PROJECTS_DIR="$RPROJ" bash "$ROOT/scripts/capture-incident.sh" wf_r209 209 retry --out "$RREPO/captures" 2>&1); RRC=$?
RCAP="$RREPO/captures/209-retry.json"
RLAST=$(printf '%s\n' "$ROUT" | grep 'status=ok out=' || true)
case "$RLAST" in
  *" retries=3") RRET=yes;;
  *) RRET=no;;
esac
if [ "$RRC" -eq 0 ] && [ "$RRET" = yes ] && [ -f "$RCAP" ]; then
  DRT="$(newdir out-retry)"
  pub "$RCAP" --out-dir "$DRT"
  RPUB="$DRT/209-retry.json"
  SMOKE_ST=$(node -e 'process.stdout.write(JSON.stringify(require(process.env.ROOT+"/fixtures/smoke/auto-lgtm.json").expect.status))')
  SMOKE_N=$(node -e 'process.stdout.write(String(Object.keys(require(process.env.ROOT+"/fixtures/smoke/auto-lgtm.json").calls).length))')
  if [ "$RC" -eq 0 ] && [ -f "$RPUB" ]; then
    rout=$(OFFLINE_STRICT=1 node scripts/run-offline.cjs "$RPUB" 2>&1 | tail -n 1)
    if [ "$(jsf "$RPUB" 'f.expect.status')" = "$SMOKE_ST" ] && [ "$(jsf "$RPUB" 'Object.keys(f.calls).length')" = "$SMOKE_N" ] \
       && [ "$(jsf "$RCAP" 'Object.keys(f.calls).length')" = "$SMOKE_N" ] && [ "$(jsf "$RCAP" 'f.expect.status')" = "$SMOKE_ST" ] \
       && ! grep -q '(retry' "$RPUB" && [ "$rout" = "[offline] status=ok passed=1 failed=0" ]; then
      ok "a capture that holds a folded retry publishes: one entry per engine label, replays to its recorded status"
    else
      bad "folded retry publication: status=$(jsf "$RPUB" 'f.expect.status') entries=$(jsf "$RPUB" 'Object.keys(f.calls).length')/$SMOKE_N replay='$rout'"
    fi
  else
    bad "folded retry publication: rc=$RC out=$OUT err=$ERR"
  fi
else
  bad "folded retry capture: rc=$RRC retries-suffix=$RRET out=$ROUT"
fi

# ---- #337: rehash-fixtures re-records the probe digests after an engine change ---------------------------
# The variant engine composes the old abbreviated worktree flag, so every probe command that carries it hashes differently.
REH_ENG="$TMP/engine-short-flag.js"
sed "s/'--worktree'/'--wt'/g" "$ROOT/workflows/deliver-pipeline.js" > "$REH_ENG"
REH_DIR="$(newdir rehash)"
cp "$ROOT/fixtures/smoke/ci-required-failing.json" "$REH_DIR/a.json"
cp "$ROOT/fixtures/smoke/ci-required-failing.json" "$TMP/rehash-orig.json"
out=$(node scripts/lib/rehash-fixtures.cjs --from workflows/deliver-pipeline.js --fp "$REH_ENG" "$REH_DIR" 2>&1 | tail -n 1)
rep=$(OFFLINE_STRICT=1 node scripts/run-offline.cjs "$REH_DIR/a.json" --fp "$REH_ENG" 2>&1 | tail -n 1)
case "$out" in "[rehash] status=ok files=1 hashes=0") R1=no;; "[rehash] status=ok files=1 hashes="*) R1=yes;; *) R1=no;; esac
case "$rep" in *"status=ok passed=1 failed=0"*) R2=yes;; *) R2=no;; esac
if [ "$R1" = yes ] && [ "$R2" = yes ] && ! cmp -s "$REH_DIR/a.json" "$TMP/rehash-orig.json"; then ok "rehash: digests rewritten to the variant engine and the copy replays green against it"; else bad "rehash forward: out='$out' replay='$rep' changed=$(cmp -s "$REH_DIR/a.json" "$TMP/rehash-orig.json" && echo no || echo yes)"; fi
out=$(node scripts/lib/rehash-fixtures.cjs --from "$REH_ENG" --fp workflows/deliver-pipeline.js "$REH_DIR" 2>&1 | tail -n 1)
if cmp -s "$REH_DIR/a.json" "$TMP/rehash-orig.json"; then ok "rehash: running it back restores the file byte for byte"; else bad "rehash back: out='$out' file differs from the original"; fi
cp "$ROOT/fixtures/incidents/151-probe-cmd-mismatch.json" "$REH_DIR/b.json"
out=$(node scripts/lib/rehash-fixtures.cjs --from workflows/deliver-pipeline.js --fp "$REH_ENG" "$REH_DIR/b.json" 2>&1 | tail -n 1)
if cmp -s "$REH_DIR/b.json" "$ROOT/fixtures/incidents/151-probe-cmd-mismatch.json"; then ok "rehash: a digest that never hashed a composed command is left untouched"; else bad "rehash uncoupled: out='$out' file changed"; fi

# ---- assertions a capture names are kept (#507) ----------------------------------------------------------

AS_DIR="$(newdir assertions)"
for v in assert assert-badres assert-badlog assert-badkey assert-empty; do node "$TMP/gen.cjs" "$AS_DIR/$v.json" "$v"; done
node "$TMP/gen.cjs" "$AS_DIR/123-plain.json" base
AS_OUT="$AS_DIR/out"; mkdir -p "$AS_OUT"
pub "$AS_DIR/assert.json" 123-assert --out-dir "$AS_OUT"
ASP="$AS_OUT/123-assert.json"; AS_STDOUT="$OUT"; AS_RC="$RC"
as_strict=$(OFFLINE_STRICT=1 node scripts/run-offline.cjs "$ASP" 2>&1 | tail -n 1)
as_keep=$(jsf "$ASP" 'JSON.stringify([f.expect.resultIncludes, f.expect.logsInclude]) === JSON.stringify([{ branch: f.calls["nick-issue-123"].branch }, ["Diagnosis confirmed: zzlogx9 marker"]]) && f.calls["nick-issue-123"].branch !== "_"' 2>/dev/null)
if [ "$AS_RC" -eq 0 ] && [ "$as_keep" = "true" ] && printf '%s' "$as_strict" | grep -q 'passed=1 failed=0'; then ok "assertions: the published fixture keeps the named resultIncludes and logsInclude, protects the value, and replays strict"; else bad "assertions keep: rc=$AS_RC keep=$as_keep strict=$as_strict"; fi

AS_ENG1="$AS_DIR/engine-badbranch.js"
sed "s/branch: nick?.branch ?? '<unavailable>'/branch: 'x'/" "$ROOT/workflows/deliver-pipeline.js" > "$AS_ENG1"
as_bad=$(node scripts/run-offline.cjs "$ASP" --fp "$AS_ENG1" 2>&1)
pub "$AS_DIR/123-plain.json" 123-plain --out-dir "$AS_OUT"
as_plain=$(OFFLINE_STRICT=1 node scripts/run-offline.cjs "$AS_OUT/123-plain.json" --fp "$AS_ENG1" 2>&1 | tail -n 1)
if printf '%s' "$as_bad" | grep -q 'failed=1' && printf '%s' "$as_bad" | grep -q 'resultIncludes: result.branch' && printf '%s' "$as_plain" | grep -q 'passed=1 failed=0'; then ok "assertions: an engine without the fix fails the published resultIncludes (a plain publication still passes: the defect)"; else bad "assertions resultIncludes: bad=$as_bad plain=$as_plain"; fi

AS_ENG2="$AS_DIR/engine-badlog.js"
sed "s/Diagnosis confirmed: /Diagnosis ok: /" "$ROOT/workflows/deliver-pipeline.js" > "$AS_ENG2"
as_badlog=$(node scripts/run-offline.cjs "$ASP" --fp "$AS_ENG2" 2>&1)
if printf '%s' "$as_badlog" | grep -q 'failed=1' && printf '%s' "$as_badlog" | grep -q 'logs: missing'; then ok "assertions: an engine without the fix fails the published logsInclude"; else bad "assertions logsInclude: $as_badlog"; fi

as_refuse() { # <variant> <stderr needle> <label>
  local d; d="$(newdir "as-$1")"
  pub "$AS_DIR/$1.json" 123-r --out-dir "$d"
  if [ "$RC" -eq 1 ] && [ "$(last_line)" = "[publish-fixture] status=refused" ] && printf '%s' "$ERR" | grep -qF -- "$2" && ! printf '%s' "$ERR" | grep -q -e 'features/other' -e zzabsent -e zzlogx9 && [ -z "$(ls -A "$d")" ]; then ok "assertions: $3"; else bad "assertions refusal $1: rc=$RC err=$ERR left=$(ls -A "$d")"; fi
}
as_refuse assert-badres 'expect.resultIncludes.branch' "refuses a resultIncludes the replay does not reproduce, without its value"
as_refuse assert-badlog 'expect.logsInclude[0]' "refuses a logsInclude needle the replay does not reproduce, without its text"
as_refuse assert-badkey 'cannot keep: trace' "refuses an expect key it cannot keep"
as_refuse assert-empty 'expect.logsInclude must be' "refuses an empty logsInclude"

if [ "$AS_RC" -eq 0 ] && printf '%s\n' "$AS_STDOUT" | grep -q 'expect.resultIncludes.branch [0-9]* free-text' && printf '%s\n' "$AS_STDOUT" | grep -q 'expect.logsInclude\[0\] [0-9]* free-text' && ! printf '%s' "$AS_STDOUT" | grep -q zzlogx9; then ok "assertions: the report lists the kept assertions by path and length, never a value"; else bad "assertions report: $AS_STDOUT"; fi

# ---- usage errors (exit 2, before any filesystem access) ----------------------------------------------

pub
case "$(last_line)" in "[publish-fixture] status=usage-error") [ "$RC" -eq 2 ] && U1=yes || U1=no;; *) U1=no;; esac
UD="$(newdir out-usage)"
pub "$RAW" '../x' --out-dir "$UD"
case "$(last_line)" in "[publish-fixture] status=usage-error") [ "$RC" -eq 2 ] && U2=yes || U2=no;; *) U2=no;; esac
uleft=$(ls -A "$UD" | wc -l | tr -d ' ')
if [ "$U1" = yes ] && [ "$U2" = yes ] && [ "$uleft" = "0" ]; then ok "usage errors exit 2"; else bad "usage errors: no-arg=$U1 bad-name=$U2 left=$uleft"; fi

