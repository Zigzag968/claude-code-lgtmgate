#!/usr/bin/env bash
# Regression test for the `already-done` mode of scripts/runtime/preflight.sh (#585): the issue state and the newest
# merged PR of the branch, by REST, and their path through the `preflight` parser into the engine's acceptAlreadyDone.
# `gh` is a stub first on PATH that answers from files; nothing reaches the network.
# Prints `PASS: <name>` per case and a last line `[already-done-test] passed=<n> failed=<m>`.
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_DIR/scripts/runtime/preflight.sh"
PROBE="$REPO_DIR/scripts/runtime/probe-run.cjs"
ENGINE="$REPO_DIR/workflows/deliver-pipeline.js"

TMP_BASE="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
WORK="$(mktemp -d "$TMP_BASE/already-done-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass_count=0
fail_count=0

check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass_count=$((pass_count + 1)); echo "PASS: $1"; else fail_count=$((fail_count + 1)); echo "FAIL: $1 (expected '$2', got '$3')"; fi
}

# The stub: `gh api repos/o/r/issues/<N>` prints $FIX/issue.json, `gh api -X GET repos/o/r/pulls ...` prints $FIX/pulls.json.
# Every argv is appended to $FIX/argv.log. GH_STUB_FAIL=tls fails every call with a TLS stderr; GH_STUB_FAIL_ONCE=1 fails
# the first call only (counter file).
BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX/argv.log"
if [ "${GH_STUB_FAIL:-}" = "tls" ]; then echo "tls: failed to verify certificate: x509: OSStatus -26276 https://api.github.com/ token ghp_secret" >&2; exit 1; fi
if [ "${GH_STUB_FAIL_ONCE:-}" = "1" ] && [ ! -f "$FIX/failed-once" ]; then : > "$FIX/failed-once"; echo "HTTP 502" >&2; exit 1; fi
[ "$1" = "api" ] || exit 1
case "$*" in
  *repos/acme/widgets/pulls*) f="$FIX/pulls.json" ;;
  *repos/acme/widgets/issues/585*) f="$FIX/issue.json" ;;
  *) exit 1 ;;
esac
[ -f "$f" ] && cat "$f" || exit 1
STUB
chmod +x "$BIN/gh"

new_fix() { FIX="$(mktemp -d "$WORK/fx.XXXXXX")"; export FIX; : > "$FIX/argv.log"; }
issue() { printf '{"number":585,"state":"%s","created_at":"2026-10-17T15:39:22Z"}' "$1" > "$FIX/issue.json"; } # REST state is lower case
# pulls <json array> : the closed PRs of the branch.
pulls() { printf '%s' "$1" > "$FIX/pulls.json"; }
pr() { # pr <number> <merged_at|null> <body>
  local m="$2"; [ "$m" = "null" ] || m="\"$2\""
  jq -nc --argjson n "$1" --argjson m "$m" --arg b "$3" '{number:$n, merged_at:$m, head:{ref:"feat/issue-585"}, body:$b}'
}
run() { PATH="$BIN:$PATH" bash "$SCRIPT" already-done --worktree "$WORK" --issue 585 --branch "${BRANCH_ARG:-feat/issue-585}" --repo acme/widgets 2>/dev/null; }
field() { printf '%s' "$1" | jq -r "$2"; }

# 1. open issue, no PR -> nothing done
new_fix; issue open; pulls '[]'
out="$(run)"
check "open-issue-no-merged-pr" 'false|false|OPEN|false|false' "$(field "$out" '[.isAlreadyDone,.isIssueClosed,.issueState,.isMerged,.mergedPrClosesIssue]|map(tostring)|join("|")')"

# 2. closed issue
new_fix; issue closed; pulls '[]'
out="$(run)"
check "closed-issue" 'true|CLOSED|2026-10-17T15:39:22Z' "$(field "$out" '[.isAlreadyDone,.issueState,.issueCreatedAt]|map(tostring)|join("|")')"

# 3. merged PR whose body closes the issue
new_fix; issue open; pulls "[$(pr 586 2026-10-17T16:27:38Z 'Closes #585')]"
out="$(run)"
check "merged-pr-closes-issue" 'true|true|586|feat/issue-585|true|2026-10-17T16:27:38Z' "$(field "$out" '[.isAlreadyDone,.isMerged,.mergedPr,.mergedHeadRef,.mergedPrClosesIssue,.mergedAt]|map(tostring)|join("|")')"

# 4. merged PR that only references the issue
new_fix; issue open; pulls "[$(pr 586 2026-10-17T16:27:38Z 'Refs #585')]"
out="$(run)"
check "refs-only-does-not-close" 'false|true|false' "$(field "$out" '[.isAlreadyDone,.isMerged,.mergedPrClosesIssue]|map(tostring)|join("|")')"

# 5. #5850 is not #585
new_fix; issue open; pulls "[$(pr 586 2026-10-17T16:27:38Z 'Closes #5850')]"
out="$(run)"
check "longer-number-does-not-close" 'false' "$(field "$out" '.mergedPrClosesIssue|tostring')"

# 6. of two merged PRs the later merged_at wins
new_fix; issue open; pulls "[$(pr 600 2026-10-16T10:00:00Z 'Closes #585'),$(pr 601 2026-10-18T10:00:00Z 'Refs #585')]"
out="$(run)"
check "newest-merged-wins" '601|false' "$(field "$out" '[.mergedPr,.mergedPrClosesIssue]|map(tostring)|join("|")')"

# 7. a closed, unmerged PR is ignored
new_fix; issue open; pulls "[$(pr 602 null 'Closes #585')]"
out="$(run)"
check "closed-unmerged-pr-ignored" 'false|null|' "$(field "$out" '[.isMerged,.mergedPr,.mergedHeadRef]|map(tostring)|join("|")')"

# 8. the REST read names the owner and the branch, a slash included
new_fix; issue open; pulls '[]'
BRANCH_ARG='feat/issue-585-part-2' run >/dev/null
check "argv-carries-owner-and-branch" '1' "$(grep -c -F 'head=acme:feat/issue-585-part-2' "$FIX/argv.log")"

# 9. a TLS failure is a named class, never the stderr text
new_fix; issue open; pulls '[]'
out="$(GH_STUB_FAIL=tls run)"
check "tls-failure-names-the-class-only" '{"mode":"already-done","checkFailed":true,"error":"tls"}' "$out"

# 10. one failure is retried with the same command
new_fix; issue open; pulls '[]'
out="$(GH_STUB_FAIL_ONCE=1 run)"
check "one-failure-is-retried" 'false|OPEN' "$(field "$out" '[.checkFailed,.issueState]|map(tostring)|join("|")')"

# 11. a failing gh still prints exactly one line and exits 0
new_fix; issue open; pulls '[]'
out="$(GH_STUB_FAIL=tls PATH="$BIN:$PATH" bash "$SCRIPT" already-done --worktree "$WORK" --issue 585 --branch feat/issue-585 --repo acme/widgets 2>/dev/null)"; rc=$?
check "failing-gh-one-line-exit-0" '1|0' "$(printf '%s\n' "$out" | wc -l | tr -d ' ')|$rc"

# 12. the parser keeps the success and the failure shapes
shapes="$(node -e '
const {PARSERS}=require(process.argv[1])
const ok=PARSERS.preflight(JSON.stringify({mode:"already-done",isAlreadyDone:true,isIssueClosed:false,issueState:"OPEN",issueCreatedAt:"2026-10-17T15:39:22Z",isMerged:true,mergedAt:"2026-10-17T16:27:38Z",mergedPr:586,mergedHeadRef:"feat/issue-581",mergedPrClosesIssue:true,checkFailed:false}))
const bad=PARSERS.preflight(JSON.stringify({mode:"already-done",checkFailed:true,error:"tls"}))
process.stdout.write(JSON.stringify(ok)+"\n"+JSON.stringify(bad))' "$PROBE")"
check "parser-success-and-failure-shapes" '{"mode":"already-done","isAlreadyDone":true,"isIssueClosed":false,"issueState":"OPEN","issueCreatedAt":"2026-10-17T15:39:22Z","isMerged":true,"mergedAt":"2026-10-17T16:27:38Z","mergedPr":586,"mergedHeadRef":"feat/issue-581","mergedPrClosesIssue":true,"checkFailed":false}
{"mode":"already-done","checkFailed":true,"error":"tls"}' "$shapes"

# 13. malformed fields normalise to non-accepting values
malformed="$(node -e '
const {PARSERS}=require(process.argv[1])
const v=PARSERS.preflight(JSON.stringify({mode:"already-done",isAlreadyDone:"true",isIssueClosed:1,issueState:5,issueCreatedAt:"",isMerged:"yes",mergedAt:7,mergedPr:"586",mergedHeadRef:null,mergedPrClosesIssue:"true",checkFailed:"no"}))
const bad=PARSERS.preflight(JSON.stringify({mode:"already-done",checkFailed:true,error:"secret text"}))
process.stdout.write(JSON.stringify(v)+"\n"+JSON.stringify(bad))' "$PROBE")"
check "parser-malformed-fields-non-accepting" '{"mode":"already-done","isAlreadyDone":false,"isIssueClosed":false,"issueState":null,"issueCreatedAt":null,"isMerged":false,"mergedAt":"","mergedPr":null,"mergedHeadRef":"","mergedPrClosesIssue":false,"checkFailed":false}
{"mode":"already-done","checkFailed":true}' "$malformed"

# Parity: script output -> parser -> the engine's own acceptAlreadyDone (extracted by its markers).
verdict() { # verdict <script stdout> -> {"accepted":..,"reason":..}
  printf '%s' "$1" | node -e '
const fs=require("fs")
const {PARSERS}=require(process.argv[1])
const src=fs.readFileSync(process.argv[2],"utf8")
const block=src.slice(src.indexOf("// --- acceptAlreadyDone:start"),src.indexOf("// --- acceptAlreadyDone:end"))
const accept=new Function(block+"\nreturn acceptAlreadyDone")()
const guard=PARSERS.preflight(fs.readFileSync(0,"utf8"))
process.stdout.write(JSON.stringify(accept(guard,"feat/issue-585","")))' "$PROBE" "$ENGINE"
}

# 14. a merged PR that closes the issue is accepted as merged
new_fix; issue open; pulls "[$(pr 586 2026-10-17T16:27:38Z 'Closes #585')]"
check "parity-merged-accepted" '{"accepted":true,"reason":"merged"}' "$(verdict "$(run)")"

# 15. a refs-only merged PR is refused by the engine's own verdict
new_fix; issue open; pulls "[$(pr 586 2026-10-17T16:27:38Z 'Refs #585')]"
check "parity-refs-only-refused" '{"accepted":false,"reason":"merged-pr-does-not-close-issue"}' "$(verdict "$(run)")"

echo "[already-done-test] passed=${pass_count} failed=${fail_count}"
[ "$fail_count" -eq 0 ]
