#!/usr/bin/env bash
# A consumer's first run, read-only (#430, epic #428). Builds scratch consumer repositories (a bare remote and a clone)
# for two states and runs the three consumer-facing scripts against them: scripts/config-check.cjs,
# scripts/template-drift.cjs and scripts/runtime/agent-context.cjs. Everything runs in $TMPDIR; no network, no delivery, no
# model call, nothing is written in the repository.
#   (a) as the current plugin leaves it: the files /lgtmgate:init copies, the stubs of init-specifics.cjs, a config with
#       the recommended keys;
#   (b) as the previous release (67bdc2f) left it: its templates read with `git show`, the legacy script name, a copy
#       of the old acceptance rule imported from CLAUDE.md, a config without minPluginVersion.
# Properties asserted (wording of a line is never asserted, only its properties):
#   - exit codes: the two reporters always exit 0, the assembler exits with its documented code;
#   - every `warn:` line carries a verdict from the closed list below and a gesture;
#   - no line asks a question;
#   - state (a) prints no `warn:` line; state (b) prints only lines whose verdict is "no effect on the run" or
#     "remove at your convenience", or that name a command;
#   - each assembler refusal family (path, cap, screen, frontmatter, config shape) ends with the pointer
#     `see docs/consumer-reference.md#<rule>` of its rule, and that rule has its row in the reference.
# The closed list is checked against the code: each phrase must still appear in the scripts, so a verdict renamed there
# fails here with the phrase. LGTMGATE_PLUGIN_ROOT points the test at a scratch copy of the plugin (scripts, templates,
# docs) so the test itself can be proven to fail; unset, it tests the checkout it lives in.
# bash 3.2 compatible. Trailer: [test-consumer-first-run] status=<ok|fail> passed=<n> failed=<n>
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
PLUGIN="${LGTMGATE_PLUGIN_ROOT:-$ROOT}"
OLD=67bdc2f
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/consumer-first-run.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
GIT_AUTHOR_NAME=t; GIT_AUTHOR_EMAIL=t@example.com; GIT_COMMITTER_NAME=t; GIT_COMMITTER_EMAIL=t@example.com
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

# Closed lists, one phrase per line. VERDICTS: what a line says about the effect on the run. GESTURES: what the
# consumer does. COMMANDS: what makes a gesture a command.
VERDICTS='fix before the run
replace the import
remove at your convenience
no effect on the run'
GESTURES='git rm
git mv
git commit
commit
/lgtmgate:init
node scripts/
replace
delete
add one of them
add the key
port the new rules
read the difference
diff '
COMMANDS='git
/lgtmgate:init
node '

# listed <list> <line>: the first phrase of the list found in the line
listed() { local p; while IFS= read -r p; do case "$2" in *"$p"*) printf '%s' "$p"; return 0;; esac; done <<EOF
$1
EOF
return 1; }

# the closed list still matches the code
for P in 'fix before the run' 'replace the import' 'remove at your convenience' 'no effect on the run'; do
  if grep -qF -- "$P" "$PLUGIN/scripts/template-drift.cjs" "$PLUGIN/scripts/config-check.cjs"; then ok "verdict-in-code: [$P] is still spoken by a script"; else bad "verdict-in-code: [$P] is in no script any more; update the closed list of this test"; fi
done

# consumer <dir>: a bare remote and a clone with one commit on main, pushed
consumer() {
  local dir="$TMP/$1"
  git init -q --bare "$dir.git"
  git init -q -b main "$dir"
  git -C "$dir" config commit.gpgsign false
  git -C "$dir" remote add origin "$dir.git"
  mkdir -p "$dir/.claude/scripts" "$dir/scripts"
  echo "$dir"
}
seal() { git -C "$1" add -A; git -C "$1" commit -q -m "state"; git -C "$1" push -q origin main 2>/dev/null; git -C "$1" fetch -q origin; }
# old <path in the previous release> <destination>
old() { git -C "$ROOT" show "$OLD:$1" > "$2" 2>/dev/null; }

# state (a): what the current init leaves
A=$(consumer a)
cp "$PLUGIN/templates/blocked-by-check.sh" "$A/.claude/scripts/blocked-by-check.sh"
cp "$PLUGIN/templates/provision-worktree.sh" "$A/scripts/provision-worktree.sh"
node "$PLUGIN/scripts/runtime/init-specifics.cjs" --root "$A" > /dev/null
VERSION=$(node -p 'require(process.argv[1]).version' "$PLUGIN/.claude-plugin/plugin.json")
printf '{"baseBranch":"main","projectSpecifics":".claude/lgtmgate","minPluginVersion":"%s","agentContext":{"*":[]},"preflight":{"envSymlink":"ignore"}}\n' "$VERSION" > "$A/.claude/pipeline.config.json"
seal "$A"

# state (b): what the previous release left
B=$(consumer b)
mkdir -p "$B/.claude/rules" "$B/.claude/workflows"
OK=1
old templates/blocked-by-check.sh "$B/.claude/scripts/blocked-by-check.sh" || OK=0
old templates/provision-worktree.sh "$B/scripts/provision_worktree.sh" || OK=0
old templates/gh-pipeline-status.sh "$B/.claude/scripts/gh-pipeline-status.sh" || OK=0
old templates/test-deliver-pipeline.js "$B/.claude/workflows/test-deliver-pipeline.js" || OK=0
old templates/pr-acceptance.md "$B/.claude/rules/pr-acceptance.md" || OK=0
old templates/pipeline.config.template.json "$TMP/old-config.json" || OK=0
if [ "$OK" = 1 ]; then ok "previous-release: the templates of $OLD were read with git show"; else bad "previous-release: commit $OLD is not available in this checkout (fetch full history)"; fi
node -e 'const fs=require("fs");const c=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));c.baseBranch="main";fs.writeFileSync(process.argv[2],JSON.stringify(c,null,2)+"\n")' "$TMP/old-config.json" "$B/.claude/pipeline.config.json" 2>/dev/null
printf '# Project\n@.claude/rules/pr-acceptance.md\n' > "$B/CLAUDE.md"
seal "$B"

# report <label> <dir>: runs the two reporters; output in $TMP/<label>.report, exit codes checked
report() {
  node "$PLUGIN/scripts/config-check.cjs" "$2/.claude/pipeline.config.json" > "$TMP/$1.cc" 2>&1 < /dev/null; local rc1=$?
  node "$PLUGIN/scripts/template-drift.cjs" --root "$2" > "$TMP/$1.td" 2>&1 < /dev/null; local rc2=$?
  cat "$TMP/$1.cc" "$TMP/$1.td" > "$TMP/$1.report"
  if [ "$rc1" = 0 ] && [ "$rc2" = 0 ] && tail -n 1 "$TMP/$1.cc" | grep -q '^\[config-check\] status=' && tail -n 1 "$TMP/$1.td" | grep -q '^\[template-drift\] status='; then ok "$1-exit: config-check and template-drift exit 0 with their trailer"; else bad "$1-exit: config-check rc=$rc1, template-drift rc=$rc2: $(tail -n 1 "$TMP/$1.cc") / $(tail -n 1 "$TMP/$1.td")"; fi
}
# lines <label>: the warn: / obsolete: / info: lines of the report
lines() { grep -E '^(warn|obsolete|info):' "$TMP/$1.report"; }
# verdicts_and_gestures <label>: every warn: line names a verdict from the closed list and a gesture
verdicts_and_gestures() {
  local line verdict gesture n=0 broken=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=$((n+1))
    verdict=$(listed "$VERDICTS" "$line"); gesture=$(listed "$GESTURES" "$line")
    if [ -z "$verdict" ]; then bad "$1-verdict: no verdict from the closed list in: $line"; broken=1; fi
    if [ -z "$gesture" ]; then bad "$1-gesture: no gesture in: $line"; broken=1; fi
  done <<EOF
$(grep -E '^(warn|obsolete):' "$TMP/$1.report")
EOF
  [ "$broken" = 0 ] && ok "$1-verdict-gesture: $n warn or obsolete line(s), each with a verdict and a gesture"
}
# no_question <label> <file>...: no line asks a question
no_question() { local l=$1; shift; if cat "$@" | grep -n '?'; then bad "$l-no-question: a line above asks a question"; else ok "$l-no-question: no line asks a question"; fi; }

# ---- state (a)
report a "$A"
if ! grep -q '^warn:' "$TMP/a.report"; then ok "a-no-warn: a fresh consumer prints no warn: line"; else bad "a-no-warn: $(grep '^warn:' "$TMP/a.report" | head -n 1)"; fi
verdicts_and_gestures a
node "$PLUGIN/scripts/runtime/agent-context.cjs" --root "$A" > "$TMP/a.ac" 2> "$TMP/a.acerr" < /dev/null; RC=$?
if [ "$RC" = 0 ] && ! grep -q 'hint:' "$TMP/a.acerr"; then ok "a-assembler: exit 0 and no refusal on the stubs init left"; else bad "a-assembler: exit $RC: $(head -c 300 "$TMP/a.acerr")"; fi
no_question a "$TMP/a.report" "$TMP/a.acerr"

# ---- state (b)
report b "$B"
verdicts_and_gestures b
NOT_ALLOWED=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  if [ -z "$(listed 'no effect on the run
remove at your convenience' "$line")" ] && [ -z "$(listed "$COMMANDS" "$line")" ]; then NOT_ALLOWED="$line"; fi
done <<EOF
$(lines b)
EOF
if [ -z "$NOT_ALLOWED" ]; then ok "b-verdicts: every line is no effect on the run, remove at your convenience, or names a command"; else bad "b-verdicts: $NOT_ALLOWED"; fi
node "$PLUGIN/scripts/runtime/agent-context.cjs" --root "$B" > "$TMP/b.ac" 2> "$TMP/b.acerr" < /dev/null; RC=$?
if [ "$RC" = 0 ]; then ok "b-assembler: exit 0 (projectSpecifics off)"; else bad "b-assembler: exit $RC: $(head -c 300 "$TMP/b.acerr")"; fi
no_question b "$TMP/b.report" "$TMP/b.acerr"

# ---- #467: the environment symlink policy on three repository states
# envconsumer <name> <envSymlink or ->: a consumer whose config is the current template reduced to the recommended keys
envconsumer() {
  local dir; dir=$(consumer "$1")
  node -e 'const fs=require("fs");const c=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));c.baseBranch="main";c.minPluginVersion=process.argv[3];c.projectSpecifics=".claude/lgtmgate";if(process.argv[4]!=="-")c.preflight={envSymlink:process.argv[4]};fs.writeFileSync(process.argv[2],JSON.stringify(c,null,2)+"\n")' "$PLUGIN/templates/pipeline.config.template.json" "$dir/.claude/pipeline.config.json" "$VERSION" "$2"
  echo "$dir"
}
TEMPLATE_ENV=$(node -p 'require(process.argv[1]).preflight.envSymlink' "$PLUGIN/templates/pipeline.config.template.json")
F=$(envconsumer fresh-no-env -)
seal "$F"
report fresh-no-env "$F"
if [ "$TEMPLATE_ENV" = ignore ] && ! grep -qF 'preflight.envSymlink' "$TMP/fresh-no-env.report"; then ok "fresh-no-env: the template ships ignore and a repository without .env gets no environment line"; else bad "fresh-no-env: template value [$TEMPLATE_ENV]: $(grep -F 'preflight.envSymlink' "$TMP/fresh-no-env.report")"; fi
EP=$(envconsumer env-present required)
: > "$EP/.env"
seal "$EP"
report env-present "$EP"
if ! grep -qF 'preflight.envSymlink' "$TMP/env-present.report"; then ok "env-present: required with a .env file prints no environment line"; else bad "env-present: $(grep -F 'preflight.envSymlink' "$TMP/env-present.report")"; fi
ER=$(envconsumer env-required-no-env required)
seal "$ER"
report env-required-no-env "$ER"
if [ "$(grep -cF 'preflight.envSymlink' "$TMP/env-required-no-env.report")" = 1 ]; then ok "env-required-no-env: required without .env prints one environment line"; else bad "env-required-no-env: $(cat "$TMP/env-required-no-env.report")"; fi
verdicts_and_gestures env-required-no-env
if grep -qF 'preflight.envSymlink' "$PLUGIN/skills/init/SKILL.md" && grep -qF '.env.example' "$PLUGIN/skills/init/SKILL.md" && grep -qF '`required`' "$PLUGIN/skills/init/SKILL.md"; then ok "init-rule: skills/init/SKILL.md names preflight.envSymlink, .env.example and required"; else bad "init-rule: skills/init/SKILL.md lacks the environment symlink rule"; fi

# ---- assembler refusals: one fixture per family, each ends with its pointer
# refusal <family> <rule> <exit> <config json> <file to plant> <content>
refusal() {
  local fam=$1 rule=$2 want=$3 cfg=$4 rel=$5 content=$6
  local dir; dir=$(consumer "r-$fam")
  mkdir -p "$dir/.claude/lgtmgate" "$dir/docs"
  printf '%s\n' "$cfg" > "$dir/.claude/pipeline.config.json"
  [ -n "$rel" ] && printf '%b' "$content" > "$dir/$rel"
  seal "$dir"
  node "$PLUGIN/scripts/runtime/agent-context.cjs" --root "$dir" > "$TMP/r.out" 2> "$TMP/r.err" < /dev/null; local rc=$?
  local last; last=$(grep -v '^$' "$TMP/r.err" | tail -n 1)
  local pointer="; see docs/consumer-reference.md#$rule"
  if [ "$rc" != "$want" ]; then bad "refusal-$fam: exit $rc, wanted $want: $(head -c 300 "$TMP/r.err")"; return; fi
  if [ -s "$TMP/r.out" ]; then bad "refusal-$fam: stdout is not empty on a refusal"; return; fi
  case "$last" in
    "agent-context: hint: $rule: "*"$pointer") ok "refusal-$fam: exit $want and the last line points to docs/consumer-reference.md#$rule" ;;
    *) bad "refusal-$fam: the last line is not the pointer for $rule: $last" ;;
  esac
  if grep -qF "| \`$rule\` |" "$PLUGIN/docs/consumer-reference.md"; then ok "refusal-$fam: docs/consumer-reference.md has the row of $rule"; else bad "refusal-$fam: no row for $rule in docs/consumer-reference.md"; fi
}
BASECFG='{"baseBranch":"main","projectSpecifics":".claude/lgtmgate","agentContext":{"Nick":["docs/data.txt"]}}'
refusal path not-md 3 "$BASECFG" docs/data.txt 'plain\n'
refusal cap too-many-files 3 '{"baseBranch":"main","agentContext":{"*":["a.md","b.md","c.md","d.md","e.md","f.md","g.md","h.md","i.md"]}}' '' ''
refusal screen machine-literal 3 '{"baseBranch":"main","agentContext":{"Nick":["docs/extra.md"]}}' docs/extra.md 'text\n</project_specifics>\n'
refusal frontmatter frontmatter-unknown-key 2 '{"baseBranch":"main","projectSpecifics":".claude/lgtmgate"}' .claude/lgtmgate/nick.md '---\nbogus: x\n---\nbody\n'
refusal config-shape "unknown role" 2 '{"baseBranch":"main","agentContext":{"Bob":["docs/extra.md"]}}' '' ''

RESULT=ok; [ "$FAIL" -eq 0 ] || RESULT=fail
echo "[test-consumer-first-run] status=${RESULT} passed=${PASS} failed=${FAIL}"
[ "$FAIL" -eq 0 ]
