#!/usr/bin/env bash
# Self-test of scripts/init-specifics.cjs (#267, epic #261) and of the init hint of
# hooks/SessionStart/inject_stub.py. Stories US-C1 (init detects, proposes, creates stubs) and
# US-C8 (the owner's rules survive: init never overwrites, never copies the plugin).
# Everything runs in $TMPDIR trees built from fixtures/specifics/init-trees/*.txt (one relative path per
# line, materialised as empty files); nothing is written in the repository.
# bash 3.2 compatible. Trailer: [test-init-specifics] status=<ok|fail> passed=<n> failed=<n>
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
IS="$ROOT/scripts/init-specifics.cjs"
TREES="$ROOT/fixtures/specifics/init-trees"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/init-specifics-selftest.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# tree <name|-> : a fresh dir, filled from the path list <name>.txt (or empty); prints its path
tree() {
  local d
  d="$(mktemp -d "$TMP/t.XXXXXX")"
  if [ "$1" != "-" ]; then
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      mkdir -p "$d/$(dirname "$p")"
      : > "$d/$p"
    done < "$TREES/$1.txt"
  fi
  echo "$d"
}
# jx <json-file> <expr>: evaluates a JS expression over the parsed JSON (j)
jx() {
  node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String(new Function("j","return ("+process.argv[2]+")")(j)))' "$1" "$2"
}
sums() { (cd "$1/.claude/lgtmgate" && shasum -a 256 *.md); }

# create-6-stubs
D=$(tree -)
node "$IS" --root "$D" > "$TMP/out" 2>"$TMP/err"; rc=$?
LS=$(ls "$D/.claude/lgtmgate" | tr '\n' ' ')
if [ "$rc" -eq 0 ] && [ "$LS" = "mia.md morgan.md nick.md sam.md shared.md theo.md " ] && [ "$(jx "$TMP/out" 'j.created.length')" = "6" ] && [ "$(jx "$TMP/out" 'j.kept.length')" = "0" ]; then ok "create-6-stubs"; else bad "create-6-stubs (rc=$rc) [$LS]"; fi

# relaunch-modified-stub-0-writes
printf 'rules of the owner\n' > "$D/.claude/lgtmgate/nick.md"
BEFORE=$(sums "$D")
node "$IS" --root "$D" > "$TMP/out" 2>"$TMP/err"; rc=$?
AFTER=$(sums "$D")
PROP=$(node "$IS" --root "$D" --propose --plugin-version 9.9.9)
if [ "$rc" -eq 0 ] && [ "$(jx "$TMP/out" 'j.created.length')" = "0" ] && [ "$(jx "$TMP/out" 'j.kept.length')" = "6" ] && [ "$BEFORE" = "$AFTER" ] && printf '%s\n' "$PROP" | grep -qF 'keep .claude/lgtmgate/nick.md (edited by the owner, never touched)'; then ok "relaunch-modified-stub-0-writes"; else bad "relaunch-modified-stub-0-writes (rc=$rc)"; fi

# relaunch-missing-stub-recreated-only-that
rm -f "$D/.claude/lgtmgate/theo.md"
node "$IS" --root "$D" > "$TMP/out" 2>"$TMP/err"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(jx "$TMP/out" 'j.created.join()')" = ".claude/lgtmgate/theo.md" ] && [ "$(cat "$D/.claude/lgtmgate/nick.md")" = "rules of the owner" ]; then ok "relaunch-missing-stub-recreated-only-that"; else bad "relaunch-missing-stub-recreated-only-that (rc=$rc) $(cat "$TMP/out")"; fi

# symlink-stub-kept
D=$(tree -)
mkdir -p "$D/.claude/lgtmgate" "$TMP/elsewhere"
ln -s "$TMP/elsewhere/target.md" "$D/.claude/lgtmgate/sam.md"
node "$IS" --root "$D" > "$TMP/out" 2>"$TMP/err"; rc=$?
if [ "$rc" -eq 0 ] && [ -L "$D/.claude/lgtmgate/sam.md" ] && [ ! -e "$TMP/elsewhere/target.md" ] && [ "$(jx "$TMP/out" 'j.kept.join()')" = ".claude/lgtmgate/sam.md" ]; then ok "symlink-stub-kept"; else bad "symlink-stub-kept (rc=$rc) $(cat "$TMP/out")"; fi

# detect-mono-stack
D=$(tree mono-stack)
node "$IS" --root "$D" --detect > "$TMP/out" 2>"$TMP/err"
if [ "$(jx "$TMP/out" 'j.stacks.join()')" = "node" ] && [ "$(jx "$TMP/out" 'j.laneCandidates.length')" = "0" ] && [ "$(jx "$TMP/out" 'j.projectAgents')" = "0" ]; then ok "detect-mono-stack"; else bad "detect-mono-stack $(cat "$TMP/out")"; fi

# detect-multi-stack
D=$(tree multi-stack)
node "$IS" --root "$D" --detect > "$TMP/out" 2>"$TMP/err"
if [ "$(jx "$TMP/out" 'j.stacks.join()')" = "node,python,xcode" ] && [ "$(jx "$TMP/out" 'j.laneCandidates.length')" = "3" ]; then ok "detect-multi-stack"; else bad "detect-multi-stack $(cat "$TMP/out")"; fi

# detect-business-agents-0-lane
D=$(tree business-agents)
node "$IS" --root "$D" --detect > "$TMP/out" 2>"$TMP/err"
if [ "$(jx "$TMP/out" 'j.stacks.join()')" = "node" ] && [ "$(jx "$TMP/out" 'j.projectAgents')" = "11" ] && [ "$(jx "$TMP/out" 'j.laneCandidates.length')" = "0" ]; then ok "detect-business-agents-0-lane"; else bad "detect-business-agents-0-lane $(cat "$TMP/out")"; fi

# proposal-equals-golden
D=$(tree mono-stack)
node "$IS" --root "$D" --propose --plugin-version 9.9.9 > "$TMP/proposal" 2>"$TMP/err"
if cmp -s "$TMP/proposal" "$ROOT/fixtures/specifics/init-golden/proposal.txt"; then ok "proposal-equals-golden"; else bad "proposal-equals-golden"; diff "$TMP/proposal" "$ROOT/fixtures/specifics/init-golden/proposal.txt" | head -n 10; fi

# stubs-inject-nothing: each stub passes the specifics content check, is empty once comments are stripped,
# and is not byte-identical to a file under templates/
if node -e '
const fs = require("fs"), path = require("path")
const { STUBS } = require(process.argv[1] + "/scripts/init-specifics.cjs")
const { checkContent } = require(process.argv[1] + "/scripts/agent-context.cjs")
const tpl = []
const walk = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name); if (e.isDirectory()) walk(p); else tpl.push(fs.readFileSync(p, "utf8")) } }
walk(path.join(process.argv[1], "templates"))
let bad = 0
for (const [n, t] of Object.entries(STUBS)) {
  if (checkContent(t).length) { console.error(n + ": content check"); bad++ }
  let prev, cur = t
  do { prev = cur; cur = cur.replace(/<!--[\s\S]*?-->/g, "") } while (cur !== prev)
  if (cur.trim() !== "") { console.error(n + ": not empty after comments"); bad++ }
  if (tpl.includes(t)) { console.error(n + ": identical to a template"); bad++ }
}
if (Object.keys(STUBS).length !== 6) bad++
process.exit(bad ? 1 : 0)' "$ROOT" 2>"$TMP/err"; then ok "stubs-inject-nothing"; else bad "stubs-inject-nothing $(cat "$TMP/err")"; fi

# nick-stub-build-test-tools
D=$(tree -)
node "$IS" --root "$D" > /dev/null 2>&1
if grep -q 'build/test tools' "$D/.claude/lgtmgate/nick.md"; then ok "nick-stub-build-test-tools"; else bad "nick-stub-build-test-tools"; fi

# guard-no-plugin-copy-fails-on-copy
G="$TMP/guard-copy"; mkdir -p "$G"
cp "$ROOT/templates/pr-acceptance.md" "$G/pr-acceptance.md"
GOUT=$(SPECIFICS_DIR="$G" bash "$ROOT/tests/templates/test-canonical-guards.sh" 2>&1 | grep 'no-plugin-copy-in-specifics')
G2="$TMP/guard-clean"; mkdir -p "$G2"; printf 'owner rules\n' > "$G2/nick.md"
GOUT2=$(SPECIFICS_DIR="$G2" bash "$ROOT/tests/templates/test-canonical-guards.sh" 2>&1 | grep 'no-plugin-copy-in-specifics')
if printf '%s\n' "$GOUT" | grep -q '^FAIL: no-plugin-copy-in-specifics' && printf '%s\n' "$GOUT2" | grep -q '^PASS: no-plugin-copy-in-specifics'; then ok "guard-no-plugin-copy-fails-on-copy"; else bad "guard-no-plugin-copy-fails-on-copy [$GOUT] [$GOUT2]"; fi

# inject-stub-hint: SessionStart stub
hint() { CLAUDE_PROJECT_DIR="$1" python3 "$ROOT/hooks/SessionStart/inject_stub.py" 2>/dev/null; }
H=$(tree -); mkdir -p "$H/.claude"
printf '{"projectSpecifics":".claude/lgtmgate"}\n' > "$H/.claude/pipeline.config.json"
OUT1=$(hint "$H")
mkdir -p "$H/.claude/lgtmgate"
OUT2=$(hint "$H")
: > "$H/.claude/lgtmgate/nick.md"
OUT3=$(hint "$H")
printf '{"projectSpecifics":"../escape"}\n' > "$H/.claude/pipeline.config.json"
OUT4=$(hint "$H")
printf '{"baseBranch":"main"}\n' > "$H/.claude/pipeline.config.json"
OUT5=$(hint "$H")
if printf '%s' "$OUT1" | grep -q 'holds no .md file' && printf '%s' "$OUT2" | grep -q 'holds no .md file' && ! printf '%s' "$OUT3" | grep -q 'holds no .md file' && ! printf '%s' "$OUT4" | grep -q 'holds no .md file' && ! printf '%s' "$OUT5" | grep -q 'holds no .md file' && printf '%s' "$OUT5" | grep -q 'config detected'; then ok "inject-stub-hint"; else bad "inject-stub-hint"; fi

# ---- lanes (#271): init --lanes and the lane hints of the SessionStart hook -----------------------------------
D=$(tree -)
node "$IS" --root "$D" --lanes ios,web > "$TMP/lout" 2>"$TMP/lerr"; rc=$?
N=$(ls "$D/.claude/lgtmgate" | wc -l | tr -d ' ')
if [ "$rc" = 0 ] && [ "$N" = 6 ] && [ "$(jx "$TMP/lout" 'j.created.length')" = 6 ] && [ "$(sed -n 1,2p "$D/.claude/lgtmgate/sam.ios.md" | tr '\n' ' ')" = "--- lane: ios " ] && [ "$(sed -n 2p "$D/.claude/lgtmgate/nick.web.md")" = "lane: web" ]; then ok "lanes-create: ios,web -> 6 lane files with the lane frontmatter"; else bad "lanes-create: rc=$rc files=$N $(head -c 200 "$TMP/lerr")"; fi
sums "$D" > "$TMP/s1"
node "$IS" --root "$D" --lanes ios,web > "$TMP/lout2" 2>/dev/null; sums "$D" > "$TMP/s2"
if [ "$(jx "$TMP/lout2" 'j.created.length')" = 0 ] && [ "$(jx "$TMP/lout2" 'j.kept.length')" = 6 ] && cmp -s "$TMP/s1" "$TMP/s2"; then ok "lanes-relaunch-0-writes: a second run creates nothing and keeps the files"; else bad "lanes-relaunch-0-writes"; fi
printf 'owner text\n' >> "$D/.claude/lgtmgate/sam.ios.md"
node "$IS" --root "$D" --lanes ios > /dev/null 2>&1
if grep -q 'owner text' "$D/.claude/lgtmgate/sam.ios.md"; then ok "lanes-owner-edit-kept: an edited lane file is never rewritten"; else bad "lanes-owner-edit-kept"; fi
node "$IS" --root "$D" --lanes 'iOS' > /dev/null 2>"$TMP/e1"; rc1=$?
node "$IS" --root "$D" --lanes 'a,../x' > /dev/null 2>"$TMP/e2"; rc2=$?
if [ "$rc1" = 2 ] && [ "$rc2" = 2 ]; then ok "lanes-bad-name-exit2"; else bad "lanes-bad-name-exit2: $rc1 $rc2"; fi
node "$IS" --root "$D" --detect > "$TMP/det" 2>/dev/null
if [ "$(jx "$TMP/det" 'j.laneFiles.length')" = 6 ] && [ "$(jx "$TMP/det" 'j.laneFiles.filter(f=>f.pristine).length')" = 5 ] && [ "$(jx "$TMP/det" 'j.laneFiles.find(f=>f.path.endsWith("sam.ios.md")).pristine')" = false ]; then ok "lanes-stub-pristine: --detect tells a pristine lane stub from an edited one"; else bad "lanes-stub-pristine: $(head -c 300 "$TMP/det")"; fi

# inject-stub-lane: the SessionStart hook reads the lane files
L=$(tree -); mkdir -p "$L/.claude/lgtmgate"
printf '{"projectSpecifics":".claude/lgtmgate"}\n' > "$L/.claude/pipeline.config.json"
printf -- '---\nlane: web\n---\nWEB rules.\n' > "$L/.claude/lgtmgate/sam.ios.md"
LH1=$(hint "$L")
if printf '%s' "$LH1" | grep -q 'contradicts the file name in sam.ios.md' && ! printf '%s' "$LH1" | grep -q 'declared but empty'; then ok "inject-stub-lane-contradiction: one line names the file"; else bad "inject-stub-lane-contradiction: $LH1"; fi
printf -- '---\nlane: ios\n---\n<!-- to complete -->\n' > "$L/.claude/lgtmgate/sam.ios.md"
node "$IS" --root "$L" --lanes web > /dev/null 2>&1
LH2=$(hint "$L")
if printf '%s' "$LH2" | grep -q 'lane declared but empty: ' && printf '%s' "$LH2" | grep -q 'sam.ios.md' && ! printf '%s' "$LH2" | grep -q 'contradicts'; then ok "inject-stub-lane-empty: a comment-only lane file gives one line"; else bad "inject-stub-lane-empty: $LH2"; fi
rm -f "$L/.claude/lgtmgate/"*.web.md
printf -- '---\nlane: ios\n---\nIOS rules.\n' > "$L/.claude/lgtmgate/sam.ios.md"
printf 'plain subject without frontmatter\n' > "$L/.claude/lgtmgate/nick.testing.md"
LH3=$(hint "$L")
if ! printf '%s' "$LH3" | grep -q 'contradicts' && ! printf '%s' "$LH3" | grep -q 'declared but empty' && printf '%s' "$LH3" | grep -q 'config detected'; then ok "inject-stub-lane-silent: consistent and filled lanes, and files without frontmatter, add no line"; else bad "inject-stub-lane-silent: $LH3"; fi

STATUS=ok; [ "$FAIL" -eq 0 ] || STATUS=fail
echo "[test-init-specifics] status=${STATUS} passed=${PASS} failed=${FAIL}"
[ "$FAIL" -eq 0 ]
