#!/usr/bin/env bash
# cause set, layout, acceptanceBoxes, encoder parity, plugin version and probe tools cases (sourced by tests/templates/test-probe-run.sh, never executed).
# [239] the parsers keep the named cause only from the closed set (never an out-of-set string), and add no key when it is absent
ok=0
node -e '
  const assert = require("assert")
  const { PARSERS } = require(process.argv[1])
  const pw = (o) => PARSERS["pr-write"](JSON.stringify(o), "", 0)
  const base = { op: "body-splice", result: "failed", reason: "read-failed", bytes: null }
  for (const c of ["tls", "auth", "rate-limit", "not-found", "other"]) assert.deepStrictEqual(pw({ ...base, detail: c }), { ...base, detail: c })
  for (const bad of ["x509: certificate signed by unknown authority", "TLS", "", null, 7, ["tls"]]) assert.deepStrictEqual(pw({ ...base, detail: bad }), base)
  assert.deepStrictEqual(pw(base), base)
  assert.ok(!("detail" in pw({ op: "status", result: "written", reason: null, bytes: null })))
' "$PR" 2>"$WORK/239p.err" && ok=1
[ "$ok" -eq 1 ] || head -n 3 "$WORK/239p.err"
check "[239] PARSERS pr-write keeps detail only from the closed set and adds no key when absent" "$ok"
ok=0
node -e '
  const assert = require("assert")
  const { PARSERS } = require(process.argv[1])
  const pf = (o) => PARSERS.preflight(JSON.stringify(o), "", 0)
  const base = { mode: "branch", headRef: null, branchPrefix: "feat/" }
  for (const c of ["tls", "auth", "rate-limit", "not-found", "other"]) assert.deepStrictEqual(pf({ ...base, readFailed: c }), { ...base, readFailed: c })
  for (const bad of ["x509: unknown authority", "TLS", "", null, 7]) assert.deepStrictEqual(pf({ ...base, readFailed: bad }), base)
  assert.deepStrictEqual(pf(base), base)
  assert.ok(!("readFailed" in pf({ mode: "dev", planStale: null, openSubIssues: null, gitDir: null, writable: null, readFailed: "tls" })))
' "$PR" 2>"$WORK/239f.err" && ok=1
[ "$ok" -eq 1 ] || head -n 3 "$WORK/239f.err"
check "[239] PARSERS preflight keeps readFailed only from the closed set (branch mode) and adds no key when absent" "$ok"

# [307] layout of the planned paths: preflight.sh dev --engine true runs ls-lint on empty files at the planned paths
PF307="$SCRIPT_DIR/preflight.sh"
if command -v jq >/dev/null 2>&1 && [ -x "$ROOT/node_modules/.bin/ls-lint" ] && [ -f "$ROOT/.ls-lint.yml" ]; then
  W307="$WORK/layout307"; mkdir -p "$W307"
  cp "$ROOT/.ls-lint.yml" "$W307/.ls-lint.yml"; ln -sfn "$ROOT/node_modules" "$W307/node_modules"
  OUT="$(bash "$PF307" dev --wt "$W307" --engine true --targets 'scripts/BadName.cjs templates/ok-name.sh')"
  ok=0
  [ "$(printf '%s' "$OUT" | jq -r '.layout.verdict')" = "NOT_CONFORMING" ] && printf '%s' "$OUT" | jq -r '.layout.issues[]' | grep -q 'scripts/BadName.cjs failed for.*kebabcase' && ok=1
  check "[307] preflight.sh dev --engine true: a non-conforming planned path -> layout NOT_CONFORMING quoting the rule" "$ok"
  OUT="$(bash "$PF307" dev --wt "$W307" --engine true --targets 'templates/ok-name.sh')"
  ok=0
  [ "$(printf '%s' "$OUT" | jq -c '.layout')" = '{"verdict":"CONFORMING","issues":[]}' ] && ok=1
  check "[307] preflight.sh dev --engine true: a conforming planned path -> layout CONFORMING, no issue" "$ok"
  OUT="$(bash "$PF307" dev --wt "$W307" --engine true --targets 'scripts/provision-worktree.sh templates/provision-worktree.sh')"
  ok=0
  [ "$(printf '%s' "$OUT" | jq -c '.layout')" = '{"verdict":"CONFORMING","issues":[]}' ] && ok=1
  check "[344] preflight.sh dev --engine true: the renamed provisioning script paths -> layout CONFORMING" "$ok"
  OUT="$(bash "$PF307" dev --wt "$W307" --targets 'scripts/BadName.cjs')"
  ok=0
  [ "$(printf '%s' "$OUT" | jq -c '.layout')" = "null" ] && [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = "1" ] && ok=1
  check "[307] preflight.sh dev without --engine: layout null, still exactly one line" "$ok"
else
  echo "SKIP - [307] preflight.sh layout e2e needs jq and node_modules/.bin/ls-lint"
  for n307 in a b c d; do check "[307] layout e2e $n307 skipped (ls-lint absent)" 1; done
fi
ok=0
node -e '
  const assert = require("assert")
  const { PARSERS } = require(process.argv[1])
  const mk = (layout) => PARSERS.preflight(JSON.stringify({ mode: "dev", planStale: null, openSubIssues: null, gitDir: null, writable: null, layout }))
  assert.deepStrictEqual(mk({ verdict: "NOT_CONFORMING", issues: ["x failed"] }).layout, { verdict: "NOT_CONFORMING", issues: ["x failed"] })
  assert.strictEqual(mk({ verdict: "MAYBE", issues: [] }).layout, null)
  assert.strictEqual(mk({ verdict: "CONFORMING", issues: [1] }).layout, null)
  assert.strictEqual(mk("bad").layout, null)
  assert.strictEqual(mk(undefined).layout, null)
' "$PR" 2>/dev/null && ok=1
check "[307] PARSERS preflight keeps a well-formed layout and nulls a malformed one" "$ok"

BLK='/^\/\/ --- prBodySplice:start ---/,/^\/\/ --- prBodySplice:end ---/p'
[ -n "$(sed -n "$BLK" "$ROOT/workflows/deliver-pipeline.js")" ] && [ "$(sed -n "$BLK" "$ROOT/workflows/deliver-pipeline.js")" = "$(sed -n "$BLK" "$SCRIPT_DIR/pr-body-splice.cjs")" ] && ok=1 || ok=0
check "pr-body-splice.cjs: source identical to the engine block" "$ok"

# [237] acceptanceBoxes: a first line of only carriage returns is blank whatever their number (the engine file and the template)
for f237 in "$ROOT/workflows/deliver-pipeline.js" "$SCRIPT_DIR/pr-body-splice.cjs"; do
  ok=0
  node -e '
    const fs = require("fs"), assert = require("assert")
    const s = fs.readFileSync(process.argv[1], "utf8")
    const a = s.indexOf("// --- prBodySplice:start ---"), b = s.indexOf("// --- prBodySplice:end ---")
    assert.ok(a >= 0 && b > a, "prBodySplice markers not found")
    const boxes = new Function(s.slice(a, b) + "\nreturn acceptanceBoxes")()
    const rows = [["\r\n", []], ["\r\r\n", []], ["\r\r\r\n", []], ["\n", []], ["note\r\n", ["note"]], [" \r\n", [" "]]]
    for (const [head, foreign] of rows) {
      const got = boxes(head + "- [ ] <!-- ac:1 --> a\r\n")
      assert.deepStrictEqual(got.foreign, foreign, "first line " + JSON.stringify(head) + ": foreign=" + JSON.stringify(got.foreign))
      assert.deepStrictEqual([...got.checkedById], [[1, false]])
    }
  ' "$f237" 2>"$WORK/237.err" && ok=1
  [ "$ok" -eq 1 ] || head -n 3 "$WORK/237.err"
  check "[237] acceptanceBoxes treats a first line of only carriage returns as blank ($(basename "$f237"))" "$ok"
done

SHA_BLK="$(sed -n '/^\/\/ --- sha256Hex:start ---/,/^\/\/ --- sha256Hex:end ---/p' "$ROOT/workflows/deliver-pipeline.js")"
ok=0
[ -n "$SHA_BLK" ] && node -e '
  const assert = require("assert"), crypto = require("crypto")
  const sha = new Function(process.argv[1] + "\nreturn sha256Hex")()
  for (const s of ["", "printf '"'"'hi\\n'"'"'", "abc", "x".repeat(200), "caf\u00e9 \u20ac \ud83d\ude00 \u65e5\u672c"]) {
    assert.strictEqual(sha(s), crypto.createHash("sha256").update(s, "utf8").digest("hex"))
  }
' "$SHA_BLK" 2>/dev/null && ok=1
check "[151] engine sha256Hex equals crypto sha256 (empty, ASCII, 200 bytes, non-ASCII)" "$ok"
B64_BLK="$(sed -n '/^\/\/ --- base64Utf8:start ---/,/^\/\/ --- base64Utf8:end ---/p' "$ROOT/workflows/deliver-pipeline.js")"
ok=0
[ -n "$B64_BLK" ] && node -e '
  const assert = require("assert")
  const b64 = new Function(process.argv[1] + "\nreturn base64Utf8")()
  const cases = ["", "a", "ab", "abc", "abcd", "abcde", "line one\nline two\n", "`tick` \"d\" \x27s\x27 $HOME", "café € 😀 日本", "x".repeat(1000), "- [ ] <!-- ac:1 --> a\n- [ ] <!-- ac:2 --> b"]
  for (const s of cases) {
    const got = b64(s)
    assert.strictEqual(got, Buffer.from(s, "utf8").toString("base64"))
    assert.ok(!got.includes("\n"))
  }
' "$B64_BLK" 2>/dev/null && ok=1
check "[tick-digest] engine base64Utf8 equals Buffer base64 of the UTF-8 bytes (lengths mod 3 = 0/1/2, newline, backtick, quotes, non-ASCII), one line" "$ok"
# parity of both hand-written encoders with Node over lone surrogates (U+D800..U+DFFF encode as U+FFFD, EF BF BD), astral characters, CRLF, empty
cat > "$WORK/parity.cjs" <<'JS'
const assert = require("assert"), crypto = require("crypto")
const [shaBlk, b64Blk] = process.argv.slice(2)
const sha = new Function(shaBlk + "\nreturn sha256Hex")()
const b64 = new Function(b64Blk + "\nreturn base64Utf8")()
const corpus = ["", "\ud800", "\udfff", "a\ud800b", "\udc00\ud800", "x\ud83dy", "\ud83d\ude00", "\ud83d\ude00\ud83d", "\ud83d", "\u{10ffff}\u{10000}",
  "caf\u00e9 \u20ac \u65e5\u672c", "line one\r\nline two\r\n", "\r\n", "a\r\nb\nc\rd", "- [ ] <!-- ac:1 --> a\r\n- [ ] <!-- ac:2 --> b\ud800\r\n", "x".repeat(1000) + "\udc00"]
for (const s of corpus) {
  assert.strictEqual(b64(s), Buffer.from(s).toString("base64"), "base64 " + JSON.stringify(s))
  assert.strictEqual(sha(s), crypto.createHash("sha256").update(Buffer.from(s)).digest("hex"), "sha256 " + JSON.stringify(s))
}
JS
ok=0
[ -n "$SHA_BLK" ] && [ -n "$B64_BLK" ] && node "$WORK/parity.cjs" "$SHA_BLK" "$B64_BLK" 2>"$WORK/parity.err" && ok=1
check "[tick-digest] engine sha256Hex and base64Utf8 equal Node over lone surrogates, astral characters, CRLF and the empty string" "$ok"
node "$PR" --verify --label x --round 0 --out "$WORK/tdv" --parser lines --attest "$WORK/tdv.jsonl" --expect-cmd "$(printf '%064d' 0)" >/dev/null 2>&1
[ "$?" -eq 2 ] && ok=1 || ok=0
check "[tick-digest] --expect-cmd together with --verify exits 2 (usage)" "$ok"
node "$PR" --label x --round 0 --out "$WORK/tdv" --parser lines --expect-cmd not-a-digest --cmd 'true' >/dev/null 2>&1
[ "$?" -eq 0 ] && ok=1 || ok=0
check "[tick-digest] an --expect-cmd that is not 64 hex characters is a refusal (exit 0 and a PROBE line), not a usage error" "$ok"
SAN_LINE="$(grep -m1 '^const sanitizeProbeToken' "$ROOT/workflows/deliver-pipeline.js")"
ok=0
[ -n "$SAN_LINE" ] && [ "$(node -e 'const f = new Function(process.argv[1] + "; return sanitizeProbeToken")(); process.stdout.write(f("PR Ready/Merged:x"))' "$SAN_LINE" 2>/dev/null)" = "PR-Ready-Merged-x" ] && ok=1
check "[151] sanitizeProbeToken maps 'PR Ready/Merged:x' to 'PR-Ready-Merged-x'" "$ok"

# (f2) #195: the plugin-version check. The REAL pluginVersionCmd runs through the REAL probe-run.cjs (parser `lines`)
# against real manifests, and the PROBE line it prints feeds the REAL pluginVersionVerdict. The roots carry a space and a
# single quote on purpose (quoting). The engine version is read from the `const BUILD` line, never hardcoded.
PV_BLK="$(sed -n '/^\/\/ --- pluginVersion:start ---/,/^\/\/ --- pluginVersion:end ---/p' "$ROOT/workflows/deliver-pipeline.js")"
PV_ENGINE="$(sed -n "s/.*const BUILD = {[^}]*version: '\([^']*\)'.*/\1/p" "$ROOT/workflows/deliver-pipeline.js" | head -n 1)"
PV_ROOTS="$WORK/pv roots o'x"
mkdir -p "$PV_ROOTS/same/.claude-plugin" "$PV_ROOTS/old/.claude-plugin" "$PV_ROOTS/bad/.claude-plugin" "$PV_ROOTS/nov/.claude-plugin"
printf '{"name":"lgtmgate","version":"%s"}\n' "$PV_ENGINE" > "$PV_ROOTS/same/.claude-plugin/plugin.json"
printf '{"name":"lgtmgate","version":"0.0.1-old"}\n' > "$PV_ROOTS/old/.claude-plugin/plugin.json"
printf '{not json\n' > "$PV_ROOTS/bad/.claude-plugin/plugin.json"
printf '{"name":"lgtmgate"}\n' > "$PV_ROOTS/nov/.claude-plugin/plugin.json"
pv_verdict() {
  node -e '
    const { spawnSync } = require("child_process")
    const [blk, pr, root, engine, out] = process.argv.slice(1)
    const { pluginVersionCmd, pluginVersionVerdict } = new Function(blk + "\nreturn { pluginVersionCmd, pluginVersionVerdict }")()
    const r = spawnSync("node", [pr, "--label", "pv", "--round", "0", "--out", out, "--parser", "lines", "--no-reuse", "--cmd", pluginVersionCmd(root)], { encoding: "utf8" })
    const m = /^PROBE name=lines exit=(\d+) .* json=(.*)$/m.exec(r.stdout || "")
    if (!m) { process.stdout.write("no-probe-line|" + r.stdout + r.stderr); process.exit(0) }
    const v = pluginVersionVerdict({ engineVersion: engine, pluginRoot: root, exit: Number(m[1]), lines: JSON.parse(m[2]).lines })
    process.stdout.write(v ? v.code + "|" + v.reason : "ok|")
  ' "$PV_BLK" "$PR" "$1" "$PV_ENGINE" "$WORK/pv-out" 2>/dev/null
}
ok=0
[ -n "$PV_BLK" ] && [ -n "$PV_ENGINE" ] && [ "$(pv_verdict "$PV_ROOTS/same")" = "ok|" ] && ok=1
check "[195] a root holding the engine's version ($PV_ENGINE) passes (real command, real probe-run.cjs, real manifest)" "$ok"
PV_OUT="$(pv_verdict "$PV_ROOTS/old")"
ok=0
case "$PV_OUT" in
  *"pv roots"*) ok=0 ;;
  "plugin-version-skew|"*"0.0.1-old"*"$PV_ENGINE"*"pass the current plugin root and relaunch") ok=1 ;;
esac
check "[195] a root holding another version is a plugin-version-skew naming both versions and the remedy, never the root path" "$ok"
PV_OUT="$(pv_verdict "$PV_ROOTS/none")"
ok=0
case "$PV_OUT" in
  *"pv roots"*) ok=0 ;;
  "plugin-version-unreadable|"*".claude-plugin/plugin.json (missing)"*"pass the current plugin root and relaunch") ok=1 ;;
esac
check "[195] a root without a manifest fails closed as plugin-version-unreadable (missing), never naming the root path" "$ok"
PV_OUT="$(pv_verdict "$PV_ROOTS/bad")"
ok=0
case "$PV_OUT" in
  "plugin-version-unreadable|"*"(unreadable)"*"pass the current plugin root and relaunch") ok=1 ;;
esac
check "[195] a manifest that is not JSON fails closed as plugin-version-unreadable (unreadable)" "$ok"
PV_OUT="$(pv_verdict "$PV_ROOTS/nov")"
ok=0
case "$PV_OUT" in
  "plugin-version-unreadable|"*"(no-version)"*"pass the current plugin root and relaunch") ok=1 ;;
esac
check "[195] a manifest without a version fails closed as plugin-version-unreadable (no-version)" "$ok"

# (f3) #338: the plugin-version command reaches the probe as ONE bare base64 token (--cmd-b64), never as nested quoting a
# model must re-type. The REAL probeCommands + base64Utf8 of the engine build the run line for the REAL pluginVersionCmd of a
# root carrying a space and a single quote; the line runs through sh against the REAL probe-run.cjs.
PB_BLK="$(sed -n '/^\/\/ --- probeCommands:start ---/,/^\/\/ --- probeCommands:end ---/p;/^\/\/ --- base64Utf8:start ---/,/^\/\/ --- base64Utf8:end ---/p' "$ROOT/workflows/deliver-pipeline.js")"
PB_WT="$WORK/pb wt"
mkdir -p "$PB_WT"
# pb_line <root> <old|b64> -> the run line; pb_cmd <root> -> the composed command
pb_line() {
  node -e '
    const crypto = require("crypto")
    const [blk, pv, pr, root, wt, mode] = process.argv.slice(1)
    const f = new Function(blk + "\n" + pv + "\nreturn { probeCommands, base64Utf8, pluginVersionCmd }")()
    const cmd = f.pluginVersionCmd(root)
    const want = crypto.createHash("sha256").update(cmd).digest("hex")
    const o = { wtPath: wt, issue: 338, probeRunPath: pr, name: "lines", cmd, label: "pb", round: 0, noReuse: true, expectCmd: want }
    if (mode === "b64") o.cmdB64 = f.base64Utf8(cmd)
    process.stdout.write(f.probeCommands(o).run)
  ' "$PB_BLK" "$PV_BLK" "$PR" "$1" "$PB_WT" "$2" 2>/dev/null
}
pb_cmd() { node -e 'const f = new Function(process.argv[1] + "\nreturn pluginVersionCmd")(); process.stdout.write(f(process.argv[2]))' "$PV_BLK" "$1" 2>/dev/null; }
PB_LINE="$(pb_line "$PV_ROOTS/same" b64)"
PB_CMD="$(pb_cmd "$PV_ROOTS/same")"
PB_TOK="${PB_LINE##* --cmd-b64 }"
ok=0
case "$PB_LINE" in
  *" --cmd-b64 "*) case "$PB_TOK" in *"'"*|*" "*) ok=0 ;; *) [ -n "$PB_TOK" ] && ok=1 ;; esac ;;
esac
check "[338] the engine's run line for the plugin-version command ends in one bare --cmd-b64 token (no quote)" "$ok"
ok=1
case "$PB_LINE" in *" --cmd '"*) ok=0 ;; esac
[ -n "$PB_LINE" ] || ok=0
check "[338] the b64 run line carries no --cmd flag" "$ok"
PB_OUT="$(sh -c "$PB_LINE" 2>&1)"
ok=0
[ "$(td_field "$PB_OUT" exit)" = "0" ] && [ "$(td_field "$PB_OUT" cmd)" = "$(td_sha "$PB_CMD")" ] && [ -n "$PB_CMD" ] && ok=1
check "[338] the command delivered as built by the engine runs (exit=0, cmd= is the sha256 of the composed command)" "$ok"
# one character of the token altered: the decoded text misses the digest, nothing runs
PB_BAD="${PB_LINE%$PB_TOK}A${PB_TOK#?}"
[ "$PB_BAD" = "$PB_LINE" ] && PB_BAD="${PB_LINE%$PB_TOK}B${PB_TOK#?}"
PB_OUT="$(sh -c "$PB_BAD" 2>&1)"
ok=0
[ "$(td_field "$PB_OUT" exit)" = "-1" ] && [ "$(td_field "$PB_OUT" cmd)" != "$(td_sha "$PB_CMD")" ] && ok=1
check "[338] a token altered in the copy runs nothing (exit=-1, digest mismatch)" "$ok"
# usage: --cmd-b64 needs --expect-cmd, excludes --cmd, and is exec-mode only
node "$PR" --label pbu --round 0 --out "$WORK/pb-out" --parser lines --cmd-b64 "$PB_TOK" >/dev/null 2>&1; PB_E1=$?
node "$PR" --label pbu --round 0 --out "$WORK/pb-out" --parser lines --expect-cmd "$(td_sha "$PB_CMD")" --cmd-b64 "$PB_TOK" --cmd 'true' >/dev/null 2>&1; PB_E2=$?
node "$PR" --verify --label pbu --round 0 --out "$WORK/pb-out" --parser lines --attest "$WORK/pb-attest.jsonl" --cmd-b64 "$PB_TOK" >/dev/null 2>&1; PB_E3=$?
ok=0
[ "$PB_E1" = "2" ] && [ "$PB_E2" = "2" ] && [ "$PB_E3" = "2" ] && ok=1
check "[338] --cmd-b64 without --expect-cmd, with --cmd, or with --verify is a usage error (exit 2)" "$ok"
# the old --cmd form with its final quote dropped dies in the shell before probe-run.cjs starts: no record (why b64 exists)
PB_OLD="$(pb_line "$PV_ROOTS/same" old)"
PB_DROP="${PB_OLD%\'}"
rm -f "$PB_WT/.pipeline/probes/issue-338/pb-r0.json"
ok=0
if [ -n "$PB_OLD" ] && [ "$PB_DROP" != "$PB_OLD" ]; then
  sh -c "$PB_DROP" >/dev/null 2>&1; PB_E4=$?
  PB_REC="$(cd "$PB_WT" && ls .pipeline/probes/issue-338/pb-r0.json 2>/dev/null)"
  [ "$PB_E4" != "0" ] && [ -z "$PB_REC" ] && ok=1
fi
check "[338] the old --cmd form with the final quote dropped fails in the shell and leaves no record" "$ok"

# (g) agents/probe.md tools: lists exactly Bash
TOOLS="$(awk '/^---$/{f++; next} f==1 && /^tools:/{t=1; next} f==1 && t && /^  - /{sub(/^  - /,""); print; next} f==1 && t{t=0}' "$ROOT/agents/probe.md" | tr '\n' ',')"
[ "$TOOLS" = "Bash," ] && ok=1 || ok=0
check "agents/probe.md tools is exactly Bash (got '$TOOLS')" "$ok"
