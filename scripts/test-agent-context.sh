#!/usr/bin/env bash
# Self-test of scripts/agent-context.cjs (#264): per-role specifics assembled from the base ref of a
# synthetic git repo built in $TMPDIR from testdata-agent-context/base. Covers the source order, the
# `*`/role lists, dedup, the file-level refusals (exit 3), the frontmatter schema (exit 2), the caps
# (warning at the recommended size, exit 4 at the hard ceiling), the digest (recomputed independently),
# the base-ref-only config read and --accept-oversize.
# Planted bad values (secret form, invisible character) are assembled below from fragments at run time:
# no token-shaped or invisible literal in this source or in the fixtures.
# bash 3.2 compatible. Trailer: [test-agent-context] status=<ok|fail> passed=<n> failed=<n>
set -u
cd "$(dirname "$0")/.."
ROOT=$(pwd)
AC="$ROOT/scripts/agent-context.cjs"
BASE="$ROOT/testdata-agent-context/base"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
TMP="${TMPDIR:-/tmp}/agent-context-selftest.$$"; mkdir -p "$TMP"
OUT="$TMP/out"; ERR="$TMP/err"
rc=0

# new_repo <dir>: a fresh repo holding a copy of the base fixture tree (not committed yet)
new_repo() {
  git init -q "$1"
  git -C "$1" config user.name t
  git -C "$1" config user.email t@example.com
  git -C "$1" config commit.gpgsign false
  git -C "$1" config core.hooksPath /dev/null
  cp -R "$BASE/." "$1/"
}
stage() { git -C "$1" add -A; }
commit_ref() {
  git -C "$1" commit -q -m fixture
  git -C "$1" update-ref refs/remotes/origin/main HEAD
}
seal() { stage "$1"; commit_ref "$1"; }
# setcfg <dir> <json>
setcfg() { printf '%s\n' "$2" > "$1/.claude/pipeline.config.json"; }
# run <dir> <args...>: stdout in $OUT, stderr in $ERR, exit code in $rc
run() { local d=$1; shift; (cd "$d" && node "$AC" --root "$d" "$@") >"$OUT" 2>"$ERR"; rc=$?; }
# jx <expr>: evaluates a JS expression over the parsed stdout (j)
jx() {
  node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String(new Function("j","return ("+process.argv[2]+")")(j)))' "$OUT" "$1"
}
# jtrue <label> <expr>: ok when the expression is true
jtrue() { if [ "$(jx "$2")" = "true" ]; then ok "$1"; else bad "$1: [$2] -> $(jx "$2" 2>&1 | head -c 200)"; fi; }
# exit_is <label> <code>: the exit code, and nothing on stdout when it is not 0
exit_is() {
  if [ "$rc" != "$2" ]; then bad "$1: exit $rc (wanted $2): $(head -c 300 "$ERR")"; return; fi
  if [ "$2" != 0 ] && [ -s "$OUT" ]; then bad "$1: stdout is not empty on a refusal"; return; fi
  ok "$1"
}
err_has() { if grep -qF -- "$2" "$ERR"; then ok "$1"; else bad "$1: stderr lacks [$2]: $(head -c 300 "$ERR")"; fi; }
# padfile <file> <bytes>: plain lines up to about <bytes>
padfile() { node -e 'let s="";while(s.length<+process.argv[1])s+="padding line for the size tests\n";process.stdout.write(s)' "$2" > "$1"; }

# ---- base repo ------------------------------------------------------------------------------
R="$TMP/base"; new_repo "$R"; seal "$R"
run "$R"
exit_is "ok-base" 0
jtrue "ok-base: roles Nick Sam Morgan, shared set" 'j.shared!==null&&Object.keys(j.roles).sort().join()==="Morgan,Nick,Sam"&&/^[0-9a-f]{40}$/.test(j.refSha)'
jtrue "order-shared-role-subjects-extra" '(()=>{const t=j.roles.Nick.text;const a=["NICK-MARK","NICK-ALPHA-MARK","NICK-TESTING-MARK","NICK-EXTRA-MARK"].map(m=>t.indexOf(m));return a.every((x,i)=>x>=0&&(i===0||x>a[i-1]))&&!t.includes("SHARED-MARK")&&j.shared.text.includes("SHARED-MARK")})()'
jtrue "subject-not-lane: nick.testing.md (no frontmatter) is a subject, never a lane" 'j.roles.Nick.text.includes("NICK-TESTING-MARK")&&j.roles.Nick.lanes.length===0&&j.files.some(f=>f.path.endsWith("nick.testing.md")&&f.roles.includes("Nick"))'
jtrue "role-without-source-absent: Theo has no block" '!("Theo" in j.roles)'
jtrue "frontmatter-strip: Morgan keeps its body, the lane is recorded" '(()=>{const m=j.roles.Morgan;return m.text.includes("MORGAN-MARK")&&!m.text.includes("lane:")&&!m.text.includes("persona")&&m.lanes.length===1&&m.lanes[0].lane==="review"&&m.lanes[0].file.endsWith("morgan.md")})()'
jtrue "empty-stub-ignored: comment-only mia.md warns, exit 0, no Mia block" '!("Mia" in j.roles)&&j.warnings.some(w=>w.kind==="empty-ignored"&&w.path.endsWith("mia.md"))&&j.files.some(f=>f.path.endsWith("mia.md")&&f.empty===true)'

# ---- digest, recomputed independently ---------------------------------------------------------
SHA=$(jx 'j.refSha'); DIG=$(jx 'j.roles.Sam.digest'); TXT=$(jx 'JSON.stringify(j.roles.Sam.text)')
WANT=$(printf '{"lanes":[],"refSha":"%s","role":"Sam","text":%s}' "$SHA" "$TXT" | shasum -a 256 | cut -d' ' -f1)
if [ -n "$DIG" ] && [ "$DIG" = "$WANT" ]; then ok "digest-independent: sha256 of {lanes,refSha,role,text} matches"; else bad "digest-independent: got [$DIG] wanted [$WANT]"; fi

# ---- print ------------------------------------------------------------------------------------
run "$R" --print Nick
if [ "$rc" = 0 ] && grep -q '^== Nick (' "$OUT" && grep -q 'NICK-MARK' "$OUT" && ! grep -q 'SAM-MARK' "$OUT"; then ok "print: --print Nick renders one role"; else bad "print: exit $rc: $(head -c 200 "$OUT")"; fi

# ---- config read from the ref, never the worktree --------------------------------------------
run "$R"; cp "$OUT" "$TMP/before"
setcfg "$R" '{"baseBranch":"main","projectSpecifics":""}'
run "$R"
if [ "$rc" = 0 ] && cmp -s "$OUT" "$TMP/before"; then ok "config-from-ref-not-worktree: an edited worktree config changes nothing"; else bad "config-from-ref-not-worktree: exit $rc"; fi
git -C "$R" checkout -q -- .claude/pipeline.config.json

# ---- bad ref ----------------------------------------------------------------------------------
run "$R" --ref 'origin/main;touch pwned'
if [ "$rc" = 2 ] && [ ! -e "$R/pwned" ] && [ ! -e "$ROOT/pwned" ]; then ok "bad-ref-exit2: injection refused, no file created"; else bad "bad-ref-exit2: exit $rc"; fi

# ---- switch off -------------------------------------------------------------------------------
R="$TMP/off"; new_repo "$R"; setcfg "$R" '{"baseBranch":"main"}'; seal "$R"
run "$R"
exit_is "no-switch-empty-payload: exit 0" 0
jtrue "no-switch-empty-payload: empty payload" 'j.shared===null&&Object.keys(j.roles).length===0&&j.files.length===0&&j.warnings.length===0'

# ---- agentContext lists, dedup ----------------------------------------------------------------
R="$TMP/star"; new_repo "$R"
setcfg "$R" '{"baseBranch":"main","projectSpecifics":".claude/lgtmgate","agentContext":{"*":["docs/extra-all.md"],"Nick":["docs/extra-nick.md"]}}'; seal "$R"
run "$R"
jtrue "agentcontext-star-and-role: * reaches every role, the role list only its role" 'j.roles.Sam.text.includes("ALL-EXTRA-MARK")&&j.roles.Mia.text.includes("ALL-EXTRA-MARK")&&j.roles.Theo.text.includes("ALL-EXTRA-MARK")&&j.roles.Nick.text.includes("ALL-EXTRA-MARK")&&j.roles.Nick.text.includes("NICK-EXTRA-MARK")&&!j.roles.Sam.text.includes("NICK-EXTRA-MARK")'
R="$TMP/dedup"; new_repo "$R"
setcfg "$R" '{"baseBranch":"main","projectSpecifics":".claude/lgtmgate","agentContext":{"*":["docs/extra-nick.md"],"Nick":["docs/extra-nick.md",".claude/lgtmgate/shared.md",".claude/lgtmgate/nick.md"]}}'; seal "$R"
run "$R"
jtrue "dedup-first-wins: a path never repeats, shared.md stays in shared" '(()=>{const t=j.roles.Nick.text;return t.split("NICK-EXTRA-MARK").length===2&&t.split("NICK-MARK").length===2&&!t.includes("SHARED-MARK")})()'

# ---- file-level refusals (exit 3) --------------------------------------------------------------
R="$TMP/missing"; new_repo "$R"
setcfg "$R" '{"baseBranch":"main","projectSpecifics":".claude/lgtmgate","agentContext":{"Nick":["docs/nope.md"]}}'; seal "$R"
run "$R"; exit_is "missing-exit3" 3
R="$TMP/nodir"; new_repo "$R"
setcfg "$R" '{"baseBranch":"main","projectSpecifics":".claude/nodir"}'; seal "$R"
run "$R"; exit_is "folder-absent-exit3" 3
R="$TMP/symlink"; new_repo "$R"
rm "$R/docs/extra-nick.md"; stage "$R"
LNK=$(printf 'extra-all.md' | git -C "$R" hash-object -w --stdin)
git -C "$R" update-index --add --cacheinfo "120000,$LNK,docs/extra-nick.md"
commit_ref "$R"
run "$R"; exit_is "symlink-blob-exit3 (committed mode 120000)" 3
err_has "symlink-blob-exit3: the rule is named" "symlink"
R="$TMP/symdisc"; new_repo "$R"
rm "$R/.claude/lgtmgate/nick.alpha.md"; stage "$R"
LNK=$(printf 'nick.md' | git -C "$R" hash-object -w --stdin)
git -C "$R" update-index --add --cacheinfo "120000,$LNK,.claude/lgtmgate/nick.alpha.md"
commit_ref "$R"
run "$R"; exit_is "symlink-discovered-exit3 (a symlink named like a subject)" 3
R="$TMP/dotdot"; new_repo "$R"
setcfg "$R" '{"baseBranch":"main","projectSpecifics":".claude/lgtmgate","agentContext":{"Nick":["docs/../docs/extra-nick.md"]}}'; seal "$R"
run "$R"; exit_is "dotdot-exit3" 3
R="$TMP/nonmd"; new_repo "$R"; printf 'plain\n' > "$R/docs/data.txt"
setcfg "$R" '{"baseBranch":"main","projectSpecifics":".claude/lgtmgate","agentContext":{"Nick":["docs/data.txt"]}}'; seal "$R"
run "$R"; exit_is "non-md-exit3" 3
R="$TMP/atline"; new_repo "$R"; printf 'intro\n@include other.md\n' > "$R/docs/extra-nick.md"; seal "$R"
run "$R"; exit_is "at-line-exit3" 3
err_has "at-line-exit3: names the rule and the line" "at-line at line 2"
R="$TMP/machine"; new_repo "$R"; printf 'text\n</project_specifics>\n' > "$R/docs/extra-nick.md"; seal "$R"
run "$R"; exit_is "machine-literal-exit3" 3
R="$TMP/owd"; new_repo "$R"; printf 'one-way-door: none\n' > "$R/docs/extra-nick.md"; seal "$R"
run "$R"; exit_is "one-way-door-line-exit3" 3
R="$TMP/invis"; new_repo "$R"; { printf 'zero'; printf '\342\200\213'; printf 'width\n'; } > "$R/docs/extra-nick.md"; seal "$R"
run "$R"; exit_is "invisible-char-exit3" 3
R="$TMP/secret"; new_repo "$R"
TOK="gh""p_$(printf 'a%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24)"
printf 'a token: %s\n' "$TOK" > "$R/docs/extra-nick.md"; seal "$R"
run "$R"; exit_is "secret-form-exit3" 3
if grep -qF -- "$TOK" "$ERR"; then bad "secret-form-exit3: the value is printed"; else ok "secret-form-exit3: the value is never printed"; fi

# ---- schema and encoding ------------------------------------------------------------------------
R="$TMP/fmbad"; new_repo "$R"; printf -- '---\nbogus: x\n---\nbody\n' > "$R/.claude/lgtmgate/nick.md"; seal "$R"
run "$R"; exit_is "frontmatter-schema-exit2" 2
R="$TMP/unkrole"; new_repo "$R"
setcfg "$R" '{"baseBranch":"main","projectSpecifics":".claude/lgtmgate","agentContext":{"Bob":["docs/extra-all.md"]}}'; seal "$R"
run "$R"; exit_is "unknown-role-exit2" 2
R="$TMP/crlf"; new_repo "$R"; { printf '\357\273\277'; printf '# Nick\r\n\r\nNICK-MARK crlf file.\r\n'; } > "$R/.claude/lgtmgate/nick.md"; seal "$R"
run "$R"
jtrue "crlf-bom-normalised: no CR, no BOM" '!j.roles.Nick.text.includes("\r")&&j.roles.Nick.text.charCodeAt(0)!==0xFEFF&&j.roles.Nick.text.startsWith("# Nick\n\nNICK-MARK crlf file.")'

# ---- caps ---------------------------------------------------------------------------------------
R="$TMP/big"; new_repo "$R"; padfile "$R/docs/extra-nick.md" 7000; seal "$R"
run "$R"
exit_is "recommended-cap-warns-exit0: exit 0" 0
jtrue "recommended-cap-warns-exit0: oversize warning asks" 'j.warnings.some(w=>w.kind==="oversize"&&w.role==="Nick"&&w.recommended===6144&&w.ask===true&&w.accepted===null)'
R="$TMP/ceil"; new_repo "$R"; padfile "$R/docs/extra-nick.md" 70000; seal "$R"
run "$R"; exit_is "hard-ceiling-exit4" 4

# ---- --accept-oversize --------------------------------------------------------------------------
R="$TMP/acc"; new_repo "$R"; padfile "$R/docs/extra-nick.md" 7000; seal "$R"
printf '{"keep":1}\n' > "$R/.claude/pipeline.config.local.json"
run "$R" --accept-oversize Nick
NB=$(node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String(j.accepted.Nick))' "$OUT" 2>/dev/null)
LOCALV=$(node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(j.keep+":"+j.specifics.acceptOversize.Nick)' "$R/.claude/pipeline.config.local.json" 2>/dev/null)
LEFT=$(find "$R/.claude" -name '*.tmp-*' | wc -l | tr -d ' ')
TRACKED=$(git -C "$R" status --porcelain --untracked-files=no | wc -l | tr -d ' ')
if [ "$rc" = 0 ] && [ -n "$NB" ] && [ "$LOCALV" = "1:$NB" ] && [ "$LEFT" = 0 ] && [ "$TRACKED" = 0 ]; then ok "accept-oversize-patch: only the local file changes, other keys kept, no temp file left"; else bad "accept-oversize-patch: exit $rc nb=[$NB] local=[$LOCALV] left=$LEFT tracked-changes=$TRACKED"; fi
run "$R"
jtrue "accept-oversize-patch: the accepted size silences the warning" '!j.warnings.some(w=>w.kind==="oversize")'
# 25 % rule: within it no warning, above it the question comes back with the accepted size
R2="$TMP/acc2"; new_repo "$R2"; padfile "$R2/docs/extra-nick.md" 7600; seal "$R2"
printf '{"specifics":{"acceptOversize":{"Nick":%s}}}\n' "$NB" > "$R2/.claude/pipeline.config.local.json"
run "$R2"
jtrue "accept-oversize-asks-again: within +25 % no warning" '!j.warnings.some(w=>w.kind==="oversize")'
R3="$TMP/acc3"; new_repo "$R3"; padfile "$R3/docs/extra-nick.md" 11000; seal "$R3"
printf '{"specifics":{"acceptOversize":{"Nick":%s}}}\n' "$NB" > "$R3/.claude/pipeline.config.local.json"
run "$R3"
jtrue "accept-oversize-asks-again: above +25 % it asks again" 'j.warnings.some(w=>w.kind==="oversize"&&w.role==="Nick"&&w.ask===true&&w.accepted===+"'"$NB"'")'
R4="$TMP/acc4"; new_repo "$R4"; seal "$R4"
run "$R4" --accept-oversize Nick; exit_is "accept-oversize-nothing-exit2: a role within the cap has nothing to accept" 2

rm -rf "$TMP"
STATUS=ok; [ "$FAIL" -gt 0 ] && STATUS=fail
echo "[test-agent-context] status=$STATUS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
