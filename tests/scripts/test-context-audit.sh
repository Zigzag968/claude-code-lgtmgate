#!/usr/bin/env bash
# Self-test of `scripts/runtime/context-audit.cjs` (#518): duplicates with their bytes, a role above the cap with its
# largest files, a near-identical pair, read-only behaviour, --help, bad ref, determinism, --json.
# A throwaway git repo is built under $TMPDIR with a pinned commit and origin/main at HEAD.
#   bash tests/scripts/test-context-audit.sh
# bash 3.2 compatible. Trailer: [test-context-audit] status=<ok|fail> passed=<n> failed=<n>
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
CA="$ROOT/scripts/runtime/context-audit.cjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

TMP="${TMPDIR:-/tmp}/context-audit-selftest.$$"; mkdir -p "$TMP"
R="$TMP/repo"
mkdir -p "$R/.claude/lgtmgate" "$R/rules"
git init -q "$R"
printf '{"baseBranch":"main","projectSpecifics":".claude/lgtmgate","agentContext":{"Sam":["rules/accept.md","rules/big.md"],"Nick":["rules/accept.md"],"Morgan":["rules/accept.md"]}}\n' > "$R/.claude/pipeline.config.json"
printf 'Sam keeps plans short.\n' > "$R/.claude/lgtmgate/sam.md"
{
  echo '# Acceptance rules'
  echo 'Every acceptance item carries one command that proves it.'
  echo 'Never tick a box without having seen the command output.'
} > "$R/rules/accept.md"
{
  echo '# Big rules'
  echo 'Always cite the file and the line of a claim you make.'
  echo ''
  echo '## When releasing a change'
  echo '1. Run the full test suite and read the trailer line.'
  echo '2. Bump the version file named by the release script.'
  echo '3. Open the pull request in draft and link the issue.'
  echo ''
  echo '## Filler'
  i=0
  while [ "$i" -lt 130 ]; do echo "Filler line number $i keeps this file well above the recommended role size."; i=$((i+1)); done
} > "$R/rules/big.md"
{
  echo '---'
  echo 'lane: ios'
  echo '---'
  echo '# iOS lane'
  echo 'Build with the simulator destination named in the project scheme.'
  echo 'Read the crash log before touching the code under test.'
  echo 'Keep every UI change behind the accessibility audit step.'
} > "$R/.claude/lgtmgate/nick.ios.md"
{
  echo '---'
  echo 'lane: ios'
  echo '---'
  echo '# iOS lane'
  echo 'Build with the simulator destination named in the project scheme.'
  echo 'Read the crash log before touching the code under test.'
  echo 'Keep every UI change behind the accessibility audit step.'
  echo 'Morgan also checks the screenshot.'
} > "$R/.claude/lgtmgate/morgan.ios.md"
git -C "$R" add -A
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com \
GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z' \
  git -C "$R" -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q -m fixture
git -C "$R" update-ref refs/remotes/origin/main HEAD

audit() { node "$CA" --root "$R" --ref origin/main "$@"; }
audit > "$TMP/out1.txt" 2> "$TMP/err1.txt"; rc=$?
[ "$rc" = 0 ] || { bad "audit exited $rc: $(head -c 300 "$TMP/err1.txt")"; }

ACCEPT_BYTES=$(wc -c < "$R/rules/accept.md" | tr -d ' ')
BIG_BYTES=$(wc -c < "$R/rules/big.md" | tr -d ' ')
SAVED=$((2 * ACCEPT_BYTES))

if grep -qF "  rules/accept.md  $ACCEPT_BYTES B  roles Morgan, Nick, Sam  copies 3  payload saved $SAVED B if moved to agentContext[\"*\"]" "$TMP/out1.txt"; then
  ok "file listed for three roles is reported as duplicated with its bytes"
else bad "duplicate line missing: $(cat "$TMP/out1.txt")"; fi

if grep -qE "^  Sam  [0-9]+ B  cap 6144  over by [0-9]+ B  largest: rules/big.md $BIG_BYTES B" "$TMP/out1.txt"; then
  ok "role above the cap is reported with its size and its largest files"
else bad "oversize line missing: $(cat "$TMP/out1.txt")"; fi

if grep -qE '^  \.claude/lgtmgate/morgan\.ios\.md ~ \.claude/lgtmgate/nick\.ios\.md  similarity 0\.[0-9]{2}  shared lines [0-9]+ B' "$TMP/out1.txt"; then
  ok "near-identical pair is reported"
else bad "near-identical line missing: $(cat "$TMP/out1.txt")"; fi

if grep -q '^  rules/big.md#When releasing a change  [0-9]* B  procedure' "$TMP/out1.txt" && grep -q 'pointer: - When releasing a change: see rules/big.md#when-releasing-a-change' "$TMP/out1.txt"; then
  ok "numbered-steps section is labelled procedure with a pointer"
else bad "advisory label missing: $(cat "$TMP/out1.txt")"; fi

if [ -z "$(git -C "$R" status --porcelain)" ] && [ ! -e "$R/.claude/pipeline.config.local.json" ]; then
  ok "read-only, git status --porcelain is empty and no local config is created"
else bad "audit wrote into the repo: $(git -C "$R" status --porcelain)"; fi

node "$CA" --help > "$TMP/help.txt" 2>&1
if grep -q 'deterministic' "$TMP/help.txt" && grep -q 'advisory' "$TMP/help.txt" && grep -q -- '--json' "$TMP/help.txt"; then ok "--help states inputs, outputs, deterministic and advisory checks"; else bad "--help incomplete"; fi

node "$CA" --root "$R" --ref origin/nope > "$TMP/o" 2> "$TMP/e"; rc=$?
if [ "$rc" = 2 ] && [ ! -s "$TMP/o" ]; then ok "bad ref exits 2 with empty stdout"; else bad "bad ref exit $rc"; fi

audit > "$TMP/out2.txt" 2> /dev/null
if cmp -s "$TMP/out1.txt" "$TMP/out2.txt"; then ok "two runs give byte-identical output"; else bad "output differs between runs"; fi

audit --json > "$TMP/out.json" 2> /dev/null
if node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.exit(Array.isArray(j.duplicates.entries)&&j.sizes.roles.length>0?0:1)' "$TMP/out.json"; then ok "--json parses and carries the report"; else bad "--json invalid"; fi

find "$TMP" -mindepth 1 -delete 2>/dev/null; rmdir "$TMP" 2>/dev/null
if [ "$FAIL" = 0 ]; then S=ok; else S=fail; fi
echo "[test-context-audit] status=$S passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
