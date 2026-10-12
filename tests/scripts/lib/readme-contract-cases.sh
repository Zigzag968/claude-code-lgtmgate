#!/usr/bin/env bash
# readme-contract cases (#159), sourced by tests/scripts/test-guards.sh (uses its ok/ko helpers, $T and $REPO_ROOT).
# The real suites are never run here: the counts come from a file built from the README itself (GUARDS_TEST_COUNTS).

# mkrc <dir>: a minimal root holding copies of what the rule reads.
mkrc() {
  mkdir -p "$1/workflows" "$1/templates" "$1/scripts"
  cp "$REPO_ROOT/README.md" "$1/README.md"
  cp "$REPO_ROOT/workflows/deliver-pipeline.js" "$1/workflows/deliver-pipeline.js"
  cp "$REPO_ROOT/templates/pipeline.config.template.json" "$1/templates/pipeline.config.template.json"
  cp "$REPO_ROOT/scripts/agent-context.cjs" "$1/scripts/agent-context.cjs"
}
# run_rc <dir> [counts-file] -> sets RC and OUT
run_rc() { OUT="$(GUARDS_ROOT="$1" GUARDS_ONLY=readme-contract GUARDS_TEST_COUNTS="${2:-$RC_COUNTS}" node "$REPO_ROOT/scripts/guards.cjs" 2>&1)"; RC=$?; }

RC_COUNTS="$T/rc-counts.json"
node -e '
const fs = require("fs"), readme = fs.readFileSync(process.argv[1], "utf8"), { SUITES } = require(process.argv[2])
const counts = {}
for (const s of SUITES) counts[s.label] = Number(new RegExp("`" + s.label.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "` \\((\\d+)").exec(readme)[1])
fs.writeFileSync(process.argv[3], JSON.stringify(counts))
' "$REPO_ROOT/README.md" "$REPO_ROOT/scripts/lib/count-tests.cjs" "$RC_COUNTS"

mkrc "$T/rc-real"
run_rc "$T/rc-real"
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q '^PASS: readme-contract:'; then ok "readme-contract: the real README with matching counts -> PASS"; else ko "readme-contract real (rc=$RC) $OUT"; fi

run_rc "$T/rc-no-readme-root"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '^FAIL: readme-contract: README.md is missing'; then ok "readme-contract: no README -> FAIL naming the file"; else ko "readme-contract no README (rc=$RC) $OUT"; fi

# rc_case <name> <sed-expression>: a copy of the README edited by sed.
rc_case() { mkrc "$T/rc-$1"; sed -E "$2" "$REPO_ROOT/README.md" > "$T/rc-$1/README.md"; run_rc "$T/rc-$1"; }

rc_case nostatus 's/^## Status$/## Situation/'
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qF "has no section '## Status'"; then ok "readme-contract: no Status section -> FAIL naming it"; else ko "readme-contract no Status (rc=$RC) $OUT"; fi
rc_case nolimits 's/^## Known limitations$/## Notes/'
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qF "has no section '## Known limitations'"; then ok "readme-contract: no Known limitations section -> FAIL naming it"; else ko "readme-contract no limitations (rc=$RC) $OUT"; fi
rc_case norisk 's/^## Use at your own risk$/## Warranty/'
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qF "has no section '## Use at your own risk'"; then ok "readme-contract: no Use at your own risk section -> FAIL naming it"; else ko "readme-contract no risk (rc=$RC) $OUT"; fi

rc_case staticbadge 's#^(\[!\[License\]\()https://img.shields.io/github/license/[^)]*#\1https://img.shields.io/badge/tests-123-green#'
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qF 'hand-written number in badge URL: img.shields.io/badge/tests-123-green'; then ok "readme-contract: static numeric badge -> FAIL naming it"; else ko "readme-contract static badge (rc=$RC) $OUT"; fi
rc_case nobadge 's#img\.shields\.io/github/last-commit/#img.shields.io/github/commit-activity/#'
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qF "no dynamic badge 'img.shields.io/github/last-commit/'"; then ok "readme-contract: a required dynamic badge removed -> FAIL naming it"; else ko "readme-contract no badge (rc=$RC) $OUT"; fi

rc_case stalecount 's#(`tests/hooks/test-deny-destructive-git.sh` \()[0-9]+#\1999#'
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qF 'states 999 for suite tests/hooks/test-deny-destructive-git.sh'; then ok "readme-contract: stale test count -> FAIL naming the suite"; else ko "readme-contract stale count (rc=$RC) $OUT"; fi

mkrc "$T/rc-engine"
grep -v '^| `classifierOutage` |' "$REPO_ROOT/README.md" > "$T/rc-engine/README.md"
run_rc "$T/rc-engine"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qF "no row for config key 'classifierOutage'"; then ok "readme-contract: engine config key missing from the table -> FAIL naming it"; else ko "readme-contract engine key (rc=$RC) $OUT"; fi

mkrc "$T/rc-template"
node -e '
const fs = require("fs"), f = process.argv[1], t = JSON.parse(fs.readFileSync(f, "utf8"))
t.zzNewTemplateKey = true
fs.writeFileSync(f, JSON.stringify(t))
' "$T/rc-template/templates/pipeline.config.template.json"
run_rc "$T/rc-template"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qF "no row for config key 'zzNewTemplateKey'"; then ok "readme-contract: template config key missing from the table -> FAIL naming it"; else ko "readme-contract template key (rc=$RC) $OUT"; fi

mkrc "$T/rc-env"
printf '#!/usr/bin/env bash\necho "${LGTMGATE_ZZ_UNDOCUMENTED:-}"\n' > "$T/rc-env/scripts/x.sh"
run_rc "$T/rc-env"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qF 'does not document environment variable LGTMGATE_ZZ_UNDOCUMENTED'; then ok "readme-contract: env var missing from the section -> FAIL naming it"; else ko "readme-contract env var (rc=$RC) $OUT"; fi

PARSED="$(node -e '
const { SUITES, parse } = require(process.argv[1])
const flow = parse(SUITES[0], { status: 0, stdout: "x\nResults: 365/365 passed\n", stderr: "" })
const unit = parse(SUITES[1], { status: 0, stdout: "", stderr: "....\nRan 512 tests in 17.2s\n\nOK (skipped=1)\n" })
const pass = parse(SUITES[2], { status: 0, stdout: "a\n9/9 PASS\n", stderr: "" })
console.log([flow.count, unit.count, pass.count].join(","))
' "$REPO_ROOT/scripts/lib/count-tests.cjs")"
if [ "$PARSED" = "365,512,9" ]; then ok "readme-contract: count parsers read the three summary formats -> ok"; else ko "readme-contract parsers got $PARSED"; fi

REFUSED="$(node -e '
const { SUITES, parse } = require(process.argv[1])
const failed = parse(SUITES[0], { status: 1, stdout: "Results: 3/3 passed\n", stderr: "" })
const none = parse(SUITES[2], { status: 0, stdout: "nothing\n", stderr: "" })
const partial = parse(SUITES[3], { status: 0, stdout: "5/6 PASS\n", stderr: "" })
const notOk = parse(SUITES[1], { status: 0, stdout: "", stderr: "Ran 4 tests in 1s\n\nFAILED (failures=1)\n" })
console.log([failed, none, partial, notOk].map((r) => (r.error ? "error" : "count")).join(","))
' "$REPO_ROOT/scripts/lib/count-tests.cjs")"
if [ "$REFUSED" = "error,error,error,error" ]; then ok "readme-contract: count parser refuses a failed or unparsable suite -> ok"; else ko "readme-contract refusal got $REFUSED"; fi

# The endpoint payload is checked against the Shields schema (required schemaVersion 1, label, message; optional color), not against the emitter's own literal.
ENDPOINT="$(node -e '
const { endpointJson } = require(process.argv[1])
const x = JSON.parse(JSON.stringify(endpointJson(961)))
const allowed = ["schemaVersion", "label", "message", "color"]
const good = Object.keys(x).every((k) => allowed.includes(k)) && x.schemaVersion === 1 && typeof x.label === "string" && x.label !== "" && typeof x.message === "string" && x.message.startsWith("961 ") && typeof x.color === "string"
console.log(good ? "valid" : "invalid " + JSON.stringify(x))
' "$REPO_ROOT/scripts/lib/count-tests.cjs")"
if [ "$ENDPOINT" = "valid" ]; then ok "readme-contract: the counter writes the endpoint JSON -> ok"; else ko "readme-contract endpoint $ENDPOINT"; fi
