#!/usr/bin/env bash
# Regression test for scripts/runtime/merged-dependencies.cjs (#545): the merged `depends-on:` issues and the epic parent of an
# issue, by REST. `gh` is a stub first on PATH that answers from files; nothing reaches the network.
# Prints `PASS: <name>` per case and a last line `[merged-dependencies-test] passed=<n> failed=<m>`.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_DIR/scripts/runtime/merged-dependencies.cjs"

TMP_BASE="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
WORK="$(mktemp -d "$TMP_BASE/merged-dependencies-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass_count=0
fail_count=0

check() { # check <name> <expected stdout> <actual stdout>
  if [ "$2" = "$3" ]; then pass_count=$((pass_count + 1)); echo "PASS: $1"; else fail_count=$((fail_count + 1)); echo "FAIL: $1 (expected '$2', got '$3')"; fi
}

# The stub: `gh api repos/o/r/issues/<N>[/parent]` prints $FIX/issue-<N>.json or $FIX/parent-<N>.json, else exits 1.
BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
[ "${GH_STUB_FAIL:-}" = "1" ] && exit 1
[ "$1" = "api" ] || exit 1
path="$2"; n="${path##*issues/}"
case "$n" in
  */parent) f="$FIX/parent-${n%/parent}.json" ;;
  *) f="$FIX/issue-$n.json" ;;
esac
[ -f "$f" ] && cat "$f" || exit 1
STUB
chmod +x "$BIN/gh"

new_fix() { FIX="$(mktemp -d "$WORK/fx.XXXXXX")"; export FIX; }
issue() { printf '{"number":%s,"state":"%s","state_reason":%s,"body":%s}' "$1" "$2" "$3" "$4" > "$FIX/issue-$1.json"; }
run() { PATH="$BIN:$PATH" node "$SCRIPT" --issue 545 --repo acme/widgets 2>/dev/null; }

# 1. every dependency closed as completed -> all merged, plus the epic
new_fix
issue 545 open null '"intro\ndepends-on: #530, #531, #532\nmore"'
for n in 530 531 532; do issue $n closed '"completed"' 'null'; done
printf '{"number":528}' > "$FIX/parent-545.json"
check "all-closed-completed" '{"merged":[530,531,532],"epic":528}' "$(run)"

# 2. an open dependency and a closed-not_planned one are left out
new_fix
issue 545 open null '"depends-on: #530 #531 #532"'
issue 530 closed '"completed"' null; issue 531 open null null; issue 532 closed '"not_planned"' null
check "open-and-not-planned-left-out" '{"merged":[530]}' "$(run)"

# 3. depends-on: none and no depends-on line -> nothing on stdout
new_fix; issue 545 open null '"depends-on: none"'
check "depends-on-none" '' "$(run)"
new_fix; issue 545 open null '"just a body"'
check "no-depends-on-line" '' "$(run)"

# 4. the epic alone (parent present, no dependency)
new_fix; issue 545 open null '"depends-on: none"'; printf '{"number":7}' > "$FIX/parent-545.json"
check "epic-only" '{"epic":7}' "$(run)"

# 5. a parent lookup that fails (404) writes no epic key
new_fix
issue 545 open null '"depends-on: #530"'; issue 530 closed '"completed"' null
check "parent-404-no-epic-key" '{"merged":[530]}' "$(run)"

# 6. gh failing -> empty stdout and exit 0
new_fix
out="$(GH_STUB_FAIL=1 PATH="$BIN:$PATH" node "$SCRIPT" --issue 545 --repo acme/widgets 2>/dev/null)"; rc=$?
check "gh-failing-empty-stdout" '' "$out"
check "gh-failing-exit-0" '0' "$rc"

# 7. at most 20 dependencies are read
new_fix
deps=""; for n in $(seq 100 130); do deps="$deps #$n"; issue $n closed '"completed"' null; done
issue 545 open null "\"depends-on:$deps\""
check "at-most-20-dependencies" '20' "$(run | node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(0,"utf8")).merged.length))')"

# 8. usage errors exit 2
node "$SCRIPT" --issue 545 >/dev/null 2>&1; check "missing-repo-exit-2" '2' "$?"
node "$SCRIPT" --issue abc --repo acme/widgets >/dev/null 2>&1; check "bad-issue-exit-2" '2' "$?"
node "$SCRIPT" --issue 545 --repo 'not a repo' >/dev/null 2>&1; check "bad-repo-exit-2" '2' "$?"

# 9. the issue title (#599): derived as is when short, cut at a word boundary within 80 bytes when long, absent when gh fails
title_of() { run | node -e 'const o = JSON.parse(require("fs").readFileSync(0, "utf8")); process.stdout.write(o.title === undefined ? "" : o.title)'; }
new_fix; printf '{"number":545,"state":"open","state_reason":null,"body":"depends-on: none","title":"Derive the run title"}' > "$FIX/issue-545.json"
check "title-derived" 'Derive the run title' "$(title_of)"
new_fix; printf '{"number":545,"state":"open","state_reason":null,"body":"x","title":"%s"}' "Hook sets the run title from the issue title and cuts it when it is far too long for one line" > "$FIX/issue-545.json"
check "title-cut (long, multi-word: within 80 bytes, ends with an ellipsis, cut on a word boundary)" 'ok' "$(title_of | node -e 'const t = require("fs").readFileSync(0, "utf8"); const src = "Hook sets the run title from the issue title and cuts it when it is far too long for one line"; const body = t.slice(0, -1); process.stdout.write(Buffer.byteLength(t) <= 80 && t.endsWith("…") && src.startsWith(body) && src[body.length] === " " ? "ok" : "bad:" + t)')"
new_fix; printf '{"number":545,"state":"open","state_reason":null,"body":"x","title":"%s"}' "$(node -e 'process.stdout.write("é".repeat(30) + " " + "ü".repeat(30) + " " + "ñ".repeat(30))')" > "$FIX/issue-545.json"
check "title-cut (multi-byte: still within 80 bytes with the 3-byte ellipsis)" 'ok' "$(title_of | node -e 'const t = require("fs").readFileSync(0, "utf8"); process.stdout.write(Buffer.byteLength(t) <= 80 && t.endsWith("…") && t.length > 1 ? "ok" : "bad:" + t)')"
new_fix; printf '{"number":545,"state":"open","state_reason":null,"body":"x","title":"Derive the run title"}' > "$FIX/issue-545.json"
out="$(GH_STUB_FAIL=1 PATH="$BIN:$PATH" node "$SCRIPT" --issue 545 --repo acme/widgets 2>/dev/null)"
check "title-absent-when-gh-fails" '' "$out"

echo "[merged-dependencies-test] passed=${pass_count} failed=${fail_count}"
[ "$fail_count" -eq 0 ]
